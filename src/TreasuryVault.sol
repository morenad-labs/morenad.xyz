// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVault.sol";

/// @title TreasuryVault
/// @notice Non-upgradeable vault that holds all funds for TreasuryStaking
/// @dev Only the immutable controller (TreasuryStaking Proxy) can withdraw funds
/// @dev Swap logic remains in TreasuryStaking (Logic Contract) for upgradeability
/// @dev No emergency functions - issues resolved by redeploying Logic Contract
contract TreasuryVault is IVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Controller address (TreasuryStaking Proxy) - immutable
    /// @dev Set once at deployment, cannot be changed
    address public immutable override controller;

    /// @notice MORE token address - immutable
    address public immutable override moreToken;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to controller only
    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy vault with immutable controller and MORE token
    /// @param _controller Address of the controller (TreasuryStaking Proxy)
    /// @param _moreToken Address of the MORE token
    /// @dev Controller must be deployed first (deploy Proxy before Vault)
    constructor(address _controller, address _moreToken) {
        if (_controller == address(0)) revert ZeroAddress();
        if (_moreToken == address(0)) revert ZeroAddress();

        controller = _controller;
        moreToken = _moreToken;
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Receive native tokens (ETH/protocol revenue)
    /// @dev Anyone can send native tokens to the vault
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit MORE tokens to vault
    /// @param amount Amount of MORE to deposit
    /// @dev Used by controller after buyback swap to deposit staker rewards
    /// @dev Requires prior approval of MORE tokens
    function depositMore(uint256 amount) external nonReentrant {
        if (amount == 0) revert InsufficientBalance();

        IERC20(moreToken).safeTransferFrom(msg.sender, address(this), amount);

        emit MoreDeposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw native tokens to specified address
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @dev Only callable by controller (TreasuryStaking Proxy)
    function withdrawNative(address to, uint256 amount) external override nonReentrant onlyController {
        if (to == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert InsufficientBalance();

        (bool success,) = to.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit NativeWithdrawn(to, amount);
    }

    /// @notice Withdraw MORE tokens to specified address
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @dev Only callable by controller (TreasuryStaking Proxy)
    function withdrawMore(address to, uint256 amount) external override nonReentrant onlyController {
        if (to == address(0)) revert ZeroAddress();
        if (amount > IERC20(moreToken).balanceOf(address(this))) revert InsufficientBalance();

        IERC20(moreToken).safeTransfer(to, amount);

        emit MoreWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get native token balance
    /// @return Current native balance held in vault
    function getBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get MORE token balance
    /// @return Current MORE balance held in vault
    function getMoreBalance() external view override returns (uint256) {
        return IERC20(moreToken).balanceOf(address(this));
    }
}
