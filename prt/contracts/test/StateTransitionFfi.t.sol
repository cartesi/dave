// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std/Test.sol";

import "./Util.sol";
import "src/state-transition/CartesiStateTransition.sol";

pragma solidity ^0.8.0;

contract Provider is IDataProvider {
    uint256 immutable LENGTH = 0;

    constructor(uint256 length) {
        LENGTH = length;
    }

    function bytesEq(bytes calldata a, bytes memory b)
        private
        pure
        returns (bool)
    {
        if (a.length != b.length) {
            return false;
        }
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    function getInput(uint256 inputIndexWithinEpoch)
        private
        pure
        returns (bytes memory, bytes32)
    {
        bytes32 val = bytes32(inputIndexWithinEpoch);
        bytes32 hash = keccak256(abi.encodePacked(val));
        bytes memory input = abi.encodePacked(val);

        while (inputIndexWithinEpoch != 0) {
            hash = keccak256(abi.encodePacked(hash, hash));
            input = abi.encodePacked(input, input);
            inputIndexWithinEpoch = inputIndexWithinEpoch >> 1;
        }

        return (input, hash);
    }

    function provideMerkleRootOfInput(
        uint256 inputIndexWithinEpoch,
        bytes calldata input
    ) external pure returns (bytes32) {
        if (inputIndexWithinEpoch >= LENGTH) {
            return bytes32(0x0);
        }

        (bytes memory i, bytes32 hash) = getInput(inputIndexWithinEpoch);
        require(bytesEq(input, i), "inputs don't match");

        return hash;
    }
}

contract StateTransitionFfiTest is Util, Test {
    CartesiStateTransition immutable stateTransition;
    RiscVStateTransition immutable riscVStateTransition;
    CmioStateTransition immutable cmioStateTransition;

    uint64 constant LOG2_UARCH_SPAN_TO_BARCH = 20;
    uint64 constant LOG2_BARCH_SPAN_TO_INPUT = 48;
    uint64 constant LOG2_INPUT_SPAN_TO_EPOCH = 24;

    uint64 constant LOG2_UARCH_SPAN_TO_EPOCH = LOG2_UARCH_SPAN_TO_BARCH
        + LOG2_BARCH_SPAN_TO_INPUT + LOG2_INPUT_SPAN_TO_EPOCH;
    uint256 constant UARCH_SPAN_TO_BARCH = 1 << LOG2_UARCH_SPAN_TO_BARCH;

    constructor() {
        (stateTransition, riscVStateTransition, cmioStateTransition) =
            Util.instantiateStateTransition();
    }

    function runCmd(uint256 counter, uint256 inputs)
        private
        returns (bytes32, bytes32, bytes memory)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "lua";
        cmd[1] = "test/step/proofs.lua";
        cmd[2] = vm.toString(counter);
        cmd[3] = vm.toString(inputs);

        bytes memory res = vm.ffi(cmd);
        return abi.decode(res, (bytes32, bytes32, bytes));
    }

    function assertStf(uint256 counter, uint256 numInputs) private {
        vm.assume((counter >> LOG2_UARCH_SPAN_TO_EPOCH) == 0);
        IDataProvider provider = new Provider(numInputs);

        (bytes32 before, bytes32 next, bytes memory proof) =
            runCmd(counter, numInputs);

        bytes32 result =
            stateTransition.transitionState(before, counter, proof, provider);

        assertEq(result, next);
    }

    function testTransitionNoInputsFuzzy(uint256 counter) public {
        assertStf(counter, 0);
    }

    function testTransitionWithInputsFuzzy(uint256 counter) public {
        assertStf(counter, 37);
    }

    function testTransitionInput() public {
        uint256 counter;

        counter = 0;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = 1 << (LOG2_UARCH_SPAN_TO_BARCH + LOG2_BARCH_SPAN_TO_INPUT);
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = 2 << (LOG2_UARCH_SPAN_TO_BARCH + LOG2_BARCH_SPAN_TO_INPUT);
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = 3 << (LOG2_UARCH_SPAN_TO_BARCH + LOG2_BARCH_SPAN_TO_INPUT);
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);
    }

    function testTransitionReset() public {
        uint256 mask = (1 << LOG2_UARCH_SPAN_TO_BARCH) - 1;
        uint256 counter;

        counter = mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = (1 << LOG2_UARCH_SPAN_TO_BARCH) + mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = (2 << LOG2_UARCH_SPAN_TO_BARCH) + mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter =
            ((1 << LOG2_BARCH_SPAN_TO_INPUT) << LOG2_UARCH_SPAN_TO_BARCH) + mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);
    }

    function testTransitionStep() public {
        uint256 counter;

        counter = 1;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = (1 << LOG2_UARCH_SPAN_TO_BARCH) + 2;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = (2 << LOG2_UARCH_SPAN_TO_BARCH) + 3;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter =
            ((1 << LOG2_BARCH_SPAN_TO_INPUT) << LOG2_UARCH_SPAN_TO_BARCH) + 1;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);
    }
}
