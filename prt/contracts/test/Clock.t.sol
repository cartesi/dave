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

import "prt-contracts/tournament/libs/Clock.sol";

pragma solidity ^0.8.0;

library ExternalClock {
    function advanceClock(Clock.State storage state) external {
        Clock.advanceClock(state);
    }

    function setNewPaused(
        Clock.State storage state,
        Time.Instant checkinInstant,
        Time.Duration initialAllowance
    ) external {
        Clock.setNewPaused(state, checkinInstant, initialAllowance);
    }

    function timeSinceTimeout(Clock.State storage state)
        external
        view
        returns (Time.Duration)
    {
        return Clock.timeSinceTimeout(state);
    }
}

contract ClockTest is Test {
    using Clock for Clock.State;
    using Time for Time.Duration;
    using Time for Time.Instant;

    Clock.State clock1;
    Clock.State clock2;
    Clock.State clock3;

    uint64 constant clock1Allowance = 20;
    uint64 constant clock2Allowance = 30;

    function setUp() public {
        Clock.setNewPaused(
            clock1, Time.currentTime(), Time.Duration.wrap(clock1Allowance)
        );
        Clock.setNewPaused(
            clock2, Time.currentTime(), Time.Duration.wrap(clock2Allowance)
        );
        Clock.setNewPaused(
            clock3, Time.currentTime(), Time.Duration.wrap(clock2Allowance)
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

    function testMax() public view {
        Time.Duration max = clock1.max(clock2);
        assertEq(
            Time.Duration.unwrap(max),
            30,
            "should return max of two paused clocks"
        );

        Time.Duration max2 = clock2.max(clock1);
        assertEq(
            Time.Duration.unwrap(max2),
            30,
            "should return max of two paused clocks"
        );
    }

    function testNewClock() public {
        vm.expectRevert("can't create clock with zero time");
        ExternalClock.setNewPaused(
            clock2, Time.currentTime(), Time.Duration.wrap(0)
        );
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
        ExternalClock.advanceClock(clock1);
    }

    function testTimeout() public {
        clock1.advanceClock();
        clock2.advanceClock();

        vm.roll(Time.Instant.unwrap(clock1.startInstant) + clock1Allowance - 1);
        assertTrue(
            clock1.timeSinceTimeout().isZero(),
            "clock1 shouldn't be timeout yet"
        );

        vm.roll(Time.Instant.unwrap(clock2.startInstant) + clock2Allowance - 1);
        assertTrue(
            clock2.timeSinceTimeout().isZero(),
            "clock2 shouldn't be timeout yet"
        );

        vm.roll(Time.Instant.unwrap(clock1.startInstant) + clock1Allowance);
        assertTrue(clock1.timeSinceTimeout().isZero(), "clock1 just timeout");

        vm.roll(Time.Instant.unwrap(clock2.startInstant) + clock2Allowance);
        assertTrue(clock2.timeSinceTimeout().isZero(), "clock2 just timeout");

        vm.roll(
            Time.Instant.unwrap(clock1.startInstant) + clock1Allowance + 100
        );
        assertTrue(
            clock1.timeSinceTimeout().gt(Time.ZERO_DURATION),
            "clock1 should be timeout"
        );

        vm.roll(Time.Instant.unwrap(clock2.startInstant) + clock2Allowance + 1);
        assertTrue(
            clock2.timeSinceTimeout().gt(Time.ZERO_DURATION),
            "clock2 shouldn be timeout"
        );

        vm.expectRevert("a paused clock can't timeout");
        ExternalClock.timeSinceTimeout(clock3);
    }
}
