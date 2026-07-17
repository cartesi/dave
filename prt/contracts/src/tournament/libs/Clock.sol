// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "prt-contracts/ITournament.sol";

import {Time} from "./Time.sol";

/// @notice Arithmetic and phase transitions for one tournament clock.
/// @dev The representation is part of the external ABI. A zero allowance is
/// uninitialized; a positive allowance with zero start instant is paused; and
/// a positive allowance with a positive start instant is running.
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

    function isInitialized(State memory state) internal pure returns (bool) {
        return !state.allowance.isZero();
    }

    function isRunning(State memory state) internal pure returns (bool) {
        return !state.startInstant.isZero();
    }

    function requireInitialized(State memory state) internal pure {
        require(state.isInitialized(), ITournament.ClockNotInitialized());
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
    /// @dev Reverts for an uninitialized clock and when `current` precedes its
    /// start instant. At the exact deadline, the result is zero.
    function remainingAt(State memory state, Time.Instant current)
        internal
        pure
        returns (Time.Duration)
    {
        state.requireInitialized();
        if (!state.isRunning()) {
            return state.allowance;
        }

        return state.allowance.monus(current.timeSpan(state.startInstant));
    }

    /// @return Time elapsed after the deadline, saturated at zero.
    /// @dev Reverts for an uninitialized or paused clock. At the exact
    /// deadline, the result is zero even though `remainingAt` is also zero.
    function overdueByAt(State memory state, Time.Instant current)
        internal
        pure
        returns (Time.Duration)
    {
        state.requireInitialized();
        if (!state.isRunning()) {
            revert ITournament.PausedClockCannotTimeout();
        }
        return current.timeSpan(state.startInstant).monus(state.allowance);
    }

    //
    // Storage methods
    //

    /// @notice Initialize a clock once, paused at its live check-in allowance.
    function initializePausedAt(
        State storage state,
        Time.Instant checkinInstant,
        Time.Duration initialAllowance,
        Time.Instant current
    ) internal {
        state.requireUninitialized();
        Time.Duration allowance =
            initialAllowance.monus(current.timeSpan(checkinInstant));
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

        Time.Duration chargedElapsed = elapsed.monus(responseBudget);
        _setPaused(state, state.allowance.monus(chargedElapsed));
    }

    /// @notice Charge a clock's live remaining time and pause it.
    /// @dev The clock may start paused or running. The result must stay
    /// positive because zero allowance denotes an uninitialized clock.
    function chargeAndPauseAt(
        State storage state,
        Time.Duration charge,
        Time.Instant current
    ) internal {
        Time.Duration remaining = state.remainingAt(current).monus(charge);
        _setPaused(state, remaining);
    }

    /// @notice Replace an initialized paused clock with another paused state.
    function replaceWithPaused(State storage state, State memory source)
        internal
    {
        state.requirePaused();
        assert(!source.isRunning());
        _setPaused(state, source.allowance);
    }

    /// @notice Charge an already-paused in-memory clock.
    /// @dev The returned allowance may be zero; a zero result cannot later be
    /// stored as an initialized clock.
    function deductPaused(State memory state, Time.Duration charge)
        internal
        pure
        returns (State memory)
    {
        state.requirePaused();
        Time.Duration remaining = state.allowance.monus(charge);
        return State({allowance: remaining, startInstant: Time.ZERO_INSTANT});
    }

    //
    // Private
    //

    function _setPaused(State storage state, Time.Duration allowance) private {
        if (allowance.isZero()) {
            revert ITournament.InitializedClockCannotHaveZeroAllowance();
        }

        state.allowance = allowance;
        state.startInstant = Time.ZERO_INSTANT;
    }
}
