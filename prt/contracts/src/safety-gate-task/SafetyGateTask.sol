// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {
    IERC165
} from "@openzeppelin-contracts-5.5.0/utils/introspection/IERC165.sol";

import {ITask} from "prt-contracts/ITask.sol";
import {
    ISafetyGateTask
} from "prt-contracts/safety-gate-task/ISafetyGateTask.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

// Upper bound on the sentry-set size, enforced both by SafetyGateTask's
// constructor and by SafetyGateTaskSpawner (which imports this as the single
// source of truth). Caps the constructor's per-sentry storage loop so an
// oversized list can never make deployment -- and thus settlement -- run out
// of gas. 16 is already a large sentry set; the bound is a safety ceiling,
// not a recommendation.
uint256 constant MAX_SENTRIES = 16;

/// @title SafetyGateTask
/// @notice Middleware that gates an inner task result behind N sentry votes.
/// @dev See `ISafetyGateTask` for the gate semantics. Implementation notes:
/// - The sentry claim collapses to ZERO_STATE on the first conflicting vote;
///   since zero votes are rejected, `_claim == ZERO && votes > 0` uniquely
///   encodes DISAGREED and no extra flag is needed.
/// - `result()` reverts if the inner task's `result()` reverts (e.g. a root
///   tournament that finished with every commitment eliminated). The gate
///   deliberately does not shield that catastrophic state.
contract SafetyGateTask is ISafetyGateTask {
    using Machine for Machine.Hash;
    using Time for Time.Instant;
    using Time for Time.Duration;

    /// @notice Inner task that provides the primary result (e.g., PRT/Dave).
    ITask public immutable INNER_TASK;

    /// @notice Delay window before falling back to the inner task result.
    Time.Duration public immutable DISAGREEMENT_WINDOW;

    /// @notice Total number of distinct sentries configured at task creation.
    uint256 public sentryCount;

    /// @notice Total number of sentry votes submitted for this task.
    uint256 public sentryTotalVotes;

    /// @dev Running claim; collapses to ZERO_STATE on the first conflict.
    Machine.Hash private _claim;

    /// @notice Whether an address is a sentry for this task (configured list).
    mapping(address => bool) public isSentry;

    /// @notice Whether a given sentry has already voted.
    mapping(address => bool) public hasVoted;

    /// @dev Start of the fallback timer; zero means not started.
    Time.Instant private _fallbackTimerStart;

    /// @notice Emitted when a sentry casts a vote.
    event SentryVoted(address indexed sentry, Machine.Hash vote);

    /// @notice Emitted when the fallback timer is started.
    event DisagreementWindowStarted(Time.Instant start);

    error NotSentry();
    error AlreadyVoted();
    error InvalidSentryVote();
    error TooManySentries();
    error ZeroSentry();

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

        // Bound the loop below so construction can never exhaust gas: this
        // is the sole anti-brick mechanism (an oversized set is the only way
        // to freeze settlement; a zero or duplicate can at worst force the
        // fallback window, i.e. delay).
        require(initialSentries.length <= MAX_SENTRIES, TooManySentries());

        // Reject the zero address loudly (it can never vote, so it is almost
        // always an uninitialized-slot mistake). Deduplicate silently: a
        // repeat is harmless once collapsed, and doing so keeps AGREED
        // reachable rather than inflating the count past what can vote.
        for (uint256 i = 0; i < initialSentries.length; i++) {
            address sentry = initialSentries[i];
            require(sentry != address(0), ZeroSentry());
            if (!isSentry[sentry]) {
                isSentry[sentry] = true;
                sentryCount++;
            }
        }
    }

    /// @inheritdoc ISafetyGateTask
    function sentryVote(Machine.Hash vote) external onlySentry {
        require(!hasVoted[msg.sender], AlreadyVoted());
        require(!vote.notInitialized(), InvalidSentryVote());

        if (sentryTotalVotes == 0) {
            _claim = vote;
        } else if (!_claim.eq(vote)) {
            _claim = Machine.ZERO_STATE;
        }

        hasVoted[msg.sender] = true;
        sentryTotalVotes++;
        emit SentryVoted(msg.sender, vote);
    }

    /// @inheritdoc ISafetyGateTask
    function sentryStatus()
        public
        view
        returns (SentryStatus status, Machine.Hash claim)
    {
        if (sentryTotalVotes > 0 && _claim.notInitialized()) {
            return (SentryStatus.DISAGREED, Machine.ZERO_STATE);
        } else if (sentryTotalVotes == sentryCount && sentryCount > 0) {
            return (SentryStatus.AGREED, _claim);
        } else {
            return (SentryStatus.VOTING, Machine.ZERO_STATE);
        }
    }

    /// @inheritdoc ISafetyGateTask
    function fallbackTimer()
        public
        view
        returns (bool started, Time.Instant startInstant, bool elapsed)
    {
        started = !_fallbackTimerStart.isZero();
        startInstant = _fallbackTimerStart;
        // Overflow-safe elapsed check: measure blocks *since* the start
        // (current - start, which never overflows since start is a past
        // block) rather than start + window, which would overflow uint64 for
        // a pathologically large window and permanently revert result().
        elapsed = started
            && !DISAGREEMENT_WINDOW.gt(
                Time.currentTime().timeSpan(_fallbackTimerStart)
            );
    }

    /// @inheritdoc ISafetyGateTask
    function startFallbackTimer() external returns (bool) {
        if (!canStartFallbackTimer()) {
            return false;
        }

        _fallbackTimerStart = Time.currentTime();
        emit DisagreementWindowStarted(_fallbackTimerStart);
        return true;
    }

    /// @inheritdoc ISafetyGateTask
    function canStartFallbackTimer() public view returns (bool) {
        if (!_fallbackTimerStart.isZero()) {
            return false;
        }

        (bool innerFinished, Machine.Hash innerState) = INNER_TASK.result();
        if (!innerFinished) {
            return false;
        }

        return !_sentriesCorroborate(innerState);
    }

    /// @inheritdoc ITask
    function result()
        external
        view
        override
        returns (bool finished, Machine.Hash finalState)
    {
        (bool innerFinished, Machine.Hash innerState) = INNER_TASK.result();
        if (!innerFinished) {
            // inner task still running: the gate cannot be finished
            return (false, Machine.ZERO_STATE);
        }

        if (_sentriesCorroborate(innerState)) {
            // all sentries corroborate the inner result: settle with no delay
            // (fast path: no need to read the fallback timer)
            return (true, innerState);
        }

        (, Time.Instant timerStart, bool timerElapsed) = fallbackTimer();

        if (timerStart.isZero()) {
            // no corroboration and no timer: hold until someone starts it
            return (false, Machine.ZERO_STATE);
        } else if (timerElapsed) {
            // the delay has been served: the inner result passes through,
            // regardless of what the sentries did (or failed to do)
            return (true, innerState);
        } else {
            // timer still running: keep holding
            return (false, Machine.ZERO_STATE);
        }
    }

    /// @inheritdoc ITask
    /// @dev Reentrancy hazard: forwards to the inner task's `cleanup`, which
    /// may call untrusted contracts (see `ITask.cleanup`). Call last.
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

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ITask).interfaceId
            || interfaceId == type(ISafetyGateTask).interfaceId;
    }

    /// @dev Whether all sentries voted and their claim matches `innerState`.
    function _sentriesCorroborate(Machine.Hash innerState)
        private
        view
        returns (bool)
    {
        (SentryStatus status, Machine.Hash claim) = sentryStatus();
        return status == SentryStatus.AGREED && claim.eq(innerState);
    }
}
