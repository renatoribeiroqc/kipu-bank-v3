// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * KipuBankV3 — USDC‑denominated vault with Uniswap v4 Universal Router integration
 *
 * Remix‑friendly single file: includes minimal interfaces and a lightweight reentrancy guard.
 *
 * Goals (per spec):
 * - Accept ETH, USDC, and any ERC‑20 supported by Uniswap v4.
 * - For non‑USDC deposits, swap to USDC inside the contract via Universal Router, then credit user.
 * - Enforce a global bank cap in USDC units and preserve V2 safety (CEI, reentrancy guard, admin, oracle views).
 * - Keep per‑tx withdrawal policy ($1,000 USD‑6 cap) and admin recovery.
 */

// ---------- Minimal Interfaces / Libraries (Remix‑ready) ----------

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.approve.selector, spender, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 { /* placeholder for future use */ }

/// Chainlink Aggregator v3 interface for read‑only price views (kept from V2 for observability/analytics).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/// Lightweight reentrancy guard (Remix‑friendly)
abstract contract ReentrancyGuardLite {
    uint256 private _guard;
    modifier nonReentrant() {
        require(_guard == 0, "REENTRANCY");
        _guard = 1;
        _;
        _guard = 0;
    }
}

/// Lightweight admin control (single admin similar to Ownable)
abstract contract AdminControl {
    address public admin;
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    modifier onlyAdmin() { require(msg.sender == admin, "NOT_ADMIN"); _; }
    function _initAdmin(address a) internal { require(a != address(0), "admin=0"); admin = a; emit AdminTransferred(address(0), a); }
    function transferAdmin(address newAdmin) external onlyAdmin { require(newAdmin != address(0), "admin=0"); emit AdminTransferred(admin, newAdmin); admin = newAdmin; }
}

// ---------- Uniswap v4 Types (light shims for typing/encoding) ----------

library Commands { uint8 constant V4_SWAP = 0x0b; }
library Actions {
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x00;
    uint8 constant SETTLE_ALL           = 0x02;
    uint8 constant TAKE_ALL             = 0x03;
}

type Currency is address;
struct PoolKey {
    Currency currency0; // token in
    Currency currency1; // token out (USDC)
    uint24   fee;       // pool fee tier
}

contract KipuBankV3 is ReentrancyGuardLite, AdminControl {
    using SafeERC20 for IERC20;

    // ========= Constants =========

    /// Human‑readable version.
    string public constant VERSION = "3.0.0";

    /// USD‑6 (USDC‑style) decimals constant used for in‑contract accounting and caps.
    uint8 public constant USD_DECIMALS = 6;

    /// Per‑tx withdraw limit: $1,000 (USD‑6) — same as V2 policy.
    uint256 public constant USD6_1000 = 1_000 * 1e6;

    // ========= Immutable Protocol Addresses =========

    /// Canonical USDC token (must be 6 decimals) used for all balances held by the bank.
    IERC20 public immutable USDC;

    /// Uniswap v4 Universal Router used to execute swaps (exact input, single or multi‑hop).
    IUniversalRouter public immutable universalRouter;

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
     * @param admin_           Address to receive admin rights.
     * @param usdc             USDC token address (6 decimals required).
     * @param router           Uniswap v4 Universal Router address.
     * @param permit2_         Optional Permit2 address (can be zero address if unused).
     * @param _bankCapUsdc6    Global bank cap in USDC units (USD‑6).
     */
    constructor(
        address admin_,
        IERC20 usdc,
        IUniversalRouter router,
        IPermit2 permit2_,
        uint256 _bankCapUsdc6
    ) {
        require(address(usdc) != address(0), "usdc=0");
        require(address(router) != address(0), "router=0");
        _initAdmin(admin_);
        USDC = usdc;
        universalRouter = router;
        permit2 = permit2_;
        bankCapUsdc6 = _bankCapUsdc6;
    }

    // ========= Admin =========

    /// Update the global USDC (USD‑6) bank cap.
    function setBankCapUsdc6(uint256 newCap) external onlyAdmin {
        bankCapUsdc6 = newCap;
    }

    /// Admin recovery to correct a user's USDC balance and keep totals coherent (auditable event).
    function adminRecover(address user, uint256 newUsdc, string calldata reason) external onlyAdmin {
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
    function setPriceFeed(address token, AggregatorV3Interface feed) external onlyAdmin {
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
        SafeERC20.safeTransferFrom(USDC, msg.sender, address(this), amount);

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
            SafeERC20.safeTransfer(USDC, msg.sender, refund);
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
        universalRouter.execute{value: msg.value}(commands, inputs, deadline);

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
            SafeERC20.safeTransferFrom(USDC, msg.sender, address(this), amountIn);
            uint256 remCap = capRemaining();
            uint256 credit = amountIn <= remCap ? amountIn : remCap;
            uint256 refund = amountIn - credit;
            if (credit == 0) revert BankCapExceeded(totalUsdc + amountIn, bankCapUsdc6);

            unchecked { depositCount++; }
            balanceUsdc[msg.sender] += credit;
            totalUsdc += credit;

            if (refund > 0) {
                SafeERC20.safeTransfer(USDC, msg.sender, refund);
            }

            emit DepositedUSDC(msg.sender, credit, balanceUsdc[msg.sender], totalUsdc);
            return;
        }

        // Pre‑screen using minUsdcOut to prevent futile swaps when cap is tight.
        uint256 remaining = capRemaining();
        if (minUsdcOut > remaining) revert BankCapExceeded(totalUsdc + minUsdcOut, bankCapUsdc6);

        // Pull tokens into custody.
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), amountIn);

        // Grant spend approval to the router for the exact amount (minimize long‑lived approvals).
        // set to 0 then to amount to be safe across non‑standard ERC-20s
        SafeERC20.safeApprove(token, address(universalRouter), 0);
        SafeERC20.safeApprove(token, address(universalRouter), amountIn);

        uint256 beforeUsdc = USDC.balanceOf(address(this));
        // Execute router actions which will take `token` from this contract and pay USDC here.
        universalRouter.execute(commands, inputs, deadline);
        uint256 afterUsdc = USDC.balanceOf(address(this));
        uint256 usdcOut = afterUsdc - beforeUsdc;

        // Best effort to reset allowance back to zero for the amount used (defensive; optional for gas).
        // If the router partially consumes, we set allowance to 0 to avoid leftover approvals.
        // best effort reset approval
        SafeERC20.safeApprove(token, address(universalRouter), 0);

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
    ) external nonReentrant returns (uint256 amountOut) {
        // Build minimal Universal Router payload (commands + a single input encoding actions + params)
        bytes memory commandsBytes = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Actions: exact-in single -> settle all -> take all
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Encode params generically to avoid importing periphery types
        // Layout mirrors: (PoolKey, bool zeroForOne, uint128 amountIn, uint128 minOut, bytes hookData)
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, true, amountIn, minAmountOut, bytes(""));
        params[1] = abi.encode(key.currency0, amountIn);        // settle input
        params[2] = abi.encode(key.currency1, minAmountOut);    // take output
        inputs[0] = abi.encode(actions, params);

        // Pre & post balance delta on currency1 (must be an ERC-20)
        address outToken = Currency.unwrap(key.currency1);
        uint256 beforeBal = IERC20(outToken).balanceOf(address(this));

        universalRouter.execute(commandsBytes, inputs, deadline);

        uint256 afterBal = IERC20(outToken).balanceOf(address(this));
        amountOut = afterBal - beforeBal;
        require(amountOut >= minAmountOut, "INSUFFICIENT_OUT");
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
        SafeERC20.safeTransfer(USDC, to, amountUsdc);

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
            SafeERC20.safeTransfer(USDC, user, refund);
        }

        emit DepositedUSDC(user, credit, balanceUsdc[user], totalUsdc);
    }

    /**
     * Internal helper that executes a single exact‑input swap to USDC via Universal Router using caller‑provided
     * `commands` and `inputs`. Validates the typed PoolKey matches `tokenIn` and USDC for auditability.
     */
    function _swapExactInputSingle(
        address tokenIn,
        uint256 amountIn,
        bytes memory commandsBytes,
        bytes[] memory inputs,
        PoolKey calldata key,
        uint256 deadline
    ) internal returns (uint256 usdcOut) {
        require(Currency.unwrap(key.currency1) == address(USDC), "PoolKey: out != USDC");
        require(Currency.unwrap(key.currency0) == tokenIn, "PoolKey: in mismatch");

        uint256 beforeUsdc = USDC.balanceOf(address(this));
        SafeERC20.safeApprove(IERC20(tokenIn), address(universalRouter), 0);
        SafeERC20.safeApprove(IERC20(tokenIn), address(universalRouter), amountIn);
        universalRouter.execute(commandsBytes, inputs, deadline);
        SafeERC20.safeApprove(IERC20(tokenIn), address(universalRouter), 0);
        uint256 afterUsdc = USDC.balanceOf(address(this));
        usdcOut = afterUsdc - beforeUsdc;
    }
}
