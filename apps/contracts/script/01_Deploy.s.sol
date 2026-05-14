// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

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

        // Lock semantics: BVS_HARD_LOCK=true makes setAmendmentRestrictions revert
        // RestrictionsLocked while a lock window is active (admin self-binds; matches
        // the /registry product). Default false = DAA-style soft-lock, where admin
        // can lift restrictions at any time and the AmendmentRestrictionsUpdated
        // event provides the audit trail. Immutable post-deploy.
        bool hardLock = vm.envOr("BVS_HARD_LOCK", false);
        BVSRegistry registry = new BVSRegistry(deployer, hardLock);
        console.log("BVSRegistry deployed at:", address(registry));
        console.log("Hard-lock semantics:", hardLock);

        // Initial categories (admin can add more via addCategory).
        registry.addCategory("Constitutional Law");
        registry.addCategory("Operational Policy");
        registry.addCategory("Resolutions");
        console.log("Seeded 3 categories");

        // Optional: transfer governance to a separate admin EOA.
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);
        if (admin != deployer) {
            token.transferOwnership(admin);
            registry.setGovernanceAuthority(admin);
            console.log("Transferred ownership/governance to:", admin);
        }

        vm.stopBroadcast();
    }
}
