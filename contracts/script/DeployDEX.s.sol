// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {TestERC20} from "../src/dex/TestERC20.sol";
import {SimpleSwapPair} from "../src/dex/SimpleSwapPair.sol";
import {SimpleSwapRouter} from "../src/dex/SimpleSwapRouter.sol";

/// @notice End-to-end DEX bring-up: deploy two test tokens + pair + router,
///         seed liquidity, and perform one swap. Great for smoke-testing a fresh chain.
///
/// Env:
///   DEX_DEPLOYER_KEY   private key used to broadcast (deployer also receives initial token supply)
///   TOKEN_A_SUPPLY     optional, default 1,000,000e18
///   TOKEN_B_SUPPLY     optional, default 1,000,000e18
///   LIQ_A / LIQ_B      optional liquidity seed, default 100,000e18 each
///   SWAP_IN            optional swap input of token A, default 1,000e18
contract DeployDEX is Script {
    function run() external {
        uint256 key = vm.envUint("DEX_DEPLOYER_KEY");
        address deployer = vm.addr(key);

        uint256 supplyA = vm.envOr("TOKEN_A_SUPPLY", uint256(1_000_000 ether));
        uint256 supplyB = vm.envOr("TOKEN_B_SUPPLY", uint256(1_000_000 ether));
        uint256 liqA = vm.envOr("LIQ_A", uint256(100_000 ether));
        uint256 liqB = vm.envOr("LIQ_B", uint256(100_000 ether));
        uint256 swapIn = vm.envOr("SWAP_IN", uint256(1_000 ether));

        console.log("Deployer:", deployer);

        vm.startBroadcast(key);

        TestERC20 tokenA = new TestERC20("Test USD", "tUSD", supplyA);
        TestERC20 tokenB = new TestERC20("Test ETH", "tETH", supplyB);
        SimpleSwapRouter router = new SimpleSwapRouter();
        SimpleSwapPair pair = new SimpleSwapPair(address(tokenA), address(tokenB));

        // Seed liquidity via the router.
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        (uint256 usedA, uint256 usedB, uint256 lp) =
            router.addLiquidity(address(pair), address(tokenA), address(tokenB), liqA, liqB, deployer);

        // Perform one swap: tokenA -> tokenB.
        uint256 outB = router.swapExactTokensForTokens(address(pair), address(tokenA), swapIn, 0, deployer);

        vm.stopBroadcast();

        (uint112 r0, uint112 r1) = pair.getReserves();
        console.log("------------------------------------------------------------");
        console.log("tokenA (tUSD):   ", address(tokenA));
        console.log("tokenB (tETH):   ", address(tokenB));
        console.log("router:          ", address(router));
        console.log("pair (LP token): ", address(pair));
        console.log("pair.token0:     ", pair.token0());
        console.log("pair.token1:     ", pair.token1());
        console.log("liquidity added A:", usedA);
        console.log("liquidity added B:", usedB);
        console.log("LP minted:       ", lp);
        console.log("swap in (tUSD):  ", swapIn);
        console.log("swap out (tETH): ", outB);
        console.log("reserve0:        ", uint256(r0));
        console.log("reserve1:        ", uint256(r1));
        console.log("------------------------------------------------------------");
    }
}
