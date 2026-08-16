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

contract FixedRootProvider is IDataProvider {
    bytes32 immutable ROOT;

    constructor(bytes32 root) {
        ROOT = root;
    }

    function provideMerkleRootOfInput(uint256, bytes calldata)
        external
        view
        returns (bytes32)
    {
        return ROOT;
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
    uint256 constant UARCH_CYCLE_MASK = UARCH_SPAN_TO_BARCH - 1;
    uint256 constant MCYCLE_MASK =
        (1 << EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE) - 1;
    uint256 constant INPUT_WINDOW_SPAN = 1 << LOG2_INPUT_WINDOW_SPAN;
    uint256 constant EPOCH_SPAN = 1 << LOG2_EPOCH_RULER_SPAN;
    uint256 constant LAST_INPUT_OPENING = EPOCH_SPAN - INPUT_WINDOW_SPAN;

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

    function runVectorCmd(string memory mode)
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

    function runLayoutCmd(string memory mode)
        private
        returns (uint256, bytes32, bytes32, uint256, uint256, bytes memory)
    {
        string[] memory cmd = new string[](3);
        cmd[0] = "lua";
        cmd[1] = "test/step/proofs.lua";
        cmd[2] = mode;

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory res = vm.ffi(cmd);
        return
            abi.decode(
                res, (uint256, bytes32, bytes32, uint256, uint256, bytes)
            );
    }

    function assertStf(uint256 counter, uint256 numInputs) private {
        assertLt(counter, EPOCH_SPAN);
        IDataProvider provider = new Provider(numInputs);

        (bytes32 before, bytes32 next, bytes memory proof) =
            runCmd(counter, numInputs);

        bytes32 result =
            STATE_TRANSITION.transitionState(before, counter, proof, provider);

        assertEq(result, next);
    }

    function testTransitionNoInputsFuzzy(
        uint24 inputIndex,
        uint48 mcycle,
        uint32 ucycle,
        uint8 shape
    ) public {
        assertStf(shapedCounter(inputIndex, mcycle, ucycle, shape), 0);
    }

    function testTransitionWithInputsFuzzy(
        uint8 inputIndex,
        uint48 mcycle,
        uint32 ucycle,
        uint8 shape
    ) public {
        uint24 boundedInputIndex = uint24(inputIndex & 3);
        assertStf(shapedCounter(boundedInputIndex, mcycle, ucycle, shape), 4);
    }

    function shapedCounter(
        uint24 inputIndex,
        uint48 mcycle,
        uint32 ucycle,
        uint8 shape
    ) private pure returns (uint256) {
        uint256 inputPrefix =
            uint256(inputIndex) << LOG2_INPUT_WINDOW_SPAN;
        uint256 selectedShape = shape & 3;

        if (selectedShape == 0) {
            return inputPrefix;
        }
        if (selectedShape == 1) {
            uint256 nonzeroMcycle = 1 + (uint256(mcycle) % MCYCLE_MASK);
            return inputPrefix
                | (nonzeroMcycle
                    << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);
        }

        uint256 prefix = inputPrefix
            | (uint256(mcycle)
                << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);
        if (selectedShape == 2) {
            uint256 interiorUcycle =
                1 + (uint256(ucycle) % (UARCH_SPAN_TO_BARCH - 2));
            return prefix | interiorUcycle;
        }
        return prefix | UARCH_CYCLE_MASK;
    }

    function testTransitionCoordinateBoundaries() public {
        uint256 U = UARCH_SPAN_TO_BARCH;
        uint256 W = INPUT_WINDOW_SPAN;
        uint256 L = LAST_INPUT_OPENING;
        uint256 E = EPOCH_SPAN;
        uint256[18] memory counters = [
            uint256(0),
            1,
            U - 2,
            U - 1,
            U,
            U + 1,
            W - U,
            W - 2,
            W - 1,
            W,
            W + 1,
            L - 1,
            L,
            L + 1,
            L + U - 1,
            E - U,
            E - 2,
            E - 1
        ];

        for (uint256 i = 0; i < counters.length; i++) {
            assertStf(counters[i], 0);
        }
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
        ) = runVectorCmd("first-input-rejection-closing");
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
        ) = runVectorCmd("uarch-cycle-overflow-closing");
        assertEq(counter + 1, UARCH_SPAN_TO_BARCH);
        assertNotEq(before, canonicalPost);

        bytes32 result = STATE_TRANSITION.transitionState(
            before, counter, proof, new Provider(0)
        );

        assertEq(result, canonicalPost);
    }

    function testTransitionHaltWithZeroExitOpening() public {
        assertTerminalVector("terminal-halt-zero-opening", 0, 1);
    }

    function testTransitionHaltWithNonzeroExitOpening() public {
        assertTerminalVector("terminal-halt-nonzero-opening", 0, 1);
    }

    function testTransitionHaltClosing() public {
        assertTerminalVector(
            "terminal-halt-zero-closing", UARCH_SPAN_TO_BARCH - 1, 0
        );
    }

    function testTransitionTxExceptionOpening() public {
        assertTerminalVector("terminal-exception-opening", 0, 1);
    }

    function testTransitionTxExceptionClosing() public {
        assertTerminalVector(
            "terminal-exception-closing", UARCH_SPAN_TO_BARCH - 1, 0
        );
    }

    function testTransitionUnexpectedManualYieldOpening() public {
        assertTerminalVector("terminal-manual-other-opening", 0, 1);
    }

    function testTransitionUnexpectedManualYieldClosing() public {
        assertTerminalVector(
            "terminal-manual-other-closing", UARCH_SPAN_TO_BARCH - 1, 0
        );
    }

    function testTransitionMcycleOverflowOpening() public {
        assertTerminalVector("terminal-mcycle-overflow-opening", 0, 1);
    }

    function testTransitionMcycleOverflowClosing() public {
        assertTerminalVector(
            "terminal-mcycle-overflow-closing", UARCH_SPAN_TO_BARCH - 1, 0
        );
    }

    function assertTerminalVector(
        string memory mode,
        uint256 expectedCounter,
        uint256 numInputs
    ) private {
        (uint256 counter, bytes32 before, bytes32 next, bytes memory proof) =
            runVectorCmd(mode);
        assertEq(counter, expectedCounter);
        assertNotEq(before, next);

        bytes32 result = STATE_TRANSITION.transitionState(
            before, counter, proof, new Provider(numInputs)
        );

        assertEq(result, next);
    }

    function testTransitionRealInputProofRejectsBoundaryTruncation() public {
        (
            uint256 counter,
            bytes32 before,
            bytes32 next,
            uint256 daEnd,
            uint256 cmioEnd,
            bytes memory proof
        ) = runLayoutCmd("input-proof-layout");
        assertEq(counter, 0);
        assertEq(daEnd, 40);
        assertLt(daEnd, cmioEnd);
        assertLt(cmioEnd, proof.length);
        assertEq(
            STATE_TRANSITION.transitionState(
                before, counter, proof, new Provider(1)
            ),
            next
        );

        uint256[7] memory lengths = [
            uint256(7),
            8,
            daEnd - 1,
            daEnd,
            cmioEnd - 1,
            cmioEnd,
            proof.length - 1
        ];
        for (uint256 i = 0; i < lengths.length; i++) {
            assertTransitionReverts(
                before, counter, copyPrefix(proof, lengths[i]), new Provider(1)
            );
        }
    }

    function testTransitionRealClosingProofRejectsBoundaryTruncation() public {
        (
            uint256 counter,
            bytes32 before,
            bytes32 next,
            uint256 stepEnd,
            uint256 resetEnd,
            bytes memory proof
        ) = runLayoutCmd("uarch-cycle-overflow-closing-layout");
        assertEq(counter, UARCH_CYCLE_MASK);
        assertGt(stepEnd, 0);
        assertLt(stepEnd, resetEnd);
        assertEq(resetEnd, proof.length);
        assertEq(
            STATE_TRANSITION.transitionState(
                before, counter, proof, new Provider(0)
            ),
            next
        );

        uint256[3] memory lengths = [stepEnd - 1, stepEnd, proof.length - 1];
        for (uint256 i = 0; i < lengths.length; i++) {
            assertTransitionReverts(
                before, counter, copyPrefix(proof, lengths[i]), new Provider(0)
            );
        }
    }

    function testTransitionRealProofCannotReplayAcrossAdjacentShapes() public {
        (bytes32 inputBefore,, bytes memory inputProof) = runCmd(0, 1);
        (bytes32 plainBefore,, bytes memory plainProof) = runCmd(1, 0);
        (bytes32 closingBefore,, bytes memory closingProof) =
            runCmd(UARCH_CYCLE_MASK, 0);

        assertTransitionReverts(inputBefore, 1, inputProof, new Provider(1));
        assertTransitionReverts(plainBefore, 0, plainProof, new Provider(0));
        assertTransitionReverts(
            closingBefore, UARCH_SPAN_TO_BARCH, closingProof, new Provider(0)
        );
        assertTransitionReverts(
            plainBefore, UARCH_CYCLE_MASK, plainProof, new Provider(0)
        );
    }

    function testTransitionRealProofBindsBeforeState() public {
        (bytes32 before,, bytes memory proof) = runCmd(1, 0);
        bytes32 wrongBefore = before ^ bytes32(uint256(1));

        assertTransitionReverts(wrongBefore, 1, proof, new Provider(0));
    }

    function testTransitionInputProofBindsDataAvailabilityPayload() public {
        (bytes32 before,, bytes memory proof) = runCmd(0, 1);
        bytes memory corrupted = bytes.concat(proof);
        corrupted[8] = bytes1(uint8(corrupted[8]) ^ 1);
        IDataProvider provider = new Provider(1);
        bytes memory expectedInput = new bytes(32);
        bytes memory corruptedInput = new bytes(32);
        corruptedInput[0] = 0x01;

        vm.expectRevert(
            abi.encodeWithSelector(
                Provider.InputMismatch.selector,
                0,
                expectedInput,
                corruptedInput
            )
        );
        STATE_TRANSITION.transitionState(before, 0, corrupted, provider);
    }

    function testTransitionInputProofRejectsWrongNonzeroProviderRoot() public {
        (bytes32 before, bytes32 next, bytes memory proof) = runCmd(0, 1);
        bytes32 expectedRoot = keccak256(abi.encodePacked(bytes32(0)));
        bytes32 wrongRoot = expectedRoot ^ bytes32(uint256(1));
        assertNotEq(wrongRoot, bytes32(0));

        assertEq(
            STATE_TRANSITION.transitionState(
                before, 0, proof, new FixedRootProvider(expectedRoot)
            ),
            next
        );

        assertTransitionReverts(
            before, 0, proof, new FixedRootProvider(wrongRoot)
        );
    }

    function testTransitionRealProofRejectsPrimitiveByteMutations() public {
        (
            uint256 inputCounter,
            bytes32 inputBefore,
            bytes32 inputNext,
            uint256 daEnd,
            uint256 cmioEnd,
            bytes memory inputProof
        ) = runLayoutCmd("input-proof-layout");
        (
            uint256 closingCounter,
            bytes32 closingBefore,
            bytes32 closingNext,
            uint256 stepEnd,,
            bytes memory closingProof
        ) = runLayoutCmd("uarch-cycle-overflow-closing-layout");

        assertEq(
            STATE_TRANSITION.transitionState(
                inputBefore, inputCounter, inputProof, new Provider(1)
            ),
            inputNext
        );
        assertEq(
            STATE_TRANSITION.transitionState(
                closingBefore, closingCounter, closingProof, new Provider(0)
            ),
            closingNext
        );

        assertTransitionReverts(
            inputBefore,
            inputCounter,
            copyAndFlip(inputProof, daEnd),
            new Provider(1)
        );
        assertTransitionReverts(
            inputBefore,
            inputCounter,
            copyAndFlip(inputProof, cmioEnd),
            new Provider(1)
        );
        assertTransitionReverts(
            closingBefore,
            closingCounter,
            copyAndFlip(closingProof, stepEnd),
            new Provider(0)
        );
    }

    function testTransitionOutOfRangeNonemptyInputIntentionallySkipsCmio()
        public
    {
        (uint256 counter, bytes32 before, bytes32 next, bytes memory proof) =
            runVectorCmd("out-of-range-nonempty-input-opening");
        assertEq(counter, 0);
        assertGt(proof.length, 40);

        bytes32 result = STATE_TRANSITION.transitionState(
            before, counter, proof, new Provider(0)
        );

        assertEq(result, next);
    }

    function assertTransitionReverts(
        bytes32 before,
        uint256 counter,
        bytes memory proof,
        IDataProvider provider
    ) private {
        vm.expectRevert();
        STATE_TRANSITION.transitionState(before, counter, proof, provider);
    }

    function copyPrefix(bytes memory data, uint256 length)
        private
        pure
        returns (bytes memory prefix)
    {
        require(length <= data.length);
        prefix = bytes.concat(data);
        assembly ("memory-safe") {
            mstore(prefix, length)
        }
    }

    function copyAndFlip(bytes memory data, uint256 index)
        private
        pure
        returns (bytes memory mutated)
    {
        require(index < data.length);
        mutated = bytes.concat(data);
        mutated[index] = bytes1(uint8(mutated[index]) ^ 1);
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
