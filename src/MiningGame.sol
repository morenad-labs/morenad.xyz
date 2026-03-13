// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./mining/MiningGameCore.sol";
import "./mining/MiningGameCheckpoint.sol";
import "./mining/MiningGameAdmin.sol";
import "./mining/MiningGameView.sol";

/// @title MiningGame
/// @notice ORE-inspired mining game with 5x5 grid and provably fair commit-reveal randomness
/// @dev Uses Mixin pattern - multiple independent modules combined via diamond inheritance
/// @dev Randomness formula: keccak256(revealedSeed, closedAtPrevrandao, roundId) % 25
/// @dev Admin commits hash before round, reveals seed after deploying closes
/// @dev Automation logic moved to separate AutomationManager contract to reduce bytecode size
///
/// Architecture (Mixin Pattern):
///
///                MiningGameTypes (file-level)
///                        |
///                MiningGameStorage (state)
///                        |
///                 MiningGameBase (virtual functions)
///                /    |      |      \
///             Core Checkpoint Admin View (independent modules)
///                \    |      /      /
///                     MiningGame (this contract)
///                         |
///               AutomationManager (separate contract)
///
contract MiningGame is
    MiningGameCore,
    MiningGameCheckpoint,
    MiningGameAdmin,
    MiningGameView
{
    /// @notice AutomationManager contract address
    address public automationManager;

    /// @notice Error for unauthorized automation calls
    error NotAutomationManager();
    /// @notice Initialize the contract (replaces constructor for UUPS proxy)
    /// @param _moreToken MORE token address
    /// @param _treasury Treasury address
    /// @param _admin Admin address
    /// @param _vault Vault contract address
    function initialize(
        address _moreToken,
        address _treasury,
        address _admin,
        address _vault
    ) external initializer {
        __MiningGameStorage_init(_moreToken, _treasury, _admin, _vault);
    }

    /*//////////////////////////////////////////////////////////////
                        OVERRIDE RESOLUTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolve _checkpoint from MiningGameCheckpoint
    function _checkpoint(uint32 roundId, address user)
        internal
        override(MiningGameBase, MiningGameCheckpoint)
    {
        MiningGameCheckpoint._checkpoint(roundId, user);
    }

    /// @dev Resolve _updateUserRewards from MiningGameCheckpoint
    function _updateUserRewards(address user)
        internal
        override(MiningGameBase, MiningGameCheckpoint)
    {
        MiningGameCheckpoint._updateUserRewards(user);
    }

    /// @dev Resolve _internalDeploy from MiningGameCore
    function _internalDeploy(
        address user,
        uint8[] memory blockIds,
        uint128 amountPerBlock
    ) internal override(MiningGameBase, MiningGameCore) {
        MiningGameCore._internalDeploy(user, blockIds, amountPerBlock);
    }

    /// @dev Resolve _closeRound from MiningGameCore
    function _closeRound()
        internal
        override(MiningGameBase, MiningGameCore)
    {
        MiningGameCore._closeRound();
    }

    /// @dev Resolve _startNewRound from MiningGameCore
    function _startNewRound()
        internal
        override(MiningGameBase, MiningGameCore)
    {
        MiningGameCore._startNewRound();
    }

    /*//////////////////////////////////////////////////////////////
                        AUTOMATION INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Set automation manager address
    /// @param _automationManager AutomationManager contract address
    function setAutomationManager(address _automationManager) external onlyOwner {
        automationManager = _automationManager;
    }

    /// @notice Set vault address (for migration only)
    /// @param _vault New vault contract address
    /// @dev Only callable by owner. Migrates balances before swapping the active vault pointer.
    function setVault(address _vault) external onlyOwner {
        _migrateVault(_vault);
    }

    /// @notice Error for invalid vault controller
    error InvalidVaultController();
    /// @notice Error for invalid vault MORE token
    error InvalidVaultMoreToken();
    /// @notice Error for non-empty destination vault
    error VaultNotEmpty();

    /// @notice Emitted when vault is updated
    event VaultUpdated(address indexed newVault);

    /// @dev Migrate funds from current vault into a new controller-compatible vault before swapping pointers.
    function _migrateVault(address _vault) internal {
        if (_vault == address(0)) revert ZeroAddress();

        IVault currentVault = vault;
        IVault newVault = IVault(_vault);

        if (newVault.controller() != address(this)) revert InvalidVaultController();
        if (newVault.moreToken() != address(moreToken)) revert InvalidVaultMoreToken();

        // Sweep any unsolicited dust from new vault back to current vault
        // to prevent dusting DoS attacks that block migration
        uint256 newVaultNativeBalance = newVault.getBalance();
        if (newVaultNativeBalance != 0) {
            newVault.withdrawNative(address(currentVault), newVaultNativeBalance);
        }
        uint256 newVaultMoreBalance = newVault.getMoreBalance();
        if (newVaultMoreBalance != 0) {
            newVault.withdrawMore(address(currentVault), newVaultMoreBalance);
        }

        uint256 nativeBalance = currentVault.getBalance();
        if (nativeBalance != 0) {
            currentVault.withdrawNative(_vault, nativeBalance);
        }

        uint256 moreBalance = currentVault.getMoreBalance();
        if (moreBalance != 0) {
            currentVault.withdrawMore(_vault, moreBalance);
        }

        if (currentVault.getBalance() != 0 || currentVault.getMoreBalance() != 0) revert VaultNotEmpty();

        vault = newVault;
        emit VaultUpdated(_vault);
    }

    /// @notice Deploy on behalf of a user (only callable by AutomationManager)
    /// @param user User address to deploy for
    /// @param blockIds Block IDs to deploy to
    /// @param amountPerBlock Amount per block
    function deployFromAutomation(
        address user,
        uint8[] calldata blockIds,
        uint128 amountPerBlock
    ) external payable nonReentrant {
        if (msg.sender != automationManager) revert NotAutomationManager();
        if (blockIds.length == 0) revert InvalidDeployAmount();
        if (amountPerBlock == 0) revert InvalidDeployAmount();
        // Security: prevent accounting/Vault mismatch on automated deploys
        if (msg.value != uint256(amountPerBlock) * blockIds.length) revert InvalidDeployAmount();

        uint32 roundId = currentRound;
        Round storage round = rounds[roundId];

        if (round.state != RoundState.ACTIVE) revert RoundNotActive();
        if (block.timestamp >= round.startTime + roundDuration) revert RoundExpired();

        // Update last participated round
        lastParticipatedRound[user] = roundId;

        // Execute deploy (state changes)
        _internalDeploy(user, blockIds, amountPerBlock);

        // Emit event
        emit Deployed(roundId, user, blockIds, amountPerBlock);

        // === INTERACTIONS (external calls LAST) ===
        // Forward msg.value to vault (CEI pattern)
        (bool success,) = address(vault).call{value: msg.value}("");
        if (!success) revert VaultDepositFailed();
    }

    /// @notice Checkpoint for a user (callable by AutomationManager)
    /// @param roundId Round ID to checkpoint
    /// @param user User address
    function checkpointFor(uint32 roundId, address user) external nonReentrant {
        if (msg.sender != automationManager) revert NotAutomationManager();
        _checkpoint(roundId, user);
    }

    /// @notice Withdraw native rewards to AutomationManager for auto-reload
    /// @param user User address to withdraw rewards for
    /// @return amount Amount withdrawn (0 if no rewards)
    /// @dev Only callable by AutomationManager. Sends ETH to msg.sender (AutomationManager)
    function withdrawNativeToAutomation(address user) external nonReentrant returns (uint128 amount) {
        if (msg.sender != automationManager) revert NotAutomationManager();

        amount = userRewardData[user].unclaimedNative;
        if (amount == 0) return 0;

        userRewardData[user].unclaimedNative = 0;

        emit NativeWithdrawn(user, amount);

        // Withdraw through vault to AutomationManager (msg.sender)
        vault.withdrawNative(msg.sender, amount);
    }

    /// @notice Fallback to receive ETH - forwards to vault
    /// @dev Only forwards ETH sent directly, deploy() handles its own forwarding
    receive() external payable {
        if (address(vault) != address(0)) {
            (bool success,) = address(vault).call{value: msg.value}("");
            if (!success) revert VaultDepositFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify vault invariant - vault balance should cover all owed amounts
    /// @return isValid Whether the invariant holds
    /// @return expected Expected minimum balance
    /// @return actual Actual vault balance
    /// @dev Used for monitoring and debugging
    function verifyVaultInvariant() external view returns (bool isValid, uint256 expected, uint256 actual) {
        expected = _calculateTotalOwed();
        actual = vault.getBalance();
        isValid = actual >= expected;
    }

    /// @notice Calculate total native tokens owed to users and treasury
    /// @return total Total owed amount
    function _calculateTotalOwed() internal view returns (uint256 total) {
        // Sum protocol revenue and admin fees
        total = protocolRevenueBalance + adminFeeBalance;

        // Sum morelode pool
        total += morelodePool;

        // Note: Individual user unclaimedNative would require iterating all users,
        // which is not practical on-chain. For comprehensive verification,
        // use off-chain indexing of checkpoint events.

        // Active round deposits are tracked via events
        // For resolved rounds, netPool is distributed to winners
    }
}
