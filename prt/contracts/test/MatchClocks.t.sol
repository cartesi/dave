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

contract MatchClocksHarness {
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

    function startOneAt(Time.Instant current) external {
        one.startAt(current);
    }

    function startTwoAt(Time.Instant current) external {
        two.startAt(current);
    }

    function startBisectionAt(Time.Instant current) external {
        MatchClocks.startBisectionAt(one, two, current);
    }

    function switchTurnAt(Time.Duration responseBudget, Time.Instant current)
        external
    {
        MatchClocks.switchTurnAt(one, two, responseBudget, current);
    }

    function startLeafRace(Time.Duration responseBudget, Time.Instant current)
        external
    {
        MatchClocks.startLeafRaceAt(one, two, responseBudget, current);
    }

    function pauseForInner(Time.Duration responseBudget, Time.Instant current)
        external
        returns (Time.Duration)
    {
        return MatchClocks.pauseForInnerAt(one, two, responseBudget, current);
    }
}

contract MatchClocksTest is Test {
    using Clock for Clock.State;
    using Time for Time.Duration;
    using Time for Time.Instant;

    uint64 constant MAX_FUZZ_DURATION = 1_000_000_000_000;

    MatchClocksHarness harness;

    function setUp() public {
        harness = new MatchClocksHarness();
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

        uint64 remainingOne = oneRunning
            ? _saturatingSub(allowanceOne, elapsedOne)
            : allowanceOne;
        uint64 remainingTwo = twoRunning
            ? _saturatingSub(allowanceTwo, elapsedTwo)
            : allowanceTwo;
        uint64 overdueOne =
            oneRunning ? _saturatingSub(elapsedOne, allowanceOne) : 0;
        uint64 overdueTwo =
            twoRunning ? _saturatingSub(elapsedTwo, allowanceTwo) : 0;
        (
            MatchClocks.TimeoutOutcome expectedOutcome,
            uint64 expectedDeferredCharge
        ) = _modelTimeout(
            remainingOne,
            overdueOne,
            oneRunning,
            remainingTwo,
            overdueTwo,
            twoRunning
        );

        MatchClocks.TimeoutStatus memory status =
            MatchClocks.classifyTimeoutAt(one, two, _instant(current));
        assertEq(uint8(status.outcome), uint8(expectedOutcome));
        assertEq(_unwrap(status.deferredCharge), expectedDeferredCharge);

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
        assertEq(_unwrap(swapped.deferredCharge), expectedDeferredCharge);
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
            start + longAllowance - 1,
            winner,
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
        uint64 expectedOne =
            allowanceOne - _saturatingSub(elapsedOne, responseBudget);
        uint64 expectedTwo = allowanceTwo;
        if (switchBeforeLeaf) {
            harness.switchTurnAt(_duration(responseBudget), _instant(leafStart));
            leafStart += elapsedTwo;
            expectedTwo -= _saturatingSub(elapsedTwo, responseBudget);
        }
        harness.startLeafRace(_duration(responseBudget), _instant(leafStart));

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
        uint64 chargedOne = _saturatingSub(elapsedOne, responseBudget);
        uint64 chargedTwo = _saturatingSub(elapsedTwo, responseBudget);
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
        assertFalse(two.isRunning());
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
        uint64 expectedOne =
            allowanceOne - _saturatingSub(elapsedOne, responseBudget);
        uint64 expectedTwo = allowanceTwo;
        if (switchBeforeSeal) {
            harness.switchTurnAt(
                _duration(responseBudget), _instant(sealInstant)
            );
            sealInstant += elapsedTwo;
            expectedTwo -= _saturatingSub(elapsedTwo, responseBudget);
        }
        Time.Duration maximum = harness.pauseForInner(
            _duration(responseBudget), _instant(sealInstant)
        );

        Clock.State memory one = harness.oneState();
        Clock.State memory two = harness.twoState();
        assertEq(_unwrap(one.allowance), expectedOne);
        assertEq(_unwrap(two.allowance), expectedTwo);
        assertFalse(one.isRunning());
        assertFalse(two.isRunning());
        assertEq(_unwrap(maximum), _max(expectedOne, expectedTwo));
    }

    function testStartBisectionRequiresBothClocksInitialized() public {
        MatchClocksHarness oneMissing = new MatchClocksHarness();
        oneMissing.initializeTwo(_instant(10), _duration(30), _instant(10));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        oneMissing.startBisectionAt(_instant(11));

        harness.initializeOne(_instant(10), _duration(20), _instant(10));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        harness.startBisectionAt(_instant(11));
    }

    function testStartBisectionRejectsEveryRunningShape() public {
        MatchClocksHarness oneRunning = _newInitializedPair(20, 30);
        oneRunning.startOneAt(_instant(11));
        vm.expectRevert(stdError.assertionError);
        oneRunning.startBisectionAt(_instant(12));

        MatchClocksHarness twoRunning = _newInitializedPair(20, 30);
        twoRunning.startTwoAt(_instant(11));
        vm.expectRevert(stdError.assertionError);
        twoRunning.startBisectionAt(_instant(12));

        MatchClocksHarness bothRunning = _newInitializedPair(20, 30);
        bothRunning.startOneAt(_instant(11));
        bothRunning.startTwoAt(_instant(11));
        vm.expectRevert(stdError.assertionError);
        bothRunning.startBisectionAt(_instant(12));
    }

    function testBisectionTransitionsRequireBothClocksInitialized() public {
        MatchClocksHarness oneMissing = new MatchClocksHarness();
        oneMissing.initializeTwo(_instant(10), _duration(30), _instant(10));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        oneMissing.switchTurnAt(_duration(0), _instant(11));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        oneMissing.startLeafRace(_duration(0), _instant(11));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        oneMissing.pauseForInner(_duration(0), _instant(11));

        harness.initializeOne(_instant(10), _duration(20), _instant(10));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        harness.switchTurnAt(_duration(0), _instant(11));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        harness.startLeafRace(_duration(0), _instant(11));
        vm.expectRevert(ITournament.ClockNotInitialized.selector);
        harness.pauseForInner(_duration(0), _instant(11));
    }

    function testBisectionTransitionsRejectBothPaused() public {
        _initializeBoth(20, 30);

        vm.expectRevert(stdError.assertionError);
        harness.switchTurnAt(_duration(0), _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.startLeafRace(_duration(0), _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.pauseForInner(_duration(0), _instant(11));
    }

    function testBisectionTransitionsRejectTwoRunningClocks() public {
        _initializeBoth(20, 30);
        harness.startOneAt(_instant(11));
        harness.startTwoAt(_instant(11));

        vm.expectRevert(stdError.assertionError);
        harness.switchTurnAt(_duration(0), _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.startLeafRace(_duration(0), _instant(11));
        vm.expectRevert(stdError.assertionError);
        harness.pauseForInner(_duration(0), _instant(11));
    }

    function _initializeBoth(uint64 allowanceOne, uint64 allowanceTwo) private {
        harness.initializeOne(
            _instant(10), _duration(allowanceOne), _instant(10)
        );
        harness.initializeTwo(
            _instant(10), _duration(allowanceTwo), _instant(10)
        );
    }

    function _newInitializedPair(uint64 allowanceOne, uint64 allowanceTwo)
        private
        returns (MatchClocksHarness pair)
    {
        pair = new MatchClocksHarness();
        pair.initializeOne(_instant(10), _duration(allowanceOne), _instant(10));
        pair.initializeTwo(_instant(10), _duration(allowanceTwo), _instant(10));
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
        bool oneRunning,
        uint64 remainingTwo,
        uint64 overdueTwo,
        bool twoRunning
    )
        private
        pure
        returns (MatchClocks.TimeoutOutcome outcome, uint64 deferredCharge)
    {
        if (remainingOne == 0) {
            if (remainingTwo == 0) {
                return (MatchClocks.TimeoutOutcome.ELIMINATE_BOTH, 0);
            }

            deferredCharge = twoRunning ? 0 : overdueOne;
            if (remainingTwo > deferredCharge) {
                return (MatchClocks.TimeoutOutcome.TWO_WINS, deferredCharge);
            } else {
                return (MatchClocks.TimeoutOutcome.ELIMINATE_BOTH, 0);
            }
        } else if (remainingTwo == 0) {
            deferredCharge = oneRunning ? 0 : overdueTwo;
            if (remainingOne > deferredCharge) {
                return (MatchClocks.TimeoutOutcome.ONE_WINS, deferredCharge);
            } else {
                return (MatchClocks.TimeoutOutcome.ELIMINATE_BOTH, 0);
            }
        } else {
            return (MatchClocks.TimeoutOutcome.NONE, 0);
        }
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
        assertEq(_unwrap(status.deferredCharge), expectedCharge);
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

    function _saturatingSub(uint64 one, uint64 two)
        private
        pure
        returns (uint64)
    {
        return one < two ? 0 : one - two;
    }
}
