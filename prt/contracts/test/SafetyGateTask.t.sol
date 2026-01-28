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

import {IDataProvider} from "src/IDataProvider.sol";
import {ITask} from "src/ITask.sol";
import {ITaskSpawner} from "src/ITaskSpawner.sol";
import {SafetyGateTask} from "src/safety-gate-task/SafetyGateTask.sol";
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

    function cleanup() external returns (bool) {
        return _finished;
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
    address constant SECURITY_COUNCIL = address(0x3001);

    function _newTask(address[] memory sentries)
        internal
        returns (SafetyGateTask task, MockTask inner)
    {
        inner = new MockTask();
        task = new SafetyGateTask(inner, WINDOW, sentries);
    }

    function testConstructorSetsSentriesAndCount() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;

        (SafetyGateTask task,) = _newTask(sentries);

        assertEq(task.sentryCount(), 2);
        assertTrue(task.isSentry(SENTRY_ONE));
        assertTrue(task.isSentry(SENTRY_TWO));
        (bool ok, Machine.Hash claim) = task.sentryVotingConsensus();
        assertFalse(ok);
        assertTrue(claim.eq(Machine.ZERO_STATE));
    }

    function testSentryVoteRequiresSentry() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        (SafetyGateTask task,) = _newTask(sentries);

        vm.expectRevert(
            abi.encodeWithSelector(SafetyGateTask.NotSentry.selector)
        );
        vm.prank(OTHER);
        task.sentryVote(STATE_ONE);
    }

    function testSentryVoteRejectsZero() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        (SafetyGateTask task,) = _newTask(sentries);

        vm.expectRevert(
            abi.encodeWithSelector(SafetyGateTask.InvalidSentryVote.selector)
        );
        vm.prank(SENTRY_ONE);
        task.sentryVote(Machine.ZERO_STATE);
    }

    function testSentryVoteOnlyOnce() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        (SafetyGateTask task,) = _newTask(sentries);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);

        vm.expectRevert(
            abi.encodeWithSelector(SafetyGateTask.AlreadyVoted.selector)
        );
        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
    }

    function testConsensusAfterAllVotesAgree() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;

        (SafetyGateTask task,) = _newTask(sentries);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_ONE);

        (bool ok, Machine.Hash claim) = task.sentryVotingConsensus();
        assertTrue(ok);
        assertTrue(claim.eq(STATE_ONE));
    }

    function testDisagreementResetsClaim() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;

        (SafetyGateTask task,) = _newTask(sentries);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_TWO);

        assertTrue(task.currentSentryClaim().eq(Machine.ZERO_STATE));
        (bool ok, Machine.Hash claim) = task.sentryVotingConsensus();
        assertFalse(ok);
        assertTrue(claim.eq(Machine.ZERO_STATE));
    }

    function testResultWhenInnerNotFinished() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);
        inner.setResult(false, STATE_ONE);

        (bool finished, Machine.Hash finalState) = task.result();
        assertFalse(finished);
        assertTrue(finalState.eq(Machine.ZERO_STATE));
    }

    function testResultWhenSentriesAgreeAndMatchInner() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);
        inner.setResult(true, STATE_ONE);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);
        vm.prank(SENTRY_TWO);
        task.sentryVote(STATE_ONE);

        (bool finished, Machine.Hash finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
    }

    function testResultMismatchRequiresFallbackTimer() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);
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
        uint256 startBlock = Time.Instant.unwrap(task.disagreementStart());
        assertGt(startBlock, 0);

        vm.roll(startBlock + Time.Duration.unwrap(WINDOW) - 1);
        (finished, finalState) = task.result();
        assertFalse(finished);
        assertTrue(finalState.eq(Machine.ZERO_STATE));

        vm.roll(startBlock + Time.Duration.unwrap(WINDOW));
        (finished, finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
    }

    function testResultMissingVotesRequiresFallbackTimer() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);
        inner.setResult(true, STATE_ONE);

        vm.prank(SENTRY_ONE);
        task.sentryVote(STATE_ONE);

        assertTrue(task.canStartFallbackTimer());
        assertTrue(task.startFallbackTimer());

        uint256 startBlock = Time.Instant.unwrap(task.disagreementStart());
        vm.roll(startBlock + Time.Duration.unwrap(WINDOW));
        (bool finished, Machine.Hash finalState) = task.result();
        assertTrue(finished);
        assertTrue(finalState.eq(STATE_ONE));
    }

    function testStartFallbackTimerRequiresInnerFinished() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);
        inner.setResult(false, STATE_ONE);

        assertFalse(task.canStartFallbackTimer());
        assertFalse(task.startFallbackTimer());
        assertTrue(task.disagreementStart().isZero());
    }

    function testStartFallbackTimerIdempotent() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        (SafetyGateTask task, MockTask inner) = _newTask(sentries);
        inner.setResult(true, STATE_ONE);

        assertTrue(task.startFallbackTimer());
        uint256 startBlock = Time.Instant.unwrap(task.disagreementStart());
        assertGt(startBlock, 0);

        vm.roll(startBlock + 1);
        assertFalse(task.startFallbackTimer());
        assertEq(Time.Instant.unwrap(task.disagreementStart()), startBlock);
    }

    function testSpawnerOnlySecurityCouncilCanSetSentries() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        MockSpawner innerSpawner = new MockSpawner();
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SECURITY_COUNCIL, innerSpawner, WINDOW, sentries
        );

        address[] memory newSentries = new address[](1);
        newSentries[0] = SENTRY_TWO;

        vm.expectRevert(
            abi.encodeWithSelector(
                SafetyGateTaskSpawner.NotSecurityCouncil.selector
            )
        );
        vm.prank(OTHER);
        spawner.setSentries(newSentries);
    }

    function testSpawnerSpawnUsesSnapshot() public {
        address[] memory sentries = new address[](1);
        sentries[0] = SENTRY_ONE;

        MockSpawner innerSpawner = new MockSpawner();
        innerSpawner.setNextResult(true, STATE_ONE);
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SECURITY_COUNCIL, innerSpawner, WINDOW, sentries
        );

        SafetyGateTask taskOne = SafetyGateTask(
            address(spawner.spawn(STATE_ONE, IDataProvider(address(0))))
        );
        assertTrue(taskOne.isSentry(SENTRY_ONE));
        assertFalse(taskOne.isSentry(SENTRY_TWO));

        address[] memory nextSentries = new address[](1);
        nextSentries[0] = SENTRY_TWO;
        vm.prank(SECURITY_COUNCIL);
        spawner.setSentries(nextSentries);

        SafetyGateTask taskTwo = SafetyGateTask(
            address(spawner.spawn(STATE_TWO, IDataProvider(address(0))))
        );
        assertFalse(taskTwo.isSentry(SENTRY_ONE));
        assertTrue(taskTwo.isSentry(SENTRY_TWO));
    }

    function testSpawnerStoresDuplicatesVerbatim() public {
        address[] memory sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_ONE;

        MockSpawner innerSpawner = new MockSpawner();
        innerSpawner.setNextResult(true, STATE_ONE);
        SafetyGateTaskSpawner spawner = new SafetyGateTaskSpawner(
            SECURITY_COUNCIL, innerSpawner, WINDOW, sentries
        );

        SafetyGateTask task = SafetyGateTask(
            address(spawner.spawn(STATE_ONE, IDataProvider(address(0))))
        );
        assertEq(task.sentryCount(), 2);
        assertTrue(task.isSentry(SENTRY_ONE));
    }
}
