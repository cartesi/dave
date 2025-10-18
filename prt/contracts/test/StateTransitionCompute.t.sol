// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std-1.9.6/src/Test.sol";

import "./Util.sol";
import "src/state-transition/ComputeStateTransition.sol";

pragma solidity ^0.8.0;

contract StateTransitionComputeTest is Util, Test {
    ComputeStateTransition immutable stateTransition;
    RiscVStateTransition immutable riscVStateTransition;

    uint64 constant LOG2_UARCH_SPAN_TO_BARCH = 20;
    uint256 constant UARCH_SPAN_TO_BARCH = 1 << LOG2_UARCH_SPAN_TO_BARCH;
    uint256 constant BIG_STEP_MASK = UARCH_SPAN_TO_BARCH - 1;

    constructor() {
        (stateTransition, riscVStateTransition) =
            Util.instantiateStateTransitionCompute();
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
        vm.assume(counterBase != ~uint32(0));
        vm.assume((counterBase + 1) & BIG_STEP_MASK != 0);

        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        uint256 counter = counterBase;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), counter, new bytes(0), IDataProvider(address(0))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }
}
