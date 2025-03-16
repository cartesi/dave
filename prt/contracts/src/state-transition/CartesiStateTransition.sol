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

/// @title StateTransition
/// @notice Transitions machine state from s to s+1

pragma solidity ^0.8.0;

import "prt-contracts/state-transition/IRiscVStateTransition.sol";
import "prt-contracts/state-transition/ICmioStateTransition.sol";
import "prt-contracts/IStateTransition.sol";

contract CartesiStateTransition is IStateTransition {
    uint64 constant LOG2_UARCH_SPAN = 20;
    uint64 constant LOG2_EMULATOR_SPAN = 48;
    // uint64 constant LOG2_INPUT_SPAN = 24;

    uint256 constant UARCH_STEP_MASK = (1 << LOG2_UARCH_SPAN) - 1;
    uint256 constant BIG_STEP_MASK =
        (1 << (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN)) - 1;

    IRiscVStateTransition immutable primitives;
    ICmioStateTransition immutable primitivesCmio;

    constructor(
        IRiscVStateTransition _primitives,
        ICmioStateTransition _primitivesCmio
    ) {
        primitives = _primitives;
        primitivesCmio = _primitivesCmio;
    }

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view returns (bytes32) {
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
    ) internal view returns (bytes32 newMachineState) {
        // Inputless version for testing
        AccessLogs.Context memory accessLogs =
            AccessLogs.Context(machineState, Buffer.Context(proofs, 0));
        if ((counter + 1) & UARCH_STEP_MASK == 0) {
            accessLogs = primitives.reset(accessLogs);
        } else {
            accessLogs = primitives.step(accessLogs);
        }

        newMachineState = accessLogs.currentRootHash;
    }

    function transitionRollups(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) internal view returns (bytes32 newMachineState) {
        if (counter & BIG_STEP_MASK == 0) {
            // cmio + uarch step

            uint64 inputLength = uint64(bytes8(proofs[:8]));
            AccessLogs.Context memory accessLogs = AccessLogs.Context(
                machineState, Buffer.Context(proofs, 8 + inputLength)
            );

            bytes calldata input = proofs[8:8 + inputLength];
            uint256 inputIndexWithinEpoch =
                counter >> (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN);
            bytes32 inputMerkleRoot =
                provider.provideMerkleRootOfInput(inputIndexWithinEpoch, input);

            if (inputMerkleRoot != bytes32(0x0)) {
                accessLogs = primitivesCmio.sendCmio(
                    accessLogs,
                    EmulatorConstants.HTIF_YIELD_REASON_ADVANCE_STATE,
                    inputMerkleRoot,
                    uint32(inputLength)
                );
            }
            accessLogs = primitives.step(accessLogs);

            newMachineState = accessLogs.currentRootHash;
        } else {
            AccessLogs.Context memory accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

            if ((counter + 1) & UARCH_STEP_MASK == 0) {
                // uarch reset
                accessLogs = primitives.reset(accessLogs);
            } else {
                // uarch step
                accessLogs = primitives.step(accessLogs);
            }

            newMachineState = accessLogs.currentRootHash;
        }
    }
}
