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
import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";

import {Util} from "./Util.sol";

contract CartesiStateTransitionHarness is CartesiStateTransition {
    function resolveInputWitness(
        bytes calldata proofs,
        uint256 inputIndexWithinEpoch,
        IDataProvider provider
    )
        external
        view
        returns (
            bytes32 inputMerkleRoot,
            uint64 inputLength,
            uint256 accessLogsOffset
        )
    {
        return _resolveInputWitness(proofs, inputIndexWithinEpoch, provider);
    }
}

contract StateTransitionTest is Util {
    using Buffer for Buffer.Context;

    CartesiStateTransition immutable STATE_TRANSITION;
    CartesiStateTransitionHarness immutable STATE_TRANSITION_HARNESS;

    uint64 constant LOG2_INPUT_WINDOW_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
    uint64 constant LOG2_EPOCH_RULER_SPAN = LOG2_INPUT_WINDOW_SPAN
        + EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH;
    uint256 constant UARCH_SPAN_TO_BARCH =
        1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
    uint256 constant MCYCLE_MASK =
        (1 << EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE) - 1;
    uint256 constant INPUT_WINDOW_SPAN = 1 << LOG2_INPUT_WINDOW_SPAN;
    uint256 constant EPOCH_RULER_SPAN = 1 << LOG2_EPOCH_RULER_SPAN;
    uint256 constant LAST_INPUT_INDEX =
        (1 << EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH) - 1;

    constructor() {
        STATE_TRANSITION = Util.instantiateStateTransition();
        STATE_TRANSITION_HARNESS = new CartesiStateTransitionHarness();
    }

    function testCmMarchIdMatchesPinnedEmulator() public view {
        assertEq(STATE_TRANSITION.CM_MARCHID(), 21);
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

    function testTransitionRejectsFirstCounterAfterEpoch() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CartesiStateTransition.CounterOutsideEpoch.selector,
                EPOCH_RULER_SPAN
            )
        );
        STATE_TRANSITION.transitionState(
            bytes32(0), EPOCH_RULER_SPAN, hex"", IDataProvider(address(0x123))
        );
    }

    function testTransitionRejectsUint256MaxCounter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CartesiStateTransition.CounterOutsideEpoch.selector,
                type(uint256).max
            )
        );
        STATE_TRANSITION.transitionState(
            bytes32(0), type(uint256).max, hex"", IDataProvider(address(0x123))
        );
    }

    function testTransitionRejectsTrailingProofBytes() public {
        (bytes32 machineState, bytes memory proof) = cycleOverflowProof();
        bytes memory proofWithTrailingByte = bytes.concat(proof, hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(
                CartesiStateTransition.InvalidAccessLogProofLength.selector,
                proof.length,
                proofWithTrailingByte.length
            )
        );
        STATE_TRANSITION.transitionState(
            machineState,
            1,
            proofWithTrailingByte,
            IDataProvider(address(0x123))
        );
    }

    function testTransitionRejectsTruncatedZeroPaddedProof() public {
        (bytes32 machineState, bytes memory proof) = cycleOverflowProof();
        bytes memory truncatedProof = new bytes(proof.length - 1);
        for (uint256 i; i < truncatedProof.length; ++i) {
            truncatedProof[i] = proof[i];
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                CartesiStateTransition.InvalidAccessLogProofLength.selector,
                proof.length,
                truncatedProof.length
            )
        );
        STATE_TRANSITION.transitionState(
            machineState, 1, truncatedProof, IDataProvider(address(0x123))
        );
    }

    function testResolveInputWitnessReturnsProviderRootAndOffset() public {
        IDataProvider provider = IDataProvider(address(0x123));
        uint256 inputIndexWithinEpoch = 17;
        bytes memory input = hex"00a1b2ff";
        bytes memory accessLogs = hex"deadbeef";
        bytes32 expectedRoot = bytes32(uint256(0x456));
        bytes memory providerCall = abi.encodeCall(
            IDataProvider.provideMerkleRootOfInput,
            (inputIndexWithinEpoch, input)
        );

        vm.mockCall(address(provider), providerCall, abi.encode(expectedRoot));
        vm.expectCall(address(provider), providerCall, 1);

        (bytes32 root, uint64 inputLength, uint256 accessLogsOffset) = STATE_TRANSITION_HARNESS.resolveInputWitness(
            abi.encodePacked(uint64(input.length), input, accessLogs),
            inputIndexWithinEpoch,
            provider
        );

        assertEq(root, expectedRoot);
        assertEq(inputLength, input.length);
        assertEq(accessLogsOffset, 8 + input.length);
    }

    function testResolveInputWitnessAcceptsZeroLengthAndZeroRoot() public {
        IDataProvider provider = IDataProvider(address(0x123));
        uint256 inputIndexWithinEpoch = 9;
        bytes memory input = new bytes(0);
        bytes memory providerCall = abi.encodeCall(
            IDataProvider.provideMerkleRootOfInput,
            (inputIndexWithinEpoch, input)
        );

        vm.mockCall(address(provider), providerCall, abi.encode(bytes32(0)));
        vm.expectCall(address(provider), providerCall, 1);

        (bytes32 root, uint64 inputLength, uint256 accessLogsOffset) = STATE_TRANSITION_HARNESS.resolveInputWitness(
            abi.encodePacked(uint64(0), hex"deadbeef"),
            inputIndexWithinEpoch,
            provider
        );

        assertEq(root, bytes32(0));
        assertEq(inputLength, 0);
        assertEq(accessLogsOffset, 8);
    }

    function testResolveInputWitnessRejectsShortHeader() public {
        IDataProvider provider = IDataProvider(address(0x123));
        vm.mockCall(
            address(provider),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            abi.encode(bytes32(0))
        );

        vm.expectRevert();
        STATE_TRANSITION_HARNESS.resolveInputWitness(
            hex"00010203040506", 0, provider
        );
    }

    function testResolveInputWitnessRejectsDeclaredLengthBeyondPayload()
        public
    {
        IDataProvider provider = IDataProvider(address(0x123));
        vm.mockCall(
            address(provider),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            abi.encode(bytes32(0))
        );

        vm.expectRevert();
        STATE_TRANSITION_HARNESS.resolveInputWitness(
            abi.encodePacked(uint64(3), hex"aabb"), 0, provider
        );
    }

    function testResolveInputWitnessBubblesProviderRevert() public {
        IDataProvider provider = IDataProvider(address(0x123));
        uint256 inputIndexWithinEpoch = 23;
        bytes memory input = hex"010203";
        bytes memory providerCall = abi.encodeCall(
            IDataProvider.provideMerkleRootOfInput,
            (inputIndexWithinEpoch, input)
        );
        bytes memory providerRevert =
            abi.encodeWithSignature("ProviderFailure(uint256)", 7);

        vm.mockCallRevert(address(provider), providerCall, providerRevert);
        vm.expectRevert(providerRevert);
        STATE_TRANSITION_HARNESS.resolveInputWitness(
            abi.encodePacked(uint64(input.length), input),
            inputIndexWithinEpoch,
            provider
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
