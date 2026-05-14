// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Script, console} from "forge-std/Script.sol";
import {VanillaExecutionStrategy} from "sx-evm/execution-strategies/VanillaExecutionStrategy.sol";

/// @notice Deploy a single VanillaExecutionStrategy used by every BVS proposal.
/// Quorum is set to 1 (any proposal with at least one For vote can be executed).
/// Admin retains discretion to Approve/Reject regardless on /vote.
contract DeployExecutionStrategy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        VanillaExecutionStrategy strat = new VanillaExecutionStrategy(deployer, 1);
        vm.stopBroadcast();

        console.log("VanillaExecutionStrategy deployed at:", address(strat));
    }
}
