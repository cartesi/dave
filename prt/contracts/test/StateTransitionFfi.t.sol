// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

pragma solidity ^0.8.0;

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {
    CartesiStateTransition
} from "src/state-transition/CartesiStateTransition.sol";

import {Util} from "./Util.sol";

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

    error InputMismatch(uint256 index, bytes input1, bytes input2);

    function provideMerkleRootOfInput(
        uint256 inputIndexWithinEpoch,
        bytes calldata input
    ) external pure returns (bytes32) {
        if (inputIndexWithinEpoch >= LENGTH) {
            return bytes32(0x0);
        }

        (bytes memory i, bytes32 hash) = getInput(inputIndexWithinEpoch);
        require(
            bytesEq(input, i), InputMismatch(inputIndexWithinEpoch, i, input)
        );

        return hash;
    }
}

contract StateTransitionFfiTest is Util {
    CartesiStateTransition immutable STATE_TRANSITION;

    uint64 constant LOG2_INPUT_WINDOW_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
    uint64 constant LOG2_EPOCH_RULER_SPAN = LOG2_INPUT_WINDOW_SPAN
        + EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH;
    uint256 constant UARCH_SPAN_TO_BARCH =
        1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;

    constructor() {
        STATE_TRANSITION = Util.instantiateStateTransition();
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

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory res = vm.ffi(cmd);
        return abi.decode(res, (bytes32, bytes32, bytes));
    }

    function runClosingCmd(string memory mode)
        private
        returns (uint256, bytes32, bytes32, bytes memory)
    {
        string[] memory cmd = new string[](3);
        cmd[0] = "lua";
        cmd[1] = "test/step/proofs.lua";
        cmd[2] = mode;

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory res = vm.ffi(cmd);
        return abi.decode(res, (uint256, bytes32, bytes32, bytes));
    }

    function assertStf(uint256 counter, uint256 numInputs) private {
        vm.assume((counter >> LOG2_EPOCH_RULER_SPAN) == 0);
        IDataProvider provider = new Provider(numInputs);

        (bytes32 before, bytes32 next, bytes memory proof) =
            runCmd(counter, numInputs);

        bytes32 result =
            STATE_TRANSITION.transitionState(before, counter, proof, provider);

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

        counter = 1 << LOG2_INPUT_WINDOW_SPAN;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = 2 << LOG2_INPUT_WINDOW_SPAN;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = 3 << LOG2_INPUT_WINDOW_SPAN;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);
    }

    function testTransitionReset() public {
        uint256 mask =
            (1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) - 1;
        uint256 counter;

        counter = mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter =
            (1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)
                + mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter =
            (2 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)
                + mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = (1 << LOG2_INPUT_WINDOW_SPAN) + mask;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);
    }

    function testTransitionFirstInputRejectionClosing() public {
        (
            uint256 counter,
            bytes32 before,
            bytes32 revertRoot,
            bytes memory proof
        ) = runClosingCmd("first-input-rejection-closing");
        assertEq((counter + 1) & (UARCH_SPAN_TO_BARCH - 1), 0);
        assertNotEq(before, revertRoot);

        IDataProvider provider = new Provider(1);
        bytes32 result =
            STATE_TRANSITION.transitionState(before, counter, proof, provider);

        assertEq(result, revertRoot);
    }

    function testTransitionUarchCycleOverflowClosing() public {
        (
            uint256 counter,
            bytes32 before,
            bytes32 canonicalPost,
            bytes memory proof
        ) = runClosingCmd("uarch-cycle-overflow-closing");
        assertEq(counter + 1, UARCH_SPAN_TO_BARCH);
        assertNotEq(before, canonicalPost);

        bytes32 result = STATE_TRANSITION.transitionState(
            before, counter, proof, new Provider(0)
        );

        assertEq(result, canonicalPost);
    }

    function testTransitionStep() public {
        uint256 counter;

        counter = 1;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter =
            (1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) + 2;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter =
            (2 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) + 3;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);

        counter = (1 << LOG2_INPUT_WINDOW_SPAN) + 1;
        assertStf(counter, 0);
        assertStf(counter, 1);
        assertStf(counter, 2);
        assertStf(counter, 37);
    }
}
