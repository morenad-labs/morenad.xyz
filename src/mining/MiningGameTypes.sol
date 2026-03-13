// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// MiningGameTypes
// Constants, enums, structs, errors, and events for MiningGame
// Base definitions for all MiningGame modules

/*//////////////////////////////////////////////////////////////
                            CONSTANTS
//////////////////////////////////////////////////////////////*/

/// @dev Grid size for block selection (25 blocks, 0-24)
uint8 constant GRID_SIZE = 25;

/// @dev Precision for reward index calculations (1e18)
uint256 constant PRECISION = 1e18;

/// @dev Fee basis points (10000 = 100%)
uint16 constant PROTOCOL_FEE_BPS = 1000; // 10%
uint16 constant ADMIN_FEE_BPS = 100; // 1%
uint16 constant REFINING_FEE_BPS = 1000; // 10%

/// @dev Morelode trigger chance (1/625)
uint16 constant MORELODE_CHANCE = 625;

/// @dev MORE token amounts (uint128 to match storage types)
uint128 constant MORE_PER_ROUND = 1e18; // 1 MORE
uint128 constant MORELODE_INCREMENT = 0.2e18; // 0.2 MORE

/*//////////////////////////////////////////////////////////////
                             ENUMS
//////////////////////////////////////////////////////////////*/

enum RoundState {
    PENDING,        // Waiting for commitment or commitment made but round not started
    ACTIVE,         // Deploying active
    CLOSED,         // Deploying ended, waiting for seed reveal
    RESOLVED,       // Seed revealed, winners determined
    EMERGENCY_SKIP  // Emergency skipped (refunds available)
}

enum RewardMode {
    SPLIT,
    JACKPOT
}

/// @notice Automation strategy types (inspired by ORE)
enum AutomationStrategy {
    RANDOM,       // Random block selection based on hash
    PREFERRED,    // Use user-defined block mask
    DISCRETIONARY // Executor chooses blocks within user's limits
}

/*//////////////////////////////////////////////////////////////
                            STRUCTS
//////////////////////////////////////////////////////////////*/

/// @notice Round data structure (gas optimized via storage slot packing)
/// @dev Layout: 5 slots instead of 9 (saves ~80,000 gas per round)
///      Slot 1: startTime(40) + winningBlock(8) + state(8) + mode(8) + morelodeTriggered(8) = 72 bits
///      Slot 2: totalDeployed(128) + netPool(128) = 256 bits (perfect packing)
///      Slot 3: moreReward(128) + revealedSeed(128) = 256 bits (perfect packing)
///      Slot 4: closedAtPrevrandao(256) = 256 bits
///      Slot 5: commitHash(256) = 256 bits
struct Round {
    // Slot 1: Packed metadata
    uint40 startTime;             // Timestamp (~34,000 years)
    uint8 winningBlock;           // 0-24 range
    RoundState state;
    RewardMode mode;
    bool morelodeTriggered;
    // Slot 2: Token amounts (perfect packing)
    uint128 totalDeployed;
    uint128 netPool;              // Net pool after fees (for checkpoint calculation)
    // Slot 3: MORE reward + seed (perfect packing)
    uint128 moreReward;           // MORE reward for this round (0 if mint failed)
    bytes16 revealedSeed;         // Revealed seed (0 until revealed)
    // Slot 4: Randomness
    uint256 closedAtPrevrandao;   // block.prevrandao captured at close time
    // Slot 5: Commitment hash
    bytes32 commitHash;           // Commitment hash for this round
}

/// @dev User's per-round deployment data available via Deployed events (gas optimization)
struct UserRoundData {
    bool nativeClaimed;
    bool moreClaimed;
}

/// @notice User reward data (gas optimized via storage slot packing)
/// @dev Layout: 2 slots instead of 3 (saves ~40,000 gas per checkpoint)
///      Slot 1: unclaimedNative(128) + unclaimedMore(128) = 256 bits (perfect packing)
///      Slot 2: rewardIndex(128) + accumulatedRefined(128) = 256 bits (perfect packing)
struct UserRewardData {
    // Slot 1: Unclaimed tokens (perfect packing)
    uint128 unclaimedNative;      // Native tokens pending withdrawal
    uint128 unclaimedMore;        // MORE pending claim (subject to refining fee)
    // Slot 2: Reward tracking (perfect packing)
    uint128 rewardIndex;          // User's last updated reward index
    uint128 accumulatedRefined;   // Refined MORE accumulated from others' fees
}

/// @notice Round result information for frontend display
/// @dev winnerCount removed - available via Deployed events (gas optimization)
struct RoundResultInfo {
    RoundState state;
    uint8 winningBlock;
    uint128 totalDeployed;
    uint128 netPool;
    uint128 moreReward;
    uint128 winningBlockTotal;
    RewardMode mode;
    bool morelodeTriggered;
}

/// @notice Winner information for a specific user
struct WinnerInfo {
    bool isWinner;
    uint128 deployedAmount;
    uint128 nativeReward;
    uint128 moreReward;
}

/// @notice Automation configuration for auto-deploying (inspired by ORE)
/// @dev Layout: 2 slots (gas optimized)
///      Slot 1: authority(160) + strategy(8) + autoReload(8) + active(8) + blockMask(32) + lastDeployedRound(24) + remainingRounds(16) = 256 bits
///      Slot 2: balance(128) + amountPerBlock(128) = 256 bits (perfect packing)
struct Automation {
    // Slot 1: Authority + flags + settings (256 bits perfect packing)
    address authority;            // User who owns this automation (160 bits)
    AutomationStrategy strategy;  // Strategy type (8 bits)
    bool autoReload;              // Auto-reload winnings into balance
    bool active;                  // Whether automation is active
    uint32 blockMask;             // Bitmask for block selection (25 bits used)
    uint24 lastDeployedRound;     // Last round this automation deployed (~31 years at 1min/round)
    uint16 remainingRounds;       // Remaining rounds before automation stops (~45 days at 1min/round)
    // Slot 2: Token amounts (perfect packing)
    uint128 balance;              // Pre-deposited ETH for betting + executor fees
    uint128 amountPerBlock;       // Amount to deploy per block each round
}

/// @notice Automation info for frontend display
struct AutomationInfo {
    address authority;
    uint128 balance;
    uint128 amountPerBlock;
    uint32 blockMask;
    uint24 lastDeployedRound;
    uint16 remainingRounds;
    AutomationStrategy strategy;
    bool autoReload;
    bool active;
}

/*//////////////////////////////////////////////////////////////
                             ERRORS
//////////////////////////////////////////////////////////////*/

error RoundNotActive();
error RoundNotPending();
error RoundNotResolved();
error NotCurrentRound();
error RoundNotClosed();
error RoundAlreadyResolved();
error InvalidBlock();
error InvalidDeployAmount();
error RoundStillActive();
error AlreadyClaimed();
error NothingToClaim();
error ZeroAddress();
error TransferFailed();
error NotAdmin();
error RoundExpired();
error NoCommitment();
error InvalidSeed();
error CommitmentMismatch();
error CommitmentAlreadyMade();
error RoundNotReadyForReveal();
error AdminCannotDeploy();
error AutomationNotActive();
error NotExecutor();
error InsufficientAutomationBalance();
error AutomationAlreadyExists();
error AutomationNotFound();
error AlreadyDeployedThisRound();
error InvalidBlockMask();
error InvalidAmountPerBlock();
error TooManyBlocks();
error VaultDepositFailed();
error NoRoundsRemaining();
error RoundIdOverflow();
error NoPendingRefund();
error ReloadAmountMismatch(uint128 reportedAmount, uint128 receivedAmount);

/*//////////////////////////////////////////////////////////////
                             EVENTS
//////////////////////////////////////////////////////////////*/

event Deployed(
    uint32 indexed roundId,
    address indexed user,
    uint8[] blockIds,
    uint128 amountPerBlock
);

event RoundClosed(uint32 indexed roundId, uint128 totalDeployed, uint256 prevrandao);

event CommitmentMade(uint32 indexed roundId, bytes32 commitHash);

event SeedRevealed(uint32 indexed roundId, bytes16 seed, uint256 randomness);

event RoundActivated(uint32 indexed roundId, uint40 startTime);

event RoundResolved(
    uint32 indexed roundId,
    uint8 winningBlock,
    RewardMode mode,
    bool morelodeTriggered,
    uint128 morelodeAmount
);

event MoreClaimed(address indexed user, uint128 amount, uint128 refinedFee);

event NativeClaimed(
    uint32 indexed roundId,
    address indexed user,
    uint128 amount
);

event NativeWithdrawn(address indexed user, uint128 amount);

event RefinedMoreDistributed(uint128 amount, uint128 newGlobalIndex);
event RefiningFeeRolledToMorelode(uint128 amount, uint128 newMorelodePool);

event ProtocolRevenueWithdrawn(address indexed treasury, uint128 amount);

event AdminFeeWithdrawn(address indexed admin, uint128 amount);

event AutomationCreated(
    address indexed authority,
    uint128 amountPerBlock,
    uint32 blockMask,
    AutomationStrategy strategy,
    bool autoReload,
    uint128 initialBalance,
    uint16 initialRounds
);

event AutomationFunded(address indexed authority, uint128 amount, uint128 newBalance);

event AutomationWithdrawn(address indexed authority, uint128 amount, uint128 newBalance);

event AutomationClosed(
    address indexed authority,
    uint128 refundedBalance,
    uint128 refundedFeeBalance
);

event AutomationDeployed(
    uint32 indexed roundId,
    address indexed authority,
    address indexed executor,
    uint8[] blockIds,
    uint128 amountPerBlock,
    uint96 executorFee
);

event AutomationReloaded(address indexed authority, uint128 amount);

event SharedExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

event ExecutorFeeUpdated(uint96 oldFee, uint96 newFee);

event RoundsAdded(address indexed authority, uint16 addedRounds, uint16 newRemainingRounds);

event BatchDeployFailed(address indexed user, bytes reason);
event AutomationRefundQueued(address indexed authority, uint128 amount, uint128 newPendingRefund);
event PendingRefundClaimed(address indexed authority, address indexed recipient, uint128 amount);

event EmergencySkip(uint32 indexed roundId);

event EmergencyRefund(uint32 indexed roundId, address indexed user, uint128 amount);
