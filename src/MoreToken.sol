// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MoreToken
/// @notice ERC20 token with 5,000,000 supply cap, mintable only by authorized minters
/// @dev Implements capped supply with role-based minting
contract MoreToken is ERC20, ERC20Capped, Ownable {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorized minter contracts
    mapping(address => bool) public isMinter;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotMinter();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a minter is added or removed
    /// @param minter Address of the minter
    /// @param status True if added, false if removed
    event MinterSet(address indexed minter, bool status);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize MORE token with 5M cap
    /// @param _owner Owner address for admin actions
    constructor(address _owner)
        ERC20("MORE", "MORE")
        ERC20Capped(5_000_000 * 1e18)
        Ownable(_owner)
    {
        if (_owner == address(0)) revert ZeroAddress();
    }

    /*//////////////////////////////////////////////////////////////
                           MINTING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint MORE tokens (only callable by authorized minters)
    /// @param to Recipient address
    /// @param amount Amount to mint (in wei)
    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        _mint(to, amount);
    }

    /// @notice Burn MORE tokens (reduces totalSupply, frees cap space)
    /// @param amount Amount to burn (in wei)
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set minter authorization
    /// @param minter Address to authorize/deauthorize
    /// @param status True to authorize, false to deauthorize
    function setMinter(address minter, bool status) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        isMinter[minter] = status;
        emit MinterSet(minter, status);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Required override for ERC20Capped
    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20, ERC20Capped)
    {
        super._update(from, to, value);
    }
}
