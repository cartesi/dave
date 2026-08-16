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

import {SafeCast} from "@openzeppelin-contracts-5.5.0/utils/math/SafeCast.sol";

import {AccessLogs} from "step/src/AccessLogs.sol";
import {Buffer} from "step/src/Buffer.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {MetaStep} from "step/src/MetaStep.sol";
import {SendCmioResponse} from "step/src/SendCmioResponse.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";

contract CartesiStateTransition is IStateTransition {
    // TODO add CM_MARCHID

    using SafeCast for uint256;

    uint64 constant LOG2_INPUT_WINDOW_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;

    uint256 constant INPUT_MASK = (1 << LOG2_INPUT_WINDOW_SPAN) - 1;

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view returns (bytes32) {
        AccessLogs.Context memory accessLogs;

        // lower bits (uarch + big arch) are zero: add input.
        if (counter & INPUT_MASK == 0) {
            // proofs structure:
            // input_length <- proofs[:8] (big endian)
            // input <- proofs[8:8+input_length]
            // access_logs <- proofs[8+input_length:]

            // first 8 bytes of the proof are the size of the input, big-endian.
            // next `inputLength` bytes of the proof are the input itself.
            uint64 inputLength = uint64(bytes8(proofs[:8]));
            bytes calldata input = proofs[8:8 + inputLength];
            uint256 inputIndexWithinEpoch = counter >> LOG2_INPUT_WINDOW_SPAN;
            bytes32 inputMerkleRoot =
                provider.provideMerkleRootOfInput(inputIndexWithinEpoch, input);

            // the rest is the access log proofs, which has the concatenated proofs for:
            // * sendCmio
            // * step
            accessLogs = AccessLogs.Context(
                machineState, Buffer.Context(proofs[8 + inputLength:], 0)
            );

            // check if input is out-of-bounds of input box for this epoch
            if (inputMerkleRoot != bytes32(0x0)) {
                // The primitive records the pre-input state for rollback.
                // A machine that cannot accept this response produces a provable no-op.
                SendCmioResponse.sendCmioResponse(
                    accessLogs,
                    EmulatorConstants.HTIF_YIELD_REASON_ADVANCE_STATE,
                    inputMerkleRoot,
                    uint256(inputLength).toUint32(),
                    machineState
                );
            }
        } else {
            accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));
        }

        // MetaStep resets the uarch at the end of each uarch span. Dave's
        // counter names the source state, while MetaStep's names the state
        // produced by this transition.
        MetaStep.step(counter + 1, accessLogs);

        return accessLogs.currentRootHash;
    }
}
