// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITask} from "prt-contracts/ITask.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";

/// @title ISafetyGateTask
/// @notice Interface for a safety-gated task wrapper.
/// @dev Semantics:
/// - All sentries must vote and agree on a non-zero claim to form consensus.
/// - If sentries disagree or fail to vote, anyone may start a fallback timer;
///   after it elapses, the inner task result is accepted.
/// - This interface does not prescribe auto-start of the fallback timer;
///   an offchain actor must call `startFallbackTimer` for liveness.
interface ISafetyGateTask is ITask {
    /// @notice Inner task that provides the primary result.
    function INNER_TASK() external view returns (ITask);

    /// @notice Delay window before falling back to the inner task result.
    function DISAGREEMENT_WINDOW() external view returns (Time.Duration);

    /// @notice Total number of sentries configured at task creation.
    function sentryCount() external view returns (uint256);

    /// @notice Total number of sentry votes submitted for this task.
    function sentryTotalVotes() external view returns (uint256);

    /// @notice Current sentry claim (ZERO_STATE means disagreement or no votes).
    function currentSentryClaim() external view returns (Machine.Hash);

    /// @notice Whether an address is a sentry for this task (configured list).
    function isSentry(address) external view returns (bool);

    /// @notice Whether a given sentry has already voted.
    function hasVoted(address) external view returns (bool);

    /// @notice Start of the fallback timer; zero means not started.
    function disagreementStart() external view returns (Time.Instant);

    /// @notice Submit a sentry vote for the expected final state.
    /// @dev
    /// - Each sentry can vote once.
    /// - A zero vote is invalid.
    /// - If any vote differs from the first, the claim becomes ZERO_STATE.
    function sentryVote(Machine.Hash vote) external;

    /// @notice Returns whether all sentries voted and agreed on a claim.
    /// @return ok True if all sentries voted and agree on a non-zero claim.
    /// @return claim The agreed claim if ok, otherwise ZERO_STATE.
    function sentryVotingConsensus()
        external
        view
        returns (bool ok, Machine.Hash claim);

    /// @notice Start the fallback timer if sentries disagree or are missing.
    /// @dev Anyone can call this; required for liveness in disagreement cases.
    ///      This does not resolve immediately; `result()` returns the inner
    ///      outcome only after the timer elapses.
    /// @return started True if the timer was started in this call.
    function startFallbackTimer() external returns (bool started);

    /// @notice Returns whether the fallback timer can be started now.
    /// @dev True only if inner task finished AND sentry consensus is missing/mismatched.
    function canStartFallbackTimer() external view returns (bool);
}
