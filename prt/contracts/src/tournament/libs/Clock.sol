// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "prt-contracts/ITournament.sol";

import {Time} from "./Time.sol";

/// @notice Arithmetic and phase transitions for one tournament clock.
/// @dev A zero allowance is uninitialized. With a positive allowance, a zero
/// start instant is paused and a positive start instant is running.
library Clock {
    using Time for Time.Instant;
    using Time for Time.Duration;

    using Clock for State;

    struct State {
        Time.Duration allowance;
        Time.Instant startInstant;
    }

    //
    // View/Pure methods
    //

    /// @notice Whether the clock has ever been initialized.
    /// @dev This does not imply that its commitment is still live. Eliminated
    /// commitments intentionally leave historical clock storage behind.
    function isInitialized(State memory state) internal pure returns (bool) {
        return !state.allowance.isZero();
    }

    /// @notice Whether the clock structurally has a start instant.
    /// @dev An expired clock remains running and accumulates overdue even after
    /// match deletion. Match topology, not clock storage, determines liveness.
    function isRunning(State memory state) internal pure returns (bool) {
        return !state.startInstant.isZero();
    }

    function requireInitialized(State memory state) internal pure {
        assert(state.isInitialized());
    }

    function requireUninitialized(State memory state) internal pure {
        require(!state.isInitialized(), ITournament.ClockAlreadyInitialized());
    }

    /// @notice Require an initialized paused clock.
    /// @dev A violation after initialization is an internal phase-machine bug.
    function requirePaused(State memory state) internal pure {
        state.requireInitialized();
        assert(!state.isRunning());
    }

    /// @notice Require an initialized running clock.
    /// @dev A violation after initialization is an internal phase-machine bug.
    function requireRunning(State memory state) internal pure {
        state.requireInitialized();
        assert(state.isRunning());
    }

    /// @return Live remaining time at `current`, saturated at zero.
    /// @dev Requires an initialized clock and `current` at or after its start
    /// instant. A running clock returns zero at and after its deadline.
    function remainingAt(State memory state, Time.Instant current)
        internal
        pure
        returns (Time.Duration)
    {
        state.requireInitialized();
        if (!state.isRunning()) {
            return state.allowance;
        }

        return
            state.allowance.saturatingSub(current.timeSpan(state.startInstant));
    }

    /// @return A paused clock's full remaining allowance.
    /// @dev Requires an initialized paused clock, for which the stored
    /// allowance is exactly the live remaining time.
    function pausedAllowance(State memory state)
        internal
        pure
        returns (Time.Duration)
    {
        state.requirePaused();
        return state.allowance;
    }

    /// @return Time elapsed strictly beyond the deadline, saturated at zero.
    /// @dev Requires an initialized running clock. A running clock is already
    /// expired at its deadline, although its overdue duration is zero.
    function overdueByAt(State memory state, Time.Instant current)
        internal
        pure
        returns (Time.Duration)
    {
        state.requireInitialized();
        assert(state.isRunning());
        return
            current.timeSpan(state.startInstant).saturatingSub(state.allowance);
    }

    //
    // Storage methods
    //

    /// @notice Initialize a clock once, paused at its live check-in allowance.
    /// @dev Stores `initialAllowance - (current - checkinInstant)`, saturating at
    /// zero. The caller must preserve a positive result because zero allowance
    /// means uninitialized.
    function initializePausedAt(
        State storage state,
        Time.Instant checkinInstant,
        Time.Duration initialAllowance,
        Time.Instant current
    ) internal {
        state.requireUninitialized();
        Time.Duration allowance =
            initialAllowance.saturatingSub(current.timeSpan(checkinInstant));
        _setPaused(state, allowance);
    }

    /// @notice Start an initialized paused clock at `current`.
    function startAt(State storage state, Time.Instant current) internal {
        state.requirePaused();
        assert(!current.isZero());
        state.startInstant = current;
    }

    /// @notice Pause a clock after a valid response, discounting part of the
    /// elapsed time.
    /// @dev The response must arrive before the original deadline. The result
    /// is `allowance - max(elapsed - responseBudget, 0)`, so it stays positive
    /// and never exceeds the balance at the start of the response.
    function pauseAfterResponseAt(
        State storage state,
        Time.Duration responseBudget,
        Time.Instant current
    ) internal {
        state.requireRunning();
        Time.Duration elapsed = current.timeSpan(state.startInstant);
        if (!state.allowance.gt(elapsed)) {
            revert ITournament.CannotAdvanceTimedOutClock();
        }

        Time.Duration chargedElapsed = elapsed.saturatingSub(responseBudget);
        _setPaused(state, state.allowance.checkedSub(chargedElapsed));
    }

    /// @notice Charge a clock's live remaining time and pause it.
    /// @dev The clock may start paused or running. The result must stay
    /// positive because zero allowance denotes an uninitialized clock.
    function chargeAndPauseAt(
        State storage state,
        Time.Duration charge,
        Time.Instant current
    ) internal {
        Time.Duration remaining = state.remainingAt(current).checkedSub(charge);
        _setPaused(state, remaining);
    }

    /// @notice Replace an initialized paused clock with another paused state.
    /// @dev This primitive is not monotone relative to the target clock. The
    /// caller owns the source bound; recursive propagation uses a shared pair
    /// envelope that may exceed the target's current allowance.
    function replaceWithPaused(State storage state, State memory source)
        internal
    {
        state.requirePaused();
        assert(!source.isRunning());
        _setPaused(state, source.allowance);
    }

    /// @notice Charge an already-paused in-memory clock.
    /// @dev The charge must leave a positive initialized allowance. Exact
    /// depletion violates the clock invariant; overcharging fails through
    /// checked arithmetic.
    function deductPaused(State memory state, Time.Duration charge)
        internal
        pure
        returns (State memory)
    {
        state.requirePaused();
        Time.Duration remaining = state.allowance.checkedSub(charge);
        return _pausedState(remaining);
    }

    //
    // Private
    //

    function _setPaused(State storage state, Time.Duration allowance) private {
        State memory paused = _pausedState(allowance);

        state.allowance = paused.allowance;
        state.startInstant = paused.startInstant;
    }

    function _pausedState(Time.Duration allowance)
        private
        pure
        returns (State memory)
    {
        assert(!allowance.isZero());

        return State({allowance: allowance, startInstant: Time.ZERO_INSTANT});
    }
}
