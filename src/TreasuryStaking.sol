// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MoreToken.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IUniswapV2Router02.sol";

/// @title TreasuryStaking
/// @notice Receives protocol revenue, performs buybacks, burns MORE, and distributes to stakers
/// @dev Uses Synthetix-style reward distribution pattern (UUPS Upgradeable)
/// @dev Uses ReentrancyGuardTransient (EIP-1153) - no initialization needed, works with proxies
contract TreasuryStaking is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for MoreToken;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BURN_BPS = 9000; // 90%
    uint256 public constant UNSTAKE_COOLDOWN = 1 days;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice MORE token
    /// @dev Changed from immutable to storage for upgradeability
    MoreToken public moreToken;

    /// @notice Total MORE staked
    uint256 public totalStaked;

    /// @notice Reward per token stored
    uint256 public rewardPerTokenStored;

    /// @notice Last update time
    uint256 public lastUpdateTime;

    /*//////////////////////////////////////////////////////////////
                               MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice User staked balances
    mapping(address => uint256) public stakedBalance;

    /// @notice User reward per token paid
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice User rewards
    mapping(address => uint256) public rewards;

    /// @notice Timestamp when a user can next unstake
    mapping(address => uint256) public unstakeAvailableAt;

    /// @notice Vault contract for holding funds
    /// @dev Non-upgradeable vault with immutable controller (this proxy)
    IVault public vault;

    /// @notice Flag to indicate buyback in progress (prevents receive() from forwarding)
    /// @dev Transient storage would be ideal but we use regular storage for compatibility
    bool private _buybackInProgress;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage gap for future upgrades (47 slots - reduced by 3 for vault, flag, and cooldown mapping)
    uint256[47] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error InsufficientBalance();
    error ZeroAddress();
    error BuybackFailed();
    error TransferFailed();
    error VaultDepositFailed();
    error UnstakeCooldownActive(uint256 availableAt);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event BuybackExecuted(
        uint256 ethSpent,
        uint256 moreBought,
        uint256 moreBurned,
        uint256 moreToStakers
    );
    event RewardDistributed(uint256 amount, uint256 newRewardPerToken);
    event UnstakeCooldownUpdated(address indexed user, uint256 availableAt);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (replaces constructor for UUPS proxy)
    /// @param _moreToken MORE token address
    /// @param _vault Vault contract address
    /// @param _owner Owner address for admin actions
    function initialize(address _moreToken, address _vault, address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);

        if (_moreToken == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();

        moreToken = MoreToken(_moreToken);
        vault = IVault(_vault);
    }

    /*//////////////////////////////////////////////////////////////
                            UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorize upgrade (only owner)
    /// @param newImplementation New implementation address
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            VAULT MIGRATION
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake MORE tokens
    /// @param amount Amount to stake
    /// @dev Transfers MORE to vault for safekeeping
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        uint256 availableAt = block.timestamp + UNSTAKE_COOLDOWN;
        unstakeAvailableAt[msg.sender] = availableAt;

        // Transfer MORE from user to vault
        moreToken.safeTransferFrom(msg.sender, address(vault), amount);

        emit Staked(msg.sender, amount);
        emit UnstakeCooldownUpdated(msg.sender, availableAt);
    }

    /// @notice Withdraw staked MORE
    /// @param amount Amount to withdraw
    /// @dev Withdraws MORE from vault to user
    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] < amount) revert InsufficientBalance();
        uint256 availableAt = unstakeAvailableAt[msg.sender];
        if (block.timestamp < availableAt) revert UnstakeCooldownActive(availableAt);

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        // Withdraw MORE from vault to user
        vault.withdrawMore(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim accumulated rewards
    /// @dev Withdraws MORE from vault to user
    function claim() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert ZeroAmount();

        rewards[msg.sender] = 0;

        // Withdraw MORE from vault to user
        vault.withdrawMore(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    /*//////////////////////////////////////////////////////////////
                           BUYBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Perform buyback using accumulated protocol revenue
    /// @param router Uniswap V2 router address
    /// @param amountOutMin Minimum MORE to receive
    /// @param deadline Transaction deadline
    /// @param ethAmount Amount of ETH to use for buyback (0 = use all available)
    /// @dev Only owner can call. Protected by nonReentrant.
    /// @dev CRITICAL: moreToStakers MUST be transferred to Vault, not kept in Logic
    /// @dev Slither false positive: cross-function reentrancy is safe because:
    ///      1. nonReentrant prevents re-entering this and all state-modifying functions
    ///      2. View functions (earned/rewardPerToken) only read state, cannot cause harm
    ///      3. Stale view data during swap is temporary and doesn't affect fund safety
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,reentrancy-events,reentrancy-no-eth
    function performBuyback(
        address router,
        uint256 amountOutMin,
        uint256 deadline,
        uint256 ethAmount
    ) external onlyOwner nonReentrant updateReward(address(0)) {
        // Check ETH balance in vault
        uint256 vaultBalance = vault.getBalance();
        if (vaultBalance == 0) revert ZeroAmount();

        // Use specified amount or all available
        uint256 ethToUse = ethAmount == 0 ? vaultBalance : ethAmount;
        if (ethToUse > vaultBalance) revert InsufficientBalance();

        // Cache totalStaked before external call
        uint256 _totalStaked = totalStaked;

        // Set flag to prevent receive() from forwarding ETH back to vault
        _buybackInProgress = true;

        // Withdraw ETH from vault to this contract for swap
        vault.withdrawNative(address(this), ethToUse);

        // Build swap path: WETH -> MORE
        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02(router).WETH();
        path[1] = address(moreToken);

        // Execute swap - MORE comes to THIS contract
        uint256[] memory amounts = IUniswapV2Router02(router)
            .swapExactETHForTokens{value: ethToUse}(
            amountOutMin,
            path,
            address(this),  // MORE arrives here
            deadline
        );

        uint256 moreBought = amounts[1];
        if (moreBought == 0) revert BuybackFailed();

        // Calculate distribution
        uint256 moreToBurn = (moreBought * BURN_BPS) / 10000;
        uint256 moreToStakers = moreBought - moreToBurn;

        // Burn MORE directly from this contract (reduces totalSupply, frees cap space)
        moreToken.burn(moreToBurn);

        // CRITICAL: Transfer staker rewards to Vault
        // claim() expects MORE in Vault, not in Logic contract
        if (moreToStakers > 0) {
            moreToken.safeTransfer(address(vault), moreToStakers);
        }

        // Clear buyback flag
        _buybackInProgress = false;

        // Update reward accounting
        if (_totalStaked > 0 && moreToStakers > 0) {
            rewardPerTokenStored += (moreToStakers * PRECISION) / _totalStaked;
            emit RewardDistributed(moreToStakers, rewardPerTokenStored);
        }

        emit BuybackExecuted(ethToUse, moreBought, moreToBurn, moreToStakers);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate current reward per token
    /// @return Current reward per token
    function rewardPerToken() public view returns (uint256) {
        return rewardPerTokenStored;
    }

    /// @notice Calculate earned rewards for user
    /// @param account User address
    /// @return Earned rewards
    function earned(address account) public view returns (uint256) {
        return
            (stakedBalance[account] *
                (rewardPerTokenStored - userRewardPerTokenPaid[account])) /
            PRECISION +
            rewards[account];
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Receive protocol revenue - forwards to vault
    /// @dev All ETH is stored in vault for safety
    /// @dev During buyback, ETH is held temporarily for swap (not forwarded)
    receive() external payable {
        // During buyback, don't forward ETH - it's needed for the swap
        if (_buybackInProgress) return;

        if (address(vault) != address(0)) {
            (bool success,) = address(vault).call{value: msg.value}("");
            if (!success) revert VaultDepositFailed();
        }
    }
}
