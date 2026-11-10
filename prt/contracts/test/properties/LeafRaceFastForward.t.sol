// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Every move of a bisection is forced by hashes, so a third party
/// that knows both trees can join the correct commitments itself and play
/// both sides, root and child, down to the leaf seal inside one block. The
/// correct party then meets its dispute as a sealed leaf race.
///
/// - Refuted: the fast-forward defeats a correct party that joined nothing.
///   With both leaf commitments joined in one block the leaf clocks are
///   equal, the proof lands after the build and one inclusion, and the
///   correct root gets its whole envelope back.
/// - Trace: joined one block after the Sybil's, the correct leaf
///   commitment holds the shorter clock, and with no proof by its deadline
///   the Sybil wins by default. A sealed leaf nobody proves is decided by
///   the clocks, which favor the earlier join, so safety needs the proof,
///   or the claim, to land (dispute-game.md, "Security statement and
///   assumptions"; reviews/2026-11-10-contracts-audit, N-04).
///
/// Two fixed schedules in the small two-level geometry; the leaf step is a
/// stub, so nothing here is evidence that a real proof fits a transaction.
contract LeafRaceFastForwardTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    function testRefutedOneBlockFastForwardToTheLeafRace() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);

        // Block 100: the adversary joins both roots and plays to the seal.
        join(root, sRoot, SYBIL);
        join(root, hRoot, THIRD);
        advanceToSeal(root, sRoot, hRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, sRoot, hRoot);
        assertEq(vm.getBlockNumber(), 100);
        assertEq(
            Time.Duration.unwrap(child.tournamentArguments().allowance),
            ALLOWANCE,
            "the child inherits the whole root allowance"
        );

        // Still block 100: both child commitments, and the leaf seal.
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        join(child, sChild, SYBIL);
        join(child, hChild, THIRD);
        advanceToSeal(child, sChild, hChild);
        uint256 d = sealLeaf(child, sChild, hChild);
        assertEq(vm.getBlockNumber(), 100);
        assertEq(allowanceOf(child, hChild.root()), ALLOWANCE);
        assertEq(allowanceOf(child, sChild.root()), ALLOWANCE);

        // Equal leaf clocks leave no timeout-win window: NONE up to the
        // last block, then both are eliminable.
        uint256 snap = vm.snapshotState();
        rollTo(100 + ALLOWANCE - 1);
        assertEq(
            uint8(classify(child, sChild, hChild)),
            uint8(ITournament.MatchTimeoutOutcome.NONE)
        );
        rollBy(1);
        assertEq(
            uint8(classify(child, sChild, hChild)),
            uint8(ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH)
        );
        vm.revertToState(snap);

        // The honest party joined nothing. It needs T to compute the proof
        // and one inclusion below G.
        rollBy(T + G - 1);
        vm.prank(HONEST);
        prove(child, sChild, hChild, hChild, d);
        assertEq(
            allowanceOf(child, hChild.root()),
            ALLOWANCE - (T - 1),
            "charged its latency beyond one G"
        );

        // Child and root close in the same block; the return refills up to
        // the envelope, which here is the whole root allowance.
        rollTo(closureOf(child));
        assertEq(closureOf(child), closureOf(root));
        vm.prank(HONEST);
        propagate(root, child, hRoot);
        assertEq(allowanceOf(root, hRoot.root()), ALLOWANCE);
        ITournament.TournamentStandingView memory s = root.tournamentStanding();
        assertEq(
            uint8(s.standing), uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(s.candidate.eq(hRoot.root()));
        assertEq(
            Machine.Hash.unwrap(s.finalState),
            Machine.Hash.unwrap(hRoot.finalState())
        );
    }

    function testTraceUnprovenLeafRaceDefaultsToTheFullerClock() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);
        join(root, sRoot, SYBIL);
        join(root, hRoot, THIRD);
        advanceToSeal(root, sRoot, hRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, sRoot, hRoot);
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        join(child, sChild, SYBIL);
        rollBy(1);
        join(child, hChild, THIRD);
        advanceToSeal(child, sChild, hChild);
        sealLeaf(child, sChild, hChild);

        // Honest clock ALLOWANCE - 1 from block 101; Sybil clock ALLOWANCE.
        rollTo(101 + ALLOWANCE - 1);
        assertEq(
            uint8(classify(child, sChild, hChild)),
            uint8(ITournament.MatchTimeoutOutcome.ONE_WINS),
            "no proof by the honest deadline: the Sybil wins by default"
        );
        vm.prank(SYBIL);
        timeoutWin(child, sChild, hChild, sChild);
        rollTo(closureOf(child) + 1);
        propagate(root, child, sRoot);
        assertTrue(dangling(root).eq(sRoot.root()));
        assertEq(root.observedClaimer(hRoot.root()), address(0));
    }
}
