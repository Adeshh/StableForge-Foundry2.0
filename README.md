# Decentralized Stablecoin (DSC)

A decentralized stablecoin system built with Solidity and Foundry, inspired by MakerDAO's DAI. This project implements an overcollateralized stablecoin that maintains a 1:1 peg with USD.

## Overview

This is a decentralized stablecoin system with the following properties:
- **Exogenously Collateralized**: Backed by external assets (WETH, WBTC)
- **Dollar Pegged**: Maintains a 1 token = $1 USD peg
- **Algorithmically Stable**: Uses algorithmic mechanisms to maintain stability
- **Overcollateralized**: Always maintains collateral value greater than minted DSC value

The system is similar to DAI but without governance, fees, and backed only by WETH and WBTC.

## Architecture

### Core Contracts

1. **DecentralizedStableCoin.sol**: The ERC20 stablecoin token that can be minted and burned by the DSCEngine
2. **DSCEngine.sol**: The core engine that manages collateral deposits, DSC minting/burning, and maintains the health factor

### Key Features

- **Collateral Management**: Users can deposit WETH or WBTC as collateral
- **DSC Minting**: Users can mint DSC tokens against their collateral (up to 50% of collateral value)
- **Health Factor**: System ensures users maintain a health factor > 1 to prevent undercollateralization
- **Liquidation**: Under-collateralized positions can be liquidated
- **Reentrancy Protection**: All functions use OpenZeppelin's ReentrancyGuard

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity ^0.8.18

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd StableForge-Foundry2.0
```

2. Install dependencies:
```bash
forge install
```

## Usage

### Build

Compile the contracts:
```bash
forge build
```

### Test

Run all tests:
```bash
forge test
```

Run tests with verbosity:
```bash
forge test -vvv
```

Run a specific test:
```bash
forge test --match-test testCanDepositCollateral
```

### Deploy

Deploy to a local Anvil network:
```bash
# Start Anvil in one terminal
anvil

# Deploy in another terminal
forge script script/DeployDSC.s.sol:DeployDSC --rpc-url http://localhost:8545 --private-key <your-private-key> --broadcast
```

Deploy to Sepolia testnet:
```bash
forge script script/DeployDSC.s.sol:DeployDSC --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

## Test Coverage

The project includes comprehensive unit tests covering:
- Constructor tests
- Price feed tests
- Collateral deposit/redeem tests
- DSC minting/burning tests
- Health factor validation
- Event emission tests
- Error handling tests

## Project Structure

```
.
├── src/
│   ├── DecentralizedStableCoin.sol  # The stablecoin ERC20 token
│   └── DSCEngine.sol                # Core engine contract
├── script/
│   ├── DeployDSC.s.sol              # Deployment script
│   └── HelperConfig.s.sol           # Network configuration helper
├── test/
│   ├── mocks/
│   │   ├── ERC20Mock.sol            # Mock ERC20 token for testing
│   │   └── MockV3Aggregator.sol     # Mock Chainlink price feed
│   └── unit/
│       └── DSCEngineTest.t.sol      # Unit tests for DSCEngine
└── lib/                             # Dependencies (submodules)
```

## Security Considerations

- All functions follow the Checks-Effects-Interactions pattern
- ReentrancyGuard protection on state-changing functions
- Health factor checks prevent undercollateralization
- Input validation on all user-facing functions

## License

MIT

## Author

@Adeshh
