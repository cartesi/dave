// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clock} from "./Clock.sol";
import {Time} from "./Time.sol";

/// @notice Phase transitions for the two clocks in one match.
/// @dev Active bisection has exactly one running clock. A sealed leaf has two
/// running clocks, while a sealed inner match has two paused clocks. Helpers
/// assert their source phase instead of silently repairing an invalid one.
library MatchClocks {
    using Clock for Clock.State;
    using Time for Time.Duration;

    enum TimeoutOutcome {
        NONE,
        ONE_WINS,
        TWO_WINS,
        ELIMINATE_BOTH
    }

    struct TimeoutStatus {
        TimeoutOutcome outcome;
        Time.Duration deferredCharge;
    }

    /// @notice Classify timeout resolution for a match at one instant.
    /// @dev Assumes both initialized clocks belong to a legal match phase; it
    /// classifies but does not validate that phase. A running winner has already
    /// paid for elapsed time through its live remainder. A paused winner is
    /// charged the expired side's overdue duration, which represents the
    /// deferred interval in which timeout cleanup could be censored. A winner
    /// must retain positive time after any deferred charge; equality eliminates
    /// both. Leaf transitions establish the common start instant expected when
    /// both clocks are running.
    function classifyTimeoutAt(
        Clock.State memory one,
        Clock.State memory two,
        Time.Instant current
    ) internal pure returns (TimeoutStatus memory) {
        Time.Duration remainingOne = one.remainingAt(current);
        Time.Duration remainingTwo = two.remainingAt(current);
        bool oneExpired = remainingOne.isZero();
        bool twoExpired = remainingTwo.isZero();

        if (!oneExpired && !twoExpired) {
            return TimeoutStatus({
                outcome: TimeoutOutcome.NONE, deferredCharge: Time.ZERO_DURATION
            });
        } else if (oneExpired && twoExpired) {
            return TimeoutStatus({
                outcome: TimeoutOutcome.ELIMINATE_BOTH,
                deferredCharge: Time.ZERO_DURATION
            });
        } else if (oneExpired) {
            return _classifySoleSurvivorAt(
                TimeoutOutcome.TWO_WINS, two, remainingTwo, one, current
            );
        } else {
            return _classifySoleSurvivorAt(
                TimeoutOutcome.ONE_WINS, one, remainingOne, two, current
            );
        }
    }

    /// @notice Start bisection with clock one running and clock two paused.
    function startBisectionAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Instant current
    ) internal {
        one.assertPaused();
        two.assertPaused();
        one.startAt(current);
    }

    /// @notice Discount a valid response and switch the running side.
    function switchTurnAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Duration responseBudget,
        Time.Instant current
    ) internal {
        Clock.State storage idle = _pauseResponderAt(
            one, two, responseBudget, current
        );
        idle.startAt(current);
    }

    /// @notice Discount the final response and enter a two-clock leaf race.
    function startLeafRaceAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Duration responseBudget,
        Time.Instant current
    ) internal {
        _pauseResponderAt(one, two, responseBudget, current);
        one.startAt(current);
        two.startAt(current);
    }

    /// @notice Discount the final response and pause before inner delegation.
    /// @return The larger remainder, used as the child tournament's shared pair
    /// envelope rather than as side-specific carryover.
    function pauseForInnerAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Duration responseBudget,
        Time.Instant current
    ) internal returns (Time.Duration) {
        _pauseResponderAt(one, two, responseBudget, current);
        return one.pausedAllowance().max(two.pausedAllowance());
    }

    /// @notice Pause the running responder, discounting its response.
    /// @dev Every successful bisection response discounts the responder exactly
    /// once; advancing and sealing differ only in which clocks run next.
    /// @return idle The other, still-paused clock.
    function _pauseResponderAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Duration responseBudget,
        Time.Instant current
    ) private returns (Clock.State storage idle) {
        _assertBisection(one, two);
        if (one.isRunning()) {
            one.pauseAfterResponseAt(responseBudget, current);
            return two;
        } else {
            two.pauseAfterResponseAt(responseBudget, current);
            return one;
        }
    }

    function _assertBisection(Clock.State memory one, Clock.State memory two)
        private
        pure
    {
        one.assertInitialized();
        two.assertInitialized();
        assert(one.isRunning() != two.isRunning());
    }

    /// @dev A paused bisection survivor has not paid for the expired responder's
    /// overdue interval, while a running leaf-race survivor has already paid for
    /// that interval through its live remainder.
    function _classifySoleSurvivorAt(
        TimeoutOutcome survivorOutcome,
        Clock.State memory survivor,
        Time.Duration survivorRemaining,
        Clock.State memory expiredClock,
        Time.Instant current
    ) private pure returns (TimeoutStatus memory) {
        Time.Duration deferredCharge = survivor.isRunning()
            ? Time.ZERO_DURATION
            : expiredClock.overdueByAt(current);

        if (survivorRemaining.gt(deferredCharge)) {
            return TimeoutStatus({
                outcome: survivorOutcome, deferredCharge: deferredCharge
            });
        } else {
            return TimeoutStatus({
                outcome: TimeoutOutcome.ELIMINATE_BOTH,
                deferredCharge: Time.ZERO_DURATION
            });
        }
    }
}
