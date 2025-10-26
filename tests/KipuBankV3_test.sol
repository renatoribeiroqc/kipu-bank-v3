// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "remix_tests.sol";      // Remix test framework
import "remix_accounts.sol";   // Provides test accounts

import "../contracts/KipuBankV3.sol";

// ---------- Mocks ----------

contract MockAggregator is AggregatorV3Interface {
    uint8 public override decimals;
    int256 private _answer;

    constructor(uint8 _decimals, int256 initialAnswer) {
        decimals = _decimals;
        _answer = initialAnswer;
    }

    function setAnswer(int256 a) external { _answer = a; }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 6;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// Mock Universal Router that credits USDC to the calling contract when execute is invoked.
contract MockUniversalRouter is IUniversalRouter {
    IERC20 public immutable usdc;
    uint256 public usdcOutNext; // amount to credit on next execute

    constructor(IERC20 _usdc) { usdc = _usdc; }

    function setUsdcOutNext(uint256 amt) external { usdcOutNext = amt; }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable override {
        // Simulate a swap by minting or transferring USDC to the caller (bank contract)
        // Our MockERC20 exposes mint, but IERC20 doesn't. Use low-level call to mint.
        (bool ok,) = address(usdc).call(abi.encodeWithSignature("mint(address,uint256)", msg.sender, usdcOutNext));
        require(ok, "mint fail");
        usdcOutNext = 0;
    }
}

// ---------- Tests ----------

contract KipuBankV3Test {
    KipuBankV3 bank;
    MockERC20 usdc;               // 6 decimals USDC mock
    MockUniversalRouter router;   // mock router
    address admin;
    address user;

    function beforeEach() public {
        admin = TestsAccounts.getAccount(0);
        user  = TestsAccounts.getAccount(1);

        usdc = new MockERC20("MockUSDC", "USDC");
        router = new MockUniversalRouter(IERC20(address(usdc)));

        // bankCapUsdc6 = $5,000.000
        bank = new KipuBankV3(admin, IERC20(address(usdc)), IUniversalRouter(address(router)), IPermit2(address(0)), 5_000_000);
    }

    function testDepositUSDCWithinAndRefundOverCap() public {
        // Mint 1.5k USDC to user and approve bank
        usdc.mint(user, 1_500_000);
        // act as user via low-level call pattern (simulate approve + deposit)
        // In Remix tests, msg.sender is this test contract; emulate user by transferring to self and approving
        // For simplicity, mint to this contract and act as depositor.
        usdc.mint(address(this), 1_500_000);
        usdc.approve(address(bank), 1_500_000);

        // Reduce cap to 1,000.000 to force refund
        bank.setBankCapUsdc6(1_000_000);
        bank.depositUSDC(1_500_000);

        Assert.equal(bank.totalUsdc(), uint256(1_000_000), "totalUsdc should be at cap");
        Assert.equal(bank.balanceUsdc(address(this)), uint256(1_000_000), "user credited up to cap");
        Assert.equal(usdc.balanceOf(address(this)), uint256(500_000), "excess refunded to depositor");
    }

    /// #value: 1000000000000000 (0.001 ETH) — value unused in mock but exercises payable
    function testDepositETHViaRouterCreditsUSDC() public payable {
        // Set router to credit 600 USDC
        router.setUsdcOutNext(600_000);

        uint256 before = bank.totalUsdc();
        bank.depositETH{value: msg.value}(hex"0b", new bytes[](0), 500_000, block.timestamp + 300);
        uint256 afterBal = bank.totalUsdc();
        Assert.equal(afterBal, before + 600_000, "ETH swap should credit USDC delta");
        Assert.equal(bank.balanceUsdc(address(this)), uint256(600_000), "user balance updated");
    }

    function testDepositArbitraryTokenSwapAndRefund() public {
        // Create arbitrary token (non-USDC)
        MockERC20 token = new MockERC20("MockT", "TKN");

        // Mint to depositor and approve bank to pull
        token.mint(address(this), 1_000_000);
        token.approve(address(bank), 1_000_000);

        // Set router to credit 1,200 USDC, but cap remaining is 1,000 -> expect refund 200
        bank.setBankCapUsdc6(1_000_000);
        router.setUsdcOutNext(1_200_000);

        bank.depositArbitraryToken(IERC20(address(token)), 1_000_000, hex"0b", new bytes[](0), 800_000, block.timestamp + 300);
        Assert.equal(bank.totalUsdc(), uint256(1_000_000), "totalUsdc at cap");
        Assert.equal(bank.balanceUsdc(address(this)), uint256(1_000_000), "credited up to cap");
        Assert.equal(usdc.balanceOf(address(this)), uint256(200_000), "over-cap refund in USDC");
    }

    function testWithdrawUSDC_WithLimit() public {
        // Seed bank/user with 2,000 USDC via direct deposit
        usdc.mint(address(this), 2_000_000);
        usdc.approve(address(bank), 2_000_000);
        bank.depositUSDC(2_000_000);

        // Withdraw within limit
        bank.withdrawUSDC(900_000, address(this));
        Assert.equal(usdc.balanceOf(address(this)), uint256(900_000), "received 900 USDC");

        // Exceed per-tx limit (1,000,000)
        (bool ok, ) = address(bank).call(abi.encodeWithSelector(bank.withdrawUSDC.selector, 1_500_000, address(this)));
        Assert.ok(!ok, "withdraw over $1k should revert");
    }

    function testAdminRecover_AdjustsTotals() public {
        // Deposit 500 USDC to user
        usdc.mint(address(this), 500_000);
        usdc.approve(address(bank), 500_000);
        bank.depositUSDC(500_000);

        // Admin corrects to 300 USDC
        bank.adminRecover(address(this), 300_000, "adj");
        Assert.equal(bank.balanceUsdc(address(this)), uint256(300_000), "user new bal 300");
        Assert.equal(bank.totalUsdc(), uint256(300_000), "totalUsdc coherent");
    }
}

