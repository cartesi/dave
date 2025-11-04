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
pragma solidity ^0.8.0;

import {AccessLogs} from "step/src/AccessLogs.sol";
import {AdvanceStatus} from "step/src/AdvanceStatus.sol";
import {EmulatorCompat} from "step/src/EmulatorCompat.sol";
import {SendCmioResponse} from "step/src/SendCmioResponse.sol";

import {ICmioStateTransition} from "./ICmioStateTransition.sol";

contract CmioStateTransition is ICmioStateTransition {
    using AdvanceStatus for AccessLogs.Context;
    using EmulatorCompat for AccessLogs.Context;

    function checkpoint(AccessLogs.Context memory a, bytes32 checkpointState)
        external
        pure
        returns (AccessLogs.Context memory)
    {
        a.setCheckpointHash(checkpointState);
        return a;
    }

    function revertIfNeeded(AccessLogs.Context memory a)
        external
        pure
        returns (AccessLogs.Context memory)
    {
        if (a.advanceStatus() == AdvanceStatus.Status.REJECTED) {
            bytes32 checkpointState = a.getCheckpointHash();
            a.currentRootHash = checkpointState;
        }

        return a;
    }

    function sendCmio(
        AccessLogs.Context memory a,
        uint16 reason,
        bytes32 dataHash,
        uint32 dataLength
    ) external pure returns (AccessLogs.Context memory) {
        SendCmioResponse.sendCmioResponse(a, reason, dataHash, dataLength);
        return a;
    }
}
