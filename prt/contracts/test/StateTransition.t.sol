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
import "src/StateTransition.sol";

pragma solidity ^0.8.0;

contract StateTransitionTest is Util, Test {
    StateTransition immutable stateTransition;
    RiscVStateTransition immutable riscVStateTransition;
    CmioStateTransition immutable cmioStateTransition;

    constructor() {
        (stateTransition, riscVStateTransition, cmioStateTransition) =
            Util.instantiateStateTransition();
    }

    function testTransitionComputeReset() public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x123)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.reset.selector),
            abi.encode(accessLogs)
        );

        bytes32 mockState = stateTransition.transitionState(
            bytes32(0),
            4951760157141521099596496895,
            new bytes(0),
            IDataProvider(address(0))
        );

        assertEq(mockState, bytes32(uint256(0x123)));
    }

    function testTransitionComputeStep() public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), 0, new bytes(0), IDataProvider(address(0))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsCmio() public {
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

        uint256 length = 20;
        bytes32 mockState = stateTransition.transitionState(
            bytes32(0),
            0,
            abi.encodePacked(abi.encodePacked(length), new bytes(length)),
            IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsStep() public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x321)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.step.selector),
            abi.encode(accessLogs)
        );

        bytes32 mockState = stateTransition.transitionState(
            bytes32(0), 1, new bytes(0), IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x321)));
    }

    function testTransitionRollupsReset() public {
        AccessLogs.Context memory accessLogs = AccessLogs.Context(
            bytes32(uint256(0x123)), Buffer.Context(new bytes(0), 0)
        );

        vm.mockCall(
            address(riscVStateTransition),
            abi.encode(riscVStateTransition.reset.selector),
            abi.encode(accessLogs)
        );

        bytes32 mockState = stateTransition.transitionState(
            bytes32(0),
            4951760157141521099596496895,
            new bytes(0),
            IDataProvider(address(0x123))
        );

        assertEq(mockState, bytes32(uint256(0x123)));
    }
}
