// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IUniswapV2Router02
/// @notice Minimal interface for Uniswap V2 Router (for buyback functionality)
interface IUniswapV2Router02 {
    /// @notice Swap exact ETH for tokens
    /// @param amountOutMin Minimum amount of output tokens
    /// @param path Array of token addresses for the swap path
    /// @param to Recipient of the output tokens
    /// @param deadline Unix timestamp after which the transaction will revert
    /// @return amounts Array of input and output amounts
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Get WETH address
    /// @return WETH token address
    function WETH() external pure returns (address);
}
