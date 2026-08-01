// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "./InspectableTournament.sol";
import {ProofSelectedStateTransition} from "./ProofSelectedStateTransition.sol";
import {SmallFullTree} from "./SmallFullTree.sol";
import {
    SmallSingleLevelParametersProvider,
    SmallSingleLevelTournamentFactory
} from "./SmallSingleLevelTournament.sol";

contract SmallSingleLevelTournamentTest is Test {
    using Match for Match.Id;
    using Match for Match.State;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    uint64 internal constant HEIGHT = 3;
    uint64 internal constant START_BLOCK = 100;
    uint64 internal constant RESPONSE_BUDGET = 5;
    uint64 internal constant MAX_ALLOWANCE = 1_000;

    address internal constant CLAIMER_ONE = address(0xa11ce);
    address internal constant CLAIMER_TWO = address(0xb0b);
    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x1234)));

    SmallSingleLevelTournamentFactory internal immutable FACTORY;

    constructor() {
        FACTORY = new SmallSingleLevelTournamentFactory(
            Time.Duration.wrap(RESPONSE_BUDGET),
            Time.Duration.wrap(MAX_ALLOWANCE)
        );
    }

    function setUp() public {
        vm.roll(START_BLOCK);
        vm.deal(CLAIMER_ONE, 100 ether);
        vm.deal(CLAIMER_TWO, 100 ether);
    }

    function testCloneArgumentsObservabilityAndPairing() public {
        InspectableTournament tournament = InspectableTournament(
            address(
                FACTORY.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
        ITournament.TournamentArguments memory args =
            tournament.tournamentArguments();
        assertEq(args.level, 0);
        assertEq(args.levels, 1);
        assertEq(args.commitmentArgs.height, HEIGHT);
        assertEq(args.commitmentArgs.log2step, 0);
        assertEq(args.commitmentArgs.startCycle, 0);
        assertEq(
            Machine.Hash.unwrap(args.commitmentArgs.initialHash),
            Machine.Hash.unwrap(INITIAL_STATE)
        );
        assertEq(Time.Instant.unwrap(args.startInstant), START_BLOCK);
        assertEq(Time.Duration.unwrap(args.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(args.responseBudget), RESPONSE_BUDGET);
        assertEq(address(args.provider), address(0));
        assertEq(args.tournamentFactory, address(FACTORY));
        assertGt(address(args.stateTransition).code.length, 0);

        SmallFullTree.Data memory one =
            SmallFullTree.build(bytes32(uint256(1)), HEIGHT);
        SmallFullTree.Data memory two =
            SmallFullTree.build(bytes32(uint256(2)), HEIGHT);
        uint256 bond = tournament.bondValue();
        _join(tournament, one, CLAIMER_ONE, bond);

        (
            Tree.Node dangling,
            uint256 activeMatches,
            Time.Instant mostRecentDeletion
        ) = tournament.observedTopology();
        assertTrue(dangling.eq(one.root()));
        assertEq(activeMatches, 0);
        assertTrue(mostRecentDeletion.isZero());
        assertEq(tournament.observedClaimer(one.root()), CLAIMER_ONE);
        (Clock.State memory clockOne, Machine.Hash finalStateOne) =
            tournament.getCommitment(one.root());
        assertTrue(clockOne.startInstant.isZero());
        assertEq(Time.Duration.unwrap(clockOne.allowance), MAX_ALLOWANCE);
        assertEq(
            Machine.Hash.unwrap(finalStateOne),
            Machine.Hash.unwrap(one.finalState())
        );
        assertEq(tournament.getCommitmentJoinedCount(), 1);
        assertEq(tournament.getMatchCreatedCount(), 0);

        _join(tournament, two, CLAIMER_TWO, bond);
        (dangling, activeMatches, mostRecentDeletion) =
            tournament.observedTopology();
        assertTrue(dangling.isZero());
        assertEq(activeMatches, 1);
        assertTrue(mostRecentDeletion.isZero());
        assertEq(tournament.observedClaimer(one.root()), CLAIMER_ONE);
        assertEq(tournament.observedClaimer(two.root()), CLAIMER_TWO);

        Match.Id memory id = Match.Id(one.root(), two.root());
        Match.State memory state = tournament.getMatch(id.hashFromId());
        assertTrue(state.exists());
        assertEq(state.currentHeight, HEIGHT);
        assertTrue(state.otherParent.eq(one.root()));
        (Tree.Node twoLeft, Tree.Node twoRight) = two.children(HEIGHT, 0);
        assertTrue(state.leftNode.eq(twoLeft));
        assertTrue(state.rightNode.eq(twoRight));
        (Clock.State memory pairedOne,) = tournament.getCommitment(one.root());
        (Clock.State memory pairedTwo,) = tournament.getCommitment(two.root());
        assertEq(Time.Instant.unwrap(pairedOne.startInstant), START_BLOCK);
        assertTrue(pairedTwo.startInstant.isZero());
        assertEq(Time.Duration.unwrap(pairedOne.allowance), MAX_ALLOWANCE);
        assertEq(Time.Duration.unwrap(pairedTwo.allowance), MAX_ALLOWANCE);
        assertEq(tournament.getCommitmentJoinedCount(), 2);
        assertEq(tournament.getMatchCreatedCount(), 1);
        assertEq(tournament.getMatchAdvancedCount(), 0);
        assertEq(tournament.getMatchDeletedCount(), 0);

        bytes32 selected = bytes32(uint256(0xfeed));
        assertEq(
            args.stateTransition
                .transitionState(
                    bytes32(0),
                    0,
                    abi.encode(selected),
                    IDataProvider(address(0))
                ),
            selected
        );
    }

    function testHarnessRejectsUnsupportedLevelAndPayload() public {
        SmallSingleLevelParametersProvider provider = new SmallSingleLevelParametersProvider(
            Time.Duration.wrap(RESPONSE_BUDGET),
            Time.Duration.wrap(MAX_ALLOWANCE)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                SmallSingleLevelParametersProvider.InvalidLevel.selector, 1
            )
        );
        provider.tournamentParameters(1);

        ProofSelectedStateTransition stateTransition =
            new ProofSelectedStateTransition();
        vm.expectRevert(
            abi.encodeWithSelector(
                ProofSelectedStateTransition.InvalidProofLength.selector, 0
            )
        );
        stateTransition.transitionState(
            bytes32(0), 0, bytes(""), IDataProvider(address(0))
        );
    }

    function testMatchAdvancedEventMatchesStoredStateOnBothBranches() public {
        _assertMatchAdvancedEvent(false);
        _assertMatchAdvancedEvent(true);
    }

    function _assertMatchAdvancedEvent(bool descendRight) internal {
        InspectableTournament tournament = InspectableTournament(
            address(
                FACTORY.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
        (SmallFullTree.Data memory one, SmallFullTree.Data memory two) =
            _eventTrees(descendRight);
        uint256 bond = tournament.bondValue();
        _join(tournament, one, CLAIMER_ONE, bond);
        _join(tournament, two, CLAIMER_TWO, bond);

        Match.Id memory id = Match.Id(one.root(), two.root());
        (Tree.Node oneLeft, Tree.Node oneRight) = one.children(HEIGHT, 0);
        (Tree.Node twoLeft, Tree.Node twoRight) = two.children(HEIGHT, 0);
        uint256 childIndex = descendRight ? 1 : 0;
        (Tree.Node newLeft, Tree.Node newRight) =
            one.children(HEIGHT - 1, childIndex);
        Tree.Node expectedOtherParent = descendRight ? twoRight : twoLeft;

        vm.expectEmit(true, false, false, true, address(tournament));
        emit ITournament.MatchAdvanced(
            id.hashFromId(), expectedOtherParent, newLeft
        );
        tournament.advanceMatch(id, oneLeft, oneRight, newLeft, newRight);

        Match.State memory state = tournament.getMatch(id.hashFromId());
        assertTrue(state.isInit);
        assertEq(state.currentHeight, HEIGHT - 1);
        assertEq(
            state.runningLeafPosition,
            descendRight ? uint256(1) << (HEIGHT - 1) : 0
        );
        assertTrue(state.otherParent.eq(expectedOtherParent));
        assertTrue(state.leftNode.eq(newLeft));
        assertTrue(state.rightNode.eq(newRight));
        assertEq(tournament.getMatchAdvancedCount(), 1);
    }

    function _eventTrees(bool rightHalfDiffers)
        internal
        pure
        returns (SmallFullTree.Data memory one, SmallFullTree.Data memory two)
    {
        uint256 leafCount = uint256(1) << HEIGHT;
        Tree.Node[] memory oneLeaves = new Tree.Node[](leafCount);
        Tree.Node[] memory twoLeaves = new Tree.Node[](leafCount);
        for (uint256 i; i < leafCount; ++i) {
            Tree.Node leaf =
                Tree.Node.wrap(keccak256(abi.encode(uint256(0x1111), i)));
            oneLeaves[i] = leaf;
            twoLeaves[i] = leaf;
        }

        uint256 divergentPosition =
            rightHalfDiffers ? uint256(1) << (HEIGHT - 1) : 0;
        twoLeaves[divergentPosition] = Tree.Node
            .wrap(keccak256(abi.encode(uint256(0x2222), divergentPosition)));
        one = SmallFullTree.buildFromLeaves(oneLeaves);
        two = SmallFullTree.buildFromLeaves(twoLeaves);
    }

    function _join(
        InspectableTournament tournament,
        SmallFullTree.Data memory tree,
        address claimer,
        uint256 bond
    ) internal {
        (Tree.Node left, Tree.Node right) = tree.children(HEIGHT, 0);
        vm.prank(claimer);
        tournament.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
    }
}
