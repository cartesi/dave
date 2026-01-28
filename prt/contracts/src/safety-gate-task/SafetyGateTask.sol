// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITask} from "prt-contracts/ITask.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @title SafetyGateTask
/// @notice Middleware that gates an inner task result behind N sentry votes.
/// @dev Semantics:
/// - All sentries must vote and agree on a non-zero claim to form consensus.
/// - If sentries disagree or fail to vote, anyone may start a fallback timer;
///   after it elapses, the inner task result is accepted.
/// - This contract does not auto-start the fallback timer; an offchain actor
///   must call `startFallbackTimer`. This is a deliberate liveness assumption.
contract SafetyGateTask is ITask {
    using Machine for Machine.Hash;
    using Time for Time.Instant;
    using Time for Time.Duration;

    /// @notice Inner task that provides the primary result (e.g., PRT/Dave).
    ITask public immutable INNER_TASK;

    /// @notice Delay window before falling back to the inner task result.
    Time.Duration public immutable DISAGREEMENT_WINDOW;

    /// @notice Total number of sentries configured at task creation.
    uint256 public sentryCount;

    /// @notice Total number of sentry votes submitted for this task.
    uint256 public sentryTotalVotes;

    /// @notice Current sentry claim (ZERO_STATE means disagreement or no votes).
    Machine.Hash public currentSentryClaim;

    /// @notice Whether an address is a sentry for this task (configured list).
    mapping(address => bool) public isSentry;

    /// @notice Whether a given sentry has already voted.
    mapping(address => bool) public hasVoted;

    /// @notice Start of the fallback timer; zero means not started.
    Time.Instant public disagreementStart;

    /// @notice Emitted when a sentry casts a vote.
    event SentryVoted(address indexed sentry, Machine.Hash vote);

    /// @notice Emitted when the fallback timer is started.
    event DisagreementWindowStarted(Time.Instant start);

    error NotSentry();
    error AlreadyVoted();
    error InvalidSentryVote();

    /// @dev Restricts to sentries configured at construction time.
    modifier onlySentry() {
        require(isSentry[msg.sender], NotSentry());
        _;
    }

    /// @notice Create a safety-gated task around an inner task.
    /// @param innerTask The inner task whose result is gated.
    /// @param disagreementWindow The delay window before falling back to inner task.
    /// @param initialSentries Immutable list of sentries for this task instance.
    constructor(
        ITask innerTask,
        Time.Duration disagreementWindow,
        address[] memory initialSentries
    ) {
        INNER_TASK = innerTask;
        DISAGREEMENT_WINDOW = disagreementWindow;

        for (uint256 i = 0; i < initialSentries.length; i++) {
            address sentry = initialSentries[i];
            isSentry[sentry] = true;
            sentryCount++;
        }
    }

    /// @notice Submit a sentry vote for the expected final state.
    /// @dev
    /// - Each sentry can vote once.
    /// - A zero vote is invalid.
    /// - If any vote differs from the first, the claim becomes ZERO_STATE,
    ///   signaling disagreement.
    function sentryVote(Machine.Hash vote) external onlySentry {
        require(!hasVoted[msg.sender], AlreadyVoted());
        require(!vote.eq(Machine.ZERO_STATE), InvalidSentryVote());

        if (sentryTotalVotes == 0) {
            currentSentryClaim = vote;
        } else if (!currentSentryClaim.eq(vote)) {
            currentSentryClaim = Machine.ZERO_STATE;
        }

        hasVoted[msg.sender] = true;
        sentryTotalVotes++;
        emit SentryVoted(msg.sender, vote);
    }

    /// @notice Returns whether all sentries voted and agreed on a claim.
    /// @return ok True if all sentries voted and agree on a non-zero claim.
    /// @return claim The agreed claim if ok, otherwise ZERO_STATE.
    function sentryVotingConsensus() public view returns (bool, Machine.Hash) {
        bool sentriesAgree = !currentSentryClaim.eq(Machine.ZERO_STATE);

        if (sentryCount == sentryTotalVotes && sentriesAgree) {
            return (true, currentSentryClaim);
        } else {
            return (false, Machine.ZERO_STATE);
        }
    }

    /// @notice Start the fallback timer if sentries disagree or are missing.
    /// @dev Anyone can call this; required for liveness in disagreement cases.
    ///      This does not resolve immediately; `result()` returns the inner
    ///      outcome only after the timer elapses.
    /// @return started True if the timer was started in this call.
    function startFallbackTimer() external returns (bool) {
        if (!canStartFallbackTimer()) {
            return false;
        }

        disagreementStart = Time.currentTime();
        emit DisagreementWindowStarted(disagreementStart);
        return true;
    }

    /// @notice Returns whether the fallback timer can be started now.
    /// @dev True only if inner task finished AND sentry consensus is missing/mismatched.
    function canStartFallbackTimer() public view returns (bool) {
        if (!disagreementStart.isZero()) {
            return false;
        }

        (bool innerFinished, Machine.Hash innerState) = INNER_TASK.result();
        if (!innerFinished) {
            return false;
        }

        (bool sentriesAgree, Machine.Hash sentryClaim) = sentryVotingConsensus();
        return !sentriesAgree || !sentryClaim.eq(innerState);
    }

    /// @inheritdoc ITask
    /// @dev Resolution policy:
    /// - If inner task is unfinished: return (false, 0).
    /// - If all sentries agree and match inner result: return (true, inner result).
    /// - Else: return (false, 0) until the fallback timer elapses, then return inner result.
    function result()
        external
        view
        override
        returns (bool finished, Machine.Hash finalState)
    {
        (bool innerFinished, Machine.Hash innerState) = INNER_TASK.result();
        if (!innerFinished) {
            return (false, Machine.ZERO_STATE);
        }

        (bool sentriesAgree, Machine.Hash sentryClaim) = sentryVotingConsensus();

        if (sentriesAgree && sentryClaim.eq(innerState)) {
            return (true, innerState);
        } else if (disagreementStart.isZero()) {
            return (false, Machine.ZERO_STATE);
        } else if (disagreementStart.timeoutElapsed(DISAGREEMENT_WINDOW)) {
            return (true, innerState);
        } else {
            return (false, Machine.ZERO_STATE);
        }
    }

    /// @inheritdoc ITask
    /// @dev Best-effort passthrough to the inner task cleanup.
    function cleanup() external override returns (bool cleaned) {
        (bool innerFinished,) = INNER_TASK.result();
        if (!innerFinished) {
            return false;
        }

        try INNER_TASK.cleanup() returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
