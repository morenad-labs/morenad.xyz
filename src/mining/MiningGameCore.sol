// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./MiningGameBase.sol";

/// @title MiningGameCore
/// @notice Core game logic: deploy, commit-reveal, round resolution
/// @dev Inherits from MiningGameBase (Mixin pattern - independent module)
abstract contract MiningGameCore is MiningGameBase {

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Commit to next round before it starts
    /// @param commitHash keccak256(abi.encodePacked(seed, roundId))
    /// @dev Only admin can commit. Commitment must be made before round can accept bets.
    function commitToNextRound(bytes32 commitHash) external {
        if (msg.sender != admin) revert NotAdmin();
        if (commitHash == bytes32(0)) revert InvalidSeed();
        if (nextRoundCommitment != bytes32(0)) revert CommitmentAlreadyMade();

        uint32 nextRound = currentRound + 1;
        nextRoundCommitment = commitHash;

        emit CommitmentMade(nextRound, commitHash);
    }

    /// @notice Commit to specific round (fallback for missed commitments)
    /// @param roundId Round ID to commit to
    /// @param commitHash keccak256(abi.encodePacked(seed, roundId))
    /// @dev Can only commit to PENDING rounds. Round becomes ACTIVE after commitment.
    function commitToRound(uint32 roundId, bytes32 commitHash) external {
        if (msg.sender != admin) revert NotAdmin();
        if (commitHash == bytes32(0)) revert InvalidSeed();

        Round storage round = rounds[roundId];
        if (round.state != RoundState.PENDING) revert RoundNotPending();

        round.commitHash = commitHash;
        round.startTime = uint40(block.timestamp); // Reset timer when round becomes ACTIVE
        round.state = RoundState.ACTIVE;

        emit CommitmentMade(roundId, commitHash);
        emit RoundActivated(roundId, uint40(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                            CORE GAME LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy to multiple blocks with equal amounts
    /// @param blockIds Array of block IDs to deploy to (0-24, max 25 blocks)
    /// @dev Follows CEI pattern: Checks -> Effects -> Interactions
    function deploy(uint8[] calldata blockIds) external payable nonReentrant {
        // === CHECKS ===
        // Prevent admin from deploying (admin knows the seed)
        if (msg.sender == admin) revert AdminCannotDeploy();

        if (blockIds.length == 0) revert InvalidDeployAmount();
        if (blockIds.length > GRID_SIZE) revert InvalidDeployAmount(); // Max 25 blocks
        if (msg.value == 0) revert InvalidDeployAmount();

        uint32 roundId = currentRound; // Cache to avoid repeated SLOAD
        Round storage round = rounds[roundId];
        if (round.state != RoundState.ACTIVE) revert RoundNotActive();
        if (block.timestamp >= round.startTime + roundDuration) revert RoundExpired();

        // Auto-checkpoint previous round before new deployment (ORE pattern)
        uint32 lastRound = lastParticipatedRound[msg.sender];
        if (lastRound > 0 && lastRound != roundId) {
            Round storage prevRound = rounds[lastRound];
            if (prevRound.state == RoundState.RESOLVED) {
                UserRoundData storage prevData = userRoundData[lastRound][msg.sender];
                if (!prevData.nativeClaimed) {
                    _checkpoint(lastRound, msg.sender);
                }
            }
        }

        if (msg.value % blockIds.length != 0) revert InvalidDeployAmount();
        uint128 amountPerBlock = uint128(msg.value / blockIds.length);
        if (amountPerBlock == 0) revert InvalidDeployAmount();

        // === EFFECTS (state changes BEFORE external calls) ===
        lastParticipatedRound[msg.sender] = uint32(roundId);

        // Cache storage references to avoid repeated mapping lookups
        uint128[GRID_SIZE] storage userDeployedForRound = userDeployed[roundId][msg.sender];
        uint128[GRID_SIZE] storage totalDeployedForRound = totalDeployedPerBlock[roundId];

        // Gas optimization: use uint8 for loop since max length is 25
        uint8 length = uint8(blockIds.length);
        for (uint8 i = 0; i < length;) {
            uint8 blockId = blockIds[i];
            if (blockId >= GRID_SIZE) revert InvalidBlock();

            // Update user deployments
            userDeployedForRound[blockId] += amountPerBlock;
            totalDeployedForRound[blockId] += amountPerBlock;

            unchecked { ++i; } // Gas optimization: i cannot overflow
        }

        // Note: userRoundData.totalDeployed removed - available via Deployed events
        round.totalDeployed += uint128(msg.value);

        // Single batch event instead of per-block events
        emit Deployed(roundId, msg.sender, blockIds, amountPerBlock);

        // === INTERACTIONS (external calls LAST) ===
        // Forward msg.value to vault
        (bool success,) = address(vault).call{value: msg.value}("");
        if (!success) revert VaultDepositFailed();
    }

    /// @notice Close current round once its deployment window has expired
    /// @dev Admin-only close is retained; close-time randomness remains a tracked accepted risk.
    function closeRound() external {
        if (msg.sender != admin) revert NotAdmin();
        Round storage round = rounds[currentRound];
        if (round.state != RoundState.ACTIVE) revert RoundNotActive();
        if (block.timestamp < round.startTime + roundDuration)
            revert RoundStillActive();

        _closeRound();
    }

    /// @notice Internal function to close round
    function _closeRound() internal virtual override {
        Round storage round = rounds[currentRound];
        round.state = RoundState.CLOSED;

        // CRITICAL: Capture prevrandao at close time (not reveal time)
        // This prevents manipulation after seed is revealed
        round.closedAtPrevrandao = block.prevrandao;

        emit RoundClosed(currentRound, round.totalDeployed, block.prevrandao);
    }

    /// @notice Reveal seed and resolve round
    /// @param roundId Round to reveal
    /// @param seed Revealed seed value
    /// @dev Only admin can reveal. Verifies commitment and generates randomness.
    function revealSeed(uint32 roundId, bytes16 seed) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();

        Round storage round = rounds[roundId];
        if (round.state != RoundState.CLOSED) revert RoundNotReadyForReveal();

        // Verify commitment: keccak256(abi.encodePacked(seed, roundId)) == commitHash
        bytes32 computedCommit = keccak256(abi.encodePacked(seed, roundId));
        if (computedCommit != round.commitHash) revert CommitmentMismatch();

        // Store revealed seed
        round.revealedSeed = seed;

        // Generate randomness: keccak256(seed, prevrandao, roundId)
        // Use the prevrandao that was captured at close time
        uint256 randomness = uint256(
            keccak256(abi.encodePacked(seed, round.closedAtPrevrandao, roundId))
        );

        emit SeedRevealed(roundId, seed, randomness);

        // Resolve round with generated randomness
        _resolveRound(roundId, randomness);
    }

    /// @notice Resolve round with randomness
    /// @param roundId Round to resolve
    /// @param randomness Random number
    /// @dev Follows CEI (Checks-Effects-Interactions) pattern to prevent reentrancy
    function _resolveRound(uint32 roundId, uint256 randomness) internal {
        Round storage round = rounds[roundId];

        // === EFFECTS (State Updates) ===

        // Determine winning block (0-24)
        uint8 winningBlock = uint8(randomness % GRID_SIZE);
        round.winningBlock = winningBlock;

        // Determine reward mode (split or jackpot) from random bits
        round.mode = ((randomness >> 8) % 2 == 0)
            ? RewardMode.SPLIT
            : RewardMode.JACKPOT;

        // Check morelode trigger
        bool morelodeTriggered = (randomness % MORELODE_CHANCE) == 0;
        round.morelodeTriggered = morelodeTriggered;

        uint128 totalDep = round.totalDeployed;

        // Calculate fees (use uint256 for intermediate calculation to prevent overflow)
        uint128 protocolFee = uint128((uint256(totalDep) * PROTOCOL_FEE_BPS) / 10000);
        uint128 adminFee = uint128((uint256(totalDep) * ADMIN_FEE_BPS) / 10000);

        protocolRevenueBalance += protocolFee;
        adminFeeBalance += adminFee;

        // Cache morelode values before state changes
        uint128 morelodeAmount = 0;
        uint128 emittedMorelodeAmount = 0;
        uint128 cachedMorelodePool = morelodePool;

        // Trigger morelode if applicable (update state)
        if (morelodeTriggered && cachedMorelodePool > 0) {
            morelodeAmount = cachedMorelodePool;
            morelodePool = 0;
        }

        // Check if winners exist
        uint128 winnerTotal = totalDeployedPerBlock[roundId][winningBlock];
        bool hasWinners = winnerTotal > 0;

        // Calculate net pool (after fees)
        uint128 netPool = totalDep - protocolFee - adminFee;

        // If no winners, send net pool to treasury (like ORE does)
        if (!hasWinners && netPool > 0) {
            protocolRevenueBalance += netPool;
            netPool = 0;
        }

        // Store netPool for checkpoint calculation
        round.netPool = netPool;

        if (hasWinners) {
            emittedMorelodeAmount = _mintRoundMore(roundId, morelodeAmount);
            morelodePool += MORELODE_INCREMENT;
        }

        // Mark round as resolved
        round.state = RoundState.RESOLVED;

        // Start new round
        _startNewRound();

        emit RoundResolved(
            roundId,
            winningBlock,
            round.mode,
            morelodeTriggered,
            emittedMorelodeAmount
        );
    }

    function _mintRoundMore(
        uint32 roundId,
        uint128 morelodeAmount
    ) internal returns (uint128 emittedMorelodeAmount) {
        uint128 totalMoreReward = MORE_PER_ROUND + morelodeAmount;
        Round storage round = rounds[roundId];

        try moreToken.mint(address(vault), totalMoreReward) {
            round.moreReward = totalMoreReward;
            emittedMorelodeAmount = morelodeAmount;
        } catch {
            round.moreReward = 0;
            if (morelodeAmount > 0) {
                morelodePool += morelodeAmount;
            }
        }
    }

    /// @notice Start a new round
    /// @dev Gas optimized: uses storage reference instead of struct literal
    ///      Avoids explicit 0/false initializations (Solidity defaults)
    function _startNewRound() internal virtual override {
        currentRound++;

        // Check if commitment was made for this round
        bytes32 commitment = nextRoundCommitment;
        RoundState initialState = commitment != bytes32(0)
            ? RoundState.ACTIVE
            : RoundState.PENDING;

        // Gas optimization: use storage reference, only set non-zero values
        // Solidity automatically initializes storage to 0/false/bytes32(0)
        Round storage newRound = rounds[currentRound];
        newRound.startTime = uint40(block.timestamp);
        newRound.commitHash = commitment;
        newRound.state = initialState;
        // mode defaults to RewardMode.SPLIT (0)
        // All other fields default to 0/false/bytes32(0)

        // Clear next round commitment
        nextRoundCommitment = bytes32(0);

        if (initialState == RoundState.ACTIVE) {
            emit RoundActivated(currentRound, uint40(block.timestamp));
        }
    }

    /// @notice Internal deploy logic shared between deploy() and deployForUser()
    /// @param user User address
    /// @param blockIds Block IDs to deploy to
    /// @param amountPerBlock Amount per block
    function _internalDeploy(
        address user,
        uint8[] memory blockIds,
        uint128 amountPerBlock
    ) internal virtual override {
        uint32 roundId = currentRound;
        Round storage round = rounds[roundId];

        // Cache storage references
        uint128[GRID_SIZE] storage userDeployedForRound = userDeployed[roundId][user];
        uint128[GRID_SIZE] storage totalDeployedForRound = totalDeployedPerBlock[roundId];

        uint128 totalAmount = 0;
        uint8 length = uint8(blockIds.length);

        for (uint8 i = 0; i < length;) {
            uint8 blockId = blockIds[i];
            if (blockId >= GRID_SIZE) revert InvalidBlock();

            // Update deployments
            userDeployedForRound[blockId] += amountPerBlock;
            totalDeployedForRound[blockId] += amountPerBlock;
            totalAmount += amountPerBlock;

            unchecked { ++i; }
        }

        // Note: userRoundData.totalDeployed removed - available via Deployed events
        round.totalDeployed += totalAmount;
    }
}
