// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/libs/Time.sol";
import "prt-contracts/arbitration-config/CanonicalConstants.sol";

library Clock {
    using Time for Time.Instant;
    using Time for Time.Duration;

    using Clock for State;

    struct State {
        Time.Duration allowance; // Add documentation (that zero means clock was not initialized yet)?
        Time.Instant startInstant; // the block number when the clock started ticking, zero means clock is paused
    }

    //
    // View/Pure methods
    //
    function notInitialized(State memory state) internal pure returns (bool) {
        return state.allowance.isZero();
    }

    function requireInitialized(State memory state) internal pure {
        require(!state.notInitialized(), "clock is not initialized");
    }

    function requireNotInitialized(State memory state) internal pure {
        require(state.notInitialized(), "clock is initialized");
    }

    function hasTimeLeft(State memory state) internal view returns (bool) {
        if (state.startInstant.isZero()) {
            // a paused clock is always considered having time left
            return true;
        } else {
            // otherwise the allowance must be greater than the timespan from current time to start instant
            return state.allowance.gt(
                // This assumes that Time.currentTime() (the current block number) >= state.startInstant,
                // because, otherwise, this expressions raises an arithmetic underflow error.
                // This seems like a reasonable assumption, given that it is either zero,
                // the number of a past block, or the number of the current block.
                // And, in this file, this seems to be the case.
                // On the factories, this is initialized with the current block number as well.
                // However, a safer calculation than subtraction is addition.
                // So, instead, you could check if state.startInstant.add(state.allowance).gt(Time.currentTime())
                // You could even define an endInstant function that calculates the first part,
                // and then you simply check whether the current time is past this end instant or not.
                Time.timeSpan(Time.currentTime(), state.startInstant)
            );
        }
    }

    // Rename as maxAllowance?
    /// @return max allowance of two paused clocks
    function max(State memory pausedState1, State memory pausedState2)
        internal
        pure
        returns (Time.Duration)
    {
        // Define max for Time.Duration in Time?
        if (pausedState1.allowance.gt(pausedState2.allowance)) {
            return pausedState1.allowance;
        } else {
            return pausedState2.allowance;
        }
    }

    /// @return duration of time has elapsed since the clock timeout
    function timeSinceTimeout(State memory state)
        internal
        view
        returns (Time.Duration)
    {
        // Rewrite this with require?
        if (state.startInstant.isZero()) {
            revert("a paused clock can't timeout");
        }

        // This expression also assumes that Time.currentTime() >= state.startInstant
        // although it doesn't have to, given that it does a monus afterwards anyway.
        // This could be rewritten as Time.currentTime.monus(state.startInstant.add(state.allowance))
        // or, if there is an auxiliary endInstant function, Time.currentTime.monus(endInstant)
        return Time.timeSpan(Time.currentTime(), state.startInstant).monus(
            state.allowance
        );
    }

    function timeLeft(State memory state)
        internal
        view
        returns (Time.Duration)
    {
        if (state.startInstant.isZero()) {
            return state.allowance;
        } else {
            // Again, this could be rewritten as
            // state.startInstant.add(state.allowance).monus(Time.currentTime()) or
            // endInstant.monus(Time.currentTime())
            return state.allowance.monus(
                Time.timeSpan(Time.currentTime(), state.startInstant)
            );
        }
    }

    //
    // Storage methods
    //

    // Rename as reinitialize?
    /// @notice re-initialize a clock with new state
    function reInitialized(State storage state, State memory newState)
        internal
    {
        Time.Duration _allowance = timeLeft(newState);
        _setNewPaused(state, _allowance);
    }

    function setNewPaused(
        State storage state,
        Time.Instant checkinInstant,
        Time.Duration initialAllowance
    ) internal {
        // This could be rewritten as
        // checkinInstant.add(initialAllowance).monus(Time.currentTime())
        Time.Duration _allowance =
            initialAllowance.monus(Time.currentTime().timeSpan(checkinInstant));
        _setNewPaused(state, _allowance);
    }

    /// @notice Resume the clock from pause state, or pause a clock and update the allowance
    function advanceClock(State storage state) internal {
        Time.Duration _timeLeft = timeLeft(state);

        if (_timeLeft.isZero()) {
            revert("can't advance clock with no time left");
        }

        toggleClock(state);
        state.allowance = _timeLeft;
    }

    /// @notice Deduct duration from a clock and set it to paused.
    /// The clock must have time left after deduction.
    function deduct(State storage state, Time.Duration deduction) internal {
        Time.Duration _timeLeft = state.allowance.monus(deduction);
        _setNewPaused(state, _timeLeft);
    }

    /// @notice Add matchEffort to a clock and set it to paused.
    /// The new clock allowance is capped by maxAllowance.
    function addMatchEffort(
        State storage state,
        Time.Duration matchEffort,
        Time.Duration maxAllowance
    ) internal {
        Time.Duration _timeLeft = timeLeft(state);

        Time.Duration _allowance = _timeLeft.add(matchEffort).min(maxAllowance);

        _setNewPaused(state, _allowance);
    }

    function setPaused(State storage state) internal {
        if (!state.startInstant.isZero()) {
            state.advanceClock();
        }
    }

    //
    // Private
    //
    function toggleClock(State storage state) private {
        if (state.startInstant.isZero()) {
            state.startInstant = Time.currentTime();
        } else {
            state.startInstant = Time.ZERO_INSTANT;
        }
    }

    function _setNewPaused(State storage state, Time.Duration allowance)
        private
    {
        // Rewrite this with require?
        if (allowance.isZero()) {
            revert("can't create clock with zero time");
        }

        state.allowance = allowance;
        state.startInstant = Time.ZERO_INSTANT;
    }
}
