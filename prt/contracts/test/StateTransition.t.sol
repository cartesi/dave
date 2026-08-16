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

import {AccessLogs} from "step/src/AccessLogs.sol";
import {Buffer} from "step/src/Buffer.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {
    CartesiStateTransition
} from "src/state-transition/CartesiStateTransition.sol";

import {Util} from "./Util.sol";

contract StateTransitionTest is Util {
    using Buffer for Buffer.Context;

    CartesiStateTransition immutable STATE_TRANSITION;

    uint64 constant LOG2_INPUT_WINDOW_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
    uint256 constant UARCH_SPAN_TO_BARCH =
        1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
    uint256 constant MCYCLE_MASK =
        (1 << EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE) - 1;
    uint256 constant INPUT_WINDOW_SPAN = 1 << LOG2_INPUT_WINDOW_SPAN;
    uint256 constant LAST_INPUT_INDEX =
        (1 << EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH) - 1;

    constructor() {
        STATE_TRANSITION = Util.instantiateStateTransition();
    }

    function testTransitionInputBoundaryWithInputEntersCmioProof(uint24 inputIndex)
        public
    {
        (bytes32 machineState, bytes memory stepProof) = cycleOverflowProof();
        IDataProvider provider = IDataProvider(address(0x123));
        bytes32 inputMerkleRoot = bytes32(uint256(0x123));
        uint64 inputLength = 20;
        bytes memory input = new bytes(inputLength);

        vm.mockCall(
            address(provider),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            abi.encode(inputMerkleRoot)
        );
        vm.expectCall(
            address(provider),
            abi.encodeCall(
                IDataProvider.provideMerkleRootOfInput,
                (uint256(inputIndex), input)
            )
        );

        // The proof contains only the following uarch step. A nonzero input
        // root must first enter the CMIO proof, where this deliberately wrong
        // first access fails.
        vm.expectRevert("Read word root doesn't match");
        STATE_TRANSITION.transitionState(
            machineState,
            uint256(inputIndex) * INPUT_WINDOW_SPAN,
            abi.encodePacked(inputLength, input, stepProof),
            provider
        );
    }

    function testTransitionInputBoundaryWithoutInput(uint24 inputIndex) public {
        assertTransitionInputBoundaryWithoutInput(inputIndex);
    }

    function testTransitionLastInputBoundaryWithoutInput() public {
        assertTransitionInputBoundaryWithoutInput(LAST_INPUT_INDEX);
    }

    function testTransitionLastInputBoundaryWithInput() public {
        testTransitionInputBoundaryWithInputEntersCmioProof(
            uint24(LAST_INPUT_INDEX)
        );
    }

    function testTransitionPlainStep(
        uint24 inputIndex,
        uint48 mcycle,
        uint32 ucycle
    ) public view {
        (bytes32 machineState, bytes memory proof) = cycleOverflowProof();
        uint256 interiorUcycle =
            1 + (uint256(ucycle) % (UARCH_SPAN_TO_BARCH - 2));
        uint256 counter = (uint256(inputIndex) << LOG2_INPUT_WINDOW_SPAN)
            | (uint256(mcycle)
                << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)
            | interiorUcycle;

        bytes32 result = STATE_TRANSITION.transitionState(
            machineState, counter, proof, IDataProvider(address(0x123))
        );

        assertEq(result, machineState);
    }

    function testTransitionBigCycleOpeningIsPlainStep(
        uint24 inputIndex,
        uint48 mcycle
    ) public view {
        (bytes32 machineState, bytes memory proof) = cycleOverflowProof();
        uint256 nonzeroMcycle = 1 + (uint256(mcycle) % MCYCLE_MASK);
        uint256 counter = (uint256(inputIndex) << LOG2_INPUT_WINDOW_SPAN)
            | (nonzeroMcycle
                << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);

        bytes32 result = STATE_TRANSITION.transitionState(
            machineState, counter, proof, IDataProvider(address(0x123))
        );

        assertEq(result, machineState);
    }

    function testTransitionFirstBigStepBoundaryRequiresResetProof() public {
        (bytes32 machineState, bytes memory stepProof) = cycleOverflowProof();
        bytes memory invalidResetProof = new bytes(43 * 32);

        vm.expectRevert("Write region root doesn't match");
        STATE_TRANSITION.transitionState(
            machineState,
            UARCH_SPAN_TO_BARCH - 1,
            bytes.concat(stepProof, invalidResetProof),
            IDataProvider(address(0x123))
        );
    }

    function testTransitionImmediatelyAfterBigStepBoundaryIsPlainStep()
        public
        view
    {
        (bytes32 machineState, bytes memory proof) = cycleOverflowProof();

        bytes32 result = STATE_TRANSITION.transitionState(
            machineState,
            UARCH_SPAN_TO_BARCH,
            proof,
            IDataProvider(address(0x123))
        );

        assertEq(result, machineState);
    }

    function testTransitionRejectsTrailingProofBytes() public {
        (bytes32 machineState, bytes memory proof) = cycleOverflowProof();

        vm.expectRevert("buffer should be fully consumed");
        STATE_TRANSITION.transitionState(
            machineState,
            1,
            bytes.concat(proof, hex"00"),
            IDataProvider(address(0x123))
        );
    }

    function assertTransitionInputBoundaryWithoutInput(uint256 inputIndex)
        private
    {
        (bytes32 machineState, bytes memory stepProof) = cycleOverflowProof();
        IDataProvider provider = IDataProvider(address(0x123));
        bytes memory input = new bytes(0);

        vm.mockCall(
            address(provider),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            abi.encode(bytes32(0))
        );
        vm.expectCall(
            address(provider),
            abi.encodeCall(
                IDataProvider.provideMerkleRootOfInput, (inputIndex, input)
            )
        );

        bytes32 result = STATE_TRANSITION.transitionState(
            machineState,
            inputIndex * INPUT_WINDOW_SPAN,
            abi.encodePacked(uint64(0), stepProof),
            provider
        );

        assertEq(result, machineState);
    }

    function cycleOverflowProof()
        private
        pure
        returns (bytes32 machineState, bytes memory proof)
    {
        Memory.PhysicalAddress cycleAddress =
            Memory.toPhysicalAddress(EmulatorConstants.UARCH_CYCLE_ADDRESS);
        (Memory.PhysicalAddress leafAddress, uint64 wordOffset) =
            Memory.truncateToLeaf(cycleAddress);
        bytes32 leaf = AccessLogs.setBytes8ToBytes32AtOffset(
            AccessLogs.solidityUint64ToMachineWord(
                EmulatorConstants.UARCH_CYCLE_MAX
            ),
            bytes32(0),
            wordOffset
        );

        proof = abi.encodePacked(
            leaf, new bytes(uint256(Memory.LOG2_MAX_SIZE) * 32)
        );
        Buffer.Context memory siblings = Buffer.Context(proof, 32);
        machineState = siblings.getRoot(
            Memory.regionFromLeafAddress(leafAddress),
            keccak256(abi.encodePacked(leaf))
        );
    }
}
