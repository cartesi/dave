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
import {MatchClocks} from "src/tournament/libs/MatchClocks.sol";
import {Time} from "src/tournament/libs/Time.sol";

contract ClockHarness {
    using Clock for Clock.State;

    Clock.State private one;
    Clock.State private two;

    function oneState() external view returns (Clock.State memory) {
        return one;
    }

    function twoState() external view returns (Clock.State memory) {
        return two;
    }

    function initializeOne(
        Time.Instant checkin,
        Time.Duration allowance,
        Time.Instant current
    ) external {
        one.initializePausedAt(checkin, allowance, current);
    }

    function initializeTwo(
        Time.Instant checkin,
        Time.Duration allowance,
        Time.Instant current
    ) external {
        two.initializePausedAt(checkin, allowance, current);
    }

    function remainingOneAt(Time.Instant current)
        external
        view
        returns (Time.Duration)
    {
        return one.remainingAt(current);
    }

    function overdueOneAt(Time.Instant current)
        external
        view
        returns (Time.Duration)
    {
        return one.overdueByAt(current);
    }

    function startOneAt(Time.Instant current) external {
        one.startAt(current);
    }

    function startTwoAt(Time.Instant current) external {
        two.startAt(current);
    }

    function pauseOneAfterResponseAt(
        Time.Duration responseBudget,
        Time.Instant current
    ) external {
        one.pauseAfterResponseAt(responseBudget, current);
    }

    function chargeOneAndPauseAt(Time.Duration charge, Time.Instant current)
        external
    {
        one.chargeAndPauseAt(charge, current);
    }

    function deductTwoAndReplaceOne(Time.Duration charge) external {
        Clock.State memory source = two.deductPaused(charge);
        one.replaceWithPaused(source);
    }

    function startBisectionAt(Time.Instant current) external {
        MatchClocks.startBisectionAt(one, two, current);
    }

    function switchTurnAt(Time.Duration responseBudget, Time.Instant current)
        external
    {
        MatchClocks.switchTurnAt(one, two, responseBudget, current);
    }

    function startLeafRaceAt(Time.Duration responseBudget, Time.Instant current)
        external
    {
        MatchClocks.startLeafRaceAt(one, two, responseBudget, current);
    }

    function pauseForInnerAt(Time.Duration responseBudget, Time.Instant current)
        external
        returns (Time.Duration)
    {
        return MatchClocks.pauseForInnerAt(one, two, responseBudget, current);
    }

    function settleProvenLeafWinnerAt(bool oneWon, Time.Instant current)
        external
    {
        MatchClocks.settleProvenLeafWinnerAt(
            one,
            two,
            oneWon
                ? ITournament.WinnerCommitment.ONE
                : ITournament.WinnerCommitment.TWO,
            current
        );
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

        harness.initializeOne(
            _instant(checkin), _duration(allowance), _instant(current)
        );

        Clock.State memory state = harness.oneState();
        assertEq(_unwrap(state.allowance), allowance - elapsed);
        assertEq(Time.Instant.unwrap(state.startInstant), 0);

        vm.expectRevert(ITournament.ClockAlreadyInitialized.selector);
        harness.initializeOne(
            _instant(checkin), _duration(allowance), _instant(current)
        );
    }

    function testInitializationRejectsInvalidInputs() public {
        vm.expectRevert(
            ITournament.InitializedClockCannotHaveZeroAllowance.selector
        );
        harness.initializeOne(_instant(10), _duration(5), _instant(15));

        vm.expectRevert(stdError.arithmeticError);
        harness.initializeOne(_instant(10), _duration(5), _instant(9));
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
        harness.initializeOne(_instant(10), _duration(20), _instant(10));

        vm.expectRevert(ITournament.PausedClockCannotTimeout.selector);
        harness.overdueOneAt(_instant(100));

        harness.startOneAt(_instant(11));
        assertEq(_unwrap(harness.remainingOneAt(_instant(31))), 0);
        assertEq(_unwrap(harness.overdueOneAt(_instant(31))), 0);
        assertEq(_unwrap(harness.overdueOneAt(_instant(32))), 1);

        vm.expectRevert(stdError.arithmeticError);
        harness.remainingOneAt(_instant(10));

        ClockHarness empty = new ClockHarness();
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        empty.remainingOneAt(_instant(10));
    }

    function testFuzzTimeoutClassificationMatchesModelAndIsSymmetric(
        uint8 rawPhase,
        uint64 rawAllowanceOne,
        uint64 rawAllowanceTwo,
        uint64 rawElapsedOne,
        uint64 rawElapsedTwo
    ) public pure {
        uint64 allowanceOne = _boundPure(rawAllowanceOne, 1, MAX_FUZZ_DURATION);
        uint64 allowanceTwo = _boundPure(rawAllowanceTwo, 1, MAX_FUZZ_DURATION);
        uint8 phase = rawPhase % 4;
        bool oneRunning = phase == 0 || phase == 2;
        bool twoRunning = phase == 1 || phase == 2;
        uint64 maximumElapsed = allowanceOne + allowanceTwo;
        uint64 elapsedOne =
            oneRunning ? _boundPure(rawElapsedOne, 0, maximumElapsed) : 0;
        uint64 elapsedTwo =
            twoRunning ? _boundPure(rawElapsedTwo, 0, maximumElapsed) : 0;
        if (phase == 2) {
            elapsedTwo = elapsedOne;
        }

        uint64 current = 3 * MAX_FUZZ_DURATION;
        Clock.State memory one =
            _clockState(allowanceOne, oneRunning, elapsedOne, current);
        Clock.State memory two =
            _clockState(allowanceTwo, twoRunning, elapsedTwo, current);

        uint64 remainingOne =
            oneRunning ? _monus(allowanceOne, elapsedOne) : allowanceOne;
        uint64 remainingTwo =
            twoRunning ? _monus(allowanceTwo, elapsedTwo) : allowanceTwo;
        uint64 overdueOne = oneRunning ? _monus(elapsedOne, allowanceOne) : 0;
        uint64 overdueTwo = twoRunning ? _monus(elapsedTwo, allowanceTwo) : 0;
        (MatchClocks.TimeoutOutcome expectedOutcome, uint64 expectedCharge) =
            _modelTimeout(remainingOne, overdueOne, remainingTwo, overdueTwo);

        MatchClocks.TimeoutStatus memory status =
            MatchClocks.classifyTimeoutAt(one, two, _instant(current));
        assertEq(uint8(status.outcome), uint8(expectedOutcome));
        assertEq(_unwrap(status.winnerCharge), expectedCharge);

        bool canWin = status.outcome == MatchClocks.TimeoutOutcome.ONE_WINS
            || status.outcome == MatchClocks.TimeoutOutcome.TWO_WINS;
        bool canEliminate =
            status.outcome == MatchClocks.TimeoutOutcome.ELIMINATE_BOTH;
        bool atLeastOneExpired = remainingOne == 0 || remainingTwo == 0;
        assertFalse(canWin && canEliminate);
        assertEq(canWin || canEliminate, atLeastOneExpired);

        MatchClocks.TimeoutStatus memory swapped =
            MatchClocks.classifyTimeoutAt(two, one, _instant(current));
        assertEq(
            uint8(swapped.outcome), uint8(_swapTimeoutOutcome(expectedOutcome))
        );
        assertEq(_unwrap(swapped.winnerCharge), expectedCharge);
    }

    function testFuzzBisectionTimeoutBoundaries(
        bool oneRuns,
        uint64 rawRunningAllowance,
        uint64 rawPausedAllowance
    ) public pure {
        uint64 runningAllowance = _boundPure(
            rawRunningAllowance, 1, MAX_FUZZ_DURATION
        );
        uint64 pausedAllowance =
            _boundPure(rawPausedAllowance, 1, MAX_FUZZ_DURATION);
        uint64 start = 10;
        Clock.State memory running = Clock.State({
            allowance: _duration(runningAllowance),
            startInstant: _instant(start)
        });
        Clock.State memory paused = Clock.State({
            allowance: _duration(pausedAllowance),
            startInstant: Time.ZERO_INSTANT
        });
        MatchClocks.TimeoutOutcome winner = oneRuns
            ? MatchClocks.TimeoutOutcome.TWO_WINS
            : MatchClocks.TimeoutOutcome.ONE_WINS;

        _assertTimeout(
            oneRuns,
            running,
            paused,
            start + runningAllowance - 1,
            MatchClocks.TimeoutOutcome.NONE,
            0
        );
        _assertTimeout(
            oneRuns, running, paused, start + runningAllowance, winner, 0
        );
        _assertTimeout(
            oneRuns,
            running,
            paused,
            start + runningAllowance + pausedAllowance - 1,
            winner,
            pausedAllowance - 1
        );
        _assertTimeout(
            oneRuns,
            running,
            paused,
            start + runningAllowance + pausedAllowance,
            MatchClocks.TimeoutOutcome.ELIMINATE_BOTH,
            0
        );
    }

    function testFuzzSealedLeafTimeoutBoundaries(
        bool commitmentOneIsShorter,
        uint64 rawShortAllowance,
        uint64 rawAllowanceGap
    ) public pure {
        uint64 shortAllowance = _boundPure(
            rawShortAllowance, 1, MAX_FUZZ_DURATION
        );
        uint64 allowanceGap = _boundPure(rawAllowanceGap, 1, MAX_FUZZ_DURATION);
        uint64 longAllowance = shortAllowance + allowanceGap;
        uint64 start = 10;
        Clock.State memory shortClock = Clock.State({
            allowance: _duration(shortAllowance), startInstant: _instant(start)
        });
        Clock.State memory longClock = Clock.State({
            allowance: _duration(longAllowance), startInstant: _instant(start)
        });
        MatchClocks.TimeoutOutcome winner = commitmentOneIsShorter
            ? MatchClocks.TimeoutOutcome.TWO_WINS
            : MatchClocks.TimeoutOutcome.ONE_WINS;
        uint64 lastWinningElapsed = (shortAllowance + longAllowance - 1) / 2;
        uint64 firstEliminationElapsed =
            (shortAllowance + longAllowance + 1) / 2;

        _assertTimeout(
            commitmentOneIsShorter,
            shortClock,
            longClock,
            start + shortAllowance - 1,
            MatchClocks.TimeoutOutcome.NONE,
            0
        );
        _assertTimeout(
            commitmentOneIsShorter,
            shortClock,
            longClock,
            start + shortAllowance,
            winner,
            0
        );
        _assertTimeout(
            commitmentOneIsShorter,
            shortClock,
            longClock,
            start + lastWinningElapsed,
            winner,
            lastWinningElapsed - shortAllowance
        );
        _assertTimeout(
            commitmentOneIsShorter,
            shortClock,
            longClock,
            start + firstEliminationElapsed,
            MatchClocks.TimeoutOutcome.ELIMINATE_BOTH,
            0
        );
        _assertTimeout(
            commitmentOneIsShorter,
            shortClock,
            longClock,
            start + longAllowance,
            MatchClocks.TimeoutOutcome.ELIMINATE_BOTH,
            0
        );
    }

    function testEqualLeafAllowancesEliminateAtTheCommonDeadline() public pure {
        Clock.State memory one =
            Clock.State({allowance: _duration(10), startInstant: _instant(5)});
        Clock.State memory two = one;

        _assertTimeout(true, one, two, 14, MatchClocks.TimeoutOutcome.NONE, 0);
        _assertTimeout(
            true, one, two, 15, MatchClocks.TimeoutOutcome.ELIMINATE_BOTH, 0
        );
    }

    function testFuzzProvenLeafWinnerFollowsTimeoutStatus(
        bool oneWon,
        uint64 rawAllowanceOne,
        uint64 rawAllowanceTwo,
        uint64 rawElapsed
    ) public {
        uint64 allowanceOne = _boundU64(rawAllowanceOne, 1, MAX_FUZZ_DURATION);
        uint64 allowanceTwo = _boundU64(rawAllowanceTwo, 1, MAX_FUZZ_DURATION);
        uint64 elapsed = _boundU64(rawElapsed, 0, allowanceOne + allowanceTwo);
        _initializeBoth(allowanceOne, allowanceTwo);
        harness.startBisectionAt(_instant(11));
        harness.startLeafRaceAt(_duration(0), _instant(11));

        uint64 remainingOne = _monus(allowanceOne, elapsed);
        uint64 remainingTwo = _monus(allowanceTwo, elapsed);
        uint64 overdueOne = _monus(elapsed, allowanceOne);
        uint64 overdueTwo = _monus(elapsed, allowanceTwo);
        (MatchClocks.TimeoutOutcome outcome, uint64 winnerCharge) =
            _modelTimeout(remainingOne, overdueOne, remainingTwo, overdueTwo);
        bool allowed = outcome == MatchClocks.TimeoutOutcome.NONE
            || (oneWon && outcome == MatchClocks.TimeoutOutcome.ONE_WINS)
            || (!oneWon && outcome == MatchClocks.TimeoutOutcome.TWO_WINS);

        if (!allowed) {
            vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        }
        harness.settleProvenLeafWinnerAt(oneWon, _instant(11 + elapsed));

        Clock.State memory one = harness.oneState();
        Clock.State memory two = harness.twoState();
        if (allowed) {
            Clock.State memory winner = oneWon ? one : two;
            Clock.State memory loser = oneWon ? two : one;
            uint64 winnerRemaining = oneWon ? remainingOne : remainingTwo;
            uint64 loserAllowance = oneWon ? allowanceTwo : allowanceOne;
            assertFalse(winner.isRunning());
            assertTrue(loser.isRunning());
            assertEq(_unwrap(winner.allowance), winnerRemaining - winnerCharge);
            assertEq(_unwrap(loser.allowance), loserAllowance);
            assertEq(Time.Instant.unwrap(loser.startInstant), 11);
        } else {
            assertTrue(one.isRunning());
            assertTrue(two.isRunning());
        }
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
        harness.initializeOne(_instant(10), _duration(allowance), _instant(10));
        harness.startOneAt(_instant(11));

        vm.expectRevert(stdError.assertionError);
        harness.startOneAt(_instant(11));

        harness.pauseOneAfterResponseAt(
            _duration(responseBudget), _instant(11 + elapsed)
        );
        Clock.State memory state = harness.oneState();
        uint64 chargedElapsed = _monus(elapsed, responseBudget);
        uint64 expectedAllowance = allowance - chargedElapsed;
        assertEq(_unwrap(state.allowance), expectedAllowance);
        assertLe(expectedAllowance, allowance);
        assertEq(
            elapsed,
            allowance - expectedAllowance + _min(elapsed, responseBudget)
        );
        assertTrue(!state.isRunning());

        vm.expectRevert(stdError.assertionError);
        harness.pauseOneAfterResponseAt(
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
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        harness.startOneAt(_instant(10));

        harness.initializeOne(_instant(10), _duration(20), _instant(10));
        vm.expectRevert(stdError.assertionError);
        harness.startOneAt(Time.ZERO_INSTANT);

        harness.startOneAt(_instant(11));
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        harness.pauseOneAfterResponseAt(_duration(100), _instant(31));

        Clock.State memory state = harness.oneState();
        assertEq(_unwrap(state.allowance), 20);
        assertEq(Time.Instant.unwrap(state.startInstant), 11);

        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        harness.pauseOneAfterResponseAt(_duration(100), _instant(32));
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

        harness.initializeOne(_instant(10), _duration(allowance), _instant(10));
        if (running) harness.startOneAt(_instant(11));
        harness.chargeOneAndPauseAt(
            _duration(charge), _instant(running ? 11 + elapsed : 100)
        );

        Clock.State memory state = harness.oneState();
        assertEq(_unwrap(state.allowance), remaining - charge);
        assertTrue(!state.isRunning());
    }

    function testChargeRejectsAZeroRemainder() public {
        harness.initializeOne(_instant(10), _duration(20), _instant(10));
        harness.startOneAt(_instant(11));

        vm.expectRevert(
            ITournament.InitializedClockCannotHaveZeroAllowance.selector
        );
        harness.chargeOneAndPauseAt(_duration(15), _instant(16));
    }

    function testFuzzPausedCarryoverPreservesTheChargedRemainder(uint64 rawCharge)
        public
    {
        uint64 charge = _boundU64(rawCharge, 0, 79);
        harness.initializeOne(_instant(10), _duration(100), _instant(10));
        harness.initializeTwo(_instant(10), _duration(80), _instant(10));

        harness.deductTwoAndReplaceOne(_duration(charge));
        Clock.State memory state = harness.oneState();
        assertEq(_unwrap(state.allowance), 80 - charge);
        assertTrue(!state.isRunning());
    }

    function testCarryoverRejectsAZeroRemainder() public {
        harness.initializeOne(_instant(10), _duration(100), _instant(10));
        harness.initializeTwo(_instant(10), _duration(80), _instant(10));

        vm.expectRevert(
            ITournament.InitializedClockCannotHaveZeroAllowance.selector
        );
        harness.deductTwoAndReplaceOne(_duration(80));
    }

    function testFuzzBisectionAndLeafRacePreservePhaseAndTime(
        bool switchBeforeLeaf,
        uint64 rawOne,
        uint64 rawTwo,
        uint64 rawElapsedOne,
        uint64 rawElapsedTwo,
        uint64 rawResponseBudget
    ) public {
        uint64 allowanceOne = _boundU64(rawOne, 1, MAX_FUZZ_DURATION);
        uint64 allowanceTwo = _boundU64(rawTwo, 1, MAX_FUZZ_DURATION);
        uint64 elapsedOne = _boundU64(rawElapsedOne, 0, allowanceOne - 1);
        uint64 elapsedTwo = _boundU64(rawElapsedTwo, 0, allowanceTwo - 1);
        uint64 responseBudget =
            _boundU64(rawResponseBudget, 0, MAX_FUZZ_DURATION);
        _initializeBoth(allowanceOne, allowanceTwo);

        harness.startBisectionAt(_instant(11));
        uint64 leafStart = 11 + elapsedOne;
        uint64 expectedOne = allowanceOne - _monus(elapsedOne, responseBudget);
        uint64 expectedTwo = allowanceTwo;
        if (switchBeforeLeaf) {
            harness.switchTurnAt(_duration(responseBudget), _instant(leafStart));
            leafStart += elapsedTwo;
            expectedTwo -= _monus(elapsedTwo, responseBudget);
        }
        harness.startLeafRaceAt(_duration(responseBudget), _instant(leafStart));

        Clock.State memory one = harness.oneState();
        Clock.State memory two = harness.twoState();
        assertEq(_unwrap(one.allowance), expectedOne);
        assertEq(_unwrap(two.allowance), expectedTwo);
        assertEq(Time.Instant.unwrap(one.startInstant), leafStart);
        assertEq(Time.Instant.unwrap(two.startInstant), leafStart);
    }

    function testFuzzSwitchTurnSupportsBothRunningSides(
        uint64 rawOne,
        uint64 rawTwo,
        uint64 rawElapsedOne,
        uint64 rawElapsedTwo,
        uint64 rawResponseBudget
    ) public {
        uint64 allowanceOne = _boundU64(rawOne, 1, MAX_FUZZ_DURATION);
        uint64 allowanceTwo = _boundU64(rawTwo, 1, MAX_FUZZ_DURATION);
        uint64 elapsedOne = _boundU64(rawElapsedOne, 0, allowanceOne - 1);
        uint64 elapsedTwo = _boundU64(rawElapsedTwo, 0, allowanceTwo - 1);
        uint64 responseBudget =
            _boundU64(rawResponseBudget, 0, MAX_FUZZ_DURATION);
        _initializeBoth(allowanceOne, allowanceTwo);

        harness.startBisectionAt(_instant(11));
        harness.switchTurnAt(
            _duration(responseBudget), _instant(11 + elapsedOne)
        );
        uint64 secondSwitch = 11 + elapsedOne + elapsedTwo;
        harness.switchTurnAt(_duration(responseBudget), _instant(secondSwitch));

        Clock.State memory one = harness.oneState();
        Clock.State memory two = harness.twoState();
        uint64 chargedOne = _monus(elapsedOne, responseBudget);
        uint64 chargedTwo = _monus(elapsedTwo, responseBudget);
        assertEq(_unwrap(one.allowance), allowanceOne - chargedOne);
        assertEq(_unwrap(two.allowance), allowanceTwo - chargedTwo);
        assertEq(
            elapsedOne + elapsedTwo,
            chargedOne + chargedTwo + _min(elapsedOne, responseBudget)
                + _min(elapsedTwo, responseBudget)
        );
        uint256 potentialBefore =
            uint256(allowanceOne) + allowanceTwo + 2 * uint256(responseBudget);
        uint256 potentialAfter =
            uint256(_unwrap(one.allowance)) + _unwrap(two.allowance);
        assertEq(
            potentialBefore - potentialAfter,
            uint256(_max(elapsedOne, responseBudget))
                + _max(elapsedTwo, responseBudget)
        );
        assertEq(Time.Instant.unwrap(one.startInstant), secondSwitch);
        assertTrue(!two.isRunning());
    }

    function testFuzzInnerSealSnapshotsBothAndReturnsMaximum(
        bool switchBeforeSeal,
        uint64 rawOne,
        uint64 rawTwo,
        uint64 rawElapsedOne,
        uint64 rawElapsedTwo,
        uint64 rawResponseBudget
    ) public {
        uint64 allowanceOne = _boundU64(rawOne, 1, MAX_FUZZ_DURATION);
        uint64 allowanceTwo = _boundU64(rawTwo, 1, MAX_FUZZ_DURATION);
        uint64 elapsedOne = _boundU64(rawElapsedOne, 0, allowanceOne - 1);
        uint64 elapsedTwo = _boundU64(rawElapsedTwo, 0, allowanceTwo - 1);
        uint64 responseBudget =
            _boundU64(rawResponseBudget, 0, MAX_FUZZ_DURATION);
        _initializeBoth(allowanceOne, allowanceTwo);

        harness.startBisectionAt(_instant(11));
        uint64 sealInstant = 11 + elapsedOne;
        uint64 expectedOne = allowanceOne - _monus(elapsedOne, responseBudget);
        uint64 expectedTwo = allowanceTwo;
        if (switchBeforeSeal) {
            harness.switchTurnAt(
                _duration(responseBudget), _instant(sealInstant)
            );
            sealInstant += elapsedTwo;
            expectedTwo -= _monus(elapsedTwo, responseBudget);
        }
        Time.Duration maximum = harness.pauseForInnerAt(
            _duration(responseBudget), _instant(sealInstant)
        );

        Clock.State memory one = harness.oneState();
        Clock.State memory two = harness.twoState();
        assertEq(_unwrap(one.allowance), expectedOne);
        assertEq(_unwrap(two.allowance), expectedTwo);
        assertTrue(!one.isRunning());
        assertTrue(!two.isRunning());
        assertEq(_unwrap(maximum), _max(expectedOne, expectedTwo));
    }

    function testPairTransitionsRejectIllegalPhases() public {
        _initializeBoth(20, 30);

        vm.expectRevert(stdError.assertionError);
        harness.settleProvenLeafWinnerAt(true, _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.switchTurnAt(_duration(0), _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.startLeafRaceAt(_duration(0), _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.pauseForInnerAt(_duration(0), _instant(11));

        harness.startBisectionAt(_instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.settleProvenLeafWinnerAt(true, _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.startBisectionAt(_instant(12));

        harness.startLeafRaceAt(_duration(0), _instant(12));
        vm.expectRevert(stdError.assertionError);
        harness.switchTurnAt(_duration(0), _instant(13));

        ClockHarness unequalStarts = new ClockHarness();
        unequalStarts.initializeOne(_instant(10), _duration(20), _instant(10));
        unequalStarts.initializeTwo(_instant(10), _duration(30), _instant(10));
        unequalStarts.startOneAt(_instant(11));
        unequalStarts.startTwoAt(_instant(12));
        vm.expectRevert(stdError.assertionError);
        unequalStarts.settleProvenLeafWinnerAt(true, _instant(12));
    }

    function _initializeBoth(uint64 allowanceOne, uint64 allowanceTwo) private {
        harness.initializeOne(
            _instant(10), _duration(allowanceOne), _instant(10)
        );
        harness.initializeTwo(
            _instant(10), _duration(allowanceTwo), _instant(10)
        );
    }

    function _clockState(
        uint64 allowance,
        bool running,
        uint64 elapsed,
        uint64 current
    ) private pure returns (Clock.State memory) {
        return Clock.State({
            allowance: _duration(allowance),
            startInstant: running
                ? _instant(current - elapsed)
                : Time.ZERO_INSTANT
        });
    }

    function _modelTimeout(
        uint64 remainingOne,
        uint64 overdueOne,
        uint64 remainingTwo,
        uint64 overdueTwo
    )
        private
        pure
        returns (MatchClocks.TimeoutOutcome outcome, uint64 winnerCharge)
    {
        if (remainingOne == 0 && remainingTwo > overdueOne) {
            return (MatchClocks.TimeoutOutcome.TWO_WINS, overdueOne);
        }
        if (remainingTwo == 0 && remainingOne > overdueTwo) {
            return (MatchClocks.TimeoutOutcome.ONE_WINS, overdueTwo);
        }
        if (remainingOne == 0 || remainingTwo == 0) {
            return (MatchClocks.TimeoutOutcome.ELIMINATE_BOTH, 0);
        }
        return (MatchClocks.TimeoutOutcome.NONE, 0);
    }

    function _swapTimeoutOutcome(MatchClocks.TimeoutOutcome outcome)
        private
        pure
        returns (MatchClocks.TimeoutOutcome)
    {
        if (outcome == MatchClocks.TimeoutOutcome.ONE_WINS) {
            return MatchClocks.TimeoutOutcome.TWO_WINS;
        }
        if (outcome == MatchClocks.TimeoutOutcome.TWO_WINS) {
            return MatchClocks.TimeoutOutcome.ONE_WINS;
        }
        return outcome;
    }

    function _assertTimeout(
        bool firstArgumentIsOne,
        Clock.State memory first,
        Clock.State memory second,
        uint64 current,
        MatchClocks.TimeoutOutcome expectedOutcome,
        uint64 expectedCharge
    ) private pure {
        MatchClocks.TimeoutStatus memory status = firstArgumentIsOne
            ? MatchClocks.classifyTimeoutAt(first, second, _instant(current))
            : MatchClocks.classifyTimeoutAt(second, first, _instant(current));
        assertEq(uint8(status.outcome), uint8(expectedOutcome));
        assertEq(_unwrap(status.winnerCharge), expectedCharge);
    }

    function _assertResponseCase(
        uint64 allowance,
        uint64 elapsed,
        uint64 responseBudget,
        uint64 expectedAllowance
    ) private {
        ClockHarness subject = new ClockHarness();
        subject.initializeOne(_instant(10), _duration(allowance), _instant(10));
        subject.startOneAt(_instant(11));
        subject.pauseOneAfterResponseAt(
            _duration(responseBudget), _instant(11 + elapsed)
        );

        Clock.State memory state = subject.oneState();
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

    function _max(uint64 one, uint64 two) private pure returns (uint64) {
        return one > two ? one : two;
    }

    function _monus(uint64 one, uint64 two) private pure returns (uint64) {
        return one < two ? 0 : one - two;
    }
}
