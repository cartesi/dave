// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std-1.9.6/src/Test.sol";

import "prt-contracts/types/Machine.sol";
import "prt-contracts/tournament/libs/Time.sol";

pragma solidity ^0.8.0;

library ExternalTime {
    function sub(Time.Duration left, Time.Duration right)
        external
        pure
        returns (Time.Duration)
    {
        return Time.sub(left, right);
    }
}

contract LibraryTest is Test {
    using Machine for Machine.Hash;
    using Time for Time.Duration;

    function testTimeSub() public pure {
        Time.Duration l = Time.Duration.wrap(25);
        Time.Duration r = Time.Duration.wrap(25);
        assertEq(Time.Duration.unwrap(l.sub(r)), 0);

        l = Time.Duration.wrap(26);
        r = Time.Duration.wrap(25);
        assertEq(Time.Duration.unwrap(l.sub(r)), 1);
    }

    function testTimeSubRevert() public {
        vm.expectRevert();
        Time.Duration l = Time.Duration.wrap(25);
        Time.Duration r = Time.Duration.wrap(35);
        ExternalTime.sub(l, r);
    }

    function testMachineNotInitialized() public pure {
        assertTrue(Machine.ZERO_STATE.notInitialized());
    }
}
