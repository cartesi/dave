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
    using Time for Time.Instant;

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

    /// @notice Return the first inclusive instant at which the current match
    /// schedule classifies as `ELIMINATE_BOTH` if no transition intervenes.
    /// @dev Supports the two timeout-bearing clock shapes: exactly one running
    /// clock during bisection, or two clocks running from the same instant in a
    /// sealed leaf race. A sealed inner match has no local timeout schedule.
    function eliminableAt(Clock.State memory one, Clock.State memory two)
        internal
        pure
        returns (Time.Instant)
    {
        one.assertInitialized();
        two.assertInitialized();

        bool oneRunning = one.isRunning();
        bool twoRunning = two.isRunning();
        if (oneRunning && twoRunning) {
            assert(
                Time.Instant.unwrap(one.startInstant)
                    == Time.Instant.unwrap(two.startInstant)
            );
            return one.startInstant.add(one.allowance.max(two.allowance));
        }

        assert(oneRunning != twoRunning);
        if (oneRunning) {
            return one.startInstant.add(one.allowance).add(two.allowance);
        } else {
            return two.startInstant.add(two.allowance).add(one.allowance);
        }
    }

    /// @notice Classify timeout resolution for a match at one instant.
    /// @dev Assumes both initialized clocks belong to a legal match phase; it
    /// classifies but does not validate that phase. A running winner has already
    /// paid for elapsed time through its live remainder. A paused winner is
    /// charged the expired side's overdue duration, which represents the
    /// deferred interval in which timeout cleanup could be censored. A winner
    /// must retain positive time after any deferred charge; equality eliminates
    /// both. Survival is decided on this full cost; `Clock.pauseWinnerAt` then
    /// forgives at most one response budget of it. Leaf transitions establish the
    /// common start instant expected when both clocks are running.
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

    /// @notice The allowance a child winner returns to its sealed parent pair
    /// with, `min(carried + refill, max(r1, r2))`: never above the pair's
    /// envelope, for any input.
    /// @dev The refill restores what the delegation cost the winner (building
    /// the child commitment, joining, and propagating back), so repeated
    /// delegations do not drain a correct commitment's clock. The cap is the
    /// child's own allowance, so no clock mass is created. Both parent clocks
    /// stay paused at their post-seal remainders while the child runs, which
    /// makes the envelope exact here. A carried remainder above the envelope
    /// is unreachable: the child's allowance is the envelope, and no clock in
    /// the child exceeds its allowance, refills from deeper returns included.
    /// It is clamped rather than reverted: a revert would block the winner's
    /// propagation until the child became eliminable, and elimination removes
    /// both sides, the correct one included.
    function childReturnAllowance(
        Clock.State storage one,
        Clock.State storage two,
        Time.Duration carried,
        Time.Duration refill
    ) internal view returns (Time.Duration) {
        Time.Duration envelope = one.pausedAllowance()
            .max(two.pausedAllowance());
        Time.Duration kept = carried.min(envelope);
        return kept.add(refill.min(envelope.saturatingSub(kept)));
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
        assertBisection(one, two);
        if (one.isRunning()) {
            one.pauseAfterResponseAt(responseBudget, current);
            return two;
        } else {
            two.pauseAfterResponseAt(responseBudget, current);
            return one;
        }
    }

    /// @notice Assert the active-bisection shape: exactly one running clock.
    function assertBisection(Clock.State memory one, Clock.State memory two)
        internal
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
