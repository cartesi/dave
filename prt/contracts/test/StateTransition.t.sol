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

contract StateTransitionTest is Util, Test {
    CartesiStateTransition immutable stateTransition;
    RiscVStateTransition immutable riscVStateTransition;
    CmioStateTransition immutable cmioStateTransition;

    uint64 constant LOG2_UARCH_SPAN_TO_BARCH = 20;
    uint64 constant LOG2_BARCH_SPAN_TO_INPUT = 48;
    uint256 constant UARCH_SPAN_TO_BARCH = 1 << LOG2_UARCH_SPAN_TO_BARCH;
    uint256 constant FULL_SPAN =
        1 << (LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH);

    constructor() {
        (stateTransition, riscVStateTransition, cmioStateTransition) =
            Util.instantiateStateTransition();
    }

    function testTransitionComputeReset(uint32 counterBase) public {
        vm.assume(counterBase > 0);
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x123)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );
        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.reset.selector),
            abi.encode(accessLogs)
        );

        uint256 counter = (counterBase * UARCH_SPAN_TO_BARCH) - 1;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), counter, new bytes(0), IDataProvider(address(0))
        );

        assertEq(mockState, bytes32(uint256(0x123)));
    }

    function testTransitionComputeStep(uint32 counterBase) public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        uint256 counter = counterBase * FULL_SPAN;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), counter, new bytes(0), IDataProvider(address(0))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsCmio(uint32 counterBase) public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(0x123),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            abi.encode(bytes32(uint256(0x123)))
        );

        vm.mockCall(
            address(cmioStateTransition),
            abi.encode(cmioStateTransition.sendCmio.selector),
            abi.encode(accessLogs)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        uint256 counter = counterBase * FULL_SPAN;
        uint64 length = 20;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0),
            counter,
            abi.encodePacked(abi.encodePacked(length), new bytes(length)),
            IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsCmioNoInput(uint32 counterBase) public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(0x123),
            abi.encode(IDataProvider.provideMerkleRootOfInput.selector),
            // No input
            abi.encode(bytes32(uint256(0)))
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        // input length = 0 (no input)
        uint64 length = 0;
        uint256 counter = counterBase * FULL_SPAN;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0),
            counter,
            abi.encodePacked(abi.encodePacked(length), new bytes(length)),
            IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsStep(uint32 counterBase, uint16 offset)
        public
    {
        vm.assume(counterBase > 0);
        vm.assume(offset > 1);
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        uint256 counter = (counterBase * UARCH_SPAN_TO_BARCH) - offset;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), counter, new bytes(0), IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsReset(uint32 counterBase) public {
        vm.assume(counterBase > 0);
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x123)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );
        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.reset.selector),
            abi.encode(accessLogs)
        );

        uint256 counter = (counterBase * UARCH_SPAN_TO_BARCH) - 1;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), counter, new bytes(0), IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x123)));
    }
}
