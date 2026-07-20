// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "prt-contracts/ITournament.sol";

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
        Time.Duration winnerCharge;
    }

    /// @notice Classify timeout resolution for a match at one instant.
    /// @dev Assumes both initialized clocks belong to a legal match phase; it
    /// classifies but does not validate that phase. A winner must retain
    /// strictly positive time after the expired side's overdue duration is
    /// charged. Equality eliminates both sides.
    function classifyTimeoutAt(
        Clock.State memory one,
        Clock.State memory two,
        Time.Instant current
    ) internal pure returns (TimeoutStatus memory) {
        Time.Duration remainingOne = one.remainingAt(current);
        Time.Duration remainingTwo = two.remainingAt(current);

        if (remainingOne.isZero()) {
            Time.Duration overdueOne = one.overdueByAt(current);
            if (remainingTwo.gt(overdueOne)) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.TWO_WINS, winnerCharge: overdueOne
                });
            }
            return TimeoutStatus({
                outcome: TimeoutOutcome.ELIMINATE_BOTH,
                winnerCharge: Time.ZERO_DURATION
            });
        }

        if (remainingTwo.isZero()) {
            Time.Duration overdueTwo = two.overdueByAt(current);
            if (remainingOne.gt(overdueTwo)) {
                return TimeoutStatus({
                    outcome: TimeoutOutcome.ONE_WINS, winnerCharge: overdueTwo
                });
            }
            return TimeoutStatus({
                outcome: TimeoutOutcome.ELIMINATE_BOTH,
                winnerCharge: Time.ZERO_DURATION
            });
        }

        return TimeoutStatus({
            outcome: TimeoutOutcome.NONE, winnerCharge: Time.ZERO_DURATION
        });
    }

    /// @notice Settle the clock of an objectively proven leaf winner.
    /// @dev Proof resolution follows the same timeout status as permissionless
    /// cleanup. With no timeout, the winner is charged zero. With one timeout
    /// winner, the proof must select that side and pays the classified charge.
    /// Every other outcome rejects the proof as too late. Both clocks must be
    /// running from the same leaf-race start instant.
    function settleProvenLeafWinnerAt(
        Clock.State storage one,
        Clock.State storage two,
        ITournament.WinnerCommitment provenWinner,
        Time.Instant current
    ) internal {
        _requireLeafRace(one, two);
        assert(provenWinner != ITournament.WinnerCommitment.NONE);

        TimeoutStatus memory timeout = classifyTimeoutAt(one, two, current);
        TimeoutOutcome requiredOutcome = provenWinner
            == ITournament.WinnerCommitment.ONE
            ? TimeoutOutcome.ONE_WINS
            : TimeoutOutcome.TWO_WINS;
        if (
            timeout.outcome != TimeoutOutcome.NONE
                && timeout.outcome != requiredOutcome
        ) {
            revert ITournament.CannotAdvanceTimedOutClock();
        }

        if (provenWinner == ITournament.WinnerCommitment.ONE) {
            one.chargeAndPauseAt(timeout.winnerCharge, current);
        } else {
            two.chargeAndPauseAt(timeout.winnerCharge, current);
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
    /// @return The larger of the two snapshotted remainders.
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
        }
        two.pauseAfterResponseAt(responseBudget, current);
        return one;
    }

    function _requireBisection(Clock.State memory one, Clock.State memory two)
        private
        pure
    {
        one.requireInitialized();
        two.requireInitialized();
        assert(one.isRunning() != two.isRunning());
    }

    function _requireLeafRace(Clock.State memory one, Clock.State memory two)
        private
        pure
    {
        one.requireRunning();
        two.requireRunning();
        assert(
            Time.Instant.unwrap(one.startInstant)
                == Time.Instant.unwrap(two.startInstant)
        );
    }
}
