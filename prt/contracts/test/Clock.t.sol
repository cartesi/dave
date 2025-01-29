// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std/Test.sol";

import "src/tournament/libs/Clock.sol";

pragma solidity ^0.8.0;

library ExternalClock {
    function advanceClockExternal(Clock.State storage state) external {
        Clock.advanceClock(state);
    }
}

contract ClockTest is Test {
    using Clock for Clock.State;
    using ExternalClock for Clock.State;
    using Time for Time.Instant;

    Clock.State clock1;
    Clock.State clock2;

    uint64 constant clock1Allowance = 20;
    uint64 constant clock2Allowance = 30;

    function setUp() public {
        Clock.setNewPaused(
            clock1, Time.currentTime(), Time.Duration.wrap(clock1Allowance)
        );
        Clock.setNewPaused(
            clock2, Time.currentTime(), Time.Duration.wrap(clock2Allowance)
        );
    }

    function testMax() public view {
        Time.Duration max = clock1.max(clock2);
        assertEq(
            Time.Duration.unwrap(max),
            30,
            "should return max of two paused clocks"
        );
    }

    function testAdvanceClock() public {
        assertTrue(clock1.startInstant.isZero(), "clock1 should be set paused");

        clock1.advanceClock();
        assertTrue(
            !clock1.startInstant.isZero(), "clock1 should be set running"
        );

        clock1.advanceClock();
        assertTrue(clock1.startInstant.isZero(), "clock1 should be set paused");
    }

    function testTimeLeft() public {
        assertTrue(clock1.hasTimeLeft(), "clock1 should have time left");

        clock1.advanceClock();
        assertTrue(clock1.hasTimeLeft(), "clock1 should have time left");

        vm.roll(vm.getBlockNumber() + clock1Allowance - 1);
        assertTrue(clock1.hasTimeLeft(), "clock1 should have time left");

        vm.roll(vm.getBlockNumber() + clock1Allowance);
        assertTrue(!clock1.hasTimeLeft(), "clock1 should run out of time");

        vm.expectRevert("can't advance clock with no time left");
        clock1.advanceClockExternal();
    }
}
