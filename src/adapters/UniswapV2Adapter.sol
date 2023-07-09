// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AbstractAdapter} from "./AbstractAdapter.sol";
import {RAY} from "../libraries/Constants.sol";

import {IUniswapV2Router01} from "v2-periphery/interfaces/IUniswapV2Router01.sol";
// import {IUniswapV2Adapter} from "../../interfaces/uniswap/IUniswapV2Adapter.sol";
// import {UniswapConnectorChecker} from "./UniswapConnectorChecker.sol";

/// @title Uniswap V2 Router adapter interface
/// @notice Implements logic allowing CAs to perform swaps via Uniswap V2 and its forks
contract UniswapV2Adapter is AbstractAdapter {
    error InvalidPathException();

    /// @notice Constructor
    /// @param _creditManager Credit manager address
    /// @param _router Uniswap V2 Router address
    constructor(address _creditManager, address _router) AbstractAdapter(_creditManager, _router) {}

    /// @notice Swap input token for given amount of output token
    /// @param amountOut Amount of output token to receive
    /// @param amountInMax Maximum amount of input token to spend
    /// @param path Array of token addresses representing swap path, which must have at most 3 hops
    ///        through registered connector tokens
    /// @param deadline Maximum timestamp until which the transaction is valid
    /// @dev Parameter `to` is ignored since swap recipient can only be the credit account
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address,
        uint256 deadline
    ) external creditFacadeOnly {
        address creditAccount = _creditAccount(); // F: [AUV2-1]

        (bool valid, address tokenIn, address tokenOut) = _parseUniV2Path(path); // F: [AUV2-2]
        if (!valid) {
            revert InvalidPathException(); // F: [AUV2-5]
        }

        // calling `_executeSwap` because we need to check if output token is registered as collateral token in the CM
        _executeSwapSafeApprove(
            tokenIn,
            tokenOut,
            abi.encodeCall(
                IUniswapV2Router01.swapTokensForExactTokens, (amountOut, amountInMax, path, creditAccount, deadline)
            ),
            false
        ); // F: [AUV2-2]
    }

    /// @notice Swap given amount of input token to output token
    /// @param amountIn Amount of input token to spend
    /// @param amountOutMin Minumum amount of output token to receive
    /// @param path Array of token addresses representing swap path, which must have at most 3 hops
    ///        through registered connector tokens
    /// @param deadline Maximum timestamp until which the transaction is valid
    /// @dev Parameter `to` is ignored since swap recipient can only be the credit account
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address,
        uint256 deadline
    ) external creditFacadeOnly {
        address creditAccount = _creditAccount(); // F: [AUV2-1]

        (bool valid, address tokenIn, address tokenOut) = _parseUniV2Path(path); // F: [AUV2-3]
        if (!valid) {
            revert InvalidPathException(); // F: [AUV2-5]
        }

        // calling `_executeSwap` because we need to check if output token is registered as collateral token in the CM
        _executeSwapSafeApprove(
            tokenIn,
            tokenOut,
            abi.encodeCall(
                IUniswapV2Router01.swapExactTokensForTokens, (amountIn, amountOutMin, path, creditAccount, deadline)
            ),
            false
        ); // F: [AUV2-3]
    }

    /// @notice Swap the entire balance of input token to output token, disables input token
    /// @param rateMinRAY Minimum exchange rate between input and output tokens, scaled by 1e27
    /// @param path Array of token addresses representing swap path, which must have at most 3 hops
    ///        through registered connector tokens
    /// @param deadline Maximum timestamp until which the transaction is valid
    function swapAllTokensForTokens(uint256 rateMinRAY, address[] calldata path, uint256 deadline)
        external
        creditFacadeOnly
    {
        address creditAccount = _creditAccount(); // F: [AUV2-1]

        (bool valid, address tokenIn, address tokenOut) = _parseUniV2Path(path); // F: [AUV2-4]
        if (!valid) {
            revert InvalidPathException(); // F: [AUV2-5]
        }

        uint256 balanceInBefore = IERC20(tokenIn).balanceOf(creditAccount); // F: [AUV2-4]
        if (balanceInBefore <= 1) return;

        unchecked {
            balanceInBefore--;
        }

        // calling `_executeSwap` because we need to check if output token is registered as collateral token in the CM
        _executeSwapSafeApprove(
            tokenIn,
            tokenOut,
            abi.encodeCall(
                IUniswapV2Router01.swapExactTokensForTokens,
                (balanceInBefore, (balanceInBefore * rateMinRAY) / RAY, path, creditAccount, deadline)
            ),
            true
        ); // F: [AUV2-4]
    }

    /// @dev Performs sanity check on a swap path, returns input and output tokens
    ///      - Path length must be no more than 4 (i.e., at most 3 hops)
    ///      - Each intermediary token must be a registered connector tokens
    function _parseUniV2Path(address[] memory path)
        internal
        view
        returns (bool valid, address tokenIn, address tokenOut)
    {
        valid = true;
        tokenIn = path[0];
        tokenOut = path[path.length - 1];

        uint256 len = path.length;

        if (len > 4) {
            valid = false;
        }

        // Simplified: does not set restricted tokens
    }
}
