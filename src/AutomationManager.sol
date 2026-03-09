// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./interfaces/IMiningGame.sol";
import "./mining/MiningGameTypes.sol";

/// @title AutomationManager
/// @notice Manages automation for MiningGame (auto-deploy functionality)
/// @dev Separate contract to reduce MiningGame bytecode size (UUPS Upgradeable)
contract AutomationManager is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice MiningGame contract reference
    IMiningGame public miningGame;

    /// @notice Shared executor for batch automation
    address public sharedExecutor;

    /// @notice User automation configurations
    mapping(address => Automation) public automations;

    /// @notice Protocol-level executor fee (0.03 MON for 300K gas @ 100 gwei)
    uint96 public executorFee;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    // Errors and Events are defined in MiningGameTypes.sol

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _miningGame MiningGame contract address
    /// @param _owner Owner address for admin actions
    function initialize(address _miningGame, address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);

        if (_miningGame == address(0)) revert ZeroAddress();
        miningGame = IMiningGame(_miningGame);
        executorFee = 0.03 ether; // 300K gas × 100 gwei
    }

    /*//////////////////////////////////////////////////////////////
                            UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        AUTOMATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new automation
    /// @param amountPerBlock Amount to deploy per block each round
    /// @param blockMask Bitmask for block selection (for PREFERRED/RANDOM strategy)
    /// @param strategy Automation strategy type
    /// @param autoReload Auto-reload winnings into balance
    /// @param rounds Number of rounds this automation will run
    function createAutomation(
        uint128 amountPerBlock,
        uint32 blockMask,
        AutomationStrategy strategy,
        bool autoReload,
        uint16 rounds
    ) external payable nonReentrant {
        if (amountPerBlock == 0) revert InvalidAmountPerBlock();
        if (automations[msg.sender].active) revert AutomationAlreadyExists();
        if (strategy == AutomationStrategy.PREFERRED && blockMask == 0) revert InvalidBlockMask();
        if (blockMask > ((1 << GRID_SIZE) - 1)) revert InvalidBlockMask();
        if (rounds == 0) revert NoRoundsRemaining();

        automations[msg.sender] = Automation({
            authority: msg.sender,
            strategy: strategy,
            autoReload: autoReload,
            active: true,
            blockMask: blockMask,
            lastDeployedRound: 0,
            remainingRounds: rounds,
            balance: uint128(msg.value),
            amountPerBlock: amountPerBlock
        });

        emit AutomationCreated(
            msg.sender,
            amountPerBlock,
            blockMask,
            strategy,
            autoReload,
            uint128(msg.value),
            rounds
        );
        if (msg.value > 0) {
            emit AutomationFunded(msg.sender, uint128(msg.value), uint128(msg.value));
        }
    }

    /// @notice Fund automation balance
    function fundAutomation() external payable nonReentrant {
        Automation storage auto_ = automations[msg.sender];
        if (!auto_.active) revert AutomationNotFound();
        if (msg.value == 0) revert InvalidDeployAmount();

        auto_.balance += uint128(msg.value);
        emit AutomationFunded(msg.sender, uint128(msg.value), auto_.balance);
    }

    /// @notice Withdraw from automation balance
    function withdrawAutomation(uint128 amount) external nonReentrant {
        Automation storage auto_ = automations[msg.sender];
        if (!auto_.active) revert AutomationNotFound();
        if (amount > auto_.balance) revert InsufficientAutomationBalance();

        auto_.balance -= amount;
        emit AutomationWithdrawn(msg.sender, amount, auto_.balance);

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Add more rounds to automation
    /// @param additionalRounds Number of rounds to add
    function addRounds(uint16 additionalRounds) external nonReentrant {
        Automation storage auto_ = automations[msg.sender];
        if (!auto_.active) revert AutomationNotFound();
        if (additionalRounds == 0) revert NoRoundsRemaining();

        uint16 newRemainingRounds = auto_.remainingRounds + additionalRounds;
        // Check for overflow
        if (newRemainingRounds < auto_.remainingRounds) revert InvalidDeployAmount();

        auto_.remainingRounds = newRemainingRounds;
        emit RoundsAdded(msg.sender, additionalRounds, newRemainingRounds);
    }

    /// @notice Close automation and refund remaining balance + feeBalance
    function closeAutomation() external nonReentrant {
        _closeAutomation(msg.sender);
    }

    /// @notice Close automation for a user (only callable by owner or sharedExecutor)
    /// @dev Used for: 1) Pre-upgrade cleanup 2) Closing depleted automations
    /// @param user The user whose automation to close
    function closeAutomationFor(address user) external nonReentrant {
        if (msg.sender != owner() && msg.sender != sharedExecutor) revert NotExecutor();
        _closeAutomation(user);
    }

    /// @notice Batch close automations for multiple users
    /// @param users Array of users whose automations to close
    function batchCloseAutomationsFor(address[] calldata users) external nonReentrant {
        if (msg.sender != owner() && msg.sender != sharedExecutor) revert NotExecutor();
        for (uint256 i = 0; i < users.length; i++) {
            if (automations[users[i]].active) {
                _closeAutomation(users[i]);
            }
        }
    }

    /// @dev Internal close automation logic
    function _closeAutomation(address user) internal {
        Automation storage auto_ = automations[user];
        if (!auto_.active) revert AutomationNotFound();

        uint128 refundBalance = auto_.balance;
        delete automations[user];

        emit AutomationClosed(user, refundBalance, 0);

        if (refundBalance > 0) {
            (bool success, ) = user.call{value: refundBalance}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @notice Deploy on behalf of a user (only callable by sharedExecutor)
    function deployForUser(address user, uint8[] calldata blockIds) external nonReentrant {
        if (msg.sender != sharedExecutor) revert NotExecutor();
        uint96 fee = _executeAutomationDeploy(user, blockIds);

        // Pay executor fee after successful deploy
        if (fee > 0) {
            (bool success, ) = msg.sender.call{value: fee}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @notice Batch deploy for multiple users
    /// @dev Executor fee is accumulated and paid once at the end for successful deploys only
    function batchDeployForUsers(
        address[] calldata users,
        uint8[][] calldata blockIdsPerUser
    ) external nonReentrant {
        if (msg.sender != sharedExecutor) revert NotExecutor();
        if (users.length != blockIdsPerUser.length) revert InvalidDeployAmount();

        uint256 totalFees = 0;

        for (uint256 i = 0; i < users.length; i++) {
            try this.deployForUserInternal(users[i], blockIdsPerUser[i]) returns (uint96 fee) {
                totalFees += fee;
            } catch (bytes memory reason) {
                emit BatchDeployFailed(users[i], reason);
            }
        }

        // Pay accumulated executor fees for successful deploys only
        if (totalFees > 0) {
            (bool success, ) = msg.sender.call{value: totalFees}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @notice Internal deploy for batch calls (returns executor fee)
    function deployForUserInternal(address user, uint8[] calldata blockIds) external returns (uint96) {
        require(msg.sender == address(this), "Only internal");
        return _executeAutomationDeploy(user, blockIds);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set shared executor
    function setSharedExecutor(address _sharedExecutor) external onlyOwner {
        address oldExecutor = sharedExecutor;
        sharedExecutor = _sharedExecutor;
        emit SharedExecutorUpdated(oldExecutor, _sharedExecutor);
    }

    /// @notice Set MiningGame address (for upgrades)
    function setMiningGame(address _miningGame) external onlyOwner {
        if (_miningGame == address(0)) revert ZeroAddress();
        miningGame = IMiningGame(_miningGame);
    }

    /// @notice Set executor fee (onlyOwner)
    /// @param _fee New executor fee in wei
    function setExecutorFee(uint96 _fee) external onlyOwner {
        uint96 oldFee = executorFee;
        executorFee = _fee;
        emit ExecutorFeeUpdated(oldFee, _fee);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Slither "arbitrary-send-eth" is a false positive:
    ///      - miningGame is a trusted contract set by owner
    ///      - user is verified via automations mapping (only automation owner's funds)
    /// @return fee Executor fee to be paid by the caller after successful deploy
    // slither-disable-next-line arbitrary-send-eth
    function _executeAutomationDeploy(
        address user,
        uint8[] calldata blockIds
    ) internal returns (uint96) {
        Automation storage auto_ = automations[user];
        if (!auto_.active) revert AutomationNotActive();
        if (auto_.remainingRounds == 0) revert NoRoundsRemaining();

        uint32 roundId = miningGame.currentRound();

        // Get round state
        (uint40 startTime,, RoundState state,,,,,,,,) = miningGame.rounds(roundId);

        if (state != RoundState.ACTIVE) revert RoundNotActive();
        if (block.timestamp >= startTime + miningGame.roundDuration()) revert RoundExpired();
        if (auto_.lastDeployedRound == roundId) revert AlreadyDeployedThisRound();

        // Determine blocks
        uint8[] memory deployBlocks = _getDeployBlocks(user, roundId, auto_.strategy, auto_.blockMask, blockIds);
        if (deployBlocks.length == 0) revert InvalidDeployAmount();

        uint128 deployAmount = auto_.amountPerBlock * uint128(deployBlocks.length);
        uint96 fee = executorFee;
        uint128 totalCost = deployAmount + uint128(fee);

        // Check balance covers both deploy amount and executor fee
        if (auto_.balance < totalCost) revert InsufficientAutomationBalance();

        // Auto-checkpoint and reload
        _autoCheckpointAndReload(user, roundId, auto_);

        // Update state - deduct total cost from balance and decrement rounds
        auto_.balance -= totalCost;
        auto_.remainingRounds--;
        auto_.lastDeployedRound = uint24(roundId);

        // Call MiningGame to deploy
        miningGame.deployFromAutomation{value: deployAmount}(user, deployBlocks, auto_.amountPerBlock);

        emit AutomationDeployed(roundId, user, sharedExecutor, deployBlocks, auto_.amountPerBlock, fee);

        // Return fee for caller to transfer (ensures fee is only paid on successful deploy)
        return fee;
    }

    function _getDeployBlocks(
        address user,
        uint32 roundId,
        AutomationStrategy strategy,
        uint32 blockMask,
        uint8[] calldata providedBlocks
    ) internal view returns (uint8[] memory) {
        if (strategy == AutomationStrategy.RANDOM) {
            return _generateRandomBlocks(user, roundId, blockMask);
        } else if (strategy == AutomationStrategy.PREFERRED) {
            return _maskToBlockIds(blockMask);
        } else {
            uint8 numBlocks = uint8(blockMask & 0xFF);
            if (numBlocks == 0) numBlocks = 1;
            if (numBlocks > GRID_SIZE) numBlocks = GRID_SIZE;
            if (providedBlocks.length != numBlocks) revert TooManyBlocks();

            uint8[] memory result = new uint8[](providedBlocks.length);
            for (uint8 i = 0; i < providedBlocks.length; i++) {
                result[i] = providedBlocks[i];
            }
            return result;
        }
    }

    function _autoCheckpointAndReload(address user, uint32 roundId, Automation storage auto_) internal {
        uint32 lastRound = miningGame.lastParticipatedRound(user);
        if (lastRound > 0 && lastRound != roundId) {
            (,, RoundState state,,,,,,,,) = miningGame.rounds(lastRound);
            if (state == RoundState.RESOLVED) {
                (bool nativeClaimed,) = miningGame.userRoundData(lastRound, user);
                if (!nativeClaimed) {
                    miningGame.checkpointFor(lastRound, user);

                    if (auto_.autoReload) {
                        // Withdraw user's native rewards directly to automation balance
                        uint128 reloadedAmount = miningGame.withdrawNativeToAutomation(user);
                        if (reloadedAmount > 0) {
                            auto_.balance += reloadedAmount;
                            emit AutomationReloaded(user, reloadedAmount);
                        }
                    }
                }
            }
        }
    }

    /// @dev Uses block.prevrandao for unpredictable randomness
    /// @dev Note: block.prevrandao is known at execution time but not predictable beforehand
    function _generateRandomBlocks(
        address user,
        uint32 roundId,
        uint32 numBlocksOrMask
    ) internal view returns (uint8[] memory) {
        uint8 numBlocks = uint8(numBlocksOrMask & 0xFF);
        if (numBlocks == 0) numBlocks = 1;
        if (numBlocks > GRID_SIZE) numBlocks = uint8(GRID_SIZE);

        uint8[GRID_SIZE] memory pool;
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            pool[i] = i;
        }

        // Include block.prevrandao to prevent prediction before execution
        bytes32 seed = keccak256(abi.encodePacked(user, roundId, block.prevrandao));
        uint8[] memory result = new uint8[](numBlocks);

        for (uint8 i = 0; i < numBlocks; i++) {
            uint8 j = i + uint8(uint256(keccak256(abi.encodePacked(seed, i))) % (GRID_SIZE - i));
            (pool[i], pool[j]) = (pool[j], pool[i]);
            result[i] = pool[i];
        }

        return result;
    }

    function _maskToBlockIds(uint32 mask) internal pure returns (uint8[] memory) {
        uint8[GRID_SIZE] memory temp;
        uint8 count = 0;

        for (uint8 i = 0; i < GRID_SIZE;) {
            if ((mask & (1 << i)) != 0) {
                temp[count] = i;
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        uint8[] memory blockIds = new uint8[](count);
        for (uint8 i = 0; i < count;) {
            blockIds[i] = temp[i];
            unchecked { ++i; }
        }

        return blockIds;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get automation info for a user
    function getAutomation(address user) external view returns (AutomationInfo memory info) {
        Automation storage auto_ = automations[user];
        info.authority = auto_.authority;
        info.balance = auto_.balance;
        info.amountPerBlock = auto_.amountPerBlock;
        info.blockMask = auto_.blockMask;
        info.lastDeployedRound = auto_.lastDeployedRound;
        info.remainingRounds = auto_.remainingRounds;
        info.strategy = auto_.strategy;
        info.autoReload = auto_.autoReload;
        info.active = auto_.active;
    }

    /// @notice Check if automation can deploy
    /// @return canDeploy Whether the automation can deploy
    /// @return reason Reason code: 0=success, 1=inactive, 2=already deployed, 3=balance insufficient, 4=round not active, 5=no rounds remaining
    function canAutomationDeploy(address user) public view returns (bool canDeploy, uint8 reason) {
        Automation storage auto_ = automations[user];

        if (!auto_.active) return (false, 1);
        if (auto_.remainingRounds == 0) return (false, 5);

        uint32 roundId = miningGame.currentRound();
        if (auto_.lastDeployedRound == roundId) return (false, 2);

        uint8 numBlocks;
        if (auto_.strategy == AutomationStrategy.RANDOM) {
            numBlocks = uint8(auto_.blockMask & 0xFF);
            if (numBlocks == 0) numBlocks = 1;
            if (numBlocks > GRID_SIZE) numBlocks = GRID_SIZE;
        } else if (auto_.strategy == AutomationStrategy.PREFERRED) {
            uint32 mask = auto_.blockMask;
            while (mask != 0) {
                mask &= (mask - 1);
                unchecked { ++numBlocks; }
            }
        } else {
            numBlocks = 1;
        }

        // Check balance covers both deploy amount and executor fee
        uint128 deployAmount = auto_.amountPerBlock * numBlocks;
        uint128 totalCost = deployAmount + uint128(executorFee);
        if (auto_.balance < totalCost) return (false, 3);

        (uint40 startTime,, RoundState state,,,,,,,,) = miningGame.rounds(roundId);
        if (state != RoundState.ACTIVE) return (false, 4);
        if (block.timestamp >= startTime + miningGame.roundDuration()) return (false, 4);

        return (true, 0);
    }

    /// @notice Batch check if automations can deploy (gas-efficient for executor)
    /// @param users Array of user addresses to check
    /// @return canDeploys Array of whether each user can deploy
    /// @return reasons Array of reason codes for each user
    function batchCanAutomationDeploy(address[] calldata users) external view returns (bool[] memory canDeploys, uint8[] memory reasons) {
        canDeploys = new bool[](users.length);
        reasons = new uint8[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            (canDeploys[i], reasons[i]) = canAutomationDeploy(users[i]);
        }
    }

    receive() external payable {}
}
