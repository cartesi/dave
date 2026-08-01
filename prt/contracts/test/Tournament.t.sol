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

import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {MatchClocks} from "src/tournament/libs/MatchClocks.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "./Util.sol";
import {
    HistoricalThreeLevelGeometry as HistoricalGeometry
} from "./fixtures/HistoricalThreeLevelGeometry.sol";

contract TournamentTest is Util {
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;

    MultiLevelTournamentFactory immutable FACTORY;
    MultiLevelTournamentFactory immutable SINGLE_LEVEL_FACTORY;
    ITournament topTournament;
    ITournament middleTournament;

    struct SealedLeafFixture {
        ITournament tournament;
        Match.Id matchId;
        Clock.State clockOne;
        Clock.State clockTwo;
    }

    // Player accounts for testing
    address player0 = vm.addr(1);
    address player1 = vm.addr(2);

    constructor() {
        (FACTORY,) = Util.instantiateHistoricalThreeLevelTournamentFactory();
        SINGLE_LEVEL_FACTORY = Util.instantiateSingleLevelTournamentFactory(
            HistoricalGeometry.log2step(0), HistoricalGeometry.height(0)
        );
    }

    receive() external payable {}

    function testJoinTournament() public {
        uint256 player0BalanceBefore = player0.balance;
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        uint256 player0BalanceAfter = player0.balance;
        uint256 bondAmount = topTournament.bondValue();
        assertEq(
            player0BalanceBefore - bondAmount,
            player0BalanceAfter,
            "Player 0 should have paid bond"
        );

        // player 1 joins tournament
        uint256 _opponent = 1;
        // pair commitment, expect a match
        vm.expectEmit(true, true, true, true, address(topTournament));
        emit ITournament.MatchCreated(
            Util.historicalMatchId(_opponent, 0).hashFromId(),
            playerNodes[0][HistoricalGeometry.height(0)],
            playerNodes[1][HistoricalGeometry.height(0)],
            playerNodes[1][HistoricalGeometry.height(0) - 1]
        );

        uint256 player1BalanceBefore = player1.balance;
        Util.joinTournament(topTournament, _opponent);
        uint256 player1BalanceAfter = player1.balance;
        assertEq(
            player1BalanceBefore - bondAmount,
            player1BalanceAfter,
            "Player 1 should have paid bond"
        );
    }

    function testJoinTournamentInsufficientBond(uint256 insufficientBond)
        public
    {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        insufficientBond =
            bound(insufficientBond, 0, topTournament.bondValue() - 1);

        // Try to join with insufficient bond - should fail
        (,,, uint64 height) = topTournament.tournamentLevelConstants();
        Tree.Node _left = playerNodes[1][height - 1];
        Tree.Node _right = playerNodes[1][height - 1];
        Machine.Hash _finalState = TWO_STATE;

        vm.expectRevert(ITournament.InsufficientBond.selector);
        topTournament.joinTournament{value: insufficientBond}(
            _finalState, generateFinalStateProof(1, height), _left, _right
        );
    }

    function testJoinAtDeadlineRejectsBeforeClockInvariant() public {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        uint64 height = args.commitmentArgs.height;
        Tree.Node left = playerNodes[1][height - 1];
        Tree.Node right = playerNodes[1][height - 1];
        bytes32[] memory proof = generateFinalStateProof(1, height);
        uint256 bond = tournament.bondValue();
        vm.roll(
            Time.Instant.unwrap(args.startInstant)
                + Time.Duration.unwrap(args.allowance)
        );

        vm.prank(addrs[1]);
        vm.expectRevert(ITournament.TournamentIsClosed.selector);
        tournament.joinTournament{value: bond}(TWO_STATE, proof, left, right);
    }

    function testAdvanceResponseBudgetDeadlineAndRollback() public {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        uint256 opponent = 1;
        Util.joinTournament(tournament, opponent);
        Match.Id memory matchId = Util.historicalMatchId(opponent, 0);
        Match.IdHash matchIdHash = matchId.hashFromId();
        Match.State memory matchBefore = tournament.getMatch(matchIdHash);
        (Clock.State memory clockOneBefore,) =
            tournament.getCommitment(matchId.commitmentOne);
        (Clock.State memory clockTwoBefore,) =
            tournament.getCommitment(matchId.commitmentTwo);
        uint256 snapshot = vm.snapshotState();
        uint256 deadline = Time.Instant
            .unwrap(clockOneBefore.startInstant.add(clockOneBefore.allowance));
        (,,, uint64 height) = tournament.tournamentLevelConstants();

        vm.roll(deadline - 1);
        tournament.advanceMatch(
            matchId,
            playerNodes[0][height - 1],
            playerNodes[0][height - 1],
            playerNodes[0][height - 2],
            playerNodes[0][height - 2]
        );
        (Clock.State memory clockOneAfter,) =
            tournament.getCommitment(matchId.commitmentOne);
        Match.State memory matchAfter = tournament.getMatch(matchIdHash);
        assertEq(
            Time.Duration.unwrap(clockOneAfter.allowance),
            Time.Duration.unwrap(RESPONSE_BUDGET) + 1
        );
        assertTrue(clockOneAfter.startInstant.isZero());
        assertEq(matchAfter.currentHeight, matchBefore.currentHeight - 1);

        vm.revertToState(snapshot);
        vm.roll(deadline);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        tournament.advanceMatch(
            matchId,
            playerNodes[0][height - 1],
            playerNodes[0][height - 1],
            playerNodes[0][height - 2],
            playerNodes[0][height - 2]
        );
        _assertMatchUnchanged(tournament, matchIdHash, matchBefore);
        _assertClockUnchanged(tournament, matchId.commitmentOne, clockOneBefore);
        _assertClockUnchanged(tournament, matchId.commitmentTwo, clockTwoBefore);
    }

    function testLeafSealResponseBudgetDeadlineAndRollback() public {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        uint256 opponent = 1;
        Util.joinTournament(tournament, opponent);
        Match.Id memory matchId = Util.historicalMatchId(opponent, 0);
        uint256 playerToSeal = Util.advanceMatch(tournament, matchId, opponent);
        Tree.Node responder =
            playerToSeal == 0 ? matchId.commitmentOne : matchId.commitmentTwo;
        Match.IdHash matchIdHash = matchId.hashFromId();
        Match.State memory matchBefore = tournament.getMatch(matchIdHash);
        (Clock.State memory clockOneBefore,) =
            tournament.getCommitment(matchId.commitmentOne);
        (Clock.State memory clockTwoBefore,) =
            tournament.getCommitment(matchId.commitmentTwo);
        Clock.State memory responderBefore =
            playerToSeal == 0 ? clockOneBefore : clockTwoBefore;
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        Tree.Node leftLeaf =
            playerToSeal == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node rightLeaf = playerNodes[playerToSeal][0];
        bytes32[] memory agreeHashProof =
            generateDivergenceProof(playerToSeal, height);
        uint256 snapshot = vm.snapshotState();
        uint256 deadline = Time.Instant
            .unwrap(responderBefore.startInstant.add(responderBefore.allowance));

        vm.roll(deadline - 1);
        Util.sealLeafMatch(tournament, matchId, playerToSeal);
        (Clock.State memory responderAfter,) =
            tournament.getCommitment(responder);
        assertEq(
            Time.Duration.unwrap(responderAfter.allowance),
            Time.Duration.unwrap(RESPONSE_BUDGET) + 1
        );
        assertFalse(responderAfter.startInstant.isZero());
        Match.State memory sealedMatch = tournament.getMatch(matchIdHash);
        assertTrue(sealedMatch.exists());
        assertTrue(sealedMatch.isSealed());

        vm.revertToState(snapshot);
        vm.roll(deadline);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        tournament.sealLeafMatch(
            matchId, leftLeaf, rightLeaf, ONE_STATE, agreeHashProof
        );
        _assertMatchUnchanged(tournament, matchIdHash, matchBefore);
        _assertClockUnchanged(tournament, matchId.commitmentOne, clockOneBefore);
        _assertClockUnchanged(tournament, matchId.commitmentTwo, clockTwoBefore);
    }

    function testInnerSealResponseBudgetDeadlineAndRollback() public {
        ITournament tournament = Util.initializePlayer0Tournament(FACTORY);
        uint256 opponent = 1;
        Util.joinTournament(tournament, opponent);
        Match.Id memory matchId = Util.historicalMatchId(opponent, 0);
        uint256 playerToSeal = Util.advanceMatch(tournament, matchId, opponent);
        Tree.Node responder =
            playerToSeal == 0 ? matchId.commitmentOne : matchId.commitmentTwo;
        Match.IdHash matchIdHash = matchId.hashFromId();
        Match.State memory matchBefore = tournament.getMatch(matchIdHash);
        (Clock.State memory clockOneBefore,) =
            tournament.getCommitment(matchId.commitmentOne);
        (Clock.State memory clockTwoBefore,) =
            tournament.getCommitment(matchId.commitmentTwo);
        Clock.State memory responderBefore =
            playerToSeal == 0 ? clockOneBefore : clockTwoBefore;
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        Tree.Node leftLeaf =
            playerToSeal == 1 ? playerNodes[1][0] : playerNodes[0][0];
        Tree.Node rightLeaf = playerNodes[playerToSeal][0];
        bytes32[] memory agreeHashProof =
            generateDivergenceProof(playerToSeal, height);
        uint256 snapshot = vm.snapshotState();
        uint256 deadline = Time.Instant
            .unwrap(responderBefore.startInstant.add(responderBefore.allowance));

        vm.roll(deadline - 1);
        tournament.sealInnerMatchAndCreateInnerTournament(
            matchId, leftLeaf, rightLeaf, ONE_STATE, agreeHashProof
        );
        (Clock.State memory responderAfter,) =
            tournament.getCommitment(responder);
        assertEq(
            Time.Duration.unwrap(responderAfter.allowance),
            Time.Duration.unwrap(RESPONSE_BUDGET) + 1
        );
        assertTrue(responderAfter.startInstant.isZero());
        Match.State memory sealedMatch = tournament.getMatch(matchIdHash);
        assertTrue(sealedMatch.exists());
        assertTrue(sealedMatch.isSealed());

        vm.revertToState(snapshot);
        vm.roll(deadline);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        tournament.sealInnerMatchAndCreateInnerTournament(
            matchId, leftLeaf, rightLeaf, ONE_STATE, agreeHashProof
        );
        _assertMatchUnchanged(tournament, matchIdHash, matchBefore);
        _assertClockUnchanged(tournament, matchId.commitmentOne, clockOneBefore);
        _assertClockUnchanged(tournament, matchId.commitmentTwo, clockTwoBefore);
    }

    function testInnerSealRejectsNonexistentMatch() public {
        ITournament tournament = Util.initializePlayer0Tournament(FACTORY);
        Util.joinTournament(tournament, 1);
        Match.Id memory existing = Util.historicalMatchId(1, 0);
        Match.Id memory nonexistent = Match.Id({
            commitmentOne: existing.commitmentTwo,
            commitmentTwo: existing.commitmentOne
        });
        assertFalse(tournament.getMatch(nonexistent.hashFromId()).exists());

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.sealInnerMatchAndCreateInnerTournament(
            nonexistent, ONE_NODE, TWO_NODE, ONE_STATE, new bytes32[](0)
        );
    }

    function testInnerResolutionRejectsUnlinkedTournamentBeforeWinnerInvariant()
        public
    {
        ITournament tournament = Util.initializePlayer0Tournament(FACTORY);
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        ITournament unlinked = FACTORY.instantiateInner(
            ONE_STATE,
            ONE_NODE,
            ONE_STATE,
            TWO_NODE,
            TWO_STATE,
            MAX_ALLOWANCE,
            1,
            1,
            args.provider
        );

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.winInnerTournament(unlinked, ONE_NODE, TWO_NODE);
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.eliminateInnerTournament(unlinked);
    }

    function testGetMatchCycleRejectsNonexistentInnerMatch() public {
        ITournament tournament = Util.initializePlayer0Tournament(FACTORY);
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        ITournament inner = FACTORY.instantiateInner(
            ONE_STATE,
            ONE_NODE,
            ONE_STATE,
            TWO_NODE,
            TWO_STATE,
            MAX_ALLOWANCE,
            1234,
            1,
            args.provider
        );
        Match.IdHash nonexistent = Match.Id(ONE_NODE, TWO_NODE).hashFromId();
        assertFalse(inner.getMatch(nonexistent).exists());

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        inner.getMatchCycle(nonexistent);
    }

    function testFuzzLateJoinAndWinnerRePairNeverGainAllowance(uint64 late)
        public
    {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        uint64 initialAllowance = Time.Duration.unwrap(args.allowance);
        late = uint64(bound(late, 1, initialAllowance - 1));
        vm.roll(Time.Instant.unwrap(args.startInstant) + late);

        Util.joinTournament(tournament, 1);
        Util.joinTournament(tournament, 2);
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        Tree.Node rootZero = playerNodes[0][height];
        Tree.Node rootOne = playerNodes[1][height];
        Tree.Node rootTwo = playerNodes[2][height];
        (Clock.State memory clockZeroBefore,) =
            tournament.getCommitment(rootZero);
        (Clock.State memory clockOneBefore,) = tournament.getCommitment(rootOne);
        (Clock.State memory danglingBefore,) = tournament.getCommitment(rootTwo);
        assertEq(
            Time.Duration.unwrap(clockZeroBefore.allowance), initialAllowance
        );
        assertEq(
            Time.Duration.unwrap(clockOneBefore.allowance),
            initialAllowance - late
        );
        assertEq(
            Time.Duration.unwrap(danglingBefore.allowance),
            initialAllowance - late
        );
        assertTrue(danglingBefore.startInstant.isZero());

        Match.Id memory firstMatch = Match.Id(rootZero, rootOne);
        uint256 playerToSeal = Util.advanceMatch(tournament, firstMatch, 1);
        Util.sealLeafMatch(tournament, firstMatch, playerToSeal);
        _mockLeafWinner(tournament, true);
        Util.winLeafMatch(tournament, firstMatch, 0);

        Match.Id memory secondMatch = Match.Id(rootTwo, rootZero);
        assertTrue(tournament.getMatch(secondMatch.hashFromId()).exists());
        (Clock.State memory survivorAfter,) = tournament.getCommitment(rootZero);
        (Clock.State memory danglingAfter,) = tournament.getCommitment(rootTwo);
        assertEq(
            Time.Duration.unwrap(survivorAfter.allowance), initialAllowance
        );
        assertTrue(survivorAfter.startInstant.isZero());
        assertEq(
            Time.Duration.unwrap(danglingAfter.allowance),
            initialAllowance - late
        );
        assertFalse(danglingAfter.startInstant.isZero());
    }

    // function testDuplicateJoinTournament() public {
    //     topTournament = Util.initializePlayer0Tournament(FACTORY);

    //     // duplicate commitment should be reverted
    //     vm.expectRevert("clock is initialized");
    //     Util.joinTournament(topTournament, 0);
    // }

    function testTimeout() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        uint256 _t = vm.getBlockNumber();
        uint256 _tournamentFinishWithMatch =
            _t + Time.Duration.unwrap(MAX_ALLOWANCE);

        // player 1 joins tournament
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.historicalMatchId(_opponent, _height);
        assertFalse(
            topTournament.canWinMatchByTimeout(_matchId),
            "shouldn't be able to win match by timeout"
        );

        // player 1 should win after fast forward time to player 0 timeout
        // player 0 timeout first because he's supposed to advance match first after the match is created
        (Clock.State memory _player0Clock,) = topTournament.getCommitment(
            playerNodes[0][HistoricalGeometry.height(0)]
        );
        vm.roll(
            Time.Instant
                .unwrap(_player0Clock.startInstant.add(_player0Clock.allowance))
        );
        assertTrue(
            topTournament.canWinMatchByTimeout(_matchId),
            "should be able to win match by timeout"
        );
        (Clock.State memory _player1ClockBeforeWin,) = topTournament.getCommitment(
            playerNodes[1][HistoricalGeometry.height(0)]
        );
        assertTrue(_player1ClockBeforeWin.startInstant.isZero());

        uint256 tournamentBalanceBefore = address(topTournament).balance;
        uint256 callerBalanceBefore = player0.balance;
        vm.txGasPrice(2);
        vm.startPrank(player0);
        Util.winMatchByTimeout(
            topTournament,
            _matchId,
            playerNodes[1][HistoricalGeometry.height(0) - 1],
            playerNodes[1][HistoricalGeometry.height(0) - 1]
        );
        vm.stopPrank();
        uint256 tournamentBalanceAfter = address(topTournament).balance;
        uint256 callerBalanceAfter = player0.balance;
        (Clock.State memory _player1ClockAfterWin,) = topTournament.getCommitment(
            playerNodes[1][HistoricalGeometry.height(0)]
        );
        assertTrue(_player1ClockAfterWin.startInstant.isZero());
        assertEq(
            Time.Duration.unwrap(_player1ClockAfterWin.allowance),
            Time.Duration.unwrap(_player1ClockBeforeWin.allowance)
        );

        uint256 bondAmount = topTournament.bondValue();
        assertEq(
            tournamentBalanceBefore,
            2 * bondAmount,
            "tournament balance should be 2 * bond amount initially"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tournament balance should be less than before"
        );
        // The caller receives a positive bounded subsidy in this test setup.
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have received a partial refund"
        );

        vm.roll(_tournamentFinishWithMatch);
        (bool _finished, Tree.Node _winner, Machine.Hash _finalState) =
            topTournament.arbitrationResult();

        uint256 _winnerPlayer = 1;
        assertTrue(
            _winner.eq(
                playerNodes[_winnerPlayer][HistoricalGeometry.height(0)]
            ),
            "winner should be player 1"
        );
        assertTrue(_finished, "tournament should be finished");
        assertTrue(
            _finalState.eq(Util.finalStates[_winnerPlayer]),
            "final state should match"
        );

        topTournament = Util.initializePlayer0Tournament(FACTORY);
        _t = vm.getBlockNumber();

        _tournamentFinishWithMatch = _t + Time.Duration.unwrap(MAX_ALLOWANCE);

        // player 1 joins tournament
        Util.joinTournament(topTournament, _opponent);

        // player 0 should win after fast forward time to player 1 timeout
        // player 1 timeout first because he's supposed to advance match after player 0 advanced
        _matchId = Util.historicalMatchId(_opponent, _height);

        callerBalanceBefore = address(this).balance;
        tournamentBalanceBefore = address(topTournament).balance;
        topTournament.advanceMatch(
            _matchId,
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[0][HistoricalGeometry.height(0) - 2],
            playerNodes[0][HistoricalGeometry.height(0) - 2]
        );
        callerBalanceAfter = address(this).balance;
        tournamentBalanceAfter = address(topTournament).balance;
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have received a partial refund"
        );
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tournament should have funded the partial refund"
        );
        (Clock.State memory _player0ClockBeforeWin,) = topTournament.getCommitment(
            playerNodes[0][HistoricalGeometry.height(0)]
        );
        assertTrue(_player0ClockBeforeWin.startInstant.isZero());

        (Clock.State memory _player1Clock,) = topTournament.getCommitment(
            playerNodes[1][HistoricalGeometry.height(0)]
        );
        vm.roll(
            Time.Instant
                .unwrap(_player1Clock.startInstant.add(_player1Clock.allowance))
        );
        assertTrue(
            topTournament.canWinMatchByTimeout(_matchId),
            "should be able to win match by timeout"
        );

        Util.winMatchByTimeout(
            topTournament,
            _matchId,
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[0][HistoricalGeometry.height(0) - 1]
        );
        (Clock.State memory _player0ClockAfterWin,) = topTournament.getCommitment(
            playerNodes[0][HistoricalGeometry.height(0)]
        );
        assertTrue(_player0ClockAfterWin.startInstant.isZero());
        assertEq(
            Time.Duration.unwrap(_player0ClockAfterWin.allowance),
            Time.Duration.unwrap(_player0ClockBeforeWin.allowance)
        );

        vm.roll(_tournamentFinishWithMatch);
        (_finished, _winner, _finalState) = topTournament.arbitrationResult();

        _winnerPlayer = 0;
        assertTrue(
            _winner.eq(
                playerNodes[_winnerPlayer][HistoricalGeometry.height(0)]
            ),
            "winner should be player 0"
        );
        assertTrue(_finished, "tournament should be finished");
        assertTrue(
            _finalState.eq(Util.finalStates[_winnerPlayer]),
            "final state should match"
        );
    }

    function testActiveTimeoutChargesPausedWinnerForOverdueInterval() public {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        uint256 opponent = 1;
        Util.joinTournament(tournament, opponent);

        uint64 height = HistoricalGeometry.height(0);
        Match.Id memory matchId = Util.historicalMatchId(opponent, 0);
        (Clock.State memory runningLoser,) =
            tournament.getCommitment(playerNodes[0][height]);
        (Clock.State memory pausedWinnerBefore,) =
            tournament.getCommitment(playerNodes[1][height]);
        assertTrue(pausedWinnerBefore.startInstant.isZero());

        uint256 overdue = 17;
        vm.roll(
            Time.Instant
                .unwrap(runningLoser.startInstant.add(runningLoser.allowance))
            + overdue
        );

        assertTrue(tournament.canWinMatchByTimeout(matchId));
        Util.winMatchByTimeout(
            tournament,
            matchId,
            playerNodes[1][height - 1],
            playerNodes[1][height - 1]
        );

        (Clock.State memory pausedWinnerAfter,) =
            tournament.getCommitment(playerNodes[1][height]);
        assertTrue(pausedWinnerAfter.startInstant.isZero());
        assertEq(
            Time.Duration.unwrap(pausedWinnerAfter.allowance),
            Time.Duration.unwrap(pausedWinnerBefore.allowance) - overdue
        );
    }

    function testTimeoutCapabilityRejectsNonexistentAndDeletedMatches() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);
        uint256 opponent = 1;
        Util.joinTournament(topTournament, opponent);

        Match.Id memory matchId = Util.historicalMatchId(opponent, 0);
        Match.Id memory reversedId = Match.Id({
            commitmentOne: matchId.commitmentTwo,
            commitmentTwo: matchId.commitmentOne
        });
        assertTrue(topTournament.getMatch(matchId.hashFromId()).exists());
        assertFalse(topTournament.getMatch(reversedId.hashFromId()).exists());

        (Clock.State memory clockOne,) =
            topTournament.getCommitment(matchId.commitmentOne);
        vm.roll(
            Time.Instant.unwrap(clockOne.startInstant.add(clockOne.allowance))
        );

        assertTrue(topTournament.canWinMatchByTimeout(matchId));
        assertFalse(topTournament.canWinMatchByTimeout(reversedId));

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        topTournament.winMatchByTimeout(
            reversedId, Tree.Node.wrap(bytes32(0)), Tree.Node.wrap(bytes32(0))
        );
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        topTournament.eliminateMatchByTimeout(reversedId);

        Util.winMatchByTimeout(
            topTournament,
            matchId,
            playerNodes[opponent][HistoricalGeometry.height(0) - 1],
            playerNodes[opponent][HistoricalGeometry.height(0) - 1]
        );
        assertFalse(topTournament.canWinMatchByTimeout(matchId));
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        topTournament.getMatchCycle(matchId.hashFromId());
    }

    function testWinLeafMatchRejectsInvalidIdsBeforeClockInvariants() public {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        uint256 opponent = 1;
        Util.joinTournament(tournament, opponent);
        Match.Id memory matchId = Util.historicalMatchId(opponent, 0);
        // Keep a dangling commitment available so resolution creates another
        // match and the tournament-level finished guard does not mask the
        // deleted-match error below.
        Util.joinTournament(tournament, 2);
        Match.Id memory reversedId = Match.Id({
            commitmentOne: matchId.commitmentTwo,
            commitmentTwo: matchId.commitmentOne
        });
        Match.Id memory unknownId = Match.Id({
            commitmentOne: Tree.Node.wrap(bytes32(uint256(0xdead))),
            commitmentTwo: Tree.Node.wrap(bytes32(uint256(0xbeef)))
        });

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.winLeafMatch(
            unknownId, Tree.ZERO_NODE, Tree.ZERO_NODE, bytes("")
        );

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.winLeafMatch(
            reversedId, Tree.ZERO_NODE, Tree.ZERO_NODE, bytes("")
        );

        (Clock.State memory clockOne,) =
            tournament.getCommitment(matchId.commitmentOne);
        vm.roll(
            Time.Instant.unwrap(clockOne.startInstant.add(clockOne.allowance))
        );
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        Util.winMatchByTimeout(
            tournament,
            matchId,
            playerNodes[opponent][height - 1],
            playerNodes[opponent][height - 1]
        );

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        tournament.winLeafMatch(
            matchId, Tree.ZERO_NODE, Tree.ZERO_NODE, bytes("")
        );
    }

    function testEliminateByTimeout() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        // pair commitment, expect a match
        // player 1 joins tournament
        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.historicalMatchId(_opponent, _height);
        Match.State memory _match =
            topTournament.getMatch(_matchId.hashFromId());
        assertTrue(_match.exists(), "match should exist");

        uint256 _t = vm.getBlockNumber();
        // the delay is increased when a match is created
        uint256 _rootTournamentFinish =
            _t + 2 * Time.Duration.unwrap(MAX_ALLOWANCE);

        vm.roll(_rootTournamentFinish - 1);
        // The running clock is overdue, but the paused side can survive the
        // charge by one block and therefore still wins by timeout.
        assertTrue(topTournament.canWinMatchByTimeout(_matchId));
        vm.expectRevert(ITournament.MatchCannotBeEliminatedByTimeout.selector);
        topTournament.eliminateMatchByTimeout(_matchId);

        vm.roll(_rootTournamentFinish);
        assertFalse(topTournament.canWinMatchByTimeout(_matchId));
        vm.expectRevert(ITournament.MatchCannotBeWonByTimeout.selector);
        topTournament.winMatchByTimeout(
            _matchId, Tree.Node.wrap(bytes32(0)), Tree.Node.wrap(bytes32(0))
        );

        uint256 tournamentBalanceBefore = address(topTournament).balance;
        uint256 callerBalanceBefore = address(this).balance;
        vm.txGasPrice(2);
        Util.eliminateMatchByTimeout(topTournament, _matchId);
        uint256 tournamentBalanceAfter = address(topTournament).balance;
        uint256 callerBalanceAfter = address(this).balance;

        uint256 bondAmount = topTournament.bondValue();
        assertEq(tournamentBalanceBefore, 2 * bondAmount);
        assertLt(
            tournamentBalanceAfter,
            tournamentBalanceBefore,
            "tournament should have funded the partial refund"
        );
        assertGt(
            callerBalanceAfter,
            callerBalanceBefore,
            "caller should have received a partial refund"
        );
    }

    function testSealedLeafTimeoutDoesNotChargeRunningWinnerTwice() public {
        uint64 allowanceGap = 10;
        SealedLeafFixture memory fixture =
            _createAsymmetricSealedLeaf(true, allowanceGap);

        uint64 shortAllowance = Time.Duration.unwrap(fixture.clockOne.allowance);
        uint64 resolutionElapsed = shortAllowance + allowanceGap / 2 - 1;
        vm.roll(
            Time.Instant.unwrap(fixture.clockOne.startInstant)
                + resolutionElapsed
        );

        uint64 winnerRemaining = Time.Duration
            .unwrap(fixture.clockTwo.allowance) - resolutionElapsed;
        Tree.Node winnerChild = _winnerChild(fixture.tournament, true);

        vm.expectRevert(ITournament.MatchCannotBeEliminatedByTimeout.selector);
        fixture.tournament.eliminateMatchByTimeout(fixture.matchId);

        Util.winMatchByTimeout(
            fixture.tournament, fixture.matchId, winnerChild, winnerChild
        );

        (Clock.State memory winnerClock,) =
            fixture.tournament.getCommitment(fixture.matchId.commitmentTwo);
        assertTrue(winnerClock.startInstant.isZero());
        assertEq(Time.Duration.unwrap(winnerClock.allowance), winnerRemaining);
    }

    function testSealedLeafTimeoutEliminatesAtLongClockDeadline() public {
        uint64 allowanceGap = 10;
        SealedLeafFixture memory fixture =
            _createAsymmetricSealedLeaf(true, allowanceGap);

        uint64 longAllowance = Time.Duration.unwrap(fixture.clockTwo.allowance);
        uint64 resolutionElapsed = longAllowance - 1;
        vm.roll(
            Time.Instant.unwrap(fixture.clockOne.startInstant)
                + resolutionElapsed
        );

        Tree.Node winnerChild = _winnerChild(fixture.tournament, true);
        _mockLeafWinner(fixture.tournament, false);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        fixture.tournament
            .winLeafMatch(
                fixture.matchId, winnerChild, winnerChild, new bytes(0)
            );
        assertTrue(fixture.tournament.canWinMatchByTimeout(fixture.matchId));
        vm.expectRevert(ITournament.MatchCannotBeEliminatedByTimeout.selector);
        fixture.tournament.eliminateMatchByTimeout(fixture.matchId);
        Util.winMatchByTimeout(
            fixture.tournament, fixture.matchId, winnerChild, winnerChild
        );

        fixture = _createAsymmetricSealedLeaf(true, allowanceGap);
        longAllowance = Time.Duration.unwrap(fixture.clockTwo.allowance);
        resolutionElapsed = longAllowance;
        vm.roll(
            Time.Instant.unwrap(fixture.clockOne.startInstant)
                + resolutionElapsed
        );

        winnerChild = _winnerChild(fixture.tournament, true);
        assertFalse(fixture.tournament.canWinMatchByTimeout(fixture.matchId));
        vm.expectRevert(ITournament.MatchCannotBeWonByTimeout.selector);
        fixture.tournament
            .winMatchByTimeout(fixture.matchId, winnerChild, winnerChild);
        Util.eliminateMatchByTimeout(fixture.tournament, fixture.matchId);
    }

    function testFuzzLeafProofYieldsToTimeout(
        bool commitmentOneIsShorter,
        uint64 allowanceGap,
        uint64 resolutionElapsed
    ) public {
        allowanceGap = uint64(
            bound(
                allowanceGap,
                1,
                Time.Duration.unwrap(MAX_ALLOWANCE)
                    - Time.Duration.unwrap(RESPONSE_BUDGET) - 1
            )
        );
        SealedLeafFixture memory fixture =
            _createAsymmetricSealedLeaf(commitmentOneIsShorter, allowanceGap);

        uint64 shortAllowance = commitmentOneIsShorter
            ? Time.Duration.unwrap(fixture.clockOne.allowance)
            : Time.Duration.unwrap(fixture.clockTwo.allowance);
        uint64 longAllowance = commitmentOneIsShorter
            ? Time.Duration.unwrap(fixture.clockTwo.allowance)
            : Time.Duration.unwrap(fixture.clockOne.allowance);
        resolutionElapsed =
            uint64(bound(resolutionElapsed, shortAllowance, longAllowance - 1));
        Time.Instant current = Time.Instant
            .wrap(
                Time.Instant.unwrap(fixture.clockOne.startInstant)
                    + resolutionElapsed
            );
        vm.roll(Time.Instant.unwrap(current));

        bool winnerIsOne = !commitmentOneIsShorter;
        Tree.Node winnerChild =
            _commitmentChild(fixture.tournament, winnerIsOne);
        Tree.Node winnerCommitment = winnerIsOne
            ? fixture.matchId.commitmentOne
            : fixture.matchId.commitmentTwo;
        uint64 winnerRemaining = longAllowance - resolutionElapsed;
        MatchClocks.TimeoutStatus memory timeout = MatchClocks.classifyTimeoutAt(
            fixture.clockOne, fixture.clockTwo, current
        );
        assertEq(
            uint8(timeout.outcome),
            uint8(
                winnerIsOne
                    ? MatchClocks.TimeoutOutcome.ONE_WINS
                    : MatchClocks.TimeoutOutcome.TWO_WINS
            )
        );
        assertEq(Time.Duration.unwrap(timeout.deferredCharge), 0);

        bool loserIsOne = !winnerIsOne;
        Tree.Node loserChild = _commitmentChild(fixture.tournament, loserIsOne);
        _mockLeafWinner(fixture.tournament, loserIsOne);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        fixture.tournament
            .winLeafMatch(fixture.matchId, loserChild, loserChild, new bytes(0));

        _mockLeafWinner(fixture.tournament, winnerIsOne);
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        fixture.tournament
            .winLeafMatch(
                fixture.matchId, winnerChild, winnerChild, new bytes(0)
            );
        assertTrue(
            fixture.tournament.getMatch(fixture.matchId.hashFromId()).exists()
        );
        _assertClockUnchanged(
            fixture.tournament, fixture.matchId.commitmentOne, fixture.clockOne
        );
        _assertClockUnchanged(
            fixture.tournament, fixture.matchId.commitmentTwo, fixture.clockTwo
        );

        Util.winMatchByTimeout(
            fixture.tournament, fixture.matchId, winnerChild, winnerChild
        );
        _assertResolvedWinner(
            fixture.tournament,
            fixture.matchId,
            winnerCommitment,
            winnerRemaining
        );
    }

    function testFuzzSealedLeafTimeoutPartition(
        bool commitmentOneIsShorter,
        uint64 allowanceGap,
        uint64 resolutionElapsed
    ) public {
        allowanceGap = uint64(
            bound(
                allowanceGap,
                1,
                Time.Duration.unwrap(MAX_ALLOWANCE)
                    - Time.Duration.unwrap(RESPONSE_BUDGET) - 1
            )
        );
        SealedLeafFixture memory fixture =
            _createAsymmetricSealedLeaf(commitmentOneIsShorter, allowanceGap);

        uint64 shortAllowance = commitmentOneIsShorter
            ? Time.Duration.unwrap(fixture.clockOne.allowance)
            : Time.Duration.unwrap(fixture.clockTwo.allowance);
        uint64 longAllowance = commitmentOneIsShorter
            ? Time.Duration.unwrap(fixture.clockTwo.allowance)
            : Time.Duration.unwrap(fixture.clockOne.allowance);
        resolutionElapsed =
            uint64(bound(resolutionElapsed, shortAllowance, longAllowance));
        vm.roll(
            Time.Instant.unwrap(fixture.clockOne.startInstant)
                + resolutionElapsed
        );

        uint64 winnerRemaining = longAllowance - resolutionElapsed;
        Tree.Node winnerChild =
            _winnerChild(fixture.tournament, commitmentOneIsShorter);
        assertEq(
            fixture.tournament.canWinMatchByTimeout(fixture.matchId),
            winnerRemaining > 0
        );

        if (winnerRemaining > 0) {
            vm.expectRevert(
                ITournament.MatchCannotBeEliminatedByTimeout.selector
            );
            fixture.tournament.eliminateMatchByTimeout(fixture.matchId);

            Util.winMatchByTimeout(
                fixture.tournament, fixture.matchId, winnerChild, winnerChild
            );

            Tree.Node winnerCommitment = commitmentOneIsShorter
                ? fixture.matchId.commitmentTwo
                : fixture.matchId.commitmentOne;
            (Clock.State memory winnerClock,) =
                fixture.tournament.getCommitment(winnerCommitment);
            assertTrue(winnerClock.startInstant.isZero());
            assertEq(
                Time.Duration.unwrap(winnerClock.allowance), winnerRemaining
            );
        } else {
            vm.expectRevert(ITournament.MatchCannotBeWonByTimeout.selector);
            fixture.tournament
                .winMatchByTimeout(fixture.matchId, winnerChild, winnerChild);
            Util.eliminateMatchByTimeout(fixture.tournament, fixture.matchId);
        }
    }

    function testSacrificialLeafCannotAmplifyCensorshipIntoDanglingWinner()
        public
    {
        ITournament tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        uint64 maximumAllowance = Time.Duration.unwrap(args.allowance);
        uint64 responseBudget = Time.Duration.unwrap(args.responseBudget);
        uint64 sacrificialAllowance = responseBudget + 1;

        vm.roll(
            Time.Instant.unwrap(args.startInstant) + maximumAllowance
                - sacrificialAllowance
        );
        Util.joinTournament(tournament, 1);
        Util.joinTournament(tournament, 2);

        Match.Id memory firstMatch = Util.historicalMatchId(1, 0);
        uint256 playerToSeal = Util.advanceMatch(tournament, firstMatch, 1);
        Util.sealLeafMatch(tournament, firstMatch, playerToSeal);

        (Clock.State memory honestClock,) =
            tournament.getCommitment(firstMatch.commitmentOne);
        (Clock.State memory sacrificialClock,) =
            tournament.getCommitment(firstMatch.commitmentTwo);
        assertEq(Time.Duration.unwrap(honestClock.allowance), maximumAllowance);
        assertEq(
            Time.Duration.unwrap(sacrificialClock.allowance),
            sacrificialAllowance
        );

        uint64 oldDoubleEliminationBoundary =
            (maximumAllowance + sacrificialAllowance + 1) / 2;
        assertLt(
            oldDoubleEliminationBoundary,
            Time.Duration.unwrap(CENSORSHIP_TOLERANCE)
        );
        vm.roll(
            Time.Instant.unwrap(honestClock.startInstant)
                + oldDoubleEliminationBoundary
        );

        assertTrue(tournament.canWinMatchByTimeout(firstMatch));
        vm.expectRevert(ITournament.MatchCannotBeEliminatedByTimeout.selector);
        tournament.eliminateMatchByTimeout(firstMatch);

        (,,, uint64 height) = tournament.tournamentLevelConstants();
        Tree.Node honestChild = playerNodes[0][height - 1];
        Util.winMatchByTimeout(tournament, firstMatch, honestChild, honestChild);

        Match.Id memory secondMatch = Match.Id({
            commitmentOne: playerNodes[2][height],
            commitmentTwo: playerNodes[0][height]
        });
        assertTrue(tournament.getMatch(secondMatch.hashFromId()).exists());

        (Clock.State memory nextAttackerClock,) =
            tournament.getCommitment(secondMatch.commitmentOne);
        vm.roll(
            Time.Instant
                .unwrap(
                    nextAttackerClock.startInstant
                    .add(nextAttackerClock.allowance)
                )
        );
        Util.winMatchByTimeout(
            tournament, secondMatch, honestChild, honestChild
        );

        _assertResolvedWinner(
            tournament,
            secondMatch,
            secondMatch.commitmentTwo,
            maximumAllowance - oldDoubleEliminationBoundary
        );
    }

    function testWinByTimeoutWrongChildrenReverts() public {
        topTournament = Util.initializePlayer0Tournament(FACTORY);

        uint256 _opponent = 1;
        uint64 _height = 0;
        Util.joinTournament(topTournament, _opponent);

        Match.Id memory _matchId = Util.historicalMatchId(_opponent, _height);

        // Let commitmentOne time out (player 0), then attempt with wrong children
        (Clock.State memory _player0Clock,) = topTournament.getCommitment(
            playerNodes[0][HistoricalGeometry.height(0)]
        );
        vm.roll(
            Time.Instant
                .unwrap(_player0Clock.startInstant.add(_player0Clock.allowance))
        );

        vm.expectRevert();
        topTournament.winMatchByTimeout(
            _matchId,
            // wrong child nodes for commitmentTwo
            playerNodes[0][HistoricalGeometry.height(0) - 1],
            playerNodes[0][HistoricalGeometry.height(0) - 1]
        );

        // Correct children should succeed
        Util.winMatchByTimeout(
            topTournament,
            _matchId,
            playerNodes[1][HistoricalGeometry.height(0) - 1],
            playerNodes[1][HistoricalGeometry.height(0) - 1]
        );
    }

    function _createAsymmetricSealedLeaf(
        bool commitmentOneIsShorter,
        uint64 allowanceGap
    ) private returns (SealedLeafFixture memory fixture) {
        fixture.tournament =
            Util.initializePlayer0Tournament(SINGLE_LEVEL_FACTORY);
        uint256 opponent = 1;
        if (!commitmentOneIsShorter) {
            vm.roll(vm.getBlockNumber() + allowanceGap);
        }
        Util.joinTournament(fixture.tournament, opponent);
        fixture.matchId = Util.historicalMatchId(opponent, 0);

        if (commitmentOneIsShorter) {
            vm.roll(
                vm.getBlockNumber() + Time.Duration.unwrap(RESPONSE_BUDGET)
                    + allowanceGap
            );
        }

        uint256 playerToSeal =
            Util.advanceMatch(fixture.tournament, fixture.matchId, opponent);

        Util.sealLeafMatch(fixture.tournament, fixture.matchId, playerToSeal);
        (fixture.clockOne,) =
            fixture.tournament.getCommitment(fixture.matchId.commitmentOne);
        (fixture.clockTwo,) =
            fixture.tournament.getCommitment(fixture.matchId.commitmentTwo);

        assertFalse(fixture.clockOne.startInstant.isZero());
        assertEq(
            Time.Instant.unwrap(fixture.clockOne.startInstant),
            Time.Instant.unwrap(fixture.clockTwo.startInstant)
        );

        uint64 allowanceOne = Time.Duration.unwrap(fixture.clockOne.allowance);
        uint64 allowanceTwo = Time.Duration.unwrap(fixture.clockTwo.allowance);
        if (commitmentOneIsShorter) {
            assertEq(allowanceTwo - allowanceOne, allowanceGap);
        } else {
            assertEq(allowanceOne - allowanceTwo, allowanceGap);
        }
    }

    function _winnerChild(ITournament tournament, bool commitmentOneIsShorter)
        private
        view
        returns (Tree.Node)
    {
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        uint256 winnerPlayer = commitmentOneIsShorter ? 1 : 0;
        return playerNodes[winnerPlayer][height - 1];
    }

    function _commitmentChild(ITournament tournament, bool commitmentOne)
        private
        view
        returns (Tree.Node)
    {
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        return playerNodes[commitmentOne ? 0 : 1][height - 1];
    }

    function _mockLeafWinner(ITournament tournament, bool commitmentOne)
        private
    {
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        Machine.Hash finalState = commitmentOne ? ONE_STATE : TWO_STATE;
        vm.mockCall(
            address(args.stateTransition),
            abi.encode(IStateTransition.transitionState.selector),
            abi.encode(Machine.Hash.unwrap(finalState))
        );
    }

    function _assertResolvedWinner(
        ITournament tournament,
        Match.Id memory matchId,
        Tree.Node winner,
        uint64 expectedAllowance
    ) private view {
        assertFalse(tournament.getMatch(matchId.hashFromId()).exists());
        (Clock.State memory clock,) = tournament.getCommitment(winner);
        assertTrue(clock.startInstant.isZero());
        assertEq(Time.Duration.unwrap(clock.allowance), expectedAllowance);
        (bool finished, Tree.Node actualWinner,) =
            tournament.arbitrationResult();
        assertTrue(finished);
        assertTrue(actualWinner.eq(winner));
    }

    function _assertClockUnchanged(
        ITournament tournament,
        Tree.Node commitment,
        Clock.State memory expected
    ) private view {
        (Clock.State memory actual,) = tournament.getCommitment(commitment);
        assertEq(
            Time.Duration.unwrap(actual.allowance),
            Time.Duration.unwrap(expected.allowance)
        );
        assertEq(
            Time.Instant.unwrap(actual.startInstant),
            Time.Instant.unwrap(expected.startInstant)
        );
    }

    function _assertMatchUnchanged(
        ITournament tournament,
        Match.IdHash matchId,
        Match.State memory expected
    ) private view {
        Match.State memory actual = tournament.getMatch(matchId);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
    }
}
