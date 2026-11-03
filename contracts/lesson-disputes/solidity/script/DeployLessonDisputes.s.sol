// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {LessonDisputes} from "../src/LessonDisputes.sol";

/// @dev No keys in this script. Broadcasting must be explicitly authorized via Engine/Vault.
contract DeployLessonDisputes is Script {
    function run() external returns (LessonDisputes deployed) {
        address administrator = vm.envAddress("DISPUTE_ADMINISTRATOR");
        address engine = vm.envAddress("DISPUTE_ENGINE");
        vm.startBroadcast();
        deployed = new LessonDisputes(administrator, engine);
        vm.stopBroadcast();
        require(deployed.paused() && !deployed.nonResponseEnabled(), "Unsafe deployment defaults");
    }
}
