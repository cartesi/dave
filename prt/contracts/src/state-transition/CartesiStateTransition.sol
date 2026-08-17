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

/// @title Cartesi machine state transition
/// @notice Verifies one epoch-local Cartesi machine transition.

pragma solidity ^0.8.0;

import {SafeCast} from "@openzeppelin-contracts-5.5.0/utils/math/SafeCast.sol";

import {AccessLogs} from "step/src/AccessLogs.sol";
import {Buffer} from "step/src/Buffer.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {SendCmioResponse} from "step/src/SendCmioResponse.sol";
import {UArchReset} from "step/src/UArchReset.sol";
import {UArchStep} from "step/src/UArchStep.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";

contract CartesiStateTransition is IStateTransition {
    /// @notice Cartesi Machine architecture ID qualified by this transition.
    /// @dev Pinned to v0.21.0 until a released solidity-step exposes it.
    uint64 public constant CM_MARCHID = 21;

    using SafeCast for uint256;

    error CounterOutsideEpoch(uint256 counter);
    error InvalidAccessLogProofLength(uint256 consumed, uint256 provided);

    uint64 constant LOG2_INPUT_WINDOW_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
    uint64 constant LOG2_EPOCH_RULER_SPAN = LOG2_INPUT_WINDOW_SPAN
        + EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH;

    uint256 constant UARCH_CYCLE_MASK =
        (1 << EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) - 1;
    uint256 constant INPUT_MASK = (1 << LOG2_INPUT_WINDOW_SPAN) - 1;
    uint256 constant EPOCH_RULER_SPAN = 1 << LOG2_EPOCH_RULER_SPAN;

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view returns (bytes32) {
        // counter indexes the output leaf; machineState is its predecessor.
        // At counter zero, that predecessor is the commitment's implicit hash.
        if (counter >= EPOCH_RULER_SPAN) {
            revert CounterOutsideEpoch(counter);
        }

        // An input-window opening fuses optional CMIO delivery with its first
        // uarch step.
        if ((counter & INPUT_MASK) == 0) {
            uint256 inputIndexWithinEpoch = counter >> LOG2_INPUT_WINDOW_SPAN;
            (
                bytes32 inputMerkleRoot,
                uint64 inputLength,
                uint256 accessLogsOffset
            ) = _resolveInputWitness(proofs, inputIndexWithinEpoch, provider);

            AccessLogs.Context memory accessLogs = AccessLogs.Context(
                machineState, Buffer.Context(proofs[accessLogsOffset:], 0)
            );

            // A nonzero root requires a CMIO proof before the uarch-step proof.
            // Zero denotes no input; the uarch step still executes.
            if (inputMerkleRoot != bytes32(0x0)) {
                // CMIO records machineState for rejected-input rollback.
                // Inapplicable responses are provable no-ops.
                // Reject rather than truncate lengths outside CMIO's uint32 domain.
                SendCmioResponse.sendCmioResponse(
                    accessLogs,
                    EmulatorConstants.HTIF_YIELD_REASON_ADVANCE_STATE,
                    inputMerkleRoot,
                    uint256(inputLength).toUint32(),
                    machineState
                );
            }

            UArchStep.step(accessLogs);
            _requireAccessLogProofFullyConsumed(accessLogs.buffer);
            return accessLogs.currentRootHash;
        } else if ((counter & UARCH_CYCLE_MASK) == UARCH_CYCLE_MASK) {
            // A uarch span's closing transition fuses its final step with reset.
            // Only RX_REJECTED restores the root recorded at input delivery.
            AccessLogs.Context memory accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

            UArchStep.step(accessLogs);
            UArchReset.reset(accessLogs);
            _requireAccessLogProofFullyConsumed(accessLogs.buffer);
            return accessLogs.currentRootHash;
        } else {
            AccessLogs.Context memory accessLogs =
                AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

            UArchStep.step(accessLogs);
            _requireAccessLogProofFullyConsumed(accessLogs.buffer);
            return accessLogs.currentRootHash;
        }
    }

    function _resolveInputWitness(
        bytes calldata proofs,
        uint256 inputIndexWithinEpoch,
        IDataProvider provider
    )
        internal
        view
        returns (
            bytes32 inputMerkleRoot,
            uint64 inputLength,
            uint256 accessLogsOffset
        )
    {
        // Prefix: an 8-byte big-endian length followed by that many input
        // bytes. Calldata slicing rejects a truncated header or payload.
        inputLength = uint64(bytes8(proofs[:8]));
        accessLogsOffset = 8 + uint256(inputLength);
        bytes calldata input = proofs[8:accessLogsOffset];
        inputMerkleRoot =
            provider.provideMerkleRootOfInput(inputIndexWithinEpoch, input);
    }

    function _requireAccessLogProofFullyConsumed(Buffer.Context memory buffer)
        private
        pure
    {
        // Buffer reads are unchecked, so exact consumption rejects both
        // trailing data and truncated proofs that read past data.length.
        if (buffer.offset != buffer.data.length) {
            revert InvalidAccessLogProofLength(
                buffer.offset, buffer.data.length
            );
        }
    }
}
