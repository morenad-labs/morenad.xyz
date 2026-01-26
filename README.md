# MORE

MORE is an on-chain mining protocol on Monad.

## Contracts

#### Core
- [`MiningGame`](src/MiningGame.sol) - Main game contract with deploy, checkpoint, and withdraw.
- [`MoreToken`](src/MoreToken.sol) - ERC20 token with 5M hard cap.
- [`MiningGameVault`](src/MiningGameVault.sol) - Non-upgradeable fund storage.

#### Staking
- [`TreasuryStaking`](src/TreasuryStaking.sol) - Staking and buyback orchestration.
- [`TreasuryVault`](src/TreasuryVault.sol) - Non-upgradeable staking fund storage.

#### Automation
- [`AutomationManager`](src/AutomationManager.sol) - User automation configurations.

## MiningGame Modules

- [`MiningGameTypes`](src/mining/MiningGameTypes.sol) - Constants, structs, errors, events.
- [`MiningGameStorage`](src/mining/MiningGameStorage.sol) - State variables.
- [`MiningGameCore`](src/mining/MiningGameCore.sol) - Deploy, commit-reveal, round resolution.
- [`MiningGameCheckpoint`](src/mining/MiningGameCheckpoint.sol) - Checkpoint and claim logic.
- [`MiningGameAdmin`](src/mining/MiningGameAdmin.sol) - Admin functions.
- [`MiningGameView`](src/mining/MiningGameView.sol) - View functions.

## Interfaces

- [`IMiningGame`](src/interfaces/IMiningGame.sol) - MiningGame interface.
- [`IVault`](src/interfaces/IVault.sol) - Vault interface.

## Tests

```bash
forge test
```
