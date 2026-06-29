// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {MyToken} from "../src/MyToken.sol";

contract DeployToken is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("GS_ADMIN_PRIVATE_KEY");
        address initialHolder = vm.envAddress("TOKEN_INITIAL_HOLDER");
        uint256 initialSupply = vm.envOr("TOKEN_INITIAL_SUPPLY", uint256(2_000_000_000 ether));

        vm.startBroadcast(deployerKey);

        MyToken token = new MyToken(initialSupply, initialHolder);

        console.log("MyToken deployed at:", address(token));
        console.log("Name:", token.name());
        console.log("Symbol:", token.symbol());
        console.log("Decimals:", token.decimals());
        console.log("Total Supply:", token.totalSupply());
        console.log("Initial Holder:", initialHolder);

        vm.stopBroadcast();
    }
}
