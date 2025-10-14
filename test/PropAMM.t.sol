// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PropAMM.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20Burnable {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock GlobalStorage for testing
contract MockGlobalStorage is IGlobalStorage {
    struct StorageValue {
        bytes32 value;
        uint64 blockTimestamp;
        uint64 blockNumber;
    }

    mapping(address => mapping(bytes32 => StorageValue)) private storage_;

    function set(bytes32 key, bytes32 value) external {
        storage_[msg.sender][key] =
            StorageValue({value: value, blockTimestamp: uint64(block.timestamp), blockNumber: uint64(block.number)});
    }

    function setBatch(bytes32[] calldata keys, bytes32[] calldata values) external {
        require(keys.length == values.length, "Length mismatch");
        for (uint256 i = 0; i < keys.length; i++) {
            storage_[msg.sender][keys[i]] = StorageValue({
                value: values[i],
                blockTimestamp: uint64(block.timestamp),
                blockNumber: uint64(block.number)
            });
        }
    }

    function get(address owner, bytes32 key) external view returns (bytes32 value) {
        return storage_[owner][key].value;
    }

    function getWithTimestamp(address owner, bytes32 key)
        external
        view
        returns (bytes32 value, uint64 blockTimestamp, uint64 blockNumber)
    {
        StorageValue memory sv = storage_[owner][key];
        return (sv.value, sv.blockTimestamp, sv.blockNumber);
    }
}

contract PropAMMTest is Test {
    PropAMM public amm;
    MockGlobalStorage public globalStorage;
    MockERC20 public weth;
    MockERC20 public usdc;

    address public owner = address(this);
    address public marketMaker = address(0x1);
    address public trader = address(0x2);

    bytes32 public wethUsdcPairId;

    // Constants
    uint256 constant WETH_DECIMALS = 18;
    uint256 constant USDC_DECIMALS = 6;
    uint256 constant INITIAL_WETH_LIQUIDITY = 100 * 10 ** WETH_DECIMALS; // 100 WETH
    uint256 constant INITIAL_USDC_LIQUIDITY = 400000 * 10 ** USDC_DECIMALS; // 400,000 USDC
    uint256 constant WETH_PRICE = 4000; // 4000 USDC per WETH

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock GlobalStorage
        globalStorage = new MockGlobalStorage();

        // Deploy PropAMM
        amm = new PropAMM(marketMaker, address(globalStorage));

        // Mint tokens to market maker for liquidity
        weth.mint(marketMaker, INITIAL_WETH_LIQUIDITY);
        usdc.mint(marketMaker, INITIAL_USDC_LIQUIDITY);

        // Mint tokens to trader for swaps
        weth.mint(trader, 10 * 10 ** WETH_DECIMALS); // 10 WETH
        usdc.mint(trader, 50000 * 10 ** USDC_DECIMALS); // 50,000 USDC
    }

    function test_CreatePair() public {
        vm.startPrank(marketMaker);

        // Create WETH-USDC pair
        // decimalsX (18) + xRetainDecimals (0) = decimalsY (6) + yRetainDecimals (12)
        // 18 + 0 = 6 + 12 = 18
        bytes32 pairId = amm.createPair(
            address(weth),
            address(usdc),
            100, // initial concentration
            0, // xRetainDecimals
            12 // yRetainDecimals
        );

        vm.stopPrank();

        // Verify pair exists
        PropAMM.TradingPair memory pair = amm.getPair(pairId);
        assertEq(address(pair.tokenX), address(weth));
        assertEq(address(pair.tokenY), address(usdc));
        assertTrue(pair.exists);
    }

    function test_SwapWETHForUSDC() public {
        // Setup: Create pair and add liquidity
        vm.startPrank(marketMaker);

        // Create WETH-USDC pair
        // decimalsX (18) + xRetainDecimals (0) = decimalsY (6) + yRetainDecimals (12)
        wethUsdcPairId = amm.createPair(
            address(weth),
            address(usdc),
            1, // low concentration for simpler curve
            0, // xRetainDecimals
            12 // yRetainDecimals
        );

        // Approve tokens for deposit
        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);

        // Deposit liquidity: 100 WETH and 400,000 USDC (price = 4000 USDC/WETH)
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        // Update parameters to set price to 4000 USDC per WETH
        // For small swaps: amountOut ≈ K / base^2 * amountIn
        // Where K = (targetX * concentration)^2 * multX / multY, base ≈ targetX * concentration
        // We have targetX = 100 * 10^18, concentration = 1
        // We want: 1 WETH (10^18) -> 4000 USDC (4000 * 10^6)
        // Solving: 4000 * 10^6 = K / (10^20)^2 * 10^18 => K = 4 * 10^31
        // K = (10^20)^2 * multX / multY => 4 * 10^31 = 10^40 * multX / multY
        // => multX / multY = 4 * 10^-9
        uint256 concentration = 1;
        uint256 multX = 4000; // Price ratio numerator
        uint256 multY = 10 ** 12; // Price ratio denominator (gives 4000/10^12 = 4*10^-9)

        amm.updateParameters(wethUsdcPairId, concentration, multX, multY);

        vm.stopPrank();

        // Trader swaps 1 WETH for USDC
        vm.startPrank(trader);

        uint256 amountWETHIn = 1 * 10 ** WETH_DECIMALS; // 1 WETH

        // Get quote for the swap
        uint256 quotedAmount = amm.quoteXtoY(wethUsdcPairId, amountWETHIn);

        // We expect close to 4000 USDC (with some slippage from the curve)
        uint256 expectedUSDCOut = 4000 * 10 ** USDC_DECIMALS; // 4000 USDC

        // Approve WETH for swap
        weth.approve(address(amm), amountWETHIn);

        // Record balances before swap
        uint256 traderWETHBefore = weth.balanceOf(trader);
        uint256 traderUSDCBefore = usdc.balanceOf(trader);

        // Perform swap with 1% slippage tolerance
        uint256 minUSDCOut = (expectedUSDCOut * 99) / 100;
        uint256 actualUSDCOut = amm.swapXtoY(wethUsdcPairId, amountWETHIn, minUSDCOut);

        // Record balances after swap
        uint256 traderWETHAfter = weth.balanceOf(trader);
        uint256 traderUSDCAfter = usdc.balanceOf(trader);

        // Verify balances changed correctly
        assertEq(traderWETHBefore - traderWETHAfter, amountWETHIn, "WETH not deducted correctly");
        assertEq(traderUSDCAfter - traderUSDCBefore, actualUSDCOut, "USDC not received correctly");
        assertEq(actualUSDCOut, quotedAmount, "Actual output doesn't match quote");

        // Verify we got approximately 4000 USDC (within 2% due to AMM curve slippage)
        assertGe(actualUSDCOut, (expectedUSDCOut * 98) / 100, "Should receive at least 98% of expected");
        assertLe(actualUSDCOut, (expectedUSDCOut * 102) / 100, "Should not receive more than 102% of expected");

        // Log the results
        emit log_named_uint("WETH Input", amountWETHIn);
        emit log_named_decimal_uint("WETH Input (human)", amountWETHIn, 18);
        emit log_named_uint("USDC Output", actualUSDCOut);
        emit log_named_decimal_uint("USDC Output (human)", actualUSDCOut, 6);

        // Calculate effective price
        uint256 effectivePrice = (actualUSDCOut * 10 ** 18) / amountWETHIn;
        emit log_named_decimal_uint("Effective Price (USDC per WETH)", effectivePrice, 6);

        vm.stopPrank();
    }

    function test_SwapUSDCForWETH() public {
        // Setup: Create pair and add liquidity
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(
            address(weth),
            address(usdc),
            1, // Same concentration as test_SwapWETHForUSDC
            0,
            12
        );

        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        // Use same parameters as test_SwapWETHForUSDC
        uint256 concentration = 1;
        uint256 multX = 4000;
        uint256 multY = 10 ** 12;
        amm.updateParameters(wethUsdcPairId, concentration, multX, multY);

        vm.stopPrank();

        // Trader swaps USDC for WETH
        vm.startPrank(trader);

        uint256 amountUSDCIn = 4000 * 10 ** USDC_DECIMALS; // 4000 USDC

        // Get quote
        uint256 quotedWETH = amm.quoteYtoX(wethUsdcPairId, amountUSDCIn);

        // Approve USDC for swap
        usdc.approve(address(amm), amountUSDCIn);

        // Perform swap
        uint256 actualWETHOut = amm.swapYtoX(wethUsdcPairId, amountUSDCIn, 0);

        assertEq(actualWETHOut, quotedWETH, "Actual output doesn't match quote");
        assertGt(actualWETHOut, 0, "Should receive some WETH");

        emit log_named_uint("USDC Input", amountUSDCIn);
        emit log_named_decimal_uint("USDC Input (human)", amountUSDCIn, 6);
        emit log_named_uint("WETH Output", actualWETHOut);
        emit log_named_decimal_uint("WETH Output (human)", actualWETHOut, 18);

        vm.stopPrank();
    }

    function test_OnlyMarketMakerCanDeposit() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);

        vm.stopPrank();

        // Trader tries to deposit (should fail)
        vm.startPrank(trader);

        weth.approve(address(amm), 1 ether);

        vm.expectRevert(PropAMM.OnlyMarketMaker.selector);
        amm.deposit(wethUsdcPairId, 1 ether, 0);

        vm.stopPrank();
    }

    function test_SlippageProtection() public {
        // Setup pair with liquidity
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);
        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        uint256 concentration = 100;
        uint256 multX = 4000 * 10 ** 6;
        uint256 multY = 10 ** 18;
        amm.updateParameters(wethUsdcPairId, concentration, multX, multY);

        vm.stopPrank();

        // Trader tries to swap with unrealistic slippage expectation
        vm.startPrank(trader);

        uint256 amountWETHIn = 1 * 10 ** WETH_DECIMALS;
        uint256 unrealisticMinOut = 5000 * 10 ** USDC_DECIMALS; // Expecting more than possible

        weth.approve(address(amm), amountWETHIn);

        vm.expectRevert(PropAMM.SlippageExceeded.selector);
        amm.swapXtoY(wethUsdcPairId, amountWETHIn, unrealisticMinOut);

        vm.stopPrank();
    }

    function test_ParameterUpdate() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);

        // Update to new concentration and multipliers
        uint256 newConcentration = 150;
        uint256 newMultX = 3500 * 10 ** 6;
        uint256 newMultY = 10 ** 18;

        amm.updateParameters(wethUsdcPairId, newConcentration, newMultX, newMultY);

        // Verify parameters updated in global storage
        (PropAMM.PairParameters memory params, uint64 timestamp, uint64 blockNum) =
            amm.getParametersWithTimestamp(wethUsdcPairId);

        assertEq(params.concentration, newConcentration);
        assertEq(params.multX, newMultX);
        assertEq(params.multY, newMultY);
        assertEq(timestamp, block.timestamp);
        assertEq(blockNum, block.number);

        vm.stopPrank();
    }

    function test_WithdrawLiquidity() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);

        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        uint256 withdrawWETH = 10 * 10 ** WETH_DECIMALS;
        uint256 withdrawUSDC = 40000 * 10 ** USDC_DECIMALS;

        uint256 balanceBefore = weth.balanceOf(marketMaker);

        amm.withdraw(wethUsdcPairId, withdrawWETH, withdrawUSDC);

        uint256 balanceAfter = weth.balanceOf(marketMaker);

        assertEq(balanceAfter - balanceBefore, withdrawWETH);

        vm.stopPrank();
    }
}
