// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {TestERC20} from "../src/dex/TestERC20.sol";
import {SimpleSwapPair} from "../src/dex/SimpleSwapPair.sol";
import {SimpleSwapRouter} from "../src/dex/SimpleSwapRouter.sol";

contract SimpleSwapTest is Test {
    TestERC20 tokenA;
    TestERC20 tokenB;
    SimpleSwapPair pair;
    SimpleSwapRouter router;

    address user = address(0xBEEF);

    function setUp() public {
        tokenA = new TestERC20("Test USD", "tUSD", 1_000_000 ether);
        tokenB = new TestERC20("Test ETH", "tETH", 1_000_000 ether);
        router = new SimpleSwapRouter();
        pair = new SimpleSwapPair(address(tokenA), address(tokenB));

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
    }

    function testAddLiquidityMintsLp() public {
        (,, uint256 lp) =
            router.addLiquidity(address(pair), address(tokenA), address(tokenB), 100_000 ether, 100_000 ether, address(this));
        assertGt(lp, 0, "should mint LP");
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(uint256(r0), 100_000 ether);
        assertEq(uint256(r1), 100_000 ether);
    }

    function testSwapRespectsConstantProduct() public {
        router.addLiquidity(address(pair), address(tokenA), address(tokenB), 100_000 ether, 100_000 ether, address(this));
        (uint112 r0Before, uint112 r1Before) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        uint256 balBefore = tokenB.balanceOf(address(this));
        uint256 out = router.swapExactTokensForTokens(address(pair), address(tokenA), 1_000 ether, 0, address(this));
        uint256 received = tokenB.balanceOf(address(this)) - balBefore;

        assertEq(received, out, "router return matches transfer");
        assertGt(out, 0, "should receive output");

        (uint112 r0After, uint112 r1After) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        assertGe(kAfter, kBefore, "k must not decrease (fee grows it)");
    }

    function testGetAmountOutMatchesSwap() public {
        router.addLiquidity(address(pair), address(tokenA), address(tokenB), 50_000 ether, 200_000 ether, address(this));
        (uint112 r0, uint112 r1) = pair.getReserves();
        bool aIs0 = pair.token0() == address(tokenA);
        (uint256 rIn, uint256 rOut) = aIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 expected = pair.getAmountOut(1_000 ether, rIn, rOut);

        uint256 out = router.swapExactTokensForTokens(address(pair), address(tokenA), 1_000 ether, 0, address(this));
        assertEq(out, expected, "quoted out equals actual out");
    }

    function testRemoveLiquidity() public {
        (,, uint256 lp) =
            router.addLiquidity(address(pair), address(tokenA), address(tokenB), 100_000 ether, 100_000 ether, address(this));
        pair.transfer(address(pair), lp);
        (uint256 a0, uint256 a1) = pair.burn(address(this));
        assertGt(a0, 0);
        assertGt(a1, 0);
    }
}
