// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * KipuBankV3 — USDC‑denominated vault with Uniswap v4 Universal Router integration
 *
 * Goals (per spec):
 * - Accept ETH, USDC, and any ERC‑20 supported by Uniswap v4.
 * - For non‑USDC deposits, swap to USDC inside the contract via Universal Router, then credit user.
 * - Enforce a global bank cap in USDC units and preserve V2 safety (CEI, reentrancy guard, roles, oracle views).
 * - Keep per‑tx withdrawal policy ($1,000 USD‑6 cap) and admin recovery.
 *
 * Notes on integration:
 * - This contract owns tokens during swaps. It approves the Universal Router to spend inputs and receives USDC out.
 * - We expose generic `commands` and `inputs` parameters so callers can encode Uniswap v4 router actions precisely
 *   (single‑hop or multi‑hop). This avoids coupling to a specific helper library while remaining fully programmatic.
 * - For convenience and auditability, we strictly account in USDC (6 decimals). The bank cap is enforced on USDC units.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap v4 and Universal Router (per Quickstart docs)
import { UniversalRouter } from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

using StateLibrary for IPoolManager;

/// Chainlink Aggregator v3 interface for read‑only price views (kept from V2 for observability/analytics).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========= Constants =========

    /// Human‑readable version.
    string public constant VERSION = "3.0.0";

    /// USD‑6 (USDC‑style) decimals constant used for in‑contract accounting and caps.
    uint8 public constant USD_DECIMALS = 6;

    /// Per‑tx withdraw limit: $1,000 (USD‑6) — same as V2 policy.
    uint256 public constant USD6_1000 = 1_000 * 1e6;

    /// Role allowed to configure caps and operational parameters.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ========= Immutable Protocol Addresses =========

    /// Canonical USDC token (must be 6 decimals) used for all balances held by the bank.
    IERC20 public immutable USDC;

    /// Uniswap v4 Universal Router used to execute swaps (exact input, single or multi‑hop).
    UniversalRouter public immutable router;

    /// Optional Permit2 instance for future permit‑based deposits (not required for basic flow).
    IPermit2 public immutable permit2;

    // ========= Storage =========

    /// Global bank cap in USD‑6 (i.e., USDC units). Total USDC held must not exceed this.
    uint256 public bankCapUsdc6;

    /// Total USDC held by the vault (sum of all user balances), in 6 decimals.
    uint256 public totalUsdc;

    /// Per‑user USDC balances (in 6 decimals).
    mapping(address => uint256) public balanceUsdc;

    /// Global counters for observability (kept from V2 style).
    uint256 public depositCount;
    uint256 public withdrawalCount;

    // ========= Events =========

    /// Emitted after a successful deposit credit (post any swap), with final USDC amount credited.
    event DepositedUSDC(address indexed account, uint256 usdcAmount, uint256 newUserBalance, uint256 newTotalUsdc);

    /// Emitted on withdrawal of USDC.
    event WithdrawnUSDC(address indexed account, address indexed to, uint256 usdcAmount, uint256 newUserBalance, uint256 newTotalUsdc);

    /// Emitted on admin balance correction.
    event AdminRecover(address indexed user, uint256 oldUsdc, uint256 newUsdc, string reason);

    /// Emitted when swap executed through the router. Provides raw in/out for traceability.
    event SwappedToUSDC(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcOut);

    // ========= Errors =========

    error AmountZero();
    error BankCapExceeded(uint256 attemptedUsdc, uint256 capUsdc);
    error InsufficientBalance(uint256 requested, uint256 available);
    error WithdrawLimitPerTx(uint256 amount, uint256 limit);
    error NegativePrice(address token);
    error StalePrice(address token);

    // ========= Constructor =========

    /**
     * @param admin            Address to receive DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
     * @param usdc             USDC token address (6 decimals required).
     * @param router           Uniswap v4 Universal Router address.
     * @param permit2_         Optional Permit2 address (can be zero address if unused).
     * @param _bankCapUsdc6    Global bank cap in USDC units (USD‑6).
     */
    constructor(
        address admin,
        IERC20 usdc,
        UniversalRouter router_,
        IPermit2 permit2_,
        uint256 _bankCapUsdc6
    ) {
        require(admin != address(0), "admin=0");
        require(address(usdc) != address(0), "usdc=0");
        require(address(router_) != address(0), "router=0");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        USDC = usdc;
        router = router_;
        permit2 = permit2_;
        bankCapUsdc6 = _bankCapUsdc6;
    }

    // ========= Admin =========

    /// Update the global USDC (USD‑6) bank cap.
    function setBankCapUsdc6(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        bankCapUsdc6 = newCap;
    }

    /// Admin recovery to correct a user's USDC balance and keep totals coherent (auditable event).
    function adminRecover(address user, uint256 newUsdc, string calldata reason) external onlyRole(ADMIN_ROLE) {
        uint256 old = balanceUsdc[user];
        if (old == newUsdc) return;

        // Adjust totalUsdc by removing old and adding new, with basic saturation safety.
        if (old > totalUsdc) totalUsdc = newUsdc; else totalUsdc = totalUsdc - old + newUsdc;
        balanceUsdc[user] = newUsdc;

        emit AdminRecover(user, old, newUsdc, reason);
    }

    // ========= Views (optional helpers retained for analytics/UX) =========

    /// Returns current cap remaining (USDC units) without considering slippage.
    function capRemaining() public view returns (uint256) {
        return bankCapUsdc6 > totalUsdc ? (bankCapUsdc6 - totalUsdc) : 0;
    }

    // ========= Optional Chainlink Views (preserved capability) =========

    /// Optional registry of TOKEN/USD feeds for UX analytics. Not used for cap enforcement.
    mapping(address => AggregatorV3Interface) public priceFeed;

    /// Admin: register or update a Chainlink Aggregator for a token.
    function setPriceFeed(address token, AggregatorV3Interface feed) external onlyRole(ADMIN_ROLE) {
        priceFeed[token] = feed;
    }

    /// Quote a token amount to USD‑6 using latestRoundData() with hygiene checks (answeredInRound and 1h staleness).
    function quoteToUsd6(address token, uint256 amount) external view returns (uint256 usd6) {
        AggregatorV3Interface feed = priceFeed[token];
        require(address(feed) != address(0), "no feed");
        (uint80 rid, int256 answer,, uint256 updatedAt, uint80 ansRid) = feed.latestRoundData();
        if (answer <= 0) revert NegativePrice(token);
        if (ansRid < rid) revert StalePrice(token);
        if (block.timestamp - updatedAt > 1 hours) revert StalePrice(token);
        uint8 fd = feed.decimals();
        // usd6 = amount * price * 10^6 / 10^fd / tokenDecimals — callers should provide token‑native units.
        // For analytics only; exact token decimals not known here, so expose price*amount in feed terms, scaled to 6.
        // If you need precise normalization, add token decimals to the registry as in V2.
        uint256 num = amount * uint256(answer) * (10 ** USD_DECIMALS);
        uint256 den = (10 ** fd);
        usd6 = num / den;
    }

    // ========= Deposits =========

    /**
     * Direct USDC deposit. Credits user up to cap; returns any excess to sender.
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();

        // Pull USDC into this contract first (CEI: state updated only after custody confirmed).
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        // Enforce bank cap. Credit up to remaining and refund any excess immediately.
        uint256 remaining = capRemaining();
        uint256 credit = amount <= remaining ? amount : remaining;
        uint256 refund = amount - credit;
        if (credit == 0) revert BankCapExceeded(totalUsdc + amount, bankCapUsdc6);

        // Effects
        unchecked { depositCount++; }
        balanceUsdc[msg.sender] += credit;
        totalUsdc += credit;

        // Refund excess amount directly to the depositor (if any).
        if (refund > 0) {
            USDC.safeTransfer(msg.sender, refund);
        }

        emit DepositedUSDC(msg.sender, credit, balanceUsdc[msg.sender], totalUsdc);
    }

    /**
     * Deposit ETH and swap to USDC via Universal Router.
     *
     * @param commands     Router command bytes (e.g., single or multi‑hop exact‑input swap). Built off‑chain or by helper.
     * @param inputs       Router inputs matching `commands` layout.
     * @param minUsdcOut   Caller‑provided slippage guard; if out < minUsdcOut, the call should revert via router.
     *
     * Security: The router executes against tokens owned by this contract. We measure USDC delta out and apply cap.
     */
    function depositETH(bytes calldata commands, bytes[] calldata inputs, uint256 minUsdcOut, uint256 deadline)
        external
        payable
        nonReentrant
    {
        if (msg.value == 0) revert AmountZero();

        // Pre‑screen using minUsdcOut to fail fast when user intent would exceed cap even at minimum execution.
        uint256 remaining = capRemaining();
        if (minUsdcOut > remaining) revert BankCapExceeded(totalUsdc + minUsdcOut, bankCapUsdc6);

        uint256 beforeBal = USDC.balanceOf(address(this));

        // Execute router swap. Router consumes msg.value as ETH input and returns USDC to this contract.
        router.execute{value: msg.value}(commands, inputs, deadline);

        uint256 afterBal = USDC.balanceOf(address(this));
        uint256 usdcOut = afterBal - beforeBal;
        emit SwappedToUSDC(msg.sender, address(0), msg.value, usdcOut);

        _creditWithCapAndRefund(msg.sender, usdcOut);
    }


    /**
     * Deposit an arbitrary ERC‑20 token and swap to USDC via Universal Router.
     *
     * @param token        ERC‑20 token to deposit.
     * @param amountIn     Token amount to pull from sender.
     * @param commands     Router command bytes (e.g., exact‑input route to USDC).
     * @param inputs       Router inputs matching the command.
     * @param minUsdcOut   Caller slippage guard; also used for pre‑screening against cap.
     *
     * Process:
     * 1) Pull tokens from the user into this contract.
     * 2) Approve router to spend `amountIn` (set approval only as needed to minimize gas/attack surface).
     * 3) Execute router. Measure USDC delta, enforce cap, credit user, refund any excess USDC above cap.
     */
    function depositArbitraryToken(
        IERC20 token,
        uint256 amountIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 minUsdcOut,
        uint256 deadline
    ) external nonReentrant {
        if (amountIn == 0) revert AmountZero();

        // Direct USDC path: pull and credit here (can't call external nonReentrant function internally).
        if (token == USDC) {
            USDC.safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 remCap = capRemaining();
            uint256 credit = amountIn <= remCap ? amountIn : remCap;
            uint256 refund = amountIn - credit;
            if (credit == 0) revert BankCapExceeded(totalUsdc + amountIn, bankCapUsdc6);

            unchecked { depositCount++; }
            balanceUsdc[msg.sender] += credit;
            totalUsdc += credit;

            if (refund > 0) {
                USDC.safeTransfer(msg.sender, refund);
            }

            emit DepositedUSDC(msg.sender, credit, balanceUsdc[msg.sender], totalUsdc);
            return;
        }

        // Pre‑screen using minUsdcOut to prevent futile swaps when cap is tight.
        uint256 remaining = capRemaining();
        if (minUsdcOut > remaining) revert BankCapExceeded(totalUsdc + minUsdcOut, bankCapUsdc6);

        // Pull tokens into custody.
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        // Grant spend approval to the router for the exact amount (minimize long‑lived approvals).
        token.safeIncreaseAllowance(address(router), amountIn);

        uint256 beforeUsdc = USDC.balanceOf(address(this));
        // Execute router actions which will take `token` from this contract and pay USDC here.
        router.execute( commands, inputs, deadline );
        uint256 afterUsdc = USDC.balanceOf(address(this));
        uint256 usdcOut = afterUsdc - beforeUsdc;

        // Best effort to reset allowance back to zero for the amount used (defensive; optional for gas).
        // If the router partially consumes, we set allowance to 0 to avoid leftover approvals.
        token.forceApprove(address(router), 0);

        emit SwappedToUSDC(msg.sender, address(token), amountIn, usdcOut);

        _creditWithCapAndRefund(msg.sender, usdcOut);
    }

    
    /**
     * Example typed swap function following the Uniswap v4 Quickstart. It constructs a V4 swap (exact input, single)
     * using Commands and Actions, and executes via the Universal Router with a deadline. The function returns the
     * amount of `key.currency1` received by this contract.
     */
    function swapExactInputSingle(
        PoolKey calldata key,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        // Encode the Universal Router command for a v4 swap
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode the V4Router actions sequence: exact-in single, settle, then take output
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Prepare parameters matching the actions sequence
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true, // swap currency0 -> currency1; caller must set poolKey ordering accordingly
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, amountIn);        // settle input
        params[2] = abi.encode(key.currency1, minAmountOut);    // take output

        // Combine actions and params into inputs for the router
        inputs[0] = abi.encode(actions, params);

        // Execute the swap via the router
        router.execute(commands, inputs, deadline);

        // Verify and return the output amount (amount of currency1 received by this contract)
        amountOut = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }

    // ========= Withdrawals =========

    /**
     * Withdraw USDC to `to`, enforcing a $1,000 (USD‑6) per‑tx limit and sufficient balance.
     */
    function withdrawUSDC(uint256 amountUsdc, address to) external nonReentrant {
        if (amountUsdc == 0) revert AmountZero();
        if (amountUsdc > USD6_1000) revert WithdrawLimitPerTx(amountUsdc, USD6_1000);
        if (to == address(0)) to = msg.sender;

        uint256 bal = balanceUsdc[msg.sender];
        if (amountUsdc > bal) revert InsufficientBalance(amountUsdc, bal);

        // Effects
        unchecked { balanceUsdc[msg.sender] = bal - amountUsdc; }
        totalUsdc -= amountUsdc;
        unchecked { withdrawalCount++; }

        // Interactions
        USDC.safeTransfer(to, amountUsdc);

        emit WithdrawnUSDC(msg.sender, to, amountUsdc, balanceUsdc[msg.sender], totalUsdc);
    }

    // ========= Internal Helpers =========

    /// Credits `usdcOut` to `user` up to cap; refunds any excess USDC to the user immediately.
    function _creditWithCapAndRefund(address user, uint256 usdcOut) internal {
        // If no output (e.g., router reverted?), rely on router revert semantics; here we just short‑circuit.
        if (usdcOut == 0) return;

        uint256 remaining = capRemaining();
        uint256 credit = usdcOut <= remaining ? usdcOut : remaining;
        uint256 refund = usdcOut - credit;
        if (credit == 0) revert BankCapExceeded(totalUsdc + usdcOut, bankCapUsdc6);

        // Effects
        unchecked { depositCount++; }
        balanceUsdc[user] += credit;
        totalUsdc += credit;

        // Interactions: refund any over‑cap amount back to the user in USDC.
        if (refund > 0) {
            USDC.safeTransfer(user, refund);
        }

        emit DepositedUSDC(user, credit, balanceUsdc[user], totalUsdc);
    }

    // ========= Uniswap v4 Types + Helper =========

    /// Uniswap v4 `Currency` newtype (address wrapper). We use it for typed PoolKey declarations.
    type Currency is address;

    /// Minimal v4 PoolKey type used for validation/documentation in the internal swap helper.
    struct PoolKey {
        Currency currencyIn;   // token in (ERC‑20) or WETH for ETH routes
        Currency currencyOut;  // token out (USDC)
        uint24 fee;            // pool fee tier
    }

    /**
     * Internal helper that executes a single exact‑input swap to USDC via Universal Router using caller‑provided
     * `commands` and `inputs`. Validates the typed PoolKey matches `tokenIn` and USDC for auditability.
     * This function centralizes approval/execute/measure‑delta patterns and ensures consistent min‑out + cap handling upstream.
     */
    function _swapExactInputSingle(
        address tokenIn,
        uint256 amountIn,
        uint256 /* minUsdcOut (enforced within encoded inputs) */,
        bytes memory commands,
        bytes[] memory inputs,
        PoolKey calldata key,
        uint256 deadline
    ) internal returns (uint256 usdcOut) {
        // Validate that the typed PoolKey corresponds to the intended in/out assets.
        require(Currency.unwrap(key.currencyOut) == address(USDC), "PoolKey: out != USDC");
        require(Currency.unwrap(key.currencyIn) == tokenIn, "PoolKey: in mismatch");

        uint256 beforeUsdc = USDC.balanceOf(address(this));
        IERC20(tokenIn).safeIncreaseAllowance(address(router), amountIn);
        router.execute(commands, inputs, deadline);
        IERC20(tokenIn).forceApprove(address(router), 0);
        uint256 afterUsdc = USDC.balanceOf(address(this));
        usdcOut = afterUsdc - beforeUsdc;
    }
}
