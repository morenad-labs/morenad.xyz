// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IVault
/// @notice Interface for Vault contracts that hold funds separately from upgradeable logic contracts
/// @dev Vaults are non-upgradeable and only accessible by their immutable controller
interface IVault {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the controller
    error NotController();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when withdrawal amount exceeds balance
    error InsufficientBalance();

    /// @notice Thrown when native transfer fails
    error TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when native tokens are withdrawn
    /// @param to Recipient address
    /// @param amount Amount withdrawn
    event NativeWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when MORE tokens are withdrawn
    /// @param to Recipient address
    /// @param amount Amount withdrawn
    event MoreWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when MORE tokens are deposited
    /// @param from Depositor address
    /// @param amount Amount deposited
    event MoreDeposited(address indexed from, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw native tokens to specified address
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @dev Only callable by controller
    function withdrawNative(address to, uint256 amount) external;

    /// @notice Withdraw MORE tokens to specified address
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @dev Only callable by controller
    function withdrawMore(address to, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the controller address
    /// @return Controller address (immutable)
    function controller() external view returns (address);

    /// @notice Get the MORE token address
    /// @return MORE token address (immutable)
    function moreToken() external view returns (address);

    /// @notice Get native token balance
    /// @return Current native balance
    function getBalance() external view returns (uint256);

    /// @notice Get MORE token balance
    /// @return Current MORE balance
    function getMoreBalance() external view returns (uint256);
}
