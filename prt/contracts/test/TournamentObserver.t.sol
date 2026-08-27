// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";
import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Commitment} from "src/tournament/libs/Commitment.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

contract TournamentObserverHarness is Tournament {
    function storeMatch(Match.IdHash matchIdHash, Match.State calldata state)
        external
    {
        matches[matchIdHash] = state;
    }

    function clearMatch(Match.IdHash matchIdHash) external {
        delete matches[matchIdHash];
    }

    function storeClock(Tree.Node commitment, Clock.State calldata state)
        external
    {
        clocks[commitment] = state;
    }

    function storeFinalState(Tree.Node commitment, Machine.Hash finalState)
        external
    {
        finalStates[commitment] = finalState;
    }

    function storeTopology(
        Tree.Node candidate,
        uint256 activeMatchCount,
        Time.Instant mostRecentDeletion
    ) external {
        danglingCommitment = candidate;
        matchCount = activeMatchCount;
        lastMatchDeleted = mostRecentDeletion;
    }
}

contract TournamentObserverTest is Test {
    using Clones for address;
    using Match for Match.Id;
    using Tree for Tree.Node;

    TournamentObserverHarness internal immutable IMPLEMENTATION;

    constructor() {
        IMPLEMENTATION = new TournamentObserverHarness();
    }

    function testPhaseProjectionCrossProductAndCanonicalZeros() public {
        TournamentObserverHarness tournament = _newTournament(
            0, ITournament.TournamentKind.LEAF, 2, 3, 100, _zeroNestedDispute()
        );
        Match.Id memory matchId = _matchId();
        Match.IdHash matchIdHash = matchId.hashFromId();

        _assertProjectionCrossProduct(
            tournament,
            matchIdHash,
            Match.State({
                otherParent: Tree.ZERO_NODE,
                leftNode: Tree.ZERO_NODE,
                rightNode: Tree.ZERO_NODE,
                runningLeafPosition: 0,
                currentHeight: 0,
                isInit: false
            }),
            Match.Phase.UNINITIALIZED
        );
        _assertProjectionCrossProduct(
            tournament, matchIdHash, _activeState(2, 4), Match.Phase.BISECTING
        );
        _assertProjectionCrossProduct(
            tournament,
            matchIdHash,
            _activeState(1, 6),
            Match.Phase.READY_TO_SEAL
        );
        _assertProjectionCrossProduct(
            tournament, matchIdHash, _sealedState(0), Match.Phase.SEALED
        );
    }

    function testAbsentAndDeletedMatchObservationsAreIdentical() public {
        TournamentObserverHarness tournament = _newLeafTournament();
        Match.Id memory matchId = _matchId();
        Match.IdHash matchIdHash = matchId.hashFromId();

        _assertAbsentObservation(tournament, matchId, matchIdHash);
        tournament.storeClock(matchId.commitmentOne, _runningClock(7, 31));
        tournament.storeClock(matchId.commitmentTwo, _runningClock(9, 47));
        tournament.storeMatch(matchIdHash, _activeState(1, 0));
        tournament.clearMatch(matchIdHash);
        _assertAbsentObservation(tournament, matchId, matchIdHash);
    }

    function testResponderParityForEvenAndOddTotalHeights() public {
        _assertResponderParity(2);
        _assertResponderParity(3);
    }

    function testSealedProjectionIsCanonicalForEveryHeightAndPositionParity()
        public
    {
        for (uint64 totalHeight = 2; totalHeight <= 3; ++totalHeight) {
            _assertSealedOrientation(totalHeight, 0);
            _assertSealedOrientation(totalHeight, 1);
        }
    }

    function testSealedProjectionUsesPositionWhenChildHashesAreEqual() public {
        TournamentObserverHarness tournament = _newTournament(
            0, ITournament.TournamentKind.LEAF, 2, 3, 100, _zeroNestedDispute()
        );
        Tree.Node child = _node(0xd1);
        Match.IdHash matchIdHash = _matchId().hashFromId();
        tournament.storeMatch(
            matchIdHash,
            Match.State({
                otherParent: _node(0xa0),
                leftNode: child,
                rightNode: child,
                runningLeafPosition: 1,
                currentHeight: 0,
                isInit: true
            })
        );

        (Match.Phase phase, ITournament.SealedMatchView memory value) =
            tournament.sealedMatch(matchIdHash);
        assertEq(uint8(phase), uint8(Match.Phase.SEALED));
        assertEq(value.divergencePosition, 1);
        assertEq(value.divergenceCycle, 104);
        assertEq(
            Machine.Hash.unwrap(value.finalStateOne), Tree.Node.unwrap(child)
        );
        assertEq(
            Machine.Hash.unwrap(value.finalStateTwo), Tree.Node.unwrap(child)
        );
    }

    function testBisectionTimeoutBoundariesWhenOneRuns() public {
        _assertBisectionTimeoutBoundaries(true);
    }

    function testBisectionTimeoutBoundariesWhenTwoRuns() public {
        _assertBisectionTimeoutBoundaries(false);
    }

    function testReadyToSealTimeoutUsesSameClassifier() public {
        TournamentObserverHarness tournament = _newLeafTournament();
        Match.Id memory matchId = _matchId();
        tournament.storeMatch(matchId.hashFromId(), _activeState(1, 0));
        tournament.storeClock(matchId.commitmentOne, _runningClock(5, 100));
        tournament.storeClock(matchId.commitmentTwo, _pausedClock(10));

        _assertTimeout(
            tournament,
            matchId,
            105,
            Match.Phase.READY_TO_SEAL,
            ITournament.MatchTimeoutOutcome.TWO_WINS,
            0
        );
        _assertTimeout(
            tournament,
            matchId,
            106,
            Match.Phase.READY_TO_SEAL,
            ITournament.MatchTimeoutOutcome.TWO_WINS,
            1
        );
    }

    function testSealedLeafTimeoutBoundariesWhenOneIsShorter() public {
        _assertLeafTimeoutBoundaries(true);
    }

    function testSealedLeafTimeoutBoundariesWhenTwoIsShorter() public {
        _assertLeafTimeoutBoundaries(false);
    }

    function testEqualLeafAllowancesEliminateAtExactCommonDeadline() public {
        TournamentObserverHarness tournament = _newLeafTournament();
        Match.Id memory matchId = _matchId();
        tournament.storeMatch(matchId.hashFromId(), _sealedState(0));
        tournament.storeClock(matchId.commitmentOne, _runningClock(10, 100));
        tournament.storeClock(matchId.commitmentTwo, _runningClock(10, 100));

        _assertTimeout(
            tournament,
            matchId,
            109,
            Match.Phase.SEALED,
            ITournament.MatchTimeoutOutcome.NONE,
            0
        );
        _assertTimeout(
            tournament,
            matchId,
            110,
            Match.Phase.SEALED,
            ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH,
            0
        );
    }

    function testSealedNonLeafTimeoutIsNoneWithPausedClocks() public {
        TournamentObserverHarness tournament = _newTournament(
            0,
            ITournament.TournamentKind.NON_LEAF,
            0,
            3,
            0,
            _zeroNestedDispute()
        );
        Match.Id memory matchId = _matchId();
        tournament.storeMatch(matchId.hashFromId(), _sealedState(0));
        tournament.storeClock(matchId.commitmentOne, _pausedClock(10));
        tournament.storeClock(matchId.commitmentTwo, _pausedClock(20));

        _assertTimeout(
            tournament,
            matchId,
            100,
            Match.Phase.SEALED,
            ITournament.MatchTimeoutOutcome.NONE,
            0
        );
    }

    function testDescriptorOwnsLevelGeometryAndBaseCycle() public {
        _assertDescriptor(0, ITournament.TournamentKind.LEAF, 0, 3, 0);
        _assertDescriptor(0, ITournament.TournamentKind.NON_LEAF, 4, 5, 100);
        _assertDescriptor(1, ITournament.TournamentKind.NON_LEAF, 2, 2, 300);
        _assertDescriptor(2, ITournament.TournamentKind.LEAF, 0, 2, 312);
    }

    function testStandingMatchesActiveWhileOpen() public {
        TournamentObserverHarness tournament = _standingTournament();
        Tree.Node candidate = _node(0xc1);
        tournament.storeTopology(candidate, 2, _instant(0));
        vm.roll(110);

        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.MATCHES_ACTIVE,
                acceptsJoins: true,
                hasCandidate: true,
                candidate: candidate,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: Time.ZERO_INSTANT
            })
        );
    }

    function testStandingMatchesActiveAfterClosureRejectsJoins() public {
        TournamentObserverHarness tournament = _standingTournament();
        tournament.storeTopology(Tree.ZERO_NODE, 1, _instant(0));
        vm.roll(120);

        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.MATCHES_ACTIVE,
                acceptsJoins: false,
                hasCandidate: false,
                candidate: Tree.ZERO_NODE,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: Time.ZERO_INSTANT
            })
        );
    }

    function testStandingAwaitsClosureWithCurrentCandidate() public {
        TournamentObserverHarness tournament = _standingTournament();
        Tree.Node candidate = _node(0xc2);
        tournament.storeTopology(candidate, 0, _instant(105));
        vm.roll(119);

        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.AWAITING_CLOSURE,
                acceptsJoins: true,
                hasCandidate: true,
                candidate: candidate,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: Time.ZERO_INSTANT
            })
        );
    }

    function testRealJoinSupersedesAwaitingClosureWithActiveMatch() public {
        TournamentObserverHarness tournament = _standingTournament();
        uint256 bond = tournament.bondValue();
        vm.deal(address(this), bond * 2);
        vm.roll(110);

        Tree.Node first = _joinUniformCommitment(tournament, _hash(0xe1), bond);
        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.AWAITING_CLOSURE,
                acceptsJoins: true,
                hasCandidate: true,
                candidate: first,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: Time.ZERO_INSTANT
            })
        );

        _joinUniformCommitment(tournament, _hash(0xe2), bond);
        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.MATCHES_ACTIVE,
                acceptsJoins: true,
                hasCandidate: false,
                candidate: Tree.ZERO_NODE,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: Time.ZERO_INSTANT
            })
        );
    }

    function testStandingReturnsRootWinnerAndFailure() public {
        TournamentObserverHarness tournament = _standingTournament();
        Tree.Node candidate = _node(0xc3);
        Machine.Hash finalState = _hash(0xf3);
        tournament.storeTopology(candidate, 0, _instant(105));
        tournament.storeFinalState(candidate, finalState);
        vm.roll(120);

        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.ROOT_WINNER,
                acceptsJoins: false,
                hasCandidate: true,
                candidate: candidate,
                finalState: finalState,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: _instant(120)
            })
        );

        tournament.storeTopology(Tree.ZERO_NODE, 0, _instant(105));
        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.ROOT_FAILED,
                acceptsJoins: false,
                hasCandidate: false,
                candidate: Tree.ZERO_NODE,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: _instant(120)
            })
        );
    }

    function testStandingMapsInnerWinnerByBothFinalStateOrientations() public {
        Tree.Node parentOne = _node(0xa1);
        Tree.Node parentTwo = _node(0xa2);
        Machine.Hash finalOne = _hash(0xb1);
        Machine.Hash finalTwo = _hash(0xb2);
        ITournament.NestedDispute memory nested = ITournament.NestedDispute({
            contestedCommitmentOne: parentOne,
            contestedFinalStateOne: finalOne,
            contestedCommitmentTwo: parentTwo,
            contestedFinalStateTwo: finalTwo
        });
        TournamentObserverHarness tournament =
            _newTournament(1, ITournament.TournamentKind.LEAF, 0, 3, 0, nested);
        Tree.Node candidate = _node(0xc4);
        tournament.storeTopology(candidate, 0, _instant(125));
        tournament.storeClock(candidate, _pausedClock(10));
        vm.roll(134);

        tournament.storeFinalState(candidate, finalOne);
        _assertInnerWinner(tournament, candidate, parentOne);
        tournament.storeFinalState(candidate, finalTwo);
        _assertInnerWinner(tournament, candidate, parentTwo);
    }

    function testStandingInnerWinnerExpiresAtExactBoundary() public {
        ITournament.NestedDispute memory nested = ITournament.NestedDispute({
            contestedCommitmentOne: _node(0xa1),
            contestedFinalStateOne: _hash(0xb1),
            contestedCommitmentTwo: _node(0xa2),
            contestedFinalStateTwo: _hash(0xb2)
        });
        TournamentObserverHarness tournament =
            _newTournament(1, ITournament.TournamentKind.LEAF, 0, 3, 0, nested);
        Tree.Node candidate = _node(0xc5);
        tournament.storeTopology(candidate, 0, _instant(125));
        tournament.storeFinalState(candidate, nested.contestedFinalStateOne);
        tournament.storeClock(candidate, _pausedClock(10));
        vm.roll(135);

        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding
                .INNER_ELIMINABLE_WINNER_EXPIRED,
                acceptsJoins: false,
                hasCandidate: true,
                candidate: candidate,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: _instant(125)
            })
        );
    }

    function testStandingInnerWithoutWinnerIsImmediatelyEliminable() public {
        TournamentObserverHarness tournament = _newTournament(
            1, ITournament.TournamentKind.LEAF, 0, 3, 0, _zeroNestedDispute()
        );
        tournament.storeTopology(Tree.ZERO_NODE, 0, _instant(125));
        vm.roll(125);

        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding
                .INNER_ELIMINABLE_NO_WINNER,
                acceptsJoins: false,
                hasCandidate: false,
                candidate: Tree.ZERO_NODE,
                finalState: Machine.ZERO_STATE,
                parentCommitment: Tree.ZERO_NODE,
                finishedAt: _instant(125)
            })
        );
    }

    function testInnerResultRejectsRootTournament() public {
        TournamentObserverHarness tournament = _newLeafTournament();

        vm.expectRevert(ITournament.RequireNonRootTournament.selector);
        tournament.innerResult();
    }

    function testInnerResultIsUnsettledWithCanonicalZerosWhileUnfinished()
        public
    {
        TournamentObserverHarness openTournament = _newTournament(
            1, ITournament.TournamentKind.LEAF, 0, 3, 0, _nestedDispute()
        );
        Tree.Node openCandidate = _node(0xc6);
        openTournament.storeTopology(openCandidate, 0, _instant(0));
        openTournament.storeFinalState(openCandidate, _hash(0xb1));
        openTournament.storeClock(openCandidate, _pausedClock(10));
        vm.roll(110);

        _assertInnerResult(
            openTournament,
            ITournament.InnerTournamentDisposition.UNSETTLED,
            Tree.ZERO_NODE,
            0
        );

        TournamentObserverHarness activeTournament = _newTournament(
            1, ITournament.TournamentKind.LEAF, 0, 3, 0, _nestedDispute()
        );
        Tree.Node activeCandidate = _node(0xc7);
        activeTournament.storeTopology(activeCandidate, 1, _instant(125));
        activeTournament.storeFinalState(activeCandidate, _hash(0xb1));
        activeTournament.storeClock(activeCandidate, _pausedClock(10));
        vm.roll(130);

        _assertInnerResult(
            activeTournament,
            ITournament.InnerTournamentDisposition.UNSETTLED,
            Tree.ZERO_NODE,
            0
        );
    }

    function testInnerResultIsEliminableWithCanonicalZerosWithoutWinner()
        public
    {
        TournamentObserverHarness tournament = _newTournament(
            1, ITournament.TournamentKind.LEAF, 0, 3, 0, _nestedDispute()
        );
        tournament.storeTopology(Tree.ZERO_NODE, 0, _instant(125));
        vm.roll(125);

        _assertInnerResult(
            tournament,
            ITournament.InnerTournamentDisposition.ELIMINABLE,
            Tree.ZERO_NODE,
            0
        );
    }

    function testInnerResultMapsBothParentOrientationsAndExactAllowance()
        public
    {
        ITournament.NestedDispute memory nested = _nestedDispute();
        TournamentObserverHarness tournament =
            _newTournament(1, ITournament.TournamentKind.LEAF, 0, 3, 0, nested);
        Tree.Node candidate = _node(0xc7);
        tournament.storeTopology(candidate, 0, _instant(125));
        tournament.storeClock(candidate, _pausedClock(10));
        vm.roll(134);

        tournament.storeFinalState(candidate, nested.contestedFinalStateOne);
        _assertInnerResult(
            tournament,
            ITournament.InnerTournamentDisposition.WINNER,
            nested.contestedCommitmentOne,
            1
        );

        tournament.storeFinalState(candidate, nested.contestedFinalStateTwo);
        _assertInnerResult(
            tournament,
            ITournament.InnerTournamentDisposition.WINNER,
            nested.contestedCommitmentTwo,
            1
        );
    }

    function testInnerResultWinnerIsEliminableAtAndAfterExactExpiry() public {
        ITournament.NestedDispute memory nested = _nestedDispute();
        TournamentObserverHarness tournament =
            _newTournament(1, ITournament.TournamentKind.LEAF, 0, 3, 0, nested);
        Tree.Node candidate = _node(0xc8);
        tournament.storeTopology(candidate, 0, _instant(125));
        tournament.storeFinalState(candidate, nested.contestedFinalStateOne);
        tournament.storeClock(candidate, _pausedClock(10));

        vm.roll(135);
        _assertInnerResult(
            tournament,
            ITournament.InnerTournamentDisposition.ELIMINABLE,
            Tree.ZERO_NODE,
            0
        );

        vm.roll(136);
        _assertInnerResult(
            tournament,
            ITournament.InnerTournamentDisposition.ELIMINABLE,
            Tree.ZERO_NODE,
            0
        );
    }

    function _assertProjectionCrossProduct(
        TournamentObserverHarness tournament,
        Match.IdHash matchIdHash,
        Match.State memory state,
        Match.Phase expectedPhase
    ) internal {
        tournament.storeMatch(matchIdHash, state);
        (
            Match.Phase bisectingPhase,
            ITournament.BisectingMatchView memory bisecting
        ) = tournament.bisectingMatch(matchIdHash);
        (
            Match.Phase readyPhase,
            ITournament.ReadyToSealMatchView memory ready
        ) = tournament.readyToSealMatch(matchIdHash);
        (
            Match.Phase sealedPhase,
            ITournament.SealedMatchView memory sealedView
        ) = tournament.sealedMatch(matchIdHash);

        assertEq(uint8(bisectingPhase), uint8(expectedPhase));
        assertEq(uint8(readyPhase), uint8(expectedPhase));
        assertEq(uint8(sealedPhase), uint8(expectedPhase));
        if (expectedPhase == Match.Phase.BISECTING) {
            assertNotEq(_hashEncoded(bisecting), _zeroBisectingHash());
        } else {
            assertEq(_hashEncoded(bisecting), _zeroBisectingHash());
        }
        if (expectedPhase == Match.Phase.READY_TO_SEAL) {
            assertNotEq(_hashEncoded(ready), _zeroReadyHash());
        } else {
            assertEq(_hashEncoded(ready), _zeroReadyHash());
        }
        if (expectedPhase == Match.Phase.SEALED) {
            assertNotEq(_hashEncoded(sealedView), _zeroSealedHash());
        } else {
            assertEq(_hashEncoded(sealedView), _zeroSealedHash());
        }
    }

    function _assertAbsentObservation(
        TournamentObserverHarness tournament,
        Match.Id memory matchId,
        Match.IdHash matchIdHash
    ) internal view {
        (
            Match.Phase phase,
            ITournament.MatchTimeoutOutcome outcome,
            Time.Duration charge
        ) = tournament.classifyMatchTimeout(matchId);
        assertEq(uint8(phase), uint8(Match.Phase.UNINITIALIZED));
        assertEq(uint8(outcome), uint8(ITournament.MatchTimeoutOutcome.NONE));
        assertEq(Time.Duration.unwrap(charge), 0);

        (, ITournament.BisectingMatchView memory bisecting) =
            tournament.bisectingMatch(matchIdHash);
        (, ITournament.ReadyToSealMatchView memory ready) =
            tournament.readyToSealMatch(matchIdHash);
        (, ITournament.SealedMatchView memory sealedView) =
            tournament.sealedMatch(matchIdHash);
        assertEq(_hashEncoded(bisecting), _zeroBisectingHash());
        assertEq(_hashEncoded(ready), _zeroReadyHash());
        assertEq(_hashEncoded(sealedView), _zeroSealedHash());
    }

    function _assertResponderParity(uint64 totalHeight) internal {
        TournamentObserverHarness tournament = _newTournament(
            0,
            ITournament.TournamentKind.LEAF,
            2,
            totalHeight,
            100,
            _zeroNestedDispute()
        );
        Match.IdHash matchIdHash = _matchId().hashFromId();
        for (
            uint64 currentHeight = totalHeight;
            currentHeight > 0;
            --currentHeight
        ) {
            tournament.storeMatch(
                matchIdHash, _activeState(currentHeight, currentHeight * 2)
            );
            ITournament.CommitmentSide expected = (totalHeight - currentHeight)
                    % 2 == 0
                ? ITournament.CommitmentSide.ONE
                : ITournament.CommitmentSide.TWO;
            if (currentHeight == 1) {
                (
                    Match.Phase phase,
                    ITournament.ReadyToSealMatchView memory value
                ) = tournament.readyToSealMatch(matchIdHash);
                assertEq(uint8(phase), uint8(Match.Phase.READY_TO_SEAL));
                assertEq(
                    Tree.Node.unwrap(value.revealingParent),
                    Tree.Node.unwrap(_node(0x11))
                );
                assertEq(
                    Tree.Node.unwrap(value.waitingLeft),
                    Tree.Node.unwrap(_node(0x12))
                );
                assertEq(
                    Tree.Node.unwrap(value.waitingRight),
                    Tree.Node.unwrap(_node(0x13))
                );
                assertEq(value.segmentStartPosition, currentHeight * 2);
                assertEq(uint8(value.responder), uint8(expected));
                assertEq(value.segmentStartCycle, 100 + (currentHeight * 2) * 4);
            } else {
                (
                    Match.Phase phase,
                    ITournament.BisectingMatchView memory value
                ) = tournament.bisectingMatch(matchIdHash);
                assertEq(uint8(phase), uint8(Match.Phase.BISECTING));
                assertEq(
                    Tree.Node.unwrap(value.revealingParent),
                    Tree.Node.unwrap(_node(0x11))
                );
                assertEq(
                    Tree.Node.unwrap(value.waitingLeft),
                    Tree.Node.unwrap(_node(0x12))
                );
                assertEq(
                    Tree.Node.unwrap(value.waitingRight),
                    Tree.Node.unwrap(_node(0x13))
                );
                assertEq(value.segmentStartPosition, currentHeight * 2);
                assertEq(uint8(value.responder), uint8(expected));
                assertEq(value.currentHeight, currentHeight);
                assertEq(value.segmentStartCycle, 100 + (currentHeight * 2) * 4);
            }
        }
    }

    function _assertSealedOrientation(uint64 totalHeight, uint256 position)
        internal
    {
        uint64 log2step = 2;
        uint256 baseCycle = 100;
        TournamentObserverHarness tournament = _newTournament(
            0,
            ITournament.TournamentKind.LEAF,
            log2step,
            totalHeight,
            baseCycle,
            _zeroNestedDispute()
        );
        Machine.Hash finalStateOne = _hash(0xb1);
        Machine.Hash finalStateTwo = _hash(0xb2);
        // Sealed storage is canonical: leftNode always holds commitment one's
        // final state and rightNode commitment two's. The projection must
        // return them unchanged for every height and position parity.
        Match.State memory state = Match.State({
            otherParent: _node(0xa0),
            leftNode: Tree.Node.wrap(Machine.Hash.unwrap(finalStateOne)),
            rightNode: Tree.Node.wrap(Machine.Hash.unwrap(finalStateTwo)),
            runningLeafPosition: position,
            currentHeight: 0,
            isInit: true
        });
        Match.IdHash matchIdHash = _matchId().hashFromId();
        tournament.storeMatch(matchIdHash, state);

        (Match.Phase phase, ITournament.SealedMatchView memory value) =
            tournament.sealedMatch(matchIdHash);
        assertEq(uint8(phase), uint8(Match.Phase.SEALED));
        assertEq(
            Machine.Hash.unwrap(value.agreeState),
            Machine.Hash.unwrap(_hash(0xa0))
        );
        assertEq(value.divergencePosition, position);
        assertEq(value.divergenceCycle, baseCycle + (position << log2step));
        assertEq(
            Machine.Hash.unwrap(value.finalStateOne),
            Machine.Hash.unwrap(finalStateOne)
        );
        assertEq(
            Machine.Hash.unwrap(value.finalStateTwo),
            Machine.Hash.unwrap(finalStateTwo)
        );
    }

    function _assertBisectionTimeoutBoundaries(bool oneRuns) internal {
        TournamentObserverHarness tournament = _newLeafTournament();
        Match.Id memory matchId = _matchId();
        uint64 currentHeight = oneRuns ? 3 : 2;
        tournament.storeMatch(
            matchId.hashFromId(), _activeState(currentHeight, 0)
        );
        Clock.State memory running = _runningClock(5, 100);
        Clock.State memory paused = _pausedClock(10);
        tournament.storeClock(matchId.commitmentOne, oneRuns ? running : paused);
        tournament.storeClock(matchId.commitmentTwo, oneRuns ? paused : running);
        ITournament.MatchTimeoutOutcome winner = oneRuns
            ? ITournament.MatchTimeoutOutcome.TWO_WINS
            : ITournament.MatchTimeoutOutcome.ONE_WINS;

        _assertTimeout(
            tournament,
            matchId,
            104,
            Match.Phase.BISECTING,
            ITournament.MatchTimeoutOutcome.NONE,
            0
        );
        _assertTimeout(
            tournament, matchId, 105, Match.Phase.BISECTING, winner, 0
        );
        _assertTimeout(
            tournament, matchId, 114, Match.Phase.BISECTING, winner, 9
        );
        _assertTimeout(
            tournament,
            matchId,
            115,
            Match.Phase.BISECTING,
            ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH,
            0
        );
    }

    function _assertLeafTimeoutBoundaries(bool oneIsShorter) internal {
        TournamentObserverHarness tournament = _newLeafTournament();
        Match.Id memory matchId = _matchId();
        tournament.storeMatch(matchId.hashFromId(), _sealedState(0));
        Clock.State memory shortClock = _runningClock(5, 100);
        Clock.State memory longClock = _runningClock(11, 100);
        tournament.storeClock(
            matchId.commitmentOne, oneIsShorter ? shortClock : longClock
        );
        tournament.storeClock(
            matchId.commitmentTwo, oneIsShorter ? longClock : shortClock
        );
        ITournament.MatchTimeoutOutcome winner = oneIsShorter
            ? ITournament.MatchTimeoutOutcome.TWO_WINS
            : ITournament.MatchTimeoutOutcome.ONE_WINS;

        _assertTimeout(
            tournament,
            matchId,
            104,
            Match.Phase.SEALED,
            ITournament.MatchTimeoutOutcome.NONE,
            0
        );
        _assertTimeout(tournament, matchId, 105, Match.Phase.SEALED, winner, 0);
        // This is beyond the stale midpoint rule; the longer live clock still wins.
        _assertTimeout(tournament, matchId, 109, Match.Phase.SEALED, winner, 0);
        _assertTimeout(tournament, matchId, 110, Match.Phase.SEALED, winner, 0);
        _assertTimeout(
            tournament,
            matchId,
            111,
            Match.Phase.SEALED,
            ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH,
            0
        );
    }

    function _assertTimeout(
        TournamentObserverHarness tournament,
        Match.Id memory matchId,
        uint64 current,
        Match.Phase expectedPhase,
        ITournament.MatchTimeoutOutcome expectedOutcome,
        uint64 expectedCharge
    ) internal {
        vm.roll(current);
        (
            Match.Phase phase,
            ITournament.MatchTimeoutOutcome outcome,
            Time.Duration charge
        ) = tournament.classifyMatchTimeout(matchId);
        assertEq(uint8(phase), uint8(expectedPhase));
        assertEq(uint8(outcome), uint8(expectedOutcome));
        assertEq(Time.Duration.unwrap(charge), expectedCharge);
    }

    function _assertDescriptor(
        uint64 level,
        ITournament.TournamentKind kind,
        uint64 log2Stride,
        uint64 height,
        uint256 baseCycle
    ) internal {
        TournamentObserverHarness tournament = _newTournament(
            level, kind, log2Stride, height, baseCycle, _zeroNestedDispute()
        );
        ITournament.TournamentDescriptor memory descriptor =
            tournament.tournamentDescriptor();
        assertEq(
            Machine.Hash.unwrap(descriptor.initialHash),
            Machine.Hash.unwrap(_hash(0xabc))
        );
        assertEq(descriptor.baseCycle, baseCycle);
        assertEq(descriptor.log2Stride, log2Stride);
        assertEq(descriptor.height, height);
        assertEq(descriptor.level, level);
        assertEq(uint8(descriptor.kind), uint8(kind));
    }

    function _assertInnerWinner(
        TournamentObserverHarness tournament,
        Tree.Node candidate,
        Tree.Node parentCommitment
    ) internal view {
        _assertStanding(
            tournament,
            ITournament.TournamentStandingView({
                standing: ITournament.TournamentStanding.INNER_WINNER,
                acceptsJoins: false,
                hasCandidate: true,
                candidate: candidate,
                finalState: Machine.ZERO_STATE,
                parentCommitment: parentCommitment,
                finishedAt: _instant(125)
            })
        );
    }

    function _assertInnerResult(
        TournamentObserverHarness tournament,
        ITournament.InnerTournamentDisposition disposition,
        Tree.Node parentCommitment,
        uint64 pausedAllowance
    ) internal view {
        ITournament.InnerResultView memory actual = tournament.innerResult();
        ITournament.InnerResultView memory expected = ITournament.InnerResultView({
            disposition: disposition,
            parentCommitment: parentCommitment,
            pausedAllowance: _duration(pausedAllowance)
        });
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
    }

    function _assertStanding(
        TournamentObserverHarness tournament,
        ITournament.TournamentStandingView memory expected
    ) internal view {
        ITournament.TournamentStandingView memory actual =
            tournament.tournamentStanding();
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
        // Independent closure derivation from the clone arguments, so this
        // parity check is an oracle, not an echo of the observer.
        assertEq(
            actual.acceptsJoins,
            !TournamentInspector.isClosed(ITournament(address(tournament)))
        );
    }

    function _standingTournament()
        internal
        returns (TournamentObserverHarness)
    {
        return _newLeafTournament();
    }

    function _joinUniformCommitment(
        TournamentObserverHarness tournament,
        Machine.Hash finalState,
        uint256 bond
    ) internal returns (Tree.Node root) {
        Tree.Node leaf = Tree.Node.wrap(Machine.Hash.unwrap(finalState));
        Tree.Node heightOne = leaf.join(leaf);
        Tree.Node heightTwo = heightOne.join(heightOne);
        root = heightTwo.join(heightTwo);
        bytes32[] memory proof = new bytes32[](3);
        proof[0] = Tree.Node.unwrap(leaf);
        proof[1] = Tree.Node.unwrap(heightOne);
        proof[2] = Tree.Node.unwrap(heightTwo);
        tournament.joinTournament{value: bond}(
            finalState, proof, heightTwo, heightTwo
        );
    }

    function _newTournament(
        uint64 level,
        ITournament.TournamentKind kind,
        uint64 log2step,
        uint64 height,
        uint256 baseCycle,
        ITournament.NestedDispute memory nestedDispute
    ) internal returns (TournamentObserverHarness) {
        ITournament.TournamentArguments memory args =
            ITournament.TournamentArguments({
                commitmentArgs: Commitment.Arguments({
                    initialHash: _hash(0xabc),
                    startCycle: baseCycle,
                    log2step: log2step,
                    height: height
                }),
                level: level,
                kind: kind,
                startInstant: _instant(100),
                allowance: _duration(20),
                responseBudget: _duration(3),
                provider: IDataProvider(address(0x1001)),
                nestedDispute: nestedDispute,
                stateTransition: IStateTransition(address(0x1002)),
                tournamentFactory: address(0x1003)
            });
        address clone =
            address(IMPLEMENTATION).cloneWithImmutableArgs(abi.encode(args));
        return TournamentObserverHarness(clone);
    }

    function _newLeafTournament() internal returns (TournamentObserverHarness) {
        return _newTournament(
            0, ITournament.TournamentKind.LEAF, 0, 3, 0, _zeroNestedDispute()
        );
    }

    function _assertProjectionZeroes(
        ITournament.BisectingMatchView memory bisecting,
        ITournament.ReadyToSealMatchView memory ready,
        ITournament.SealedMatchView memory sealedView
    ) internal pure {
        assert(_hashEncoded(bisecting) == _zeroBisectingHash());
        assert(_hashEncoded(ready) == _zeroReadyHash());
        assert(_hashEncoded(sealedView) == _zeroSealedHash());
    }

    function _zeroBisectingHash() internal pure returns (bytes32) {
        ITournament.BisectingMatchView memory value;
        return _hashEncoded(value);
    }

    function _zeroReadyHash() internal pure returns (bytes32) {
        ITournament.ReadyToSealMatchView memory value;
        return _hashEncoded(value);
    }

    function _zeroSealedHash() internal pure returns (bytes32) {
        ITournament.SealedMatchView memory value;
        return _hashEncoded(value);
    }

    function _hashEncoded(ITournament.BisectingMatchView memory value)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(value));
    }

    function _hashEncoded(ITournament.ReadyToSealMatchView memory value)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(value));
    }

    function _hashEncoded(ITournament.SealedMatchView memory value)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(value));
    }

    function _activeState(uint64 currentHeight, uint256 position)
        internal
        pure
        returns (Match.State memory)
    {
        return Match.State({
            otherParent: _node(0x11),
            leftNode: _node(0x12),
            rightNode: _node(0x13),
            runningLeafPosition: position,
            currentHeight: currentHeight,
            isInit: true
        });
    }

    function _sealedState(uint256 position)
        internal
        pure
        returns (Match.State memory)
    {
        return Match.State({
            otherParent: _node(0xa0),
            leftNode: _node(0xb1),
            rightNode: _node(0xb2),
            runningLeafPosition: position,
            currentHeight: 0,
            isInit: true
        });
    }

    function _matchId() internal pure returns (Match.Id memory) {
        return
            Match.Id({commitmentOne: _node(0x101), commitmentTwo: _node(0x202)});
    }

    function _pausedClock(uint64 allowance)
        internal
        pure
        returns (Clock.State memory)
    {
        return Clock.State({
            allowance: _duration(allowance), startInstant: Time.ZERO_INSTANT
        });
    }

    function _runningClock(uint64 allowance, uint64 start)
        internal
        pure
        returns (Clock.State memory)
    {
        return Clock.State({
            allowance: _duration(allowance), startInstant: _instant(start)
        });
    }

    function _zeroNestedDispute()
        internal
        pure
        returns (ITournament.NestedDispute memory)
    {
        return ITournament.NestedDispute({
            contestedCommitmentOne: Tree.ZERO_NODE,
            contestedFinalStateOne: Machine.ZERO_STATE,
            contestedCommitmentTwo: Tree.ZERO_NODE,
            contestedFinalStateTwo: Machine.ZERO_STATE
        });
    }

    function _nestedDispute()
        internal
        pure
        returns (ITournament.NestedDispute memory)
    {
        return ITournament.NestedDispute({
            contestedCommitmentOne: _node(0xa1),
            contestedFinalStateOne: _hash(0xb1),
            contestedCommitmentTwo: _node(0xa2),
            contestedFinalStateTwo: _hash(0xb2)
        });
    }

    function _node(uint256 value) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(bytes32(value));
    }

    function _hash(uint256 value) internal pure returns (Machine.Hash) {
        return Machine.Hash.wrap(bytes32(value));
    }

    function _instant(uint64 value) internal pure returns (Time.Instant) {
        return Time.Instant.wrap(value);
    }

    function _duration(uint64 value) internal pure returns (Time.Duration) {
        return Time.Duration.wrap(value);
    }
}
