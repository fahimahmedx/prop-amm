# PropAMM

A **Proprietary Automated Market Maker** implementation in Solidity, inspired by Obric's Prop AMM deployed on Sui. PropAMM is a specialized AMM where only a designated market maker can provide liquidity, offering precise control over pricing curves and protection against frontrunning.

## Overview

PropAMM implements a proprietary market making model with the following key characteristics:

- **Single Market Maker**: Only the designated market maker can add/remove liquidity
- **Custom Pricing Curves**: Uses concentration parameters and multipliers for flexible pricing
- **Frontrunning Protection**: Integrates with GlobalStorage to ensure parameter updates are atomic and read from the top of the block
- **Safety Mechanisms**: Automatic pair locking when target deviation exceeds thresholds
- **Multi-Token Support**: Create multiple trading pairs with different configurations

## Key Features

### 1. Proprietary Liquidity
Only the market maker (set by the owner) can:
- Create trading pairs
- Deposit/withdraw liquidity
- Update pricing parameters

### 2. GlobalStorage Integration
- Parameter updates (`concentration`, `multX`, `multY`) are stored in GlobalStorage
- Prevents frontrunning by ensuring all reads get top-of-block values
- Atomic batch updates for parameter consistency

### 3. Flexible Pricing Model
The AMM uses a custom curve defined by:
- **Concentration**: Controls the steepness of the pricing curve (1-2000)
- **Multipliers**: `multX` and `multY` for price normalization between tokens
- **Target Reserves**: Dynamic target amounts that affect the curve shape

### 4. Safety Features
- **Target Y Lock**: Automatically locks trading if target Y deviates by >5% from reference
- **Slippage Protection**: Traders can set minimum output amounts
- **Reentrancy Guards**: All state-changing functions are protected

## Architecture

```
PropAMM
├── Market Maker Functions (restricted)
│   ├── createPair()
│   ├── deposit()
│   ├── withdraw()
│   ├── updateParameters()
│   └── unlock()
├── Trading Functions (public)
│   ├── swapXtoY()
│   └── swapYtoX()
└── View Functions
    ├── quoteXtoY()
    ├── quoteYtoX()
    ├── getParametersWithTimestamp()
    └── getPair()
```

## Smart Contract Details

### TradingPair Structure
Each pair maintains:
- Token addresses and reserves
- Target amounts for the curve
- Decimal configurations for price normalization
- Lock status and reference values

### Pricing Formula
The AMM calculates swap amounts using:
```
v0 = targetX × concentration
K = (v0² × multX) / multY
base = v0 + reserveX - targetX

For X→Y: amountOut = K/base - K/(base + amountXIn)
For Y→X: amountOut = base - K/(K/base + amountYIn)
```

## Usage

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- A deployed GlobalStorage contract (for frontrunning protection)

### Installation

```shell
git clone <repository-url>
cd prop-amm
forge install
```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

Run with verbosity for detailed output:
```shell
forge test -vvv
```

### Deploy

1. Update `script/PropAMM.s.sol` with your deployment parameters
2. Deploy to your target network:

```shell
forge script script/PropAMM.s.sol:PropAMMScript \
    --rpc-url <your_rpc_url> \
    --private-key <your_private_key> \
    --broadcast \
    --verify
```

### Integration Example

```solidity
// 1. Deploy PropAMM
PropAMM amm = new PropAMM(marketMakerAddress, globalStorageAddress);

// 2. Create a trading pair (as market maker)
bytes32 pairId = amm.createPair(
    tokenXAddress,
    tokenYAddress,
    1000,  // concentration
    6,     // xRetainDecimals
    6      // yRetainDecimals
);

// 3. Deposit liquidity (as market maker)
amm.deposit(pairId, 1000e18, 1000e6);

// 4. Update pricing parameters (as market maker)
amm.updateParameters(pairId, 1200, multX, multY);

// 5. Trade (anyone can trade)
uint256 amountOut = amm.swapXtoY(pairId, amountIn, minAmountOut);
```

## Security Considerations

1. **Market Maker Trust**: The market maker has significant control over liquidity and pricing
2. **Parameter Updates**: Market maker should update parameters responsibly to avoid locking pairs
3. **GlobalStorage Dependency**: Ensure GlobalStorage contract is properly deployed and trusted
4. **Decimal Configuration**: Token decimal settings must satisfy: `decimalsX + xRetainDecimals == decimalsY + yRetainDecimals`

## Development

### Format Code

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Local Testing with Anvil

```shell
# Terminal 1: Start local node
anvil

# Terminal 2: Deploy and test
forge script script/PropAMM.s.sol --rpc-url http://localhost:8545 --broadcast
```

## Inspiration

This implementation is inspired by [Obric's Prop AMM](https://obricxyz.gitbook.io/smart/) deployed on Sui [here](https://suiscan.xyz/mainnet/object/0xb84e63d22ea4822a0a333c250e790f69bf5c2ef0c63f4e120e05a6415991368f/contracts), adapted for Ethereum with additional safety features and GlobalStorage integration for MEV protection.

## Resources

- [Foundry Documentation](https://book.getfoundry.sh/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Obric Protocol](https://obricxyz.gitbook.io/smart/)
