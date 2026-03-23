// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {BVSToken} from "../src/BVSToken.sol";
import {BVSRegistry} from "../src/BVSRegistry.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        BVSToken token = new BVSToken(deployer, true, true);
        console.log("BVSToken deployed at:", address(token));

        BVSRegistry registry = new BVSRegistry(deployer);
        console.log("BVSRegistry deployed at:", address(registry));

        registry.addCategory("Constitutional Law");
        registry.addCategory("Operational Policy");
        registry.addCategory("Resolutions");
        console.log("Seeded 3 categories");

        vm.stopBroadcast();
    }
}
