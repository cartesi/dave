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
    // TODO add CM_MARCHID

    uint64 constant LOG2_UARCH_SPAN_TO_BARCH = 20;
    uint64 constant LOG2_BARCH_SPAN_TO_INPUT = 48;

    uint256 constant BIG_STEP_MASK = (1 << LOG2_UARCH_SPAN_TO_BARCH) - 1;
    uint256 constant INPUT_MASK =
        (1 << (LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH)) - 1;

    IRiscVStateTransition immutable riscVStateTransition;
    ICmioStateTransition immutable cmioStateTransition;

    constructor(
        IRiscVStateTransition _riscVStateTransition,
        ICmioStateTransition _cmioStateTransition
    ) {
        riscVStateTransition = _riscVStateTransition;
        cmioStateTransition = _cmioStateTransition;
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
        if ((counter + 1) & BIG_STEP_MASK == 0) {
            accessLogs = riscVStateTransition.step(accessLogs);
            accessLogs = riscVStateTransition.reset(accessLogs);
        } else {
            accessLogs = riscVStateTransition.step(accessLogs);
        }

        newMachineState = accessLogs.currentRootHash;
    }

    function transitionRollups(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) internal view returns (bytes32) {
        // lower bits (uarch + big arch) are zero: add input.
        if (counter & INPUT_MASK == 0) {
            // cmio + uarch step

            // first eight bytes of the proof are the size of the input, big-endian.
            // next `inputLength` bytes of the proof are the input itself.
            uint64 inputLength = uint64(bytes8(proofs[:8]));
            bytes calldata input = proofs[8:8 + inputLength];

            // the rest is the access log proofs
            AccessLogs.Context memory accessLogs = AccessLogs.Context(
                machineState, Buffer.Context(proofs[8 + inputLength:], 0)
            );

            uint256 inputIndexWithinEpoch =
                counter >> (LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH);
            bytes32 inputMerkleRoot =
                provider.provideMerkleRootOfInput(inputIndexWithinEpoch, input);

            // check if input is out-of-bounds of input box for this epoch
            if (inputMerkleRoot != bytes32(0x0)) {
                accessLogs = cmioStateTransition.sendCmio(
                    accessLogs,
                    EmulatorConstants.CMIO_YIELD_REASON_ADVANCE_STATE,
                    inputMerkleRoot,
                    uint32(inputLength)
                );
            }

            accessLogs = riscVStateTransition.step(accessLogs);

            return accessLogs.currentRootHash;
        } else {
            AccessLogs.Context memory accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

            // lower bits (uarch) are all 1s: reset uarch.
            if ((counter + 1) & BIG_STEP_MASK == 0) {
                // uarch reset
                accessLogs = riscVStateTransition.step(accessLogs);
                accessLogs = riscVStateTransition.reset(accessLogs);
            } else {
                // uarch step
                accessLogs = riscVStateTransition.step(accessLogs);
            }

            return accessLogs.currentRootHash;
        }
    }
}
