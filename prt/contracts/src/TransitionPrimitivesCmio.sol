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

/// @title TransitionPrimitives
/// @notice Contain three primitives that transitions machine state from s to s+1

pragma solidity ^0.8.0;

import "./ITransitionPrimitivesCmio.sol";
import "step/src/SendCmioResponse.sol";

contract TransitionPrimitivesCmio is ITransitionPrimitivesCmio {
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
