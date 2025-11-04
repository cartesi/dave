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

import {AccessLogs} from "step/src/AccessLogs.sol";
import {Buffer} from "step/src/Buffer.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

import {ICmioStateTransition} from "./ICmioStateTransition.sol";
import {IRiscVStateTransition} from "./IRiscVStateTransition.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";

contract CartesiStateTransition is IStateTransition {
    // TODO add CM_MARCHID

    uint64 constant LOG2_UARCH_SPAN_TO_BARCH = 20;
    uint64 constant LOG2_BARCH_SPAN_TO_INPUT = 48;

    uint256 constant BIG_STEP_MASK = (1 << LOG2_UARCH_SPAN_TO_BARCH) - 1;
    uint256 constant INPUT_MASK =
        (1 << (LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH)) - 1;

    IRiscVStateTransition immutable RISC_V_STATE_TRANSITION;
    ICmioStateTransition immutable CMIO_STATE_TRANSITION;

    constructor(
        IRiscVStateTransition _riscVStateTransition,
        ICmioStateTransition _cmioStateTransition
    ) {
        RISC_V_STATE_TRANSITION = _riscVStateTransition;
        CMIO_STATE_TRANSITION = _cmioStateTransition;
    }

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view returns (bytes32) {
        // lower bits (uarch + big arch) are zero: add input.
        if (counter & INPUT_MASK == 0) {
            // chekpoint + cmio + uarch step

            // proofs structure:
            // input_length <- proofs[:8] (big endian)
            // input <- proofs[8:8+input_length]
            // access_logs <- proofs[8+input_length:]

            // first 8 bytes of the proof are the size of the input, big-endian.
            // next `inputLength` bytes of the proof are the input itself.
            uint64 inputLength = uint64(bytes8(proofs[:8]));
            bytes calldata input = proofs[8:8 + inputLength];
            uint256 inputIndexWithinEpoch = counter
                >> (LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH);
            bytes32 inputMerkleRoot =
                provider.provideMerkleRootOfInput(inputIndexWithinEpoch, input);

            // the rest is the access log proofs, which has the concatenated proofs for:
            // * checkpoint
            // * sendCmio
            // * step
            AccessLogs.Context memory accessLogs = AccessLogs.Context(
                machineState, Buffer.Context(proofs[8 + inputLength:], 0)
            );

            // check if input is out-of-bounds of input box for this epoch
            if (inputMerkleRoot != bytes32(0x0)) {
                // checkpoint
                accessLogs =
                    CMIO_STATE_TRANSITION.checkpoint(accessLogs, machineState);

                // sendCmio
                accessLogs = CMIO_STATE_TRANSITION.sendCmio(
                    accessLogs,
                    EmulatorConstants.CMIO_YIELD_REASON_ADVANCE_STATE,
                    inputMerkleRoot,
                    uint32(inputLength)
                );
            }

            // step
            accessLogs = RISC_V_STATE_TRANSITION.step(accessLogs);

            return accessLogs.currentRootHash;

            // lower bits (uarch) are all 1s: reset uarch.
        } else if ((counter + 1) & BIG_STEP_MASK == 0) {
            // access log proofs has the concatenated proofs for:
            // * step
            // * reset
            // * advanceStatus
            // * getCheckpointHash (only if needed)
            AccessLogs.Context memory accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

            accessLogs = RISC_V_STATE_TRANSITION.step(accessLogs);
            accessLogs = RISC_V_STATE_TRANSITION.reset(accessLogs);
            accessLogs = CMIO_STATE_TRANSITION.revertIfNeeded(accessLogs);

            return accessLogs.currentRootHash;

            // else: step uarch.
        } else {
            // access log proofs has proofs for:
            // * step
            AccessLogs.Context memory accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

            accessLogs = RISC_V_STATE_TRANSITION.step(accessLogs);

            return accessLogs.currentRootHash;
        }
    }
}
