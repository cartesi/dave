// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "../fixtures/InspectableTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";
import {SmallTwoLevelClaims} from "../fixtures/SmallTwoLevelClaims.sol";
import {
    SmallTwoLevelGeometry,
    SmallTwoLevelTournamentFactory
} from "../fixtures/SmallTwoLevelTournament.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;
using TournamentInspector for InspectableTournament;

/// @dev Deterministic traces across the parent-child seam. The state-transition
/// stub selects a supplied child leaf; these tests cover tournament plumbing,
/// not the objective correctness of that transition.
contract RecursiveTournamentLifecycleTest is Test {
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;
    using Machine for Machine.Hash;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Instant;
    using Time for Time.Duration;
    using Tree for Tree.Node;

    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant RESPONSE_BUDGET = 5;
    uint64 internal constant MAX_ALLOWANCE = 200;
    uint256 internal constant CONTESTED_SEGMENT = 2;

    address internal constant CLAIMER_ONE = address(0xa11ce);
    address internal constant CLAIMER_TWO = address(0xb0b);
    address internal constant CLAIMER_DANGLING = address(0xca11);
    address internal constant CLAIMER_IMPOSTOR = address(0xbad);

    SmallTwoLevelTournamentFactory internal immutable FACTORY;

    InspectableTournament internal parent;
    InspectableTournament internal child;
    Match.Id internal parentMatch;
    Match.Id internal childMatch;
    Tree.Node internal parentOne;
    Tree.Node internal parentTwo;
    Tree.Node internal parentDangling;
    Tree.Node internal childOne;
    Tree.Node internal childTwo;

    constructor() {
        FACTORY = new SmallTwoLevelTournamentFactory(
            Time.Duration.wrap(RESPONSE_BUDGET),
            Time.Duration.wrap(MAX_ALLOWANCE)
        );
    }

    function setUp() public {
        vm.roll(START_BLOCK);
        vm.fee(0);
        vm.txGasPrice(0);
        vm.deal(CLAIMER_ONE, 100 ether);
        vm.deal(CLAIMER_TWO, 100 ether);
        vm.deal(CLAIMER_DANGLING, 100 ether);
        vm.deal(CLAIMER_IMPOSTOR, 100 ether);

        parent = InspectableTournament(
            address(
                FACTORY.instantiate(
                    SmallTwoLevelClaims.initialState(),
                    IDataProvider(address(0))
                )
            )
        );

        SmallFullTree.Data memory one =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);
        SmallFullTree.Data memory two =
            _parentTree(SmallTwoLevelClaims.CLAIM_TWO);
        SmallFullTree.Data memory dangling =
            _parentTree(SmallTwoLevelClaims.DANGLING_CLAIM);

        parentOne = _join(parent, one, CLAIMER_ONE);
        parentTwo = _join(parent, two, CLAIMER_TWO);
        parentDangling = _join(parent, dangling, CLAIMER_DANGLING);
        parentMatch = Match.Id(parentOne, parentTwo);

        _assertParentSeeded();
    }

    function testChildWinnerOnePropagatesAndWinsRoot() public {
        _sealParent();
        Tree.Node winningChild = _resolveChild(SmallTwoLevelClaims.CLAIM_ONE);
        _closeChildWithWinner(
            SmallTwoLevelClaims.CLAIM_ONE, winningChild, MAX_ALLOWANCE
        );

        Match.Id memory finalMatch =
            _propagateChildWinner(SmallTwoLevelClaims.CLAIM_ONE, MAX_ALLOWANCE);
        _resolveFinalRootTimeout(SmallTwoLevelClaims.CLAIM_ONE, finalMatch);
    }

    function testChildWinnerTwoPropagatesAndWinsRoot() public {
        _sealParent();
        Tree.Node winningChild = _resolveChild(SmallTwoLevelClaims.CLAIM_TWO);
        _closeChildWithWinner(
            SmallTwoLevelClaims.CLAIM_TWO, winningChild, MAX_ALLOWANCE
        );

        Match.Id memory finalMatch =
            _propagateChildWinner(SmallTwoLevelClaims.CLAIM_TWO, MAX_ALLOWANCE);
        _resolveFinalRootTimeout(SmallTwoLevelClaims.CLAIM_TWO, finalMatch);
    }

    function testRegisteredUnfinishedChildRejectsWinBeforeWinnerInvariant()
        public
    {
        _sealParent();
        assertFalse(child.isFinished());
        assertFalse(child.canBeEliminated());

        SmallFullTree.Data memory winner =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);

        vm.expectRevert(ITournament.ChildTournamentNotFinished.selector);
        parent.winInnerTournament(child, left, right);

        Match.State memory state = parent.getMatch(parentMatch.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
        _assertLiveOrigin();
    }

    function testInnerJoinRejectsUncontestedFinalState() public {
        _sealParent();

        SmallFullTree.Data memory invalid =
            _childTree(SmallTwoLevelClaims.CLAIM_THREE);
        (,,, uint64 height) = child.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = invalid.children(height, 0);
        Machine.Hash invalidFinalState = invalid.finalState();
        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        uint256 bond = child.bondValue();

        vm.prank(CLAIMER_IMPOSTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.InvalidContestedFinalState.selector,
                args.nestedDispute.contestedFinalStateOne,
                args.nestedDispute.contestedFinalStateTwo,
                invalidFinalState
            )
        );
        child.joinTournament{value: bond}(
            invalidFinalState, invalid.finalProof(), left, right
        );

        (Clock.State memory clock,) = child.getCommitment(invalid.root());
        assertFalse(clock.isInitialized());
        assertEq(child.getCommitmentJoinedCount(), 0);
    }

    /// @dev A child winner selects the parent side by contested final state,
    /// not by tree identity. A distinct-root entrant sharing side one's final
    /// state may win the child; propagation rejects that root's own children
    /// and resolves the sealed match for parent side one.
    function testChildWinnerSelectsParentSideByFinalStateNotByRoot() public {
        _sealParent();

        // The entrant shares contested side one's final state but not its
        // root, and separately holds an unrelated parent commitment that
        // pairs against the waiting dangling claim.
        SmallFullTree.Data memory entrant = SmallTwoLevelClaims.childTreeVariant(
            SmallTwoLevelClaims.CLAIM_ONE, CONTESTED_SEGMENT, 1
        );
        Tree.Node entrantRoot = _join(parent, entrant, CLAIMER_IMPOSTOR);
        assertFalse(entrantRoot.eq(parentOne) || entrantRoot.eq(parentTwo));
        _assertNodeEq(_join(child, entrant, CLAIMER_IMPOSTOR), entrantRoot);

        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        vm.roll(_deadline(args.startInstant, args.allowance));
        assertTrue(child.isFinished());
        assertFalse(child.canBeEliminated());
        _assertInnerWinner(
            SmallTwoLevelClaims.CLAIM_ONE, entrantRoot, MAX_ALLOWANCE
        );

        // Snapshot the entrant's unrelated parent match and clock before
        // either propagation attempt.
        Match.IdHash entrantMatch =
            Match.Id(parentDangling, entrantRoot).hashFromId();
        bytes memory entrantMatchBefore =
            abi.encode(parent.getMatch(entrantMatch));
        (Clock.State memory entrantClockBefore,) =
            parent.getCommitment(entrantRoot);

        // The child winner's own children are not the selected parent side.
        (Tree.Node left, Tree.Node right) =
            entrant.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.WrongTournamentWinner.selector,
                entrantRoot,
                parentOne
            )
        );
        parent.winInnerTournament(child, left, right);

        // Parent side one, which shares the winner's final state, propagates.
        SmallFullTree.Data memory selected =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);
        (Tree.Node selectedLeft, Tree.Node selectedRight) =
            selected.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        parent.winInnerTournament(child, selectedLeft, selectedRight);

        // Side one becomes the dangling survivor with the carried child
        // clock; the entrant's own parent match and clock are unchanged.
        (Tree.Node dangling, uint256 matches,) = parent.observedTopology();
        _assertNodeEq(dangling, parentOne);
        assertEq(matches, 1);
        assertFalse(parent.getMatch(parentMatch.hashFromId()).exists());
        assertEq(abi.encode(parent.getMatch(entrantMatch)), entrantMatchBefore);
        (Clock.State memory entrantClockAfter,) =
            parent.getCommitment(entrantRoot);
        assertEq(abi.encode(entrantClockAfter), abi.encode(entrantClockBefore));
        (Clock.State memory carried,) = parent.getCommitment(parentOne);
        assertFalse(carried.isRunning());
        assertEq(Time.Duration.unwrap(carried.allowance), MAX_ALLOWANCE);
    }

    function testFuzzLateSingleChildEntrantCarriesRemainingAllowance(uint64 late)
        public
    {
        late = uint64(bound(uint256(late), 1, MAX_ALLOWANCE - 1));
        _sealParent();

        vm.roll(START_BLOCK + late);
        SmallFullTree.Data memory winner =
            _childTree(SmallTwoLevelClaims.CLAIM_ONE);
        Tree.Node winningChild = _join(child, winner, CLAIMER_ONE);
        uint64 remaining = MAX_ALLOWANCE - late;

        (Clock.State memory joinedClock,) = child.getCommitment(winningChild);
        assertFalse(joinedClock.isRunning());
        assertEq(Time.Duration.unwrap(joinedClock.allowance), remaining);
        (Tree.Node dangling, uint256 matches,) = child.observedTopology();
        _assertNodeEq(dangling, winningChild);
        assertEq(matches, 0);
        assertEq(child.getCommitmentJoinedCount(), 1);
        assertEq(child.getMatchCreatedCount(), 0);

        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        uint256 closedAt = _deadline(args.startInstant, args.allowance);
        vm.roll(closedAt);

        assertTrue(child.isFinished());
        assertFalse(child.canBeEliminated());
        _assertInnerWinner(
            SmallTwoLevelClaims.CLAIM_ONE, winningChild, remaining
        );

        Match.Id memory finalMatch =
            _propagateChildWinner(SmallTwoLevelClaims.CLAIM_ONE, remaining);
        (Clock.State memory propagated,) = parent.getCommitment(parentOne);
        assertFalse(propagated.isRunning());
        assertEq(Time.Duration.unwrap(propagated.allowance), remaining);
        assertTrue(
            finalMatch.commitmentOne.eq(parentDangling)
                && finalMatch.commitmentTwo.eq(parentOne)
        );
    }

    function testFuzzActiveChildCanResolveAfterGlobalClose(
        uint64 joinLate,
        uint64 resolveLate
    ) public {
        joinLate = uint64(bound(uint256(joinLate), 3, MAX_ALLOWANCE - 1));
        resolveLate =
            uint64(bound(uint256(resolveLate), 1, (uint256(joinLate) - 1) / 2));
        _sealParent();

        SmallFullTree.Data memory one =
            _childTree(SmallTwoLevelClaims.CLAIM_ONE);
        SmallFullTree.Data memory two =
            _childTree(SmallTwoLevelClaims.CLAIM_TWO);
        childOne = _join(child, one, CLAIMER_ONE);

        vm.roll(START_BLOCK + joinLate);
        childTwo = _join(child, two, CLAIMER_TWO);
        childMatch = Match.Id(childOne, childTwo);
        _advanceAndSealChildAtFirstLeaf(
            SmallTwoLevelClaims.CLAIM_ONE,
            SmallTwoLevelClaims.CLAIM_TWO,
            CONTESTED_SEGMENT
        );

        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        uint256 closedAt = _deadline(args.startInstant, args.allowance);
        vm.roll(closedAt + resolveLate);

        assertTrue(child.isClosed());
        assertFalse(child.isFinished());
        assertFalse(child.canBeEliminated());
        (bool finished,,,) = child.innerTournamentWinner();
        assertFalse(finished);

        (Clock.State memory clockOne,) = child.getCommitment(childOne);
        (Clock.State memory clockTwo,) = child.getCommitment(childTwo);
        assertEq(
            Time.Duration
                .unwrap(
                    clockOne.remainingAt(
                        Time.Instant.wrap(uint64(block.number))
                    )
                ),
            joinLate - resolveLate
        );
        assertTrue(
            clockTwo.remainingAt(Time.Instant.wrap(uint64(block.number)))
                .isZero()
        );
        assertEq(
            Time.Duration
                .unwrap(
                    clockTwo.overdueByAt(
                        Time.Instant.wrap(uint64(block.number))
                    )
                ),
            resolveLate
        );

        SmallFullTree.Data memory winner =
            _childTree(SmallTwoLevelClaims.CLAIM_ONE);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.LEAF_HEIGHT, 0);
        child.winMatchByTimeout(childMatch, left, right);
        Tree.Node winningChild = winner.root();
        uint64 carried = joinLate - resolveLate;
        assertTrue(child.isFinished());
        assertFalse(child.canBeEliminated());
        (bool timeKnown, Time.Instant finishedAt) = child.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), block.number);
        _assertInnerWinner(SmallTwoLevelClaims.CLAIM_ONE, winningChild, carried);

        _propagateChildWinner(SmallTwoLevelClaims.CLAIM_ONE, carried);
        (Clock.State memory propagated,) = parent.getCommitment(parentOne);
        assertFalse(propagated.isRunning());
        assertEq(Time.Duration.unwrap(propagated.allowance), carried);
    }

    function testTwoSequentialChildrenPropagateAcrossDifferentSegments()
        public
    {
        _sealParent();
        Tree.Node firstWinner = _resolveChild(SmallTwoLevelClaims.CLAIM_ONE);
        _closeChildWithWinner(
            SmallTwoLevelClaims.CLAIM_ONE, firstWinner, MAX_ALLOWANCE
        );

        InspectableTournament firstChild = child;
        uint256 firstChildBalance = address(firstChild).balance;
        Match.Id memory secondParentMatch =
            _propagateChildWinner(SmallTwoLevelClaims.CLAIM_ONE, MAX_ALLOWANCE);
        _assertClearedOrigin(firstChild);
        assertTrue(parent.isClosed());
        assertFalse(parent.isFinished());

        child = _sealSecondParentMatch(secondParentMatch);
        Tree.Node secondWinner = _resolveSecondChildMatch();
        uint256 secondChildBalance = address(child).balance;
        _closeChildWithWinner(
            SmallTwoLevelClaims.CLAIM_ONE, secondWinner, MAX_ALLOWANCE
        );

        SmallFullTree.Data memory winningParent =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);
        (Tree.Node left, Tree.Node right) =
            winningParent.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        parent.winInnerTournament(child, left, right);

        assertEq(address(firstChild).balance, firstChildBalance);
        assertEq(address(child).balance, secondChildBalance);
        _assertClearedOrigin(firstChild);
        _assertClearedOrigin(child);
        _assertSequentialChildrenResult(secondParentMatch, winningParent);
    }

    function testLastLegalPropagationCarriesOneBlock() public {
        _sealParent();
        Tree.Node winningChild = _resolveChild(SmallTwoLevelClaims.CLAIM_ONE);
        uint256 finishedAt = _closeChildWithWinner(
            SmallTwoLevelClaims.CLAIM_ONE, winningChild, MAX_ALLOWANCE
        );

        vm.roll(finishedAt + MAX_ALLOWANCE - 1);
        assertFalse(child.canBeEliminated());
        _assertInnerWinner(SmallTwoLevelClaims.CLAIM_ONE, winningChild, 1);
        vm.expectRevert(ITournament.ChildTournamentCannotBeEliminated.selector);
        parent.eliminateInnerTournament(child);

        uint256 childBalance = address(child).balance;
        Match.Id memory finalMatch =
            _propagateChildWinner(SmallTwoLevelClaims.CLAIM_ONE, 1);
        assertEq(address(child).balance, childBalance);

        (Clock.State memory propagated,) = parent.getCommitment(parentOne);
        assertFalse(propagated.isRunning());
        assertEq(Time.Duration.unwrap(propagated.allowance), 1);
        assertTrue(
            finalMatch.commitmentOne.eq(parentDangling)
                && finalMatch.commitmentTwo.eq(parentOne)
        );
    }

    function testCarryoverEqualityEliminatesParentMatch() public {
        _sealParent();
        Tree.Node winningChild = _resolveChild(SmallTwoLevelClaims.CLAIM_TWO);
        uint256 finishedAt = _closeChildWithWinner(
            SmallTwoLevelClaims.CLAIM_TWO, winningChild, MAX_ALLOWANCE
        );

        vm.roll(finishedAt + MAX_ALLOWANCE);
        assertTrue(child.canBeEliminated());
        (bool hasWinner, Tree.Node parentWinner, Tree.Node childWinner,) =
            child.innerTournamentWinner();
        assertFalse(hasWinner);
        assertTrue(parentWinner.isZero());
        assertTrue(childWinner.isZero());

        SmallFullTree.Data memory winner =
            _parentTree(SmallTwoLevelClaims.CLAIM_TWO);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        vm.expectRevert(ITournament.ChildTournamentMustBeEliminated.selector);
        parent.winInnerTournament(child, left, right);

        uint256 childBalance = address(child).balance;
        parent.eliminateInnerTournament(child);
        assertEq(address(child).balance, childBalance);

        _assertParentEliminatedToDangling();
    }

    function testChildWithoutWinnerIsImmediatelyEliminable() public {
        _sealParent();
        _sealChild();

        ITournament.TournamentArguments memory childArgs =
            child.tournamentArguments();
        uint256 childClosedAt =
            _deadline(childArgs.startInstant, childArgs.allowance);
        vm.roll(childClosedAt);

        child.eliminateMatchByTimeout(childMatch);
        assertTrue(child.isFinished());
        assertTrue(child.canBeEliminated());
        (bool finished, Time.Instant finishedAt) = child.timeFinished();
        assertTrue(finished);
        assertEq(Time.Instant.unwrap(finishedAt), childClosedAt);

        (Tree.Node dangling, uint256 matches,) = child.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(matches, 0);
        assertEq(child.getCommitmentJoinedCount(), 2);
        assertEq(child.getMatchCreatedCount(), 1);
        assertEq(child.getMatchAdvancedCount(), 1);
        assertEq(child.getMatchDeletedCount(), 1);

        uint256 childBalance = address(child).balance;
        parent.eliminateInnerTournament(child);
        assertEq(address(child).balance, childBalance);

        _assertParentEliminatedToDangling();
    }

    function testParentSealDerivesChildArgumentsAndClocks() public {
        vm.roll(120);
        _advanceParent();
        vm.roll(130);
        _sealParentAfterAdvance();

        SmallFullTree.Data memory one =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);
        SmallFullTree.Data memory two =
            _parentTree(SmallTwoLevelClaims.CLAIM_TWO);
        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        ITournament.TournamentArguments memory parentArgs =
            parent.tournamentArguments();

        assertEq(args.level, 1);
        assertEq(uint8(args.kind), uint8(ITournament.TournamentKind.LEAF));
        assertEq(args.commitmentArgs.height, SmallTwoLevelGeometry.LEAF_HEIGHT);
        assertEq(
            args.commitmentArgs.log2step, SmallTwoLevelGeometry.LEAF_LOG2_STEP
        );
        assertEq(
            Machine.Hash.unwrap(args.commitmentArgs.initialHash),
            Machine.Hash
                .unwrap(
                    SmallTwoLevelClaims.childInitialState(
                        SmallTwoLevelClaims.CLAIM_ONE, CONTESTED_SEGMENT
                    )
                )
        );
        assertEq(
            args.commitmentArgs.startCycle,
            SmallTwoLevelClaims.childStartCycle(CONTESTED_SEGMENT)
        );
        assertEq(Time.Instant.unwrap(args.startInstant), 130);
        assertEq(Time.Duration.unwrap(args.allowance), 195);
        assertEq(Time.Duration.unwrap(args.responseBudget), RESPONSE_BUDGET);
        assertEq(address(args.provider), address(parentArgs.provider));
        assertEq(
            address(args.stateTransition), address(parentArgs.stateTransition)
        );
        assertEq(args.tournamentFactory, address(FACTORY));

        _assertNodeEq(args.nestedDispute.contestedCommitmentOne, parentOne);
        _assertNodeEq(args.nestedDispute.contestedCommitmentTwo, parentTwo);
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateOne,
            one.leaf(CONTESTED_SEGMENT).toMachineHash()
        );
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateTwo,
            two.leaf(CONTESTED_SEGMENT).toMachineHash()
        );

        (Clock.State memory clockOne,) = parent.getCommitment(parentOne);
        (Clock.State memory clockTwo,) = parent.getCommitment(parentTwo);
        (Clock.State memory danglingClock,) =
            parent.getCommitment(parentDangling);
        assertFalse(clockOne.isRunning());
        assertFalse(clockTwo.isRunning());
        assertFalse(danglingClock.isRunning());
        assertEq(Time.Duration.unwrap(clockOne.allowance), 185);
        assertEq(Time.Duration.unwrap(clockTwo.allowance), 195);
        assertEq(Time.Duration.unwrap(danglingClock.allowance), MAX_ALLOWANCE);

        Match.State memory sealedMatch =
            parent.getMatch(parentMatch.hashFromId());
        assertTrue(sealedMatch.exists());
        assertTrue(sealedMatch.isSealed());
        assertEq(sealedMatch.runningLeafPosition, CONTESTED_SEGMENT);
        assertEq(
            parent.getMatchCycle(parentMatch.hashFromId()),
            SmallTwoLevelClaims.childStartCycle(CONTESTED_SEGMENT)
        );
        _assertLiveOrigin();

        (Tree.Node dangling, uint256 matches,) = parent.observedTopology();
        _assertNodeEq(dangling, parentDangling);
        assertEq(matches, 1);
        assertEq(parent.getCommitmentJoinedCount(), 3);
        assertEq(parent.getMatchCreatedCount(), 1);
        assertEq(parent.getMatchAdvancedCount(), 1);
        assertEq(parent.getMatchDeletedCount(), 0);
        assertEq(parent.getNewInnerTournamentCount(), 1);
    }

    function testChildReturnUsesSharedParentPairEnvelope() public {
        vm.roll(120);
        _advanceParent();
        vm.roll(130);
        _sealParentAfterAdvance();

        (Clock.State memory smallerBefore,) = parent.getCommitment(parentOne);
        (Clock.State memory largerBefore,) = parent.getCommitment(parentTwo);
        uint64 smallerAllowance = Time.Duration.unwrap(smallerBefore.allowance);
        uint64 largerAllowance = Time.Duration.unwrap(largerBefore.allowance);
        assertLt(smallerAllowance, largerAllowance);

        SmallFullTree.Data memory winner =
            _childTree(SmallTwoLevelClaims.CLAIM_ONE);
        Tree.Node winningChild = _join(child, winner, CLAIMER_ONE);
        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        assertEq(Time.Duration.unwrap(args.allowance), largerAllowance);

        vm.roll(_deadline(args.startInstant, args.allowance));
        _assertInnerWinner(
            SmallTwoLevelClaims.CLAIM_ONE, winningChild, largerAllowance
        );
        _propagateChildWinner(SmallTwoLevelClaims.CLAIM_ONE, largerAllowance);

        (Clock.State memory returned,) = parent.getCommitment(parentOne);
        uint64 returnedAllowance = Time.Duration.unwrap(returned.allowance);
        assertGt(returnedAllowance, smallerAllowance);
        assertLe(returnedAllowance, largerAllowance);
        assertLe(
            uint256(returnedAllowance),
            uint256(smallerAllowance) + largerAllowance
        );
    }

    function testSealedParentCannotResolveThroughClockTimeouts() public {
        _sealParent();
        vm.roll(START_BLOCK + 2 * MAX_ALLOWANCE);

        assertFalse(parent.canWinMatchByTimeout(parentMatch));
        vm.expectRevert(ITournament.MatchCannotBeWonByTimeout.selector);
        parent.winMatchByTimeout(parentMatch, Tree.ZERO_NODE, Tree.ZERO_NODE);

        vm.expectRevert(ITournament.MatchCannotBeEliminatedByTimeout.selector);
        parent.eliminateMatchByTimeout(parentMatch);
        assertTrue(parent.getMatch(parentMatch.hashFromId()).exists());
    }

    function _assertParentSeeded() private view {
        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            parent.observedTopology();
        _assertNodeEq(dangling, parentDangling);
        assertEq(matches, 1);
        assertTrue(lastDeleted.isZero());

        Match.State memory state = parent.getMatch(parentMatch.hashFromId());
        assertTrue(state.exists());
        assertEq(state.currentHeight, SmallTwoLevelGeometry.ROOT_HEIGHT);
        _assertNodeEq(state.otherParent, parentOne);

        (Clock.State memory one,) = parent.getCommitment(parentOne);
        (Clock.State memory two,) = parent.getCommitment(parentTwo);
        (Clock.State memory waiting,) = parent.getCommitment(parentDangling);
        assertTrue(one.isRunning());
        assertFalse(two.isRunning());
        assertFalse(waiting.isRunning());
        assertEq(Time.Instant.unwrap(one.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(one.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(two.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(waiting.allowance), MAX_ALLOWANCE);

        assertEq(parent.getCommitmentJoinedCount(), 3);
        assertEq(parent.getMatchCreatedCount(), 1);
        assertEq(parent.getMatchAdvancedCount(), 0);
        assertEq(parent.getMatchDeletedCount(), 0);
        assertEq(parent.getNewInnerTournamentCount(), 0);
    }

    function _sealParent() private {
        _advanceParent();
        _sealParentAfterAdvance();
    }

    function _advanceParent() private {
        SmallFullTree.Data memory one =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);
        (Tree.Node left, Tree.Node right) =
            one.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        (Tree.Node nextLeft, Tree.Node nextRight) = one.children(1, 1);
        parent.advanceMatch(parentMatch, left, right, nextLeft, nextRight);

        Match.State memory state = parent.getMatch(parentMatch.hashFromId());
        assertEq(state.currentHeight, 1);
        assertEq(state.runningLeafPosition, CONTESTED_SEGMENT);
    }

    function _sealParentAfterAdvance() private {
        SmallFullTree.Data memory two =
            _parentTree(SmallTwoLevelClaims.CLAIM_TWO);
        (Tree.Node left, Tree.Node right) = two.children(1, 1);
        Machine.Hash agree = two.leaf(CONTESTED_SEGMENT - 1).toMachineHash();

        vm.recordLogs();
        parent.sealInnerMatchAndCreateInnerTournament(
            parentMatch, left, right, agree, two.proof(CONTESTED_SEGMENT - 1)
        );
        child = _recordedChild(parentMatch);

        Match.State memory state = parent.getMatch(parentMatch.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
        assertEq(state.runningLeafPosition, CONTESTED_SEGMENT);
        _assertLiveOrigin();
    }

    function _recordedChild(Match.Id memory origin)
        private
        returns (InspectableTournament recorded)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(parent) || entry.topics.length != 3
                    || entry.topics[0]
                        != ITournament.NewInnerTournament.selector
            ) {
                continue;
            }

            ++count;
            assertEq(entry.topics[1], Match.IdHash.unwrap(origin.hashFromId()));
            assertEq(entry.data.length, 0);
            recorded = InspectableTournament(
                address(uint160(uint256(entry.topics[2])))
            );
        }
        assertEq(count, 1);
        assertNotEq(address(recorded), address(0));
    }

    function _sealSecondParentMatch(Match.Id memory secondParentMatch)
        private
        returns (InspectableTournament secondChild)
    {
        SmallFullTree.Data memory one =
            _parentTree(SmallTwoLevelClaims.DANGLING_CLAIM);
        SmallFullTree.Data memory two =
            _parentTree(SmallTwoLevelClaims.CLAIM_ONE);

        (Tree.Node left, Tree.Node right) =
            one.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        (Tree.Node nextLeft, Tree.Node nextRight) = one.children(1, 0);
        parent.advanceMatch(secondParentMatch, left, right, nextLeft, nextRight);

        Match.State memory state =
            parent.getMatch(secondParentMatch.hashFromId());
        assertEq(state.currentHeight, 1);
        assertEq(state.runningLeafPosition, 0);

        (left, right) = two.children(1, 0);
        vm.recordLogs();
        parent.sealInnerMatchAndCreateInnerTournament(
            secondParentMatch,
            left,
            right,
            SmallTwoLevelClaims.initialState(),
            new bytes32[](0)
        );
        secondChild = _recordedChild(secondParentMatch);

        state = parent.getMatch(secondParentMatch.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
        assertEq(state.runningLeafPosition, 0);
        assertEq(parent.getMatchCycle(secondParentMatch.hashFromId()), 0);
        _assertSecondChildArguments(secondChild, secondParentMatch, one, two);
    }

    function _assertSecondChildArguments(
        InspectableTournament secondChild,
        Match.Id memory secondParentMatch,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) private view {
        ITournament.TournamentArguments memory
            args = secondChild.tournamentArguments();
        assertEq(args.level, 1);
        assertEq(
            Machine.Hash.unwrap(args.commitmentArgs.initialHash),
            Machine.Hash.unwrap(SmallTwoLevelClaims.initialState())
        );
        assertEq(args.commitmentArgs.startCycle, 0);
        assertEq(
            Time.Instant.unwrap(args.startInstant), START_BLOCK + MAX_ALLOWANCE
        );
        assertEq(Time.Duration.unwrap(args.allowance), MAX_ALLOWANCE);
        _assertNodeEq(args.nestedDispute.contestedCommitmentOne, parentDangling);
        _assertNodeEq(args.nestedDispute.contestedCommitmentTwo, parentOne);
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateOne,
            one.leaf(0).toMachineHash()
        );
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateTwo,
            two.leaf(0).toMachineHash()
        );
        _assertOrigin(secondChild, secondParentMatch);

        (Clock.State memory clockOne,) = parent.getCommitment(parentDangling);
        (Clock.State memory clockTwo,) = parent.getCommitment(parentOne);
        assertFalse(clockOne.isRunning());
        assertFalse(clockTwo.isRunning());
        assertEq(Time.Duration.unwrap(clockOne.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(clockTwo.allowance), MAX_ALLOWANCE);
        assertEq(parent.getMatchCreatedCount(), 2);
        assertEq(parent.getMatchAdvancedCount(), 2);
        assertEq(parent.getMatchDeletedCount(), 1);
        assertEq(parent.getNewInnerTournamentCount(), 2);
    }

    function _resolveSecondChildMatch()
        private
        returns (Tree.Node winningChild)
    {
        SmallFullTree.Data memory one =
            _childTreeAt(SmallTwoLevelClaims.DANGLING_CLAIM, 0);
        SmallFullTree.Data memory two =
            _childTreeAt(SmallTwoLevelClaims.CLAIM_ONE, 0);
        childOne = _join(child, one, CLAIMER_DANGLING);
        childTwo = _join(child, two, CLAIMER_ONE);
        childMatch = Match.Id(childOne, childTwo);

        _advanceAndSealChildAtFirstLeaf(
            SmallTwoLevelClaims.DANGLING_CLAIM, SmallTwoLevelClaims.CLAIM_ONE, 0
        );
        winningChild = _winChildAtFirstLeaf(SmallTwoLevelClaims.CLAIM_ONE, 0);

        assertFalse(child.getMatch(childMatch.hashFromId()).exists());
        (Tree.Node dangling, uint256 matches,) = child.observedTopology();
        _assertNodeEq(dangling, winningChild);
        assertEq(matches, 0);
        assertEq(child.getCommitmentJoinedCount(), 2);
        assertEq(child.getMatchCreatedCount(), 1);
        assertEq(child.getMatchAdvancedCount(), 1);
        assertEq(child.getMatchDeletedCount(), 1);
    }

    function _sealChild() private {
        SmallFullTree.Data memory one =
            _childTree(SmallTwoLevelClaims.CLAIM_ONE);
        SmallFullTree.Data memory two =
            _childTree(SmallTwoLevelClaims.CLAIM_TWO);

        childOne = _join(child, one, CLAIMER_ONE);
        childTwo = _join(child, two, CLAIMER_TWO);
        childMatch = Match.Id(childOne, childTwo);

        _advanceAndSealChildAtFirstLeaf(
            SmallTwoLevelClaims.CLAIM_ONE,
            SmallTwoLevelClaims.CLAIM_TWO,
            CONTESTED_SEGMENT
        );
    }

    function _advanceAndSealChildAtFirstLeaf(
        uint8 claimOne,
        uint8 claimTwo,
        uint256 contestedSegment
    ) private {
        SmallFullTree.Data memory one = _childTreeAt(claimOne, contestedSegment);
        SmallFullTree.Data memory two = _childTreeAt(claimTwo, contestedSegment);
        (bool found, uint256 position) = one.firstDivergence(two);
        assertTrue(found);
        assertEq(position, 0);

        (Tree.Node left, Tree.Node right) =
            one.children(SmallTwoLevelGeometry.LEAF_HEIGHT, 0);
        (Tree.Node nextLeft, Tree.Node nextRight) = one.children(1, 0);
        child.advanceMatch(childMatch, left, right, nextLeft, nextRight);

        (left, right) = two.children(1, 0);
        child.sealLeafMatch(
            childMatch,
            left,
            right,
            SmallTwoLevelClaims.childInitialState(claimOne, contestedSegment),
            new bytes32[](0)
        );

        Match.State memory state = child.getMatch(childMatch.hashFromId());
        assertTrue(state.exists());
        assertTrue(state.isSealed());
        assertEq(state.runningLeafPosition, 0);
        assertEq(
            child.getMatchCycle(childMatch.hashFromId()),
            SmallTwoLevelClaims.childStartCycle(contestedSegment)
        );
    }

    function _resolveChild(uint8 winnerClaim)
        private
        returns (Tree.Node winningChild)
    {
        _sealChild();
        winningChild = _winChildAtFirstLeaf(winnerClaim, CONTESTED_SEGMENT);

        assertFalse(child.getMatch(childMatch.hashFromId()).exists());
        (Tree.Node dangling, uint256 matches,) = child.observedTopology();
        _assertNodeEq(dangling, winningChild);
        assertEq(matches, 0);
        assertEq(child.getCommitmentJoinedCount(), 2);
        assertEq(child.getMatchCreatedCount(), 1);
        assertEq(child.getMatchAdvancedCount(), 1);
        assertEq(child.getMatchDeletedCount(), 1);
    }

    function _winChildAtFirstLeaf(uint8 winnerClaim, uint256 contestedSegment)
        private
        returns (Tree.Node winningChild)
    {
        SmallFullTree.Data memory winner =
            _childTreeAt(winnerClaim, contestedSegment);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.LEAF_HEIGHT, 0);
        child.winLeafMatch(
            childMatch,
            left,
            right,
            abi.encode(Tree.Node.unwrap(winner.leaf(0)))
        );
        winningChild = winner.root();
    }

    function _closeChildWithWinner(
        uint8 winnerClaim,
        Tree.Node winningChild,
        uint64 expectedAllowance
    ) private returns (uint256 finishedAt) {
        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        finishedAt = _deadline(args.startInstant, args.allowance);
        vm.roll(finishedAt);

        assertTrue(child.isClosed());
        assertTrue(child.isFinished());
        assertFalse(child.canBeEliminated());
        (bool finished, Time.Instant actualFinishedAt) = child.timeFinished();
        assertTrue(finished);
        assertEq(Time.Instant.unwrap(actualFinishedAt), finishedAt);
        _assertInnerWinner(winnerClaim, winningChild, expectedAllowance);
    }

    function _assertInnerWinner(
        uint8 winnerClaim,
        Tree.Node expectedChildWinner,
        uint64 expectedAllowance
    ) private view {
        (
            bool finished,
            Tree.Node contestedParent,
            Tree.Node actualChildWinner,
            Clock.State memory returnedClock
        ) = child.innerTournamentWinner();

        assertTrue(finished);
        _assertNodeEq(contestedParent, _parentRoot(winnerClaim));
        _assertNodeEq(actualChildWinner, expectedChildWinner);
        assertFalse(returnedClock.isRunning());
        assertEq(
            Time.Duration.unwrap(returnedClock.allowance), expectedAllowance
        );
    }

    function _propagateChildWinner(uint8 winnerClaim, uint64 expectedAllowance)
        private
        returns (Match.Id memory finalMatch)
    {
        SmallFullTree.Data memory winner = _parentTree(winnerClaim);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        uint256 childBalance = address(child).balance;

        parent.winInnerTournament(child, left, right);
        assertEq(address(child).balance, childBalance);

        Tree.Node selectedParent = winner.root();
        finalMatch = Match.Id(parentDangling, selectedParent);
        assertFalse(parent.getMatch(parentMatch.hashFromId()).exists());
        assertTrue(parent.getMatch(finalMatch.hashFromId()).exists());

        (Clock.State memory selectedClock,) =
            parent.getCommitment(selectedParent);
        (Clock.State memory danglingClock,) =
            parent.getCommitment(parentDangling);
        assertFalse(selectedClock.isRunning());
        assertTrue(danglingClock.isRunning());
        assertEq(
            Time.Duration.unwrap(selectedClock.allowance), expectedAllowance
        );
        assertEq(Time.Instant.unwrap(danglingClock.startInstant), block.number);

        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            parent.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(matches, 1);
        assertEq(Time.Instant.unwrap(lastDeleted), block.number);
        assertEq(parent.getMatchCreatedCount(), 2);
        assertEq(parent.getMatchAdvancedCount(), 1);
        assertEq(parent.getMatchDeletedCount(), 1);
        assertEq(parent.getNewInnerTournamentCount(), 1);
        _assertClearedOrigin();
    }

    function _resolveFinalRootTimeout(
        uint8 winnerClaim,
        Match.Id memory finalMatch
    ) private {
        SmallFullTree.Data memory winner = _parentTree(winnerClaim);
        (Clock.State memory danglingClock,) =
            parent.getCommitment(parentDangling);
        vm.roll(_deadline(danglingClock.startInstant, danglingClock.allowance));
        assertTrue(parent.canWinMatchByTimeout(finalMatch));

        (Tree.Node left, Tree.Node right) =
            winner.children(SmallTwoLevelGeometry.ROOT_HEIGHT, 0);
        parent.winMatchByTimeout(finalMatch, left, right);

        assertTrue(parent.isClosed());
        assertTrue(parent.isFinished());
        assertFalse(parent.getMatch(finalMatch.hashFromId()).exists());
        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            parent.observedTopology();
        _assertNodeEq(dangling, winner.root());
        assertEq(matches, 0);
        assertEq(Time.Instant.unwrap(lastDeleted), block.number);
        assertEq(parent.getMatchCreatedCount(), 2);
        assertEq(parent.getMatchDeletedCount(), 2);
        (bool timeKnown, Time.Instant finishedAt) = parent.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), block.number);

        (bool finished, Tree.Node result, Machine.Hash finalState) =
            parent.arbitrationResult();
        assertTrue(finished);
        _assertNodeEq(result, winner.root());
        _assertMachineEq(finalState, winner.finalState());
        assertEq(
            parent.observedClaimer(winner.root()),
            winnerClaim == SmallTwoLevelClaims.CLAIM_ONE
                ? CLAIMER_ONE
                : CLAIMER_TWO
        );
        assertEq(
            parent.observedClaimer(
                winnerClaim == SmallTwoLevelClaims.CLAIM_ONE
                    ? parentTwo
                    : parentOne
            ),
            address(0)
        );
        assertEq(parent.observedClaimer(parentDangling), address(0));
    }

    function _assertParentEliminatedToDangling() private view {
        assertFalse(parent.getMatch(parentMatch.hashFromId()).exists());
        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            parent.observedTopology();
        _assertNodeEq(dangling, parentDangling);
        assertEq(matches, 0);
        assertEq(Time.Instant.unwrap(lastDeleted), block.number);
        assertTrue(parent.isClosed());
        assertTrue(parent.isFinished());
        assertEq(parent.getMatchCreatedCount(), 1);
        assertEq(parent.getMatchAdvancedCount(), 1);
        assertEq(parent.getMatchDeletedCount(), 1);
        assertEq(parent.getNewInnerTournamentCount(), 1);
        _assertClearedOrigin();
        (bool timeKnown, Time.Instant finishedAt) = parent.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), block.number);
        assertEq(parent.observedClaimer(parentOne), address(0));
        assertEq(parent.observedClaimer(parentTwo), address(0));
        assertEq(parent.observedClaimer(parentDangling), CLAIMER_DANGLING);

        SmallFullTree.Data memory danglingTree =
            _parentTree(SmallTwoLevelClaims.DANGLING_CLAIM);
        (bool finished, Tree.Node result, Machine.Hash finalState) =
            parent.arbitrationResult();
        assertTrue(finished);
        _assertNodeEq(result, parentDangling);
        _assertMachineEq(finalState, danglingTree.finalState());
    }

    function _assertSequentialChildrenResult(
        Match.Id memory secondParentMatch,
        SmallFullTree.Data memory winningParent
    ) private view {
        assertFalse(parent.getMatch(parentMatch.hashFromId()).exists());
        assertFalse(parent.getMatch(secondParentMatch.hashFromId()).exists());

        (Clock.State memory winnerClock,) = parent.getCommitment(parentOne);
        assertFalse(winnerClock.isRunning());
        assertEq(Time.Duration.unwrap(winnerClock.allowance), MAX_ALLOWANCE);

        (Tree.Node dangling, uint256 matches, Time.Instant lastDeleted) =
            parent.observedTopology();
        _assertNodeEq(dangling, parentOne);
        assertEq(matches, 0);
        assertEq(Time.Instant.unwrap(lastDeleted), block.number);
        assertTrue(parent.isClosed());
        assertTrue(parent.isFinished());
        assertEq(parent.getCommitmentJoinedCount(), 3);
        assertEq(parent.getMatchCreatedCount(), 2);
        assertEq(parent.getMatchAdvancedCount(), 2);
        assertEq(parent.getMatchDeletedCount(), 2);
        assertEq(parent.getNewInnerTournamentCount(), 2);

        (bool timeKnown, Time.Instant finishedAt) = parent.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), block.number);
        (bool finished, Tree.Node result, Machine.Hash finalState) =
            parent.arbitrationResult();
        assertTrue(finished);
        _assertNodeEq(result, parentOne);
        _assertMachineEq(finalState, winningParent.finalState());
        assertEq(parent.observedClaimer(parentOne), CLAIMER_ONE);
        assertEq(parent.observedClaimer(parentTwo), address(0));
        assertEq(parent.observedClaimer(parentDangling), address(0));
    }

    function _assertLiveOrigin() private view {
        _assertOrigin(child, parentMatch);
    }

    function _assertClearedOrigin() private view {
        _assertClearedOrigin(child);
    }

    function _assertOrigin(
        InspectableTournament tournament,
        Match.Id memory expected
    ) private view {
        Match.Id memory origin = parent.observedOriginatingMatch(tournament);
        _assertNodeEq(origin.commitmentOne, expected.commitmentOne);
        _assertNodeEq(origin.commitmentTwo, expected.commitmentTwo);
    }

    function _assertClearedOrigin(InspectableTournament tournament)
        private
        view
    {
        Match.Id memory origin = parent.observedOriginatingMatch(tournament);
        assertTrue(origin.commitmentOne.isZero());
        assertTrue(origin.commitmentTwo.isZero());
    }

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer
    ) private returns (Tree.Node root) {
        (,,, uint64 height) = tournament.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = tree.children(height, 0);
        // A prank affects only the next external call, including view calls.
        uint256 bond = tournament.bondValue();
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
        root = tree.root();
    }

    function _parentTree(uint8 claim)
        private
        pure
        returns (SmallFullTree.Data memory)
    {
        return SmallTwoLevelClaims.rootTree(claim);
    }

    function _childTree(uint8 claim)
        private
        pure
        returns (SmallFullTree.Data memory)
    {
        return _childTreeAt(claim, CONTESTED_SEGMENT);
    }

    function _childTreeAt(uint8 claim, uint256 segment)
        private
        pure
        returns (SmallFullTree.Data memory)
    {
        return SmallTwoLevelClaims.childTree(claim, segment);
    }

    function _parentRoot(uint8 claim) private pure returns (Tree.Node) {
        return SmallTwoLevelClaims.rootTree(claim).root();
    }

    function _deadline(Time.Instant start, Time.Duration allowance)
        private
        pure
        returns (uint256)
    {
        return uint256(Time.Instant.unwrap(start))
            + Time.Duration.unwrap(allowance);
    }

    function _assertNodeEq(Tree.Node actual, Tree.Node expected) private pure {
        assertEq(Tree.Node.unwrap(actual), Tree.Node.unwrap(expected));
    }

    function _assertMachineEq(Machine.Hash actual, Machine.Hash expected)
        private
        pure
    {
        assertEq(Machine.Hash.unwrap(actual), Machine.Hash.unwrap(expected));
    }
}
