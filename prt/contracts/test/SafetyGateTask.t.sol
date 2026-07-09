// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

pragma solidity ^0.8.0;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {
    IERC165
} from "@openzeppelin-contracts-5.5.0/utils/introspection/IERC165.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITask} from "src/ITask.sol";
import {ITaskSpawner} from "src/ITaskSpawner.sol";
import {ISafetyGateTask} from "src/safety-gate-task/ISafetyGateTask.sol";
import {
    MAX_SENTRIES,
    SafetyGateTask
} from "src/safety-gate-task/SafetyGateTask.sol";
import {
    SafetyGateTaskSpawner
} from "src/safety-gate-task/SafetyGateTaskSpawner.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";

contract MockTask is ITask {
    bool private _finished;
    Machine.Hash private _state;

    function setResult(bool finished, Machine.Hash state) external {
        _finished = finished;
        _state = state;
    }

    function result() external view returns (bool, Machine.Hash) {
        return (_finished, _state);
    }

    function cleanup() external view returns (bool) {
        return _finished;
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(ITask).interfaceId;
    }
}

/// @notice Mock whose `cleanup` always reverts, and whose `result` reverts
/// once finished (mimicking a tournament that failed with no winner).
contract RevertingMockTask is ITask {
    bool private _finished;

    error MockResultRevert();
    error MockCleanupRevert();

    function setFinished(bool finished) external {
        _finished = finished;
    }

    function result() external view returns (bool, Machine.Hash) {
        if (_finished) {
            revert MockResultRevert();
        }
        return (false, Machine.ZERO_STATE);
    }

    function cleanup() external pure returns (bool) {
        revert MockCleanupRevert();
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(ITask).interfaceId;
    }
}

contract MockSpawner is ITaskSpawner {
    MockTask public lastTask;
    Machine.Hash public lastInitial;
    IDataProvider public lastProvider;
    bool public nextFinished;
    Machine.Hash public nextState;

    function setNextResult(bool finished, Machine.Hash state) external {
        nextFinished = finished;
        nextState = state;
    }

    function spawn(Machine.Hash initial, IDataProvider provider)
        external
        returns (ITask)
    {
        lastInitial = initial;
        lastProvider = provider;
        lastTask = new MockTask();
        lastTask.setResult(nextFinished, nextState);
        return ITask(address(lastTask));
    }
}

contract SafetyGateTaskTest is Test {
    using Machine for Machine.Hash;
    using Time for Time.Instant;

    Machine.Hash constant STATE_ONE = Machine.Hash.wrap(bytes32(uint256(1)));
    Machine.Hash constant STATE_TWO = Machine.Hash.wrap(bytes32(uint256(2)));
    Time.Duration constant WINDOW = Time.Duration.wrap(10);

    address constant SENTRY_ONE = address(0x1001);
    address constant SENTRY_TWO = address(0x1002);
    address constant OTHER = address(0x2001);
    address constant SENTRY_MANAGER = address(0x3001);

    function _newTask(address[] memory sentries)
        internal
        returns (SafetyGateTask task, MockTask inner)
    {
        inner = new MockTask();
        task = new SafetyGateTask(inner, WINDOW, sentries);
    }

    function _oneSentry() internal pure returns (address[] memory sentries) {
        sentries = new address[](1);
        sentries[0] = SENTRY_ONE;
    }

    function _twoSentries() internal pure returns (address[] memory sentries) {
        sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;
    }

    function _assertStatus(
        SafetyGateTask task,
        ISafetyGateTask.SentryStatus expectedStatus,
        Machine.Hash expectedClaim
    ) internal view {
        (ISafetyGateTask.SentryStatus status, Machine.Hash claim) =
            task.sentryStatus();
        assertEq(uint8(status), uint8(expectedStatus));
        assertTrue(claim.eq(expectedClaim));
    }

    function testConstructorSetsSentriesAndCount() public {
        (SafetyGateTask task,) = _newTask(_twoSentries());

        assertEq(task.sentryCount(), 2);
        assertTrue(task.isSentry(SENTRY_ONE));
        assertTrue(task.isSentry(SENTRY_TWO));
        _assertStatus(
            task, ISafetyGateTask.SentryStatus.VOTING, Machine.ZERO_STATE
        );
    }

    function testConstructorDeduplicatesSentries() public {
        address[] memory sentries = new address[](3);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_ONE;
        sentries[2] = SENTRY_TWO;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);

        // A duplicate is collapsed, so it stays harmless (AGREED remains
        // reachable) rather than inflating the count past what can vote.
        assertEq(task.sentryCount(), 2);

        inner.setResult(true, STATE_ONE);
        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_ONE);

        _assertStatus(task, ISafetyGateTask.SentryStatus.AGREED, STATE_ONE);
    }

    function testConstructorRejectsZeroAddressSentry() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = address(0);

        // address(0) can never vote, so it must not be accepted.
        MockTask inner = new MockTask();
        vm.expectRevert(SafetyGateTask.ZeroSentry.selector);
        new SafetyGateTask(inner, WINDOW, sentries);
    }

    function testConstructorRejectsOversizedSentryList() public {
        uint256 max = MAX_SENTRIES;
        address[] memory sentries = new address[](max + 1);
        for (uint256 i = 0; i < sentries.length; i++) {
            sentries[i] = address(uint160(i + 1));
        }

        MockTask inner = new MockTask();
        vm.expectRevert(SafetyGateTask.TooManySentries.selector);
        new SafetyGateTask(inner, WINDOW, sentries);
    }

    function testConstructorAcceptsMaxSentryList() public {
        uint256 max = MAX_SENTRIES;
        address[] memory sentries = new address[](max);
        for (uint256 i = 0; i < sentries.length; i++) {
            sentries[i] = address(uint160(i + 1));
        }

        MockTask inner = new MockTask();
        SafetyGateTask task = new SafetyGateTask(inner, WINDOW, sentries);
        assertEq(task.sentryCount(), max);
    }

    /// @dev A task with a pathologically large window must not brick: once the
    /// fallback timer elapses, result() must return the inner state, not revert
    /// on a uint64 overflow of (start + window).
    function testHugeWindowDoesNotBrickResult() public {
        Time.Duration hugeWindow = Time.Duration.wrap(type(uint64).max);
        MockTask inner = new MockTask();
        SafetyGateTask task =
            new SafetyGateTask(inner, hugeWindow, _oneSentry());

        inner.setResult(true, STATE_ONE);
        assertTrue(task.startFallbackTimer());

        // Before the (astronomical) window elapses: still holding, no revert.
        (bool finished, Machine.Hash finalState) = task.result();
        assertFalse(finished);
        assertTrue(finalState.eq(Machine.ZERO_STATE));

        // fallbackTimer() must not revert either.
        (bool started,, bool elapsed) = task.fallbackTimer();
        assertTrue(started);
        assertFalse(elapsed);
    }

    function testSentryVoteRequiresSentry() public {
        (SafetyGateTask task,) = _newTask(_oneSentry());

        vm.expectRevert(
            abi.encodeWithSelector(SafetyGateTask.NotSentry.selector)
        );
        vm.prank(OTHER);
        task.sentryVote(STATE_ONE);
    }

    function testSentryVoteRejectsZero() public {
        (SafetyGateTask task,) = _newTask(_oneSentry());

        vm.expectRevert(
            abi.encodeWithSelector(SafetyGateTask.InvalidSentryVote.selector)
        );
        vm.prank(SENTRY_ONE);
        task.sentryVote(Machine.ZERO_STATE);
    }

    function testSentryVoteOnlyOnce() public {
        (SafetyGateTask task,) = _newTask(_oneSentry());

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);

        vm.expectRevert(
            abi.encodeWithSelector(SafetyGateTask.AlreadyVoted.selector)
        );
        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
    }

    function testSentryVoteEmitsEvent() public {
        (SafetyGateTask task,) = _newTask(_oneSentry());

        vm.expectEmit(true, false, false, true, address(task));
        emit SafetyGateTask.SentryVoted(SENTRY_ONE, STATE_ONE);
        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
    }

    function testStatusWhileVotesAccumulate() public {
        (SafetyGateTask task,) = _newTask(_twoSentries());

        // partial consistent votes are still VOTING, and no claim leaks
        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        _assertStatus(
            task, ISafetyGateTask.SentryStatus.VOTING, Machine.ZERO_STATE
        );

        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_ONE);
        _assertStatus(task, ISafetyGateTask.SentryStatus.AGREED, STATE_ONE);
    }

    function testDisagreementIsAbsorbing() public {
        (SafetyGateTask task,) = _newTask(_twoSentries());

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_TWO);

        _assertStatus(
            task, ISafetyGateTask.SentryStatus.DISAGREED, Machine.ZERO_STATE
        );
    }

    function testResultWhenInnerNotFinished() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_oneSentry());
        inner.setResult(false, STATE_ONE);

        (bool finished, Machine.Hash finalState) = task.result();
        assertFalse(finished);
        assertTrue(finalState.eq(Machine.ZERO_STATE));
    }

    function testResultWhenSentriesAgreeAndMatchInner() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_twoSentries());
        inner.setResult(true, STATE_ONE);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_ONE);

        (bool finished, Machine.Hash finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
    }

    function testResultNeverReturnsSentryClaim() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_oneSentry());
        inner.setResult(true, STATE_ONE);

        // Full sentry agreement on a state that differs from the inner
        // result must never surface the sentry claim.
        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_TWO);

        assertTrue(task.startFallbackTimer());
        (, Time.Instant startInstant,) = task.fallbackTimer();
        vm.roll(
            Time.Instant.unwrap(startInstant) + Time.Duration.unwrap(WINDOW)
        );

        (bool finished, Machine.Hash finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
    }

    function testResultMismatchRequiresFallbackTimer() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_twoSentries());
        inner.setResult(true, STATE_ONE);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_TWO);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_TWO);

        (bool finished, Machine.Hash finalState) = task.result();
        assertFalse(finished);
        assertTrue(finalState.eq(Machine.ZERO_STATE));

        assertTrue(task.canStartFallbackTimer());

        assertTrue(task.startFallbackTimer());
        assertFalse(task.canStartFallbackTimer());

        (bool started, Time.Instant startInstant, bool elapsed) =
            task.fallbackTimer();
        assertTrue(started);
        assertFalse(elapsed);
        uint256 startBlock = Time.Instant.unwrap(startInstant);
        assertGt(startBlock, 0);

        vm.roll(startBlock + Time.Duration.unwrap(WINDOW) - 1);
        (finished, finalState) = task.result();
        assertFalse(finished);
        assertTrue(finalState.eq(Machine.ZERO_STATE));
        (,, elapsed) = task.fallbackTimer();
        assertFalse(elapsed);

        vm.roll(startBlock + Time.Duration.unwrap(WINDOW));
        (finished, finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
        (,, elapsed) = task.fallbackTimer();
        assertTrue(elapsed);
    }

    function testResultMissingVotesRequiresFallbackTimer() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_twoSentries());
        inner.setResult(true, STATE_ONE);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);

        assertTrue(task.canStartFallbackTimer());
        assertTrue(task.startFallbackTimer());

        (, Time.Instant startInstant,) = task.fallbackTimer();
        vm.roll(
            Time.Instant.unwrap(startInstant) + Time.Duration.unwrap(WINDOW)
        );
        (bool finished, Machine.Hash finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
    }

    function testResultIsMonotoneUnderLateVotes() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_twoSentries());
        inner.setResult(true, STATE_ONE);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);

        assertTrue(task.startFallbackTimer());
        (, Time.Instant startInstant,) = task.fallbackTimer();
        vm.roll(
            Time.Instant.unwrap(startInstant) + Time.Duration.unwrap(WINDOW)
        );

        (bool finished,) = task.result();
        assertTrue(finished);

        // a late conflicting vote cannot un-finish the gate
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_TWO);

        (finished,) = task.result();
        assertTrue(finished);
    }

    function testResultRevertPassthrough() public {
        RevertingMockTask inner = new RevertingMockTask();
        SafetyGateTask task = new SafetyGateTask(inner, WINDOW, _oneSentry());

        // gate is transparent to inner `result()` reverts
        inner.setFinished(true);
        vm.expectRevert(
            abi.encodeWithSelector(RevertingMockTask.MockResultRevert.selector)
        );
        task.result();
    }

    function testStartFallbackTimerRequiresInnerFinished() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_oneSentry());
        inner.setResult(false, STATE_ONE);

        assertFalse(task.canStartFallbackTimer());
        assertFalse(task.startFallbackTimer());
        (bool started,,) = task.fallbackTimer();
        assertFalse(started);
    }

    function testStartFallbackTimerIdempotent() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_oneSentry());
        inner.setResult(true, STATE_ONE);

        vm.expectEmit(false, false, false, true, address(task));
        emit SafetyGateTask.DisagreementWindowStarted(Time.Instant
            .wrap(uint64(vm.getBlockNumber())));
        assertTrue(task.startFallbackTimer());

        (bool started, Time.Instant startInstant,) = task.fallbackTimer();
        assertTrue(started);
        uint256 startBlock = Time.Instant.unwrap(startInstant);
        assertGt(startBlock, 0);

        vm.roll(startBlock + 1);
        assertFalse(task.startFallbackTimer());
        (, startInstant,) = task.fallbackTimer();
        assertEq(Time.Instant.unwrap(startInstant), startBlock);
    }

    function testCleanupDelegatesToInner() public {
        (SafetyGateTask task, MockTask inner) = _newTask(_oneSentry());

        inner.setResult(false, STATE_ONE);
        assertFalse(task.cleanup());

        inner.setResult(true, STATE_ONE);
        assertTrue(task.cleanup());
    }

    function testCleanupSwallowsInnerRevert() public {
        RevertingMockTask inner = new RevertingMockTask();
        SafetyGateTask task = new SafetyGateTask(inner, WINDOW, _oneSentry());

        // inner unfinished: cleanup short-circuits
        assertFalse(task.cleanup());

        // inner cleanup reverts: swallowed into false
        // (use a MockTask wrapper state where result() is fine but cleanup reverts)
        MockRevertingCleanupTask innerCleanup = new MockRevertingCleanupTask();
        SafetyGateTask task2 =
            new SafetyGateTask(innerCleanup, WINDOW, _oneSentry());
        assertFalse(task2.cleanup());
    }

    function testSupportsInterface() public {
        (SafetyGateTask task,) = _newTask(_oneSentry());

        assertTrue(task.supportsInterface(type(IERC165).interfaceId));
        assertTrue(task.supportsInterface(type(ITask).interfaceId));
        assertTrue(task.supportsInterface(type(ISafetyGateTask).interfaceId));
        assertFalse(task.supportsInterface(bytes4(0xffffffff)));
    }

    function testInterfaceIdMatchesNodeConstant() public pure {
        // The node hardcodes this id to detect safety gates behind the
        // EpochSealed task address (SAFETY_GATE_TASK_INTERFACE_ID in the
        // epoch-manager crate). Solidity computes interface ids excluding
        // inherited functions, so it cannot be derived by XORing the full
        // contract ABI. If this assert breaks, update the node constant.
        assertEq(
            bytes32(type(ISafetyGateTask).interfaceId),
            bytes32(bytes4(0xf77c3559))
        );
    }

    function testSpawnerOnlySentryManagerCanSetSentries() public {
        MockSpawner innerSpawner = new MockSpawner();
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, _oneSentry()
        );

        address[] memory newSentries = new address[](1);
        newSentries[0] = SENTRY_TWO;

        vm.expectRevert(
            abi.encodeWithSelector(
                SafetyGateTaskSpawner.NotSentryManager.selector
            )
        );
        vm.prank(OTHER);
        spawner.setSentries(newSentries);
    }

    function testSpawnerSpawnUsesSnapshot() public {
        MockSpawner innerSpawner = new MockSpawner();
        innerSpawner.setNextResult(true, STATE_ONE);
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, _oneSentry()
        );

        SafetyGateTask taskOne = SafetyGateTask(
            address(spawner.spawn(STATE_ONE, IDataProvider(address(0))))
        );
        assertTrue(taskOne.isSentry(SENTRY_ONE));
        assertFalse(taskOne.isSentry(SENTRY_TWO));

        address[] memory nextSentries = new address[](1);
        nextSentries[0] = SENTRY_TWO;
        vm.expectEmit(false, false, false, true, address(spawner));
        emit SafetyGateTaskSpawner.SentriesUpdated(nextSentries);
        vm.prank(SENTRY_MANAGER);
        spawner.setSentries(nextSentries);

        SafetyGateTask taskTwo = SafetyGateTask(
            address(spawner.spawn(STATE_TWO, IDataProvider(address(0))))
        );
        assertFalse(taskTwo.isSentry(SENTRY_ONE));
        assertTrue(taskTwo.isSentry(SENTRY_TWO));
    }

    function testSpawnerEmitsSpawnEvent() public {
        MockSpawner innerSpawner = new MockSpawner();
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, _oneSentry()
        );

        // task/innerTask addresses are unknown upfront: check only that the
        // event was emitted by the spawner, then check consistency after
        vm.recordLogs();
        ITask task = spawner.spawn(STATE_ONE, IDataProvider(address(0)));

        bool foundSpawnEvent;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(spawner)
                    && logs[i].topics[0]
                        == SafetyGateTaskSpawner.SafetyGateTaskSpawned.selector
            ) {
                foundSpawnEvent = true;
                assertEq(
                    address(uint160(uint256(logs[i].topics[1]))), address(task)
                );
                assertEq(
                    address(uint160(uint256(logs[i].topics[2]))),
                    address(innerSpawner.lastTask())
                );
            }
        }
        assertTrue(foundSpawnEvent, "SafetyGateTaskSpawned not emitted");
    }

    function testSpawnerSentryViews() public {
        MockSpawner innerSpawner = new MockSpawner();
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, _twoSentries()
        );

        assertTrue(spawner.isSentry(SENTRY_ONE));
        assertTrue(spawner.isSentry(SENTRY_TWO));
        assertFalse(spawner.isSentry(OTHER));

        address[] memory current = spawner.getSentries();
        assertEq(current.length, 2);
        assertEq(current[0], SENTRY_ONE);
        assertEq(current[1], SENTRY_TWO);
    }

    function testSpawnerStoresDuplicatesVerbatim() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_ONE;

        MockSpawner innerSpawner = new MockSpawner();
        innerSpawner.setNextResult(true, STATE_ONE);
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, sentries
        );

        // The spawner stores duplicates verbatim (no O(n^2) scan)...
        assertEq(spawner.sentries(0), SENTRY_ONE);
        assertEq(spawner.sentries(1), SENTRY_ONE);
        assertEq(spawner.getSentries().length, 2);

        // ...and the spawned task collapses them, so this can never brick.
        SafetyGateTask task = SafetyGateTask(
            address(spawner.spawn(STATE_ONE, IDataProvider(address(0))))
        );
        assertEq(task.sentryCount(), 1);
        assertTrue(task.isSentry(SENTRY_ONE));
    }

    function testSpawnerRejectsZeroSentry() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = address(0);

        MockSpawner innerSpawner = new MockSpawner();
        vm.expectRevert(SafetyGateTaskSpawner.ZeroSentry.selector);
        new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, sentries
        );
    }

    function testSpawnerSetSentriesRejectsZero() public {
        MockSpawner innerSpawner = new MockSpawner();
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, _oneSentry()
        );

        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_TWO;
        sentries[1] = address(0);

        vm.prank(SENTRY_MANAGER);
        vm.expectRevert(SafetyGateTaskSpawner.ZeroSentry.selector);
        spawner.setSentries(sentries);
    }

    function testSpawnerRejectsZeroWindow() public {
        MockSpawner innerSpawner = new MockSpawner();
        vm.expectRevert(SafetyGateTaskSpawner.ZeroDisagreementWindow.selector);
        new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, Time.Duration.wrap(0), _oneSentry()
        );
    }

    function testSpawnerConstructorRejectsOversizedList() public {
        address[] memory sentries = new address[](MAX_SENTRIES + 1);
        for (uint256 i = 0; i < sentries.length; i++) {
            sentries[i] = address(uint160(i + 1));
        }

        MockSpawner innerSpawner = new MockSpawner();
        vm.expectRevert(SafetyGateTaskSpawner.TooManySentries.selector);
        new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, sentries
        );
    }

    /// @dev The compromised/careless-manager DoS the review flagged: an
    /// oversized setSentries() must revert, so it can never brick spawn().
    function testSpawnerSetSentriesRejectsOversizedList() public {
        MockSpawner innerSpawner = new MockSpawner();
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SENTRY_MANAGER, innerSpawner, WINDOW, _oneSentry()
        );

        address[] memory sentries = new address[](MAX_SENTRIES + 1);
        for (uint256 i = 0; i < sentries.length; i++) {
            sentries[i] = address(uint160(i + 1));
        }

        vm.prank(SENTRY_MANAGER);
        vm.expectRevert(SafetyGateTaskSpawner.TooManySentries.selector);
        spawner.setSentries(sentries);
    }
}

/// @notice Mock whose `result` reports finished but whose `cleanup` reverts.
contract MockRevertingCleanupTask is ITask {
    error MockCleanupRevert();

    function result() external pure returns (bool, Machine.Hash) {
        return (true, Machine.Hash.wrap(bytes32(uint256(1))));
    }

    function cleanup() external pure returns (bool) {
        revert MockCleanupRevert();
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(ITask).interfaceId;
    }
}
