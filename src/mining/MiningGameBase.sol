// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./MiningGameStorage.sol";

/// @title MiningGameBase
/// @notice Base contract with virtual function declarations for cross-module calls
/// @dev All modules inherit from this. Enables Mixin pattern by decoupling modules.
abstract contract MiningGameBase is MiningGameStorage {
    /*//////////////////////////////////////////////////////////////
                        VIRTUAL FUNCTION DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal checkpoint logic
    /// @param roundId Round ID to checkpoint
    /// @param user User address to checkpoint for
    function _checkpoint(uint32 roundId, address user) internal virtual;

    /// @notice Update user's refined MORE rewards
    /// @param user User address
    function _updateUserRewards(address user) internal virtual;

    /// @notice Internal deploy logic shared between deploy() and deployForUser()
    /// @param user User address
    /// @param blockIds Block IDs to deploy to
    /// @param amountPerBlock Amount per block
    function _internalDeploy(
        address user,
        uint8[] memory blockIds,
        uint128 amountPerBlock
    ) internal virtual;

    /// @notice Internal function to close round
    function _closeRound() internal virtual;

    /// @notice Start a new round
    function _startNewRound() internal virtual;
}
