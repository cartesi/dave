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

import "./IRiscVStateTransition.sol";
import "step/src/UArchReset.sol";
import "step/src/UArchStep.sol";

contract RiscVStateTransition is IRiscVStateTransition {
    function step(AccessLogs.Context memory a)
        external
        pure
        returns (AccessLogs.Context memory)
    {
        UArchStep.step(a);
        return a;
    }

    function reset(AccessLogs.Context memory a)
        external
        pure
        returns (AccessLogs.Context memory)
    {
        UArchReset.reset(a);
        return a;
    }
}
