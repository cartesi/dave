// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

pragma solidity ^0.8.0;

import {stdError} from "forge-std-1.9.6/src/StdError.sol";
import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Time} from "src/tournament/libs/Time.sol";

contract ClockHarness {
    using Clock for Clock.State;

    Clock.State private clock;
    Clock.State private source;

    function state() external view returns (Clock.State memory) {
        return clock;
    }

    function initialize(
        Time.Instant checkin,
        Time.Duration allowance,
        Time.Instant current
    ) external {
        clock.initializePausedAt(checkin, allowance, current);
    }

    function initializeSource(
        Time.Instant checkin,
        Time.Duration allowance,
        Time.Instant current
    ) external {
        source.initializePausedAt(checkin, allowance, current);
    }

    function remainingAt(Time.Instant current)
        external
        view
        returns (Time.Duration)
    {
        return clock.remainingAt(current);
    }

    function overdueByAt(Time.Instant current)
        external
        view
        returns (Time.Duration)
    {
        return clock.overdueByAt(current);
    }

    function startAt(Time.Instant current) external {
        clock.startAt(current);
    }

    function startSourceAt(Time.Instant current) external {
        source.startAt(current);
    }

    function pauseAfterResponseAt(
        Time.Duration responseBudget,
        Time.Instant current
    ) external {
        clock.pauseAfterResponseAt(responseBudget, current);
    }

    function chargeAndPauseAt(Time.Duration charge, Time.Instant current)
        external
    {
        clock.chargeAndPauseAt(charge, current);
    }

    function replaceFromSource() external {
        clock.replaceWithPaused(source.allowance);
    }

    function pausedAllowance() external view returns (Time.Duration) {
        return clock.pausedAllowance();
    }

    function deductSource(Time.Duration charge)
        external
        view
        returns (Clock.State memory)
    {
        return source.deductPaused(charge);
    }

    function deductSourceAndReplace(Time.Duration charge) external {
        Clock.State memory chargedSource = source.deductPaused(charge);
        clock.replaceWithPaused(chargedSource.allowance);
    }
}

contract ClockTest is Test {
    using Clock for Clock.State;
    using Time for Time.Duration;
    using Time for Time.Instant;

    uint64 constant MAX_FUZZ_DURATION = 1_000_000_000_000;

    ClockHarness harness;

    function setUp() public {
        harness = new ClockHarness();
    }

    function testFuzzInitializationChargesElapsed(
        uint64 rawAllowance,
        uint64 rawElapsed,
        uint64 rawCheckin
    ) public {
        uint64 allowance = _boundU64(rawAllowance, 1, MAX_FUZZ_DURATION);
        uint64 elapsed = _boundU64(rawElapsed, 0, allowance - 1);
        uint64 checkin = _boundU64(rawCheckin, 1, type(uint64).max - elapsed);
        uint64 current = checkin + elapsed;

        harness.initialize(
            _instant(checkin), _duration(allowance), _instant(current)
        );

        Clock.State memory state = harness.state();
        assertEq(_unwrap(state.allowance), allowance - elapsed);
        assertEq(Time.Instant.unwrap(state.startInstant), 0);

        vm.expectRevert(ITournament.ClockAlreadyInitialized.selector);
        harness.initialize(
            _instant(checkin), _duration(allowance), _instant(current)
        );
    }

    function testInitializationRejectsInvalidInputs() public {
        vm.expectRevert(stdError.assertionError);
        harness.initialize(_instant(10), _duration(5), _instant(15));

        vm.expectRevert(stdError.arithmeticError);
        harness.initialize(_instant(10), _duration(5), _instant(9));
    }

    function testFuzzRemainingAndOverdueFollowModel(
        uint64 rawAllowance,
        uint64 rawEarlierElapsed,
        uint64 rawLaterElapsed,
        uint64 rawStart
    ) public pure {
        uint64 allowance = _boundPure(rawAllowance, 1, MAX_FUZZ_DURATION);
        uint64 earlierElapsed =
            _boundPure(rawEarlierElapsed, 0, allowance + 100);
        uint64 laterElapsed =
            _boundPure(rawLaterElapsed, earlierElapsed, allowance + 200);
        uint64 start = _boundPure(rawStart, 1, type(uint64).max - laterElapsed);
        Time.Instant earlier = _instant(start + earlierElapsed);
        Time.Instant later = _instant(start + laterElapsed);

        Clock.State memory running = Clock.State({
            allowance: _duration(allowance), startInstant: _instant(start)
        });
        Clock.State memory paused = Clock.State({
            allowance: _duration(allowance), startInstant: Time.ZERO_INSTANT
        });

        uint64 earlierRemaining = _unwrap(running.remainingAt(earlier));
        uint64 laterRemaining = _unwrap(running.remainingAt(later));
        uint64 earlierOverdue = _unwrap(running.overdueByAt(earlier));
        uint64 laterOverdue = _unwrap(running.overdueByAt(later));

        assertEq(
            earlierRemaining,
            earlierElapsed < allowance ? allowance - earlierElapsed : 0
        );
        assertEq(
            earlierOverdue,
            earlierElapsed > allowance ? earlierElapsed - allowance : 0
        );
        assertLe(laterRemaining, earlierRemaining);
        assertGe(laterOverdue, earlierOverdue);
        assertEq(_unwrap(paused.remainingAt(earlier)), allowance);
        assertEq(_unwrap(paused.remainingAt(later)), allowance);
    }

    function testDeadlineAndInvalidQuerySemantics() public {
        harness.initialize(_instant(10), _duration(20), _instant(10));

        vm.expectRevert(stdError.assertionError);
        harness.overdueByAt(_instant(100));

        harness.startAt(_instant(11));
        assertEq(_unwrap(harness.remainingAt(_instant(31))), 0);
        assertEq(_unwrap(harness.overdueByAt(_instant(31))), 0);
        assertEq(_unwrap(harness.overdueByAt(_instant(32))), 1);

        vm.expectRevert(stdError.arithmeticError);
        harness.remainingAt(_instant(10));

        ClockHarness empty = new ClockHarness();
        vm.expectRevert(stdError.assertionError);
        empty.remainingAt(_instant(10));
    }

    function testFuzzResponseBudgetDiscountsElapsedWithoutMinting(
        uint64 rawAllowance,
        uint64 rawElapsed,
        uint64 rawResponseBudget
    ) public {
        uint64 allowance = _boundU64(rawAllowance, 1, MAX_FUZZ_DURATION);
        uint64 elapsed = _boundU64(rawElapsed, 0, allowance - 1);
        uint64 responseBudget =
            _boundU64(rawResponseBudget, 0, MAX_FUZZ_DURATION);
        harness.initialize(_instant(10), _duration(allowance), _instant(10));
        harness.startAt(_instant(11));

        vm.expectRevert(stdError.assertionError);
        harness.startAt(_instant(11));

        harness.pauseAfterResponseAt(
            _duration(responseBudget), _instant(11 + elapsed)
        );
        Clock.State memory state = harness.state();
        uint64 chargedElapsed = _saturatingSub(elapsed, responseBudget);
        uint64 expectedAllowance = allowance - chargedElapsed;
        assertEq(_unwrap(state.allowance), expectedAllowance);
        assertLe(expectedAllowance, allowance);
        assertEq(
            elapsed,
            allowance - expectedAllowance + _min(elapsed, responseBudget)
        );
        assertFalse(state.isRunning());

        vm.expectRevert(stdError.assertionError);
        harness.pauseAfterResponseAt(
            _duration(responseBudget), _instant(11 + elapsed)
        );
    }

    function testResponseBudgetBoundaryTable() public {
        _assertResponseCase(100, 0, 10, 100);
        _assertResponseCase(100, 9, 10, 100);
        _assertResponseCase(100, 10, 10, 100);
        _assertResponseCase(100, 11, 10, 99);
        _assertResponseCase(100, 11, 0, 89);
        _assertResponseCase(100, 99, 200, 100);
    }

    function testStartAndResponsePauseRejectInvalidTransitions() public {
        vm.expectRevert(stdError.assertionError);
        harness.startAt(_instant(10));

        harness.initialize(_instant(10), _duration(20), _instant(10));
        vm.expectRevert(stdError.assertionError);
        harness.startAt(Time.ZERO_INSTANT);

        harness.startAt(_instant(11));
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        harness.pauseAfterResponseAt(_duration(100), _instant(31));

        Clock.State memory state = harness.state();
        assertEq(_unwrap(state.allowance), 20);
        assertEq(Time.Instant.unwrap(state.startInstant), 11);

        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        harness.pauseAfterResponseAt(_duration(100), _instant(32));
    }

    function testFuzzChargeUsesLiveRemainingTime(
        bool running,
        uint64 rawAllowance,
        uint64 rawElapsed,
        uint64 rawCharge
    ) public {
        uint64 allowance = _boundU64(rawAllowance, 1, MAX_FUZZ_DURATION);
        uint64 elapsed = running ? _boundU64(rawElapsed, 0, allowance - 1) : 0;
        uint64 remaining = allowance - elapsed;
        uint64 charge = _boundU64(rawCharge, 0, remaining - 1);

        harness.initialize(_instant(10), _duration(allowance), _instant(10));
        if (running) harness.startAt(_instant(11));
        harness.chargeAndPauseAt(
            _duration(charge), _instant(running ? 11 + elapsed : 100)
        );

        Clock.State memory state = harness.state();
        assertEq(_unwrap(state.allowance), remaining - charge);
        assertFalse(state.isRunning());
    }

    function testChargeRejectsAZeroRemainder() public {
        harness.initialize(_instant(10), _duration(20), _instant(10));
        harness.startAt(_instant(11));

        vm.expectRevert(stdError.assertionError);
        harness.chargeAndPauseAt(_duration(15), _instant(16));
    }

    function testChargeRejectsAnOvercharge() public {
        harness.initialize(_instant(10), _duration(20), _instant(10));
        harness.startAt(_instant(11));

        vm.expectRevert(stdError.arithmeticError);
        harness.chargeAndPauseAt(_duration(16), _instant(16));
    }

    function testFuzzPausedCarryoverPreservesTheChargedRemainder(uint64 rawCharge)
        public
    {
        uint64 charge = _boundU64(rawCharge, 0, 79);
        harness.initialize(_instant(10), _duration(100), _instant(10));
        harness.initializeSource(_instant(10), _duration(80), _instant(10));

        harness.deductSourceAndReplace(_duration(charge));
        Clock.State memory state = harness.state();
        assertEq(_unwrap(state.allowance), 80 - charge);
        assertFalse(state.isRunning());
    }

    function testCarryoverRejectsAZeroRemainder() public {
        harness.initialize(_instant(10), _duration(100), _instant(10));
        harness.initializeSource(_instant(10), _duration(80), _instant(10));

        vm.expectRevert(stdError.assertionError);
        harness.deductSourceAndReplace(_duration(80));
    }

    function testPausedReplacementRequiresInitializedPausedTarget() public {
        harness.initializeSource(_instant(10), _duration(80), _instant(10));

        vm.expectRevert(stdError.assertionError);
        harness.replaceFromSource();

        harness.initialize(_instant(10), _duration(100), _instant(10));
        harness.startAt(_instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.replaceFromSource();
    }

    function testPausedReplacementRejectsZeroAllowanceSource() public {
        harness.initialize(_instant(10), _duration(100), _instant(10));

        vm.expectRevert(stdError.assertionError);
        harness.replaceFromSource();
    }

    function testDeductPausedRejectsUninitializedClock() public {
        vm.expectRevert(stdError.assertionError);
        harness.deductSource(_duration(0));
    }

    function testDeductPausedRejectsRunningClock() public {
        harness.initializeSource(_instant(10), _duration(80), _instant(10));
        harness.startSourceAt(_instant(11));

        vm.expectRevert(stdError.assertionError);
        harness.deductSource(_duration(0));
    }

    function testDeductPausedRejectsAZeroRemainder() public {
        harness.initializeSource(_instant(10), _duration(80), _instant(10));

        vm.expectRevert(stdError.assertionError);
        harness.deductSource(_duration(80));
    }

    function testDeductPausedRejectsAnOvercharge() public {
        harness.initializeSource(_instant(10), _duration(80), _instant(10));

        vm.expectRevert(stdError.arithmeticError);
        harness.deductSource(_duration(81));
    }

    function testPausedAllowanceReturnsThePausedRemainder() public {
        harness.initialize(_instant(10), _duration(80), _instant(15));

        assertEq(_unwrap(harness.pausedAllowance()), 75);
        assertEq(
            _unwrap(harness.pausedAllowance()),
            _unwrap(harness.remainingAt(_instant(40)))
        );
    }

    function testPausedAllowanceRejectsUninitializedClock() public {
        vm.expectRevert(stdError.assertionError);
        harness.pausedAllowance();
    }

    function testPausedAllowanceRejectsRunningClock() public {
        harness.initialize(_instant(10), _duration(80), _instant(10));
        harness.startAt(_instant(11));

        vm.expectRevert(stdError.assertionError);
        harness.pausedAllowance();
    }

    function _assertResponseCase(
        uint64 allowance,
        uint64 elapsed,
        uint64 responseBudget,
        uint64 expectedAllowance
    ) private {
        ClockHarness subject = new ClockHarness();
        subject.initialize(_instant(10), _duration(allowance), _instant(10));
        subject.startAt(_instant(11));
        subject.pauseAfterResponseAt(
            _duration(responseBudget), _instant(11 + elapsed)
        );

        Clock.State memory state = subject.state();
        assertEq(_unwrap(state.allowance), expectedAllowance);
        assertFalse(state.isRunning());
    }

    function _boundU64(uint64 value, uint64 minimum, uint64 maximum)
        private
        pure
        returns (uint64)
    {
        return uint64(bound(uint256(value), minimum, maximum));
    }

    function _boundPure(uint64 value, uint64 minimum, uint64 maximum)
        private
        pure
        returns (uint64)
    {
        uint256 size = uint256(maximum) - minimum + 1;
        return uint64(minimum + (uint256(value) % size));
    }

    function _duration(uint64 value) private pure returns (Time.Duration) {
        return Time.Duration.wrap(value);
    }

    function _instant(uint64 value) private pure returns (Time.Instant) {
        return Time.Instant.wrap(value);
    }

    function _unwrap(Time.Duration value) private pure returns (uint64) {
        return Time.Duration.unwrap(value);
    }

    function _min(uint64 one, uint64 two) private pure returns (uint64) {
        return one < two ? one : two;
    }

    function _saturatingSub(uint64 one, uint64 two)
        private
        pure
        returns (uint64)
    {
        return one < two ? 0 : one - two;
    }
}
