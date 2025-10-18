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

contract ComputeStateTransition is IStateTransition {
    uint64 constant LOG2_UARCH_SPAN_TO_BARCH = 20;
    uint256 constant BIG_STEP_MASK = (1 << LOG2_UARCH_SPAN_TO_BARCH) - 1;

    IRiscVStateTransition immutable riscVStateTransition;

    constructor(IRiscVStateTransition _riscVStateTransition) {
        riscVStateTransition = _riscVStateTransition;
    }

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider
    ) external view returns (bytes32 newMachineState) {
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
}
