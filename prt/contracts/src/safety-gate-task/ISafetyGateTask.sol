// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITask} from "prt-contracts/ITask.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @title ISafetyGateTask
/// @notice Interface for a safety-gated task wrapper.
/// @dev Semantics:
/// - All sentries must vote and corroborate the inner task result for the
///   gate to finish without delay.
/// - Otherwise, anyone may start a fallback timer once the inner task is
///   finished; after it elapses, the inner task result is accepted as-is.
/// - The gate is delay-only: `result()` only ever surfaces the inner task's
///   state. Sentries decide *when* it becomes visible, never *what* it is.
/// - This interface does not prescribe auto-start of the fallback timer;
///   an offchain actor must call `startFallbackTimer` for liveness.
interface ISafetyGateTask is ITask {
    /// @notice Aggregate status of the sentry voting process.
    /// @dev DISAGREED is absorbing: once two sentries cast conflicting
    /// votes, the status stays DISAGREED for the lifetime of the task.
    enum SentryStatus {
        VOTING, // votes still accumulating, no conflict observed so far
        AGREED, // all sentries voted and corroborate the same claim
        DISAGREED // conflicting votes were cast
    }

    /// @notice Inner task that provides the primary result.
    function INNER_TASK() external view returns (ITask);

    /// @notice Delay window before falling back to the inner task result.
    function DISAGREEMENT_WINDOW() external view returns (Time.Duration);

    /// @notice Total number of distinct sentries configured at task creation.
    function sentryCount() external view returns (uint256);

    /// @notice Total number of sentry votes submitted for this task.
    function sentryTotalVotes() external view returns (uint256);

    /// @notice Whether an address is a sentry for this task (configured list).
    function isSentry(address) external view returns (bool);

    /// @notice Whether a given sentry has already voted.
    function hasVoted(address) external view returns (bool);

    /// @notice Submit a sentry vote for the expected final state.
    /// @dev
    /// - Each sentry can vote once; the zero state is an invalid vote.
    /// - A vote that conflicts with an earlier vote permanently marks the
    ///   sentry set as disagreeing for this task (see `SentryStatus`).
    /// - Votes are still accepted after the gate has finished; they are
    ///   harmless, as `result()` is monotone and cannot become unfinished.
    function sentryVote(Machine.Hash vote) external;

    /// @notice Aggregate status of the sentry voting process.
    /// @return status See `SentryStatus`.
    /// @return claim The corroborated claim if status is AGREED,
    /// otherwise ZERO_STATE.
    function sentryStatus()
        external
        view
        returns (SentryStatus status, Machine.Hash claim);

    /// @notice State of the fallback timer.
    /// @return started Whether the timer has been started.
    /// @return startInstant When the timer was started (meaningless unless started).
    /// @return elapsed Whether the disagreement window has fully elapsed.
    function fallbackTimer()
        external
        view
        returns (bool started, Time.Instant startInstant, bool elapsed);

    /// @notice Start the fallback timer if sentries disagree or are missing.
    /// @dev Anyone can call this; required for liveness in disagreement cases.
    ///      This does not resolve immediately; `result()` returns the inner
    ///      outcome only after the timer elapses.
    /// @return started True if the timer was started in this call.
    function startFallbackTimer() external returns (bool started);

    /// @notice Returns whether the fallback timer can be started now.
    /// @dev True only if the timer has not started, the inner task finished,
    /// AND the sentries do not corroborate the inner result.
    function canStartFallbackTimer() external view returns (bool);
}
