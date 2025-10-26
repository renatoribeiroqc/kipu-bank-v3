// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "remix_tests.sol";      // Remix test framework
import "remix_accounts.sol";   // Provides test accounts

import "../contracts/KipuBank.sol";

// ---------- Mocks ----------

contract MockAggregator is AggregatorV3Interface {
    uint8 public override decimals;
    int256 private _answer;

    constructor(uint8 _decimals, int256 initialAnswer) {
        decimals = _decimals;
        _answer = initialAnswer;
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

contract MockERC20 is IERC20, IERC20Metadata {
    string public name;
    string public symbol;
    uint8 public override decimals;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n; symbol = s; decimals = d;
    }

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

// ---------- Tests ----------

contract KipuBankTest {
    KipuBank bank;
    MockAggregator ethFeed;
    address acc0;
    address acc1;

    MockERC20 usdt;           // 6 decimals
    MockAggregator usdtFeed;  // USDT/USD ~ 1.0

    function beforeEach() public {
        // Set up test accounts
        acc0 = TestsAccounts.getAccount(0);
        acc1 = TestsAccounts.getAccount(1);

        // Price feeds (8 decimals is common in Chainlink)
        ethFeed  = new MockAggregator(8, 2000e8); // 1 ETH = $2000.00
        usdtFeed = new MockAggregator(8, 1e8);    // 1 USDT = $1.00

        // Bank cap = $5,000.00 (USD-6)
        bank = new KipuBank(acc0, 5_000_000, AggregatorV3Interface(address(ethFeed)));

        // Deploy mock USDT (6 decimals) and enable it
        usdt = new MockERC20("MockUSDT", "USDT", 6);
        bank.setTokenConfig(address(usdt), true, 6, AggregatorV3Interface(address(usdtFeed)));
    }

    function testConstructorAndConfig() public {
        Assert.equal(bank.VERSION(), "2.0.0", "version mismatch");
        (bool enabled, uint8 decs, AggregatorV3Interface feed) = bank.tokenConfig(bank.ETH_ADDRESS());
        Assert.ok(enabled, "ETH should be enabled");
        Assert.equal(uint256(decs), uint256(18), "ETH decimals 18");
        Assert.equal(address(feed), address(ethFeed), "ETH feed mismatch");
        Assert.equal(bank.bankCapUsd6(), uint256(5_000_000), "cap mismatch");
    }

    /// #value: 1000000000000000000   (1 ETH)
    function testDepositETHWithinCap() public payable {
        uint256 beforeTotal = bank.totalUsd6();
        bank.depositETH{value: msg.value}(); // 1 ETH @ $2000 => 2,000,000 usd6
        uint256 afterTotal = bank.totalUsd6();
        Assert.equal(afterTotal, beforeTotal + 2_000_000, "totalUsd6 should add $2000.000");

        uint256 my = bank.balanceOf(bank.ETH_ADDRESS(), address(this));
        Assert.equal(my, msg.value, "my ETH vault bal should increase by 1 ETH");
    }

    function testDepositERC20WithinCap() public {
        // Mint 1500 USDT (6 decimals) to this test contract
        usdt.mint(address(this), 1_500_000); // == $1,500.000 usd6

        // Approve and deposit 1500 USDT
        usdt.approve(address(bank), 1_500_000);
        bank.depositERC20(address(usdt), 1_500_000);

        Assert.equal(bank.totalUsd6(), uint256(1_500_000), "totalUsd6 should be $1,500.000 after USDT deposit");
        Assert.equal(bank.balanceOf(address(usdt), address(this)), uint256(1_500_000), "user USDT vault bal should be 1500");
    }

    function testCapEnforcement() public {
        // Try to exceed cap with ETH after depositing 3,500 USDT
        usdt.mint(address(this), 3_500_000);
        usdt.approve(address(bank), 3_500_000);
        bank.depositERC20(address(usdt), 3_500_000); // $3,500

        // Now try 1 ETH ($2,000) -> would exceed $5,000 cap => revert
        (bool ok, ) = address(bank).call{value: 1 ether}(abi.encodeWithSelector(bank.depositETH.selector));
        Assert.ok(!ok, "depositETH should revert due to cap");
    }

    function testWithdrawERC20() public {
        // Deposit 1000 USDT, then withdraw 400
        usdt.mint(address(this), 1_000_000);
        usdt.approve(address(bank), 1_000_000);
        bank.depositERC20(address(usdt), 1_000_000);

        bank.withdraw(address(usdt), 400_000, address(this)); // 400 USDT
        Assert.equal(usdt.balanceOf(address(this)), uint256(400_000), "should receive 400 USDT back");
        Assert.equal(bank.balanceOf(address(usdt), address(this)), uint256(600_000), "vault bal should be 600 USDT");
    }

    function testWithdrawETH() public {
        // Deposit 0.3 ETH then withdraw 0.1
        bank.depositETH{value: 0.3 ether}();
        bank.withdraw(bank.ETH_ADDRESS(), 0.1 ether, address(this));
        Assert.equal(bank.balanceOf(bank.ETH_ADDRESS(), address(this)), uint256(0.2 ether), "ETH vault bal 0.2");
    }
}
