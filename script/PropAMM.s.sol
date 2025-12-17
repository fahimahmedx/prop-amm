// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {PropAMM} from "../src/PropAMM.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IGlobalStorage {
    function setBatch(bytes32[] calldata keys, bytes32[] calldata values) external;
}

contract PropAMMScript is Script {
    PropAMM public propAMM;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address marketMaker = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        address globalStorage = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;

        // Token addresses
        address wethAddress = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
        address usdcAddress = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;

        // Output nonce before deployment
        uint64 nonce = vm.getNonce(msg.sender);
        console.log("Nonce before deployment:", nonce);

        propAMM = new PropAMM(marketMaker, globalStorage);

        // Output nonce after deployment
        console.log("Nonce after deployment:", vm.getNonce(msg.sender));
        console.log("PropAMM address:", address(propAMM));

        // Create pair
        bytes32 pairId = propAMM.createPair(
            wethAddress,
            usdcAddress,
            100,  // initial concentration
            0,    // xRetainDecimals
            0     // yRetainDecimals
        );

        console.log("Pair created with ID:");
        console.logBytes32(pairId);

        // Initialize parameters (multX and multY start at 0, need to be set)
        console.log("\nInitializing parameters via GlobalStorage...");
        IGlobalStorage gs = IGlobalStorage(globalStorage);
        bytes32[] memory keys = propAMM.getParameterKeys(pairId);
        bytes32[] memory values = propAMM.encodeParameters(
            100,  // concentration
            1 ether,  // multX (1 WETH in base units)
            3000 ether  // multY (3000 USDC in base units, ~price of WETH)
        );
        gs.setBatch(keys, values);
        console.log("Parameters initialized via GlobalStorage!");

        // Get token decimals
        IERC20 weth = IERC20(wethAddress);
        IERC20 usdc = IERC20(usdcAddress);
        
        uint8 wethDecimals = weth.decimals();
        uint8 usdcDecimals = usdc.decimals();
        console.log("WETH decimals:", wethDecimals);
        console.log("USDC decimals:", usdcDecimals);

        // Deposit amounts
        uint256 depositAmountWeth = 10 ether;  // 10 WETH
        uint256 depositAmountUsdc = 30000 * 10**usdcDecimals;  // 30,000 USDC

        console.log("\nApproving WETH...");
        weth.approve(address(propAMM), depositAmountWeth*10); // 10x the amount to be approved for future usages/
        console.log("WETH approved!");

        console.log("Approving USDC...");
        usdc.approve(address(propAMM), depositAmountUsdc*10);
        console.log("USDC approved!");

        // Deposit liquidity
        console.log("\nDepositing liquidity:");
        console.log("  WETH amount:", depositAmountWeth / 10**wethDecimals);
        console.log("  USDC amount:", depositAmountUsdc / 10**usdcDecimals);
        
        propAMM.deposit(
            pairId,
            depositAmountWeth,
            depositAmountUsdc
        );
        
        console.log("Liquidity deposited successfully!");
        console.log("sender address:", msg.sender);

        vm.stopBroadcast();
    }
}
