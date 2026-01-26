// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../mining/MiningGameTypes.sol";

/// @title IMiningGame
/// @notice Interface for MiningGame used by AutomationManager
interface IMiningGame {
    /// @notice Deploy on behalf of a user (only callable by automationManager)
    /// @param user User address to deploy for
    /// @param blockIds Block IDs to deploy to
    /// @param amountPerBlock Amount per block
    function deployFromAutomation(
        address user,
        uint8[] calldata blockIds,
        uint128 amountPerBlock
    ) external payable;

    /// @notice Checkpoint rewards for a user
    /// @param roundId Round ID to checkpoint
    /// @param user User address
    function checkpointFor(uint32 roundId, address user) external;

    /// @notice Withdraw native rewards to AutomationManager for auto-reload
    /// @param user User address to withdraw rewards for
    /// @return amount Amount withdrawn (0 if no rewards)
    function withdrawNativeToAutomation(address user) external returns (uint128 amount);

    /// @notice Get current round ID
    function currentRound() external view returns (uint32);

    /// @notice Get round duration
    function roundDuration() external view returns (uint16);

    /// @notice Get round data
    function rounds(uint32 roundId) external view returns (
        uint40 startTime,
        uint8 winningBlock,
        RoundState state,
        RewardMode mode,
        bool morelodeTriggered,
        uint128 totalDeployed,
        uint128 netPool,
        uint128 moreReward,
        uint256 closedAtPrevrandao,
        bytes32 commitHash,
        bytes32 revealedSeed
    );

    /// @notice Get last participated round for user
    function lastParticipatedRound(address user) external view returns (uint32);

    /// @notice Get user round data
    function userRoundData(uint32 roundId, address user) external view returns (
        bool nativeClaimed,
        bool moreClaimed
    );

    /// @notice Get user reward data
    function userRewardData(address user) external view returns (
        uint128 unclaimedNative,
        uint128 unclaimedMore,
        uint128 rewardIndex,
        uint128 accumulatedRefined
    );
}
