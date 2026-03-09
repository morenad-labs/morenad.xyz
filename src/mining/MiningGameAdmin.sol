// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./MiningGameBase.sol";

/// @title MiningGameAdmin
/// @notice Admin functions for MiningGame
/// @dev Inherits from MiningGameBase (Mixin pattern - independent module)
abstract contract MiningGameAdmin is MiningGameBase {
    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw protocol revenue to treasury
    /// @dev Only owner can trigger withdrawal
    /// @dev Withdraws through vault - vault holds all funds
    function withdrawProtocolRevenue() external onlyOwner {
        uint128 amount = protocolRevenueBalance;
        if (amount == 0) revert NothingToClaim();

        protocolRevenueBalance = 0;

        emit ProtocolRevenueWithdrawn(treasury, amount);

        // Withdraw through vault
        vault.withdrawNative(treasury, amount);
    }

    /// @notice Withdraw admin fees
    /// @dev Only admin can trigger withdrawal
    /// @dev Withdraws through vault - vault holds all funds
    function withdrawAdminFees() external {
        if (msg.sender != admin) revert NotAdmin();
        uint128 amount = adminFeeBalance;
        if (amount == 0) revert NothingToClaim();

        adminFeeBalance = 0;

        emit AdminFeeWithdrawn(admin, amount);

        // Withdraw through vault
        vault.withdrawNative(admin, amount);
    }

    /// @notice Set treasury address
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /// @notice Set admin address
    /// @param _admin New admin address
    function setAdmin(address _admin) external onlyOwner {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Skip a stuck round and start the next round
    /// @param roundId Round ID to skip (must be current round)
    /// @dev Only owner can call. Round must be ACTIVE or CLOSED.
    ///      After skipping, users can call checkpoint() to get full refund.
    function setEmergencySkip(uint32 roundId) external onlyOwner {
        if (roundId != currentRound) revert NotCurrentRound();

        Round storage round = rounds[roundId];
        // Only allow ACTIVE or CLOSED (not PENDING, RESOLVED, or already EMERGENCY_SKIP)
        if (round.state == RoundState.PENDING) revert RoundNotPending();
        if (round.state == RoundState.RESOLVED) revert RoundAlreadyResolved();
        if (round.state == RoundState.EMERGENCY_SKIP) revert RoundAlreadyResolved();

        round.state = RoundState.EMERGENCY_SKIP;

        // Start next round
        _startNewRound();

        emit EmergencySkip(roundId);
    }
}
