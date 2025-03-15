// Copyright Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

/// @title TransitionState
/// @notice Transitions machine state from s to s+1

pragma solidity ^0.8.0;

import "./ITransitionState.sol";
import "step/src/SendCmioResponse.sol";
import "step/src/UArchReset.sol";
import "step/src/UArchStep.sol";
import "step/src/AccessLogs.sol";

contract TransitionState is ITransitionState {
    uint64 constant LOG2_UARCH_SPAN = 20;
    uint64 constant LOG2_EMULATOR_SPAN = 48;
    uint64 constant LOG2_INPUT_SPAN = 24;

    uint256 constant UARCH_STEP_MASK = (1 << LOG2_UARCH_SPAN) - 1;
    uint256 constant BIG_STEP_MASK =
        (1 << (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN)) - 1;

    function transition(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view returns (bytes32 newMachineState) {
        if (address(provider) == address(0)) {
            return transitionCompute(machineState, counter, proofs);
        } else {
            return transitionRollups(machineState, counter, proofs, provider);
        }
    }

    function transitionCompute(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs
    ) internal pure returns (bytes32 newMachineState) {
        // this is a inputless version of the meta step implementation primarily used for testing
        AccessLogs.Context memory accessLogs =
            AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

        if ((counter + 1) & UARCH_STEP_MASK == 0) {
            UArchReset.reset(accessLogs);
        } else {
            UArchStep.step(accessLogs);
        }
        newMachineState = accessLogs.currentRootHash;
    }

    function transitionRollups(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) internal view returns (bytes32 newMachineState) {
        // rollups meta step handles input
        AccessLogs.Context memory accessLogs =
            AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

        if (counter & BIG_STEP_MASK == 0) {
            uint256 inputLength = uint256(bytes32(proofs[:32]));
            accessLogs = AccessLogs.Context(
                machineState, Buffer.Context(proofs, 32 + inputLength)
            );

            if (inputLength > 0) {
                bytes calldata input = proofs[32:32 + inputLength];
                uint256 inputIndexWithinEpoch =
                    counter >> (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN);

                // TODO: maybe assert retrieved input length matches?
                bytes32 inputMerkleRoot = provider.provideMerkleRootOfInput(
                    inputIndexWithinEpoch, input
                );

                require(inputMerkleRoot != bytes32(0));
                SendCmioResponse.sendCmioResponse(
                    accessLogs,
                    EmulatorConstants.HTIF_YIELD_REASON_ADVANCE_STATE,
                    inputMerkleRoot,
                    uint32(inputLength)
                );
                UArchStep.step(accessLogs);
            } else {
                UArchStep.step(accessLogs);
            }
        } else if ((counter + 1) & UARCH_STEP_MASK == 0) {
            UArchReset.reset(accessLogs);
        } else {
            UArchStep.step(accessLogs);
        }
        newMachineState = accessLogs.currentRootHash;
    }
}
