// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SimpleSwapPair, IERC20Minimal} from "./SimpleSwapPair.sol";

/// @title SimpleSwapRouter - convenience layer over SimpleSwapPair.
/// @notice Pulls tokens from the caller, forwards them to the pair, and triggers mint/swap.
///         Callers must `approve` this router for the input tokens first.
contract SimpleSwapRouter {
    /// @notice Add liquidity to `pair`. amountADesired/amountBDesired are in terms of (tokenA, tokenB).
    /// @dev For non-empty pools the amounts are rebalanced to the current ratio; dust is left with caller.
    function addLiquidity(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        address to
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        SimpleSwapPair p = SimpleSwapPair(pair);
        (uint112 r0, uint112 r1) = p.getReserves();
        (uint256 rA, uint256 rB) = tokenA == p.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        if (rA == 0 && rB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = (amountADesired * rB) / rA;
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * rA) / rB;
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        require(IERC20Minimal(tokenA).transferFrom(msg.sender, pair, amountA), "TRANSFER_A_FAILED");
        require(IERC20Minimal(tokenB).transferFrom(msg.sender, pair, amountB), "TRANSFER_B_FAILED");
        liquidity = p.mint(to);
    }

    /// @notice Swap an exact amount of `tokenIn` for `tokenOut` via `pair`.
    function swapExactTokensForTokens(
        address pair,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external returns (uint256 amountOut) {
        SimpleSwapPair p = SimpleSwapPair(pair);
        (uint112 r0, uint112 r1) = p.getReserves();
        bool inIsToken0 = tokenIn == p.token0();
        (uint256 reserveIn, uint256 reserveOut) = inIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountOut = p.getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");

        require(IERC20Minimal(tokenIn).transferFrom(msg.sender, pair, amountIn), "TRANSFER_IN_FAILED");
        (uint256 amount0Out, uint256 amount1Out) = inIsToken0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        p.swap(amount0Out, amount1Out, to);
    }
}
