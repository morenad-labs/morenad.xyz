// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MiningGameBase.sol";

/// @title MiningGameCheckpoint
/// @notice Checkpoint and claim logic for MiningGame
/// @dev Inherits from MiningGameBase (Mixin pattern - independent module)
abstract contract MiningGameCheckpoint is MiningGameBase {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checkpoint rewards for last participated round (no roundId needed)
    /// @dev Uses lastParticipatedRound to determine which round to checkpoint
    function checkpoint() external nonReentrant {
        uint32 roundId = lastParticipatedRound[msg.sender];
        if (roundId == 0) revert NothingToClaim();
        _checkpoint(roundId, msg.sender);
    }

    /// @notice Checkpoint rewards for a specific round
    /// @param roundId Round ID to checkpoint
    function checkpointRound(uint32 roundId) external nonReentrant {
        _checkpoint(roundId, msg.sender);
    }

    /// @notice Internal checkpoint logic
    /// @param roundId Round ID to checkpoint
    /// @param user User address to checkpoint for
    function _checkpoint(uint32 roundId, address user) internal virtual override {
        Round storage round = rounds[roundId];

        // Check if this is an emergency skipped round
        bool isEmergency = round.state == RoundState.EMERGENCY_SKIP;

        // Must be RESOLVED or EMERGENCY_SKIP
        if (!isEmergency && round.state != RoundState.RESOLVED) revert RoundNotResolved();

        UserRoundData storage userData = userRoundData[roundId][user];

        // Already checkpointed
        if (userData.nativeClaimed && userData.moreClaimed) return;

        // Handle emergency refund (like ORE)
        if (isEmergency) {
            // Already refunded - nativeClaimed is used to track this
            if (userData.nativeClaimed) return;

            // Calculate user's total deployed amount for refund
            uint128 refundAmount = 0;
            uint128[GRID_SIZE] storage userDep = userDeployed[roundId][user];
            for (uint8 i = 0; i < GRID_SIZE; i++) {
                refundAmount += userDep[i];
            }

            if (refundAmount == 0) {
                userData.nativeClaimed = true;
                userData.moreClaimed = true;
                return;
            }

            // Mark as refunded using existing flags
            userData.nativeClaimed = true;
            userData.moreClaimed = true;

            // Credit refund to user's unclaimed balance
            userRewardData[user].unclaimedNative += refundAmount;

            emit EmergencyRefund(roundId, user, refundAmount);
            return;
        }

        // Normal checkpoint logic for resolved rounds
        uint8 winningBlock = round.winningBlock;
        uint128 userDeployedOnWinner = userDeployed[roundId][user][winningBlock];

        // User didn't win - mark as processed and return (no rewards)
        if (userDeployedOnWinner == 0) {
            userData.nativeClaimed = true;
            userData.moreClaimed = true;
            return;
        }

        uint128 winnerTotal = totalDeployedPerBlock[roundId][winningBlock];

        // Gas optimization: cache storage reference
        UserRewardData storage rewardData = userRewardData[user];

        // Calculate and credit native rewards
        if (!userData.nativeClaimed) {
            uint128 nativeReward = uint128((uint256(round.netPool) * userDeployedOnWinner) / winnerTotal);
            rewardData.unclaimedNative += nativeReward;
            userData.nativeClaimed = true;

            emit NativeClaimed(roundId, user, nativeReward);
        }

        // Calculate and credit MORE rewards
        if (!userData.moreClaimed) {
            if (round.moreReward > 0) {
                uint128 moreReward = uint128((uint256(round.moreReward) * userDeployedOnWinner) / winnerTotal);

                _updateUserRewards(user);
                rewardData.unclaimedMore += moreReward;
                totalUnclaimedMore += moreReward;

                emit MoreClaimed(user, moreReward, 0);
            }

            userData.moreClaimed = true;
        }
    }

    /// @notice Withdraw all accumulated native token rewards
    /// @dev Withdraws through vault - vault holds all funds
    function withdrawNative() external nonReentrant {
        // Auto-checkpoint last participated round if needed
        uint32 lastRound = lastParticipatedRound[msg.sender];
        RoundState lastState = rounds[lastRound].state;
        if (lastRound > 0 && (lastState == RoundState.RESOLVED || lastState == RoundState.EMERGENCY_SKIP)) {
            if (!userRoundData[lastRound][msg.sender].nativeClaimed) {
                _checkpoint(lastRound, msg.sender);
            }
        }

        uint128 amount = userRewardData[msg.sender].unclaimedNative;
        if (amount == 0) revert NothingToClaim();

        userRewardData[msg.sender].unclaimedNative = 0;

        emit NativeWithdrawn(msg.sender, amount);

        // Withdraw through vault
        vault.withdrawNative(msg.sender, amount);
    }

    /// @notice Withdraw unclaimed MORE (always pays 10% refining fee on unclaimed MORE)
    /// @dev Withdraws through vault - vault holds all MORE
    function withdrawMore() external nonReentrant {
        // Auto-checkpoint last participated round if needed
        uint32 lastRound = lastParticipatedRound[msg.sender];
        RoundState lastState = rounds[lastRound].state;
        if (lastRound > 0 && (lastState == RoundState.RESOLVED || lastState == RoundState.EMERGENCY_SKIP)) {
            if (!userRoundData[lastRound][msg.sender].moreClaimed) {
                _checkpoint(lastRound, msg.sender);
            }
        }

        _updateUserRewards(msg.sender);

        UserRewardData storage userData = userRewardData[msg.sender];
        uint128 unclaimed = userData.unclaimedMore;
        uint128 refined = userData.accumulatedRefined;

        if (unclaimed == 0 && refined == 0) revert NothingToClaim();

        uint128 refiningFee = uint128((uint256(unclaimed) * REFINING_FEE_BPS) / 10000);
        uint128 netMore = unclaimed - refiningFee;

        // Update state
        userData.unclaimedMore = 0;
        userData.accumulatedRefined = 0;
        totalUnclaimedMore -= unclaimed;

        if (refiningFee > 0) {
            if (totalUnclaimedMore > 0) {
                _distributeRefiningFee(refiningFee, totalUnclaimedMore);
            } else {
                _burnUndistributableRefiningFee(refiningFee);
            }
        }

        // Transfer MORE to user through vault
        uint128 totalWithdraw = netMore + refined;
        vault.withdrawMore(msg.sender, totalWithdraw);

        emit MoreClaimed(msg.sender, totalWithdraw, refiningFee);
    }

    /// @notice Withdraw both native and MORE rewards in a single transaction
    /// @dev More gas efficient than calling withdrawNative and withdrawMore separately
    function withdrawAll() external nonReentrant {
        // Auto-checkpoint last participated round if needed
        uint32 lastRound = lastParticipatedRound[msg.sender];
        RoundState lastState = rounds[lastRound].state;
        if (lastRound > 0 && (lastState == RoundState.RESOLVED || lastState == RoundState.EMERGENCY_SKIP)) {
            UserRoundData storage userData = userRoundData[lastRound][msg.sender];
            if (!userData.nativeClaimed || !userData.moreClaimed) {
                _checkpoint(lastRound, msg.sender);
            }
        }

        UserRewardData storage rewardData = userRewardData[msg.sender];
        uint128 nativeAmount = rewardData.unclaimedNative;

        _updateUserRewards(msg.sender);
        uint128 unclaimedMore = rewardData.unclaimedMore;
        uint128 refinedMore = rewardData.accumulatedRefined;

        // Must have at least one reward to claim
        if (nativeAmount == 0 && unclaimedMore == 0 && refinedMore == 0) revert NothingToClaim();

        // Withdraw native if available
        if (nativeAmount > 0) {
            rewardData.unclaimedNative = 0;
            emit NativeWithdrawn(msg.sender, nativeAmount);
            vault.withdrawNative(msg.sender, nativeAmount);
        }

        // Withdraw MORE if available
        if (unclaimedMore > 0 || refinedMore > 0) {
            uint128 refiningFee = uint128((uint256(unclaimedMore) * REFINING_FEE_BPS) / 10000);
            uint128 netMore = unclaimedMore - refiningFee;

            rewardData.unclaimedMore = 0;
            rewardData.accumulatedRefined = 0;
            totalUnclaimedMore -= unclaimedMore;

            if (refiningFee > 0) {
                if (totalUnclaimedMore > 0) {
                    _distributeRefiningFee(refiningFee, totalUnclaimedMore);
                } else {
                    _burnUndistributableRefiningFee(refiningFee);
                }
            }

            uint128 totalMoreWithdraw = netMore + refinedMore;
            vault.withdrawMore(msg.sender, totalMoreWithdraw);
            emit MoreClaimed(msg.sender, totalMoreWithdraw, refiningFee);
        }
    }

    /// @notice Update user's refined MORE rewards
    /// @param user User address
    function _updateUserRewards(address user) internal virtual override {
        UserRewardData storage userData = userRewardData[user];

        uint128 pending = uint128((uint256(userData.unclaimedMore) *
            uint256(globalRewardIndex - userData.rewardIndex)) / PRECISION);

        userData.accumulatedRefined += pending;
        userData.rewardIndex = globalRewardIndex;
    }

    function _distributeRefiningFee(uint128 refiningFee, uint128 remainingUnclaimedMore) internal {
        uint256 increment = (uint256(refiningFee) * PRECISION) / uint256(remainingUnclaimedMore);
        uint256 newGlobalIndex = uint256(globalRewardIndex) + increment;

        // Preserve packed uint128 storage in pathological dust cases without changing reward accounting layout.
        if (newGlobalIndex > type(uint128).max) {
            _burnUndistributableRefiningFee(refiningFee);
            return;
        }

        globalRewardIndex = uint128(newGlobalIndex);
        emit RefinedMoreDistributed(refiningFee, globalRewardIndex);
    }

    function _burnUndistributableRefiningFee(uint128 refiningFee) internal {
        vault.withdrawMore(address(this), refiningFee);
        moreToken.burn(refiningFee);
    }
}
