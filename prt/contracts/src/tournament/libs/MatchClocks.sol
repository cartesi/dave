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

        if (remainingOne.isZero()) {
            if (remainingTwo.isZero()) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ELIMINATE_BOTH,
                    deferredCharge: Time.ZERO_DURATION
                });
            }

            Time.Duration deferredCharge = _deferredCharge(two, one, current);
            if (remainingTwo.gt(deferredCharge)) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.TWO_WINS,
                    deferredCharge: deferredCharge
                });
            } else {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ELIMINATE_BOTH,
                    deferredCharge: Time.ZERO_DURATION
                });
            }
        } else if (remainingTwo.isZero()) {
            Time.Duration deferredCharge = _deferredCharge(one, two, current);
            if (remainingOne.gt(deferredCharge)) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ONE_WINS,
                    deferredCharge: deferredCharge
                });
            } else {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ELIMINATE_BOTH,
                    deferredCharge: Time.ZERO_DURATION
                });
            }
        } else {
            return TimeoutStatus({
                outcome: TimeoutOutcome.NONE, deferredCharge: Time.ZERO_DURATION
            });
        }
    }

    /// @notice Start bisection with clock one running and clock two paused.
    function startBisectionAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Instant current
    ) internal {
        one.requirePaused();
        two.requirePaused();
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
    /// @dev Every legal exit from active bisection discounts the responder
    /// exactly once; the public verbs differ only in which clocks run next.
    /// @return idle The other, still-paused clock.
    function _pauseResponderAt(
        Clock.State storage one,
        Clock.State storage two,
        Time.Duration responseBudget,
        Time.Instant current
    ) private returns (Clock.State storage idle) {
        _requireBisection(one, two);
        if (one.isRunning()) {
            one.pauseAfterResponseAt(responseBudget, current);
            return two;
        } else {
            two.pauseAfterResponseAt(responseBudget, current);
            return one;
        }
    }

    function _requireBisection(Clock.State memory one, Clock.State memory two)
        private
        pure
    {
        one.requireInitialized();
        two.requireInitialized();
        assert(one.isRunning() != two.isRunning());
    }

    /// @dev Charge only elapsed time not already reflected in the winner's
    /// live remainder. During bisection the winner is paused, so the expired
    /// responder's overdue interval is deferred to it. During a leaf race the
    /// winner is already running, so transferring that interval would charge
    /// the same censorship time twice.
    function _deferredCharge(
        Clock.State memory winner,
        Clock.State memory loser,
        Time.Instant current
    ) private pure returns (Time.Duration) {
        if (winner.isRunning()) {
            return Time.ZERO_DURATION;
        } else {
            return loser.overdueByAt(current);
        }
    }
}
