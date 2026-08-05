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
import {
    SmallFourLevelClaims,
    SmallFourLevelGeometry,
    SmallFourLevelTournamentFactory
} from "../fixtures/SmallFourLevelTournament.sol";
import {SmallFullTree} from "../fixtures/SmallFullTree.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;
using TournamentInspector for InspectableTournament;

/// @dev A strict production-path recursion trace over four injected levels.
/// The fine state tables are commitment-plumbing witnesses, not an execution
/// oracle; ProofSelectedStateTransition selects the final divergent state.
contract FourLevelRecursiveLifecycleTest is Test {
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant RESPONSE_BUDGET = 1;
    uint64 internal constant MAX_ALLOWANCE = 100;
    uint64 internal constant LEAF_PROOF_DELAY = 5;
    uint64 internal constant CARRIED_ALLOWANCE =
        MAX_ALLOWANCE - LEAF_PROOF_DELAY;

    address internal constant CLAIMER_ONE = address(0xa11ce);
    address internal constant CLAIMER_TWO = address(0xb0b);
    address internal constant PROVIDER_ADDRESS = address(0xdada);

    SmallFourLevelTournamentFactory internal immutable FACTORY;

    InspectableTournament[4] internal tournaments;
    Match.Id[4] internal matchIds;
    Tree.Node[4] internal rootsOne;
    Tree.Node[4] internal rootsTwo;
    address internal expectedStateTransition;

    constructor() {
        FACTORY = new SmallFourLevelTournamentFactory(
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

        tournaments[0] = InspectableTournament(
            address(
                FACTORY.instantiate(
                    SmallFourLevelClaims.initialState(),
                    IDataProvider(PROVIDER_ADDRESS)
                )
            )
        );
        ITournament.TournamentArguments memory args =
            tournaments[0].tournamentArguments();
        expectedStateTransition = address(args.stateTransition);
    }

    function testFourLevelWinnerPropagatesToRoot() public {
        _assertRootArguments();
        _joinPair(0);

        for (uint64 level; level < SmallFourLevelGeometry.LEVELS - 1; ++level) {
            _sealAndCreateChild(level);
            _joinPair(level + 1);
        }

        _sealAndResolveLeaf();
        vm.roll(START_BLOCK + MAX_ALLOWANCE);

        for (
            uint64 childLevel = SmallFourLevelGeometry.LEVELS - 1;
            childLevel > 0;
            --childLevel
        ) {
            _propagateWinner(childLevel);
        }

        _assertRootResult();
    }

    function _assertRootArguments() private view {
        ITournament.TournamentArguments memory args =
            tournaments[0].tournamentArguments();
        assertEq(args.level, 0);
        assertEq(args.levels, SmallFourLevelGeometry.LEVELS);
        assertEq(args.commitmentArgs.height, SmallFourLevelGeometry.HEIGHT);
        assertEq(
            args.commitmentArgs.log2step, SmallFourLevelGeometry.log2step(0)
        );
        assertEq(args.commitmentArgs.startCycle, 0);
        _assertMachineEq(
            args.commitmentArgs.initialHash, SmallFourLevelClaims.initialState()
        );
        assertEq(Time.Instant.unwrap(args.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(args.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(args.responseBudget), RESPONSE_BUDGET);
        assertEq(address(args.provider), PROVIDER_ADDRESS);
        assertEq(address(args.stateTransition), expectedStateTransition);
        assertGt(expectedStateTransition.code.length, 0);
        assertEq(args.tournamentFactory, address(FACTORY));
        assertTrue(args.nestedDispute.contestedCommitmentOne.isZero());
        assertTrue(args.nestedDispute.contestedCommitmentTwo.isZero());
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateOne, Machine.ZERO_STATE
        );
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateTwo, Machine.ZERO_STATE
        );
    }

    function _joinPair(uint64 level) private {
        InspectableTournament tournament = tournaments[level];
        SmallFullTree.Data memory one =
            SmallFourLevelClaims.tree(SmallFourLevelClaims.CLAIM_ONE, level);
        SmallFullTree.Data memory two =
            SmallFourLevelClaims.tree(SmallFourLevelClaims.CLAIM_TWO, level);
        _assertCoordinateCoherence(level, one, two);

        rootsOne[level] = _join(tournament, one, CLAIMER_ONE);
        rootsTwo[level] = _join(tournament, two, CLAIMER_TWO);
        matchIds[level] = Match.Id(rootsOne[level], rootsTwo[level]);

        Match.State memory state =
            tournament.getMatch(matchIds[level].hashFromId());
        assertTrue(state.exists());
        assertFalse(state.isSealed());
        assertTrue(state.canBeSealed());
        assertEq(state.currentHeight, SmallFourLevelGeometry.HEIGHT);
        assertEq(state.runningLeafPosition, 0);
        _assertNodeEq(state.otherParent, rootsOne[level]);
        (Tree.Node leftTwo, Tree.Node rightTwo) =
            two.children(SmallFourLevelGeometry.HEIGHT, 0);
        _assertNodeEq(state.leftNode, leftTwo);
        _assertNodeEq(state.rightNode, rightTwo);

        (Clock.State memory clockOne, Machine.Hash finalStateOne) =
            tournament.getCommitment(rootsOne[level]);
        (Clock.State memory clockTwo, Machine.Hash finalStateTwo) =
            tournament.getCommitment(rootsTwo[level]);
        assertTrue(clockOne.isRunning());
        assertFalse(clockTwo.isRunning());
        assertEq(Time.Instant.unwrap(clockOne.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(clockOne.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(clockTwo.allowance), MAX_ALLOWANCE);
        _assertMachineEq(finalStateOne, one.finalState());
        _assertMachineEq(finalStateTwo, two.finalState());
        assertEq(tournament.observedClaimer(rootsOne[level]), CLAIMER_ONE);
        assertEq(tournament.observedClaimer(rootsTwo[level]), CLAIMER_TWO);

        (Tree.Node dangling, uint256 activeMatches, Time.Instant lastDeleted) =
            tournament.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(activeMatches, 1);
        assertTrue(lastDeleted.isZero());
        assertEq(tournament.getCommitmentJoinedCount(), 2);
        assertEq(tournament.getMatchCreatedCount(), 1);
        assertEq(tournament.getMatchAdvancedCount(), 0);
        assertEq(tournament.getMatchDeletedCount(), 0);
        assertEq(tournament.getNewInnerTournamentCount(), 0);
    }

    function _sealAndCreateChild(uint64 parentLevel) private {
        InspectableTournament parent = tournaments[parentLevel];
        SmallFullTree.Data memory one = SmallFourLevelClaims.tree(
            SmallFourLevelClaims.CLAIM_ONE, parentLevel
        );
        (Tree.Node left, Tree.Node right) =
            one.children(SmallFourLevelGeometry.HEIGHT, 0);

        vm.recordLogs();
        parent.sealInnerMatchAndCreateInnerTournament(
            matchIds[parentLevel],
            left,
            right,
            one.leaf(0).toMachineHash(),
            one.proof(0)
        );

        uint64 childLevel = parentLevel + 1;
        tournaments[childLevel] = _recordedChild(parent, matchIds[parentLevel]);
        _assertSealedParent(parentLevel);
        _assertChildArguments(childLevel);
    }

    function _assertSealedParent(uint64 parentLevel) private view {
        InspectableTournament parent = tournaments[parentLevel];
        Match.IdHash idHash = matchIds[parentLevel].hashFromId();
        Match.State memory state = parent.getMatch(idHash);
        assertTrue(state.exists());
        assertTrue(state.isSealed());
        assertEq(state.runningLeafPosition, 1);
        assertEq(
            parent.getMatchCycle(idHash),
            SmallFourLevelClaims.startCycle(parentLevel + 1)
        );

        (Clock.State memory clockOne,) =
            parent.getCommitment(rootsOne[parentLevel]);
        (Clock.State memory clockTwo,) =
            parent.getCommitment(rootsTwo[parentLevel]);
        assertFalse(clockOne.isRunning());
        assertFalse(clockTwo.isRunning());
        assertEq(Time.Duration.unwrap(clockOne.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(clockTwo.allowance), MAX_ALLOWANCE);

        (Tree.Node dangling, uint256 activeMatches,) = parent.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(activeMatches, 1);
        assertEq(parent.getCommitmentJoinedCount(), 2);
        assertEq(parent.getMatchCreatedCount(), 1);
        assertEq(parent.getMatchAdvancedCount(), 0);
        assertEq(parent.getMatchDeletedCount(), 0);
        assertEq(parent.getNewInnerTournamentCount(), 1);
    }

    function _assertChildArguments(uint64 childLevel) private view {
        uint64 parentLevel = childLevel - 1;
        InspectableTournament parent = tournaments[parentLevel];
        InspectableTournament child = tournaments[childLevel];
        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        SmallFullTree.Data memory parentOne = SmallFourLevelClaims.tree(
            SmallFourLevelClaims.CLAIM_ONE, parentLevel
        );
        SmallFullTree.Data memory parentTwo = SmallFourLevelClaims.tree(
            SmallFourLevelClaims.CLAIM_TWO, parentLevel
        );

        assertEq(args.level, childLevel);
        assertEq(args.levels, SmallFourLevelGeometry.LEVELS);
        assertEq(args.commitmentArgs.height, SmallFourLevelGeometry.HEIGHT);
        assertEq(
            args.commitmentArgs.log2step,
            SmallFourLevelGeometry.log2step(childLevel)
        );
        assertEq(
            args.commitmentArgs.startCycle,
            SmallFourLevelClaims.startCycle(childLevel)
        );
        _assertMachineEq(
            args.commitmentArgs.initialHash,
            SmallFourLevelClaims.stateAfter(
                SmallFourLevelClaims.CLAIM_ONE,
                SmallFourLevelClaims.startCycle(childLevel)
            )
        );
        assertEq(Time.Instant.unwrap(args.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(args.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(args.responseBudget), RESPONSE_BUDGET);
        assertEq(address(args.provider), PROVIDER_ADDRESS);
        assertEq(address(args.stateTransition), expectedStateTransition);
        assertEq(args.tournamentFactory, address(FACTORY));

        _assertNodeEq(
            args.nestedDispute.contestedCommitmentOne, rootsOne[parentLevel]
        );
        _assertNodeEq(
            args.nestedDispute.contestedCommitmentTwo, rootsTwo[parentLevel]
        );
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateOne,
            parentOne.leaf(1).toMachineHash()
        );
        _assertMachineEq(
            args.nestedDispute.contestedFinalStateTwo,
            parentTwo.leaf(1).toMachineHash()
        );

        Match.Id memory origin = parent.observedOriginatingMatch(child);
        _assertMatchEq(origin, matchIds[parentLevel]);
        Match.State memory sealedState =
            parent.getMatch(matchIds[parentLevel].hashFromId());
        assertTrue(sealedState.exists());
        assertTrue(sealedState.isSealed());

        (Tree.Node dangling, uint256 activeMatches, Time.Instant lastDeleted) =
            child.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(activeMatches, 0);
        assertTrue(lastDeleted.isZero());
        assertEq(child.getCommitmentJoinedCount(), 0);
        assertEq(child.getMatchCreatedCount(), 0);
        assertEq(child.getMatchAdvancedCount(), 0);
        assertEq(child.getMatchDeletedCount(), 0);
        assertEq(child.getNewInnerTournamentCount(), 0);
    }

    function _sealAndResolveLeaf() private {
        uint64 level = SmallFourLevelGeometry.LEVELS - 1;
        InspectableTournament leaf = tournaments[level];
        SmallFullTree.Data memory winner =
            SmallFourLevelClaims.tree(SmallFourLevelClaims.CLAIM_ONE, level);
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallFourLevelGeometry.HEIGHT, 0);

        leaf.sealLeafMatch(
            matchIds[level],
            left,
            right,
            winner.leaf(0).toMachineHash(),
            winner.proof(0)
        );

        Match.State memory sealedState =
            leaf.getMatch(matchIds[level].hashFromId());
        assertTrue(sealedState.exists());
        assertTrue(sealedState.isSealed());
        assertEq(sealedState.runningLeafPosition, 1);
        assertEq(leaf.getMatchCycle(matchIds[level].hashFromId()), 15);

        (Clock.State memory clockOne,) = leaf.getCommitment(rootsOne[level]);
        (Clock.State memory clockTwo,) = leaf.getCommitment(rootsTwo[level]);
        assertTrue(clockOne.isRunning());
        assertTrue(clockTwo.isRunning());
        assertEq(Time.Instant.unwrap(clockOne.startInstant), START_BLOCK);
        assertEq(Time.Instant.unwrap(clockTwo.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(clockOne.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(clockTwo.allowance), MAX_ALLOWANCE);

        vm.roll(START_BLOCK + LEAF_PROOF_DELAY);
        leaf.winLeafMatch(
            matchIds[level],
            left,
            right,
            abi.encode(Tree.Node.unwrap(winner.leaf(1)))
        );

        assertFalse(leaf.getMatch(matchIds[level].hashFromId()).exists());
        (Tree.Node dangling, uint256 activeMatches, Time.Instant lastDeleted) =
            leaf.observedTopology();
        _assertNodeEq(dangling, rootsOne[level]);
        assertEq(activeMatches, 0);
        assertEq(
            Time.Instant.unwrap(lastDeleted), START_BLOCK + LEAF_PROOF_DELAY
        );
        assertFalse(leaf.isClosed());
        assertFalse(leaf.isFinished());
        assertEq(leaf.getCommitmentJoinedCount(), 2);
        assertEq(leaf.getMatchCreatedCount(), 1);
        assertEq(leaf.getMatchAdvancedCount(), 0);
        assertEq(leaf.getMatchDeletedCount(), 1);
        assertEq(leaf.getNewInnerTournamentCount(), 0);

        (clockOne,) = leaf.getCommitment(rootsOne[level]);
        (clockTwo,) = leaf.getCommitment(rootsTwo[level]);
        assertFalse(clockOne.isRunning());
        assertTrue(clockTwo.isRunning());
        assertEq(Time.Duration.unwrap(clockOne.allowance), CARRIED_ALLOWANCE);
        assertEq(leaf.observedClaimer(rootsOne[level]), CLAIMER_ONE);
        assertEq(leaf.observedClaimer(rootsTwo[level]), address(0));
    }

    function _propagateWinner(uint64 childLevel) private {
        uint64 parentLevel = childLevel - 1;
        InspectableTournament child = tournaments[childLevel];
        InspectableTournament parent = tournaments[parentLevel];
        Match.IdHash parentMatchHash = matchIds[parentLevel].hashFromId();

        assertTrue(child.isClosed());
        assertTrue(child.isFinished());
        assertFalse(child.canBeEliminated());
        (
            bool finished,
            Tree.Node parentWinner,
            Tree.Node childWinner,
            Clock.State memory carriedClock
        ) = child.innerTournamentWinner();
        assertTrue(finished);
        _assertNodeEq(parentWinner, rootsOne[parentLevel]);
        _assertNodeEq(childWinner, rootsOne[childLevel]);
        assertFalse(carriedClock.isRunning());
        assertEq(
            Time.Duration.unwrap(carriedClock.allowance), CARRIED_ALLOWANCE
        );

        Match.State memory sealedState = parent.getMatch(parentMatchHash);
        assertTrue(sealedState.exists());
        assertTrue(sealedState.isSealed());
        _assertMatchEq(
            parent.observedOriginatingMatch(child), matchIds[parentLevel]
        );
        (Clock.State memory beforeOne,) =
            parent.getCommitment(rootsOne[parentLevel]);
        (Clock.State memory beforeTwo,) =
            parent.getCommitment(rootsTwo[parentLevel]);
        assertFalse(beforeOne.isRunning());
        assertFalse(beforeTwo.isRunning());
        assertEq(Time.Duration.unwrap(beforeOne.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(beforeTwo.allowance), MAX_ALLOWANCE);

        SmallFullTree.Data memory winner = SmallFourLevelClaims.tree(
            SmallFourLevelClaims.CLAIM_ONE, parentLevel
        );
        (Tree.Node left, Tree.Node right) =
            winner.children(SmallFourLevelGeometry.HEIGHT, 0);
        parent.winInnerTournament(child, left, right);

        assertFalse(parent.getMatch(parentMatchHash).exists());
        Match.Id memory cleared = parent.observedOriginatingMatch(child);
        assertTrue(cleared.commitmentOne.isZero());
        assertTrue(cleared.commitmentTwo.isZero());

        (Tree.Node dangling, uint256 activeMatches, Time.Instant lastDeleted) =
            parent.observedTopology();
        _assertNodeEq(dangling, rootsOne[parentLevel]);
        assertEq(activeMatches, 0);
        assertEq(Time.Instant.unwrap(lastDeleted), START_BLOCK + MAX_ALLOWANCE);
        assertTrue(parent.isClosed());
        assertTrue(parent.isFinished());
        (bool timeKnown, Time.Instant finishedAt) = parent.timeFinished();
        assertTrue(timeKnown);
        assertEq(Time.Instant.unwrap(finishedAt), START_BLOCK + MAX_ALLOWANCE);

        (Clock.State memory propagated,) =
            parent.getCommitment(rootsOne[parentLevel]);
        (Clock.State memory loser,) =
            parent.getCommitment(rootsTwo[parentLevel]);
        assertFalse(propagated.isRunning());
        assertFalse(loser.isRunning());
        assertEq(
            Time.Duration.unwrap(propagated.allowance),
            Time.Duration.unwrap(carriedClock.allowance)
        );
        assertEq(Time.Duration.unwrap(loser.allowance), MAX_ALLOWANCE);
        assertEq(parent.observedClaimer(rootsOne[parentLevel]), CLAIMER_ONE);
        assertEq(parent.observedClaimer(rootsTwo[parentLevel]), address(0));
        assertEq(parent.getCommitmentJoinedCount(), 2);
        assertEq(parent.getMatchCreatedCount(), 1);
        assertEq(parent.getMatchAdvancedCount(), 0);
        assertEq(parent.getMatchDeletedCount(), 1);
        assertEq(parent.getNewInnerTournamentCount(), 1);
    }

    function _assertRootResult() private view {
        InspectableTournament root = tournaments[0];
        SmallFullTree.Data memory winner =
            SmallFourLevelClaims.tree(SmallFourLevelClaims.CLAIM_ONE, 0);
        (bool finished, Tree.Node result, Machine.Hash finalState) =
            root.arbitrationResult();
        assertTrue(finished);
        _assertNodeEq(result, rootsOne[0]);
        _assertMachineEq(finalState, winner.finalState());
        _assertMachineEq(
            finalState,
            SmallFourLevelClaims.stateAfter(
                SmallFourLevelClaims.CLAIM_ONE, SmallFourLevelClaims.FINAL_CYCLE
            )
        );

        assertEq(root.getCommitmentJoinedCount(), 2);
        assertEq(root.getMatchCreatedCount(), 1);
        assertEq(root.getMatchAdvancedCount(), 0);
        assertEq(root.getMatchDeletedCount(), 1);
        assertEq(root.getNewInnerTournamentCount(), 1);
        assertEq(root.observedClaimer(rootsOne[0]), CLAIMER_ONE);
        assertEq(root.observedClaimer(rootsTwo[0]), address(0));
        (Clock.State memory winnerClock,) = root.getCommitment(rootsOne[0]);
        assertFalse(winnerClock.isRunning());
        assertEq(Time.Duration.unwrap(winnerClock.allowance), CARRIED_ALLOWANCE);
    }

    function _assertCoordinateCoherence(
        uint64 level,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) private pure {
        assertEq(one.height(), SmallFourLevelGeometry.HEIGHT);
        assertEq(two.height(), SmallFourLevelGeometry.HEIGHT);
        (bool found, uint256 position) = one.firstDivergence(two);
        assertTrue(found);
        assertEq(position, 1);
        _assertNodeEq(one.leaf(0), two.leaf(0));
        assertFalse(one.leaf(1).eq(two.leaf(1)));

        uint256 start = SmallFourLevelClaims.startCycle(level);
        uint256 step = uint256(1) << SmallFourLevelGeometry.log2step(level);
        _assertMachineEq(
            one.leaf(0).toMachineHash(),
            SmallFourLevelClaims.stateAfter(
                SmallFourLevelClaims.CLAIM_ONE, start + step
            )
        );
        _assertMachineEq(
            one.leaf(1).toMachineHash(),
            SmallFourLevelClaims.stateAfter(
                SmallFourLevelClaims.CLAIM_ONE, start + 2 * step
            )
        );
        _assertMachineEq(
            two.leaf(1).toMachineHash(),
            SmallFourLevelClaims.stateAfter(
                SmallFourLevelClaims.CLAIM_TWO, start + 2 * step
            )
        );
    }

    function _recordedChild(
        InspectableTournament parent,
        Match.Id memory origin
    ) private returns (InspectableTournament recorded) {
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

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer
    ) private returns (Tree.Node root) {
        (Tree.Node left, Tree.Node right) =
            tree.children(SmallFourLevelGeometry.HEIGHT, 0);
        uint256 bond = tournament.bondValue();
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
        return tree.root();
    }

    function _assertMatchEq(Match.Id memory actual, Match.Id memory expected)
        private
        pure
    {
        _assertNodeEq(actual.commitmentOne, expected.commitmentOne);
        _assertNodeEq(actual.commitmentTwo, expected.commitmentTwo);
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
