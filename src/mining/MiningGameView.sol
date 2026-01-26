// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./MiningGameBase.sol";

/// @title MiningGameView
/// @notice View functions for MiningGame
/// @dev Inherits from MiningGameBase (Mixin pattern - independent module)
abstract contract MiningGameView is MiningGameBase {
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's claimable native token for a round
    /// @param roundId Round ID
    /// @param user User address
    /// @return Claimable native token amount
    function getClaimableNative(uint32 roundId, address user)
        external
        view
        returns (uint128)
    {
        Round storage round = rounds[roundId];
        if (round.state != RoundState.RESOLVED) return 0;

        UserRoundData storage userData = userRoundData[roundId][user];
        if (userData.nativeClaimed) return 0;

        uint8 winningBlock = round.winningBlock;
        uint128 userDeployedOnWinner = userDeployed[roundId][user][winningBlock];

        if (userDeployedOnWinner == 0) return 0;

        uint128 winnerTotal = totalDeployedPerBlock[roundId][winningBlock];
        // Protection: Return 0 if no one deployed on winning block
        if (winnerTotal == 0) return 0;

        uint128 totalDep = round.totalDeployed;
        uint128 protocolFee = uint128((uint256(totalDep) * PROTOCOL_FEE_BPS) / 10000);
        uint128 adminFee = uint128((uint256(totalDep) * ADMIN_FEE_BPS) / 10000);
        uint128 netPool = totalDep - protocolFee - adminFee;

        return uint128((uint256(netPool) * userDeployedOnWinner) / winnerTotal);
    }

    /// @notice Get user's pending refined MORE
    /// @param user User address
    /// @return Pending refined MORE
    function getPendingRefined(address user) external view returns (uint128) {
        UserRewardData storage userData = userRewardData[user];

        uint128 pending = uint128((uint256(userData.unclaimedMore) *
            uint256(globalRewardIndex - userData.rewardIndex)) / PRECISION);

        return userData.accumulatedRefined + pending;
    }

    /// @notice Get user's unclaimed native token balance
    /// @param user User address
    /// @return Unclaimed native tokens
    function getUnclaimedNative(address user) external view returns (uint128) {
        return userRewardData[user].unclaimedNative;
    }

    /// @notice Get total deployed amounts for all blocks in a round
    /// @param roundId Round ID
    /// @return Array of total deployed amounts per block (25 elements)
    function getTotalDeployedForRound(uint32 roundId) external view returns (uint128[GRID_SIZE] memory) {
        return totalDeployedPerBlock[roundId];
    }

    /// @notice Get user's deployed amounts for all blocks in a round
    /// @param roundId Round ID
    /// @param user User address
    /// @return Array of user deployed amounts per block (25 elements)
    function getUserDeployedForRound(uint32 roundId, address user) external view returns (uint128[GRID_SIZE] memory) {
        uint128[GRID_SIZE] memory amounts;
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            amounts[i] = userDeployed[roundId][user][i];
        }
        return amounts;
    }

    /// @notice Get comprehensive round result information
    /// @param roundId Round ID
    /// @return info RoundResultInfo struct with all round result data
    /// @dev winnerCount removed - available via Deployed events (gas optimization)
    function getRoundResult(uint32 roundId) external view returns (RoundResultInfo memory info) {
        Round storage round = rounds[roundId];
        uint8 wBlock = round.winningBlock;

        info.state = round.state;
        info.winningBlock = wBlock;
        info.totalDeployed = round.totalDeployed;
        info.netPool = round.netPool;
        info.moreReward = round.moreReward;
        info.winningBlockTotal = totalDeployedPerBlock[roundId][wBlock];
        info.mode = round.mode;
        info.morelodeTriggered = round.morelodeTriggered;
    }

    /// @notice Check if user won in a specific round and get their rewards
    /// @param roundId Round ID
    /// @param user User address
    /// @return info WinnerInfo struct with winner status and rewards
    function getWinnerInfo(uint32 roundId, address user) public view returns (WinnerInfo memory info) {
        Round storage round = rounds[roundId];
        if (round.state != RoundState.RESOLVED) return info;

        uint8 wBlock = round.winningBlock;
        uint128 userDep = userDeployed[roundId][user][wBlock];
        if (userDep == 0) return info;

        uint128 winnerTotal = totalDeployedPerBlock[roundId][wBlock];
        if (winnerTotal == 0) return info;

        info.isWinner = true;
        info.deployedAmount = userDep;
        info.nativeReward = uint128((uint256(round.netPool) * userDep) / winnerTotal);
        info.moreReward = round.moreReward > 0 ? uint128((uint256(round.moreReward) * userDep) / winnerTotal) : 0;
    }

    /// @notice Get winner info for multiple users in a single call
    /// @param roundId Round ID
    /// @param users Array of user addresses
    /// @return infos Array of WinnerInfo structs for each user
    function getWinnersInfoBatch(uint32 roundId, address[] calldata users) external view returns (WinnerInfo[] memory infos) {
        infos = new WinnerInfo[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            infos[i] = getWinnerInfo(roundId, users[i]);
        }
    }

    /// @notice Get user's deployment on a specific block in a round
    /// @param roundId Round ID
    /// @param user User address
    /// @param blockId Block ID (0-24)
    /// @return Amount deployed by user on the block
    function getUserDeployedOnBlock(uint32 roundId, address user, uint8 blockId) external view returns (uint128) {
        return userDeployed[roundId][user][blockId];
    }

}
