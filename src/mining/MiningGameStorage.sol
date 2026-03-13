// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "../MoreToken.sol";
import "../interfaces/IVault.sol";
import "./MiningGameTypes.sol";

/// @title MiningGameStorage
/// @notice State variables for MiningGame
/// @dev Abstract contract providing all storage variables (UUPS Upgradeable)
/// @dev Uses ReentrancyGuardTransient (EIP-1153) - no initialization needed, works with proxies
abstract contract MiningGameStorage is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice MORE token contract
    /// @dev Changed from immutable to storage for upgradeability
    MoreToken public moreToken;

    /// @notice Treasury contract for protocol fees
    /// @dev Packed with roundDuration to save gas (20 bytes + 2 bytes = 22 bytes in 1 slot)
    address public treasury;

    /// @notice Round duration in seconds (max 65,535 seconds = ~18.2 hours)
    /// @dev Packed with treasury in same storage slot
    uint16 public roundDuration;

    /// @notice Admin address for admin fees
    /// @dev Packed with currentRound (20 bytes + 4 bytes = 24 bytes in 1 slot)
    address public admin;

    /// @notice Current round ID (max ~8,171 years at 1 round/min)
    /// @dev Packed with admin in same storage slot
    uint32 public currentRound;

    /// @notice Morelode pool balance (MORE tokens, uint128 sufficient)
    uint128 public morelodePool;

    /// @notice Protocol revenue balance (MON tokens, uint128 sufficient)
    uint128 public protocolRevenueBalance;

    /// @notice Admin fee balance (MON tokens, uint128 sufficient)
    uint128 public adminFeeBalance;

    /// @notice Global reward index for refining fee redistribution
    /// @dev Uses PRECISION (1e18) but accumulated value stays within uint128
    uint128 public globalRewardIndex;

    /// @notice Total unclaimed MORE across all users (MORE tokens, uint128 sufficient)
    uint128 public totalUnclaimedMore;

    /// @notice Commitment hash for next round
    bytes32 public nextRoundCommitment;

    /// @notice Last participated round per user (for checkpoint enforcement)
    mapping(address => uint32) public lastParticipatedRound;

    /*//////////////////////////////////////////////////////////////
                               MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Round data by round ID
    mapping(uint32 => Round) public rounds;

    /// @notice User deployments per round per block: roundId => user => blockId => amount
    /// @dev uint128 sufficient (10^38 max, MON max ~10^29). Saves ~12 slots per user per round.
    mapping(uint32 => mapping(address => uint128[GRID_SIZE])) public userDeployed;

    /// @notice Total deployments per block per round: roundId => blockId => total
    /// @dev uint128 sufficient. 25 elements pack into 13 slots instead of 25.
    mapping(uint32 => uint128[GRID_SIZE]) public totalDeployedPerBlock;

    /// @notice User round-specific data: roundId => user => data
    /// @dev Only stores claim flags; other data available via Deployed events
    mapping(uint32 => mapping(address => UserRoundData)) public userRoundData;

    /// @notice User reward data for refining fees
    mapping(address => UserRewardData) public userRewardData;

    /// @notice Vault contract for holding funds
    /// @dev Non-upgradeable vault with immutable controller (this proxy)
    IVault public vault;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage gap for future upgrades
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (replaces constructor)
    /// @param _moreToken MORE token address
    /// @param _treasury Treasury address
    /// @param _admin Admin address
    /// @param _vault Vault contract address
    function __MiningGameStorage_init(
        address _moreToken,
        address _treasury,
        address _admin,
        address _vault
    ) internal onlyInitializing {
        // Set ownership to the provided admin (not the proxy itself)
        __Ownable_init(_admin);

        if (
            _moreToken == address(0) ||
            _treasury == address(0) ||
            _admin == address(0) ||
            _vault == address(0)
        ) revert ZeroAddress();

        moreToken = MoreToken(_moreToken);
        treasury = _treasury;
        admin = _admin;
        vault = IVault(_vault);
        roundDuration = 60;

        // Create first round in PENDING state (waiting for commitment)
        currentRound = 1;
        rounds[1] = Round({
            startTime: uint40(block.timestamp),
            winningBlock: 0,
            state: RoundState.PENDING,
            mode: RewardMode.SPLIT,
            morelodeTriggered: false,
            totalDeployed: 0,
            netPool: 0,
            moreReward: 0,
            revealedSeed: bytes16(0),
            closedAtPrevrandao: 0,
            commitHash: bytes32(0)
        });
    }

    /*//////////////////////////////////////////////////////////////
                            UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorize upgrade (only owner)
    /// @param newImplementation New implementation address
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
