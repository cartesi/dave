// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import "cartesi-rollups-contracts-2.0.0/inputs/InputBox.sol";

// Only used for tests
contract InputBoxScript is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        InputBox inputBox = new InputBox();
        inputBox.addInput(address(0x0), bytes("First input")); // add an input for epoch 0

        vm.stopBroadcast();
    }
}
