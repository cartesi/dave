// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev What "within G" has to mean for the deployed formula
/// C + 2G + (L - 1)(T + 2G). Every expiry is inclusive: a response is
/// accepted only while elapsed < allowance, and a child winner is usable
/// only before its carryover instant. The security statement therefore
/// reads every latency bound as strict (dispute-game.md, "Security
/// statement and assumptions"; dimensioning.md, "Honest survival under the
/// budgets"; reviews/2026-11-10-contracts-audit, N-07). These pins show
/// what an inclusive reading, a landing exactly at its bound, costs:
///
/// - one level: a join at G and a response at G, with exactly C of
///   censorship, lose by one block; either latency one block shorter wins;
/// - two levels: with every latency at its bound and the whole censorship
///   budget spent on the child join, each acceptance keeps a margin of G;
/// - two levels, one unopposed delegation at C = 0: the formula survives
///   latencies of exactly G, one inclusion less does not, and one inclusion
///   less survives latencies of G - 1, the strict reading the survival
///   searches use.
///
/// Exact boundaries on three fixed schedules in small injected geometry,
/// not a search: HonestSurvivalInvariant.t.sol and
/// MultiLevelHonestSurvival.t.sol own the schedules under strict latencies.
contract InclusiveLatencyBoundaryTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant C = 10;

    function extAdvance(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) external {
        advance(t, one, two);
    }

    /// @dev One level at C + 2G. A Sybil holds the dangling slot and
    /// reveals in the pairing block; the honest response lands after its
    /// latency plus the whole censorship budget.
    /// @param joinLatency Honest root join latency
    /// @param responseLatency Honest response latency before censorship
    /// @return responded Whether the honest response was accepted
    function _oneLevel(uint64 joinLatency, uint64 responseLatency)
        internal
        returns (bool responded)
    {
        uint64 allowance = C + 2 * G;
        vm.roll(100);
        InspectableTournament root = newRoot(singleLevelFactory(G, allowance));
        SmallFullTree.Data memory sybil = seededTree(bytes32("sybil"), 3);
        SmallFullTree.Data memory honest = seededTree(bytes32("honest"), 3);

        join(root, sybil, SYBIL);
        rollTo(100 + joinLatency);
        join(root, honest, HONEST);
        advance(root, sybil, honest);
        rollBy(responseLatency + C);
        try this.extAdvance(root, sybil, honest) {
            return true;
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason), ITournament.CannotAdvanceTimedOutClock.selector
            );
            // The Sybil takes the match and, at closure, the root.
            timeoutWin(root, sybil, honest, sybil);
            if (vm.getBlockNumber() < closureOf(root)) {
                rollTo(closureOf(root));
            }
            assertEq(
                uint8(standing(root)),
                uint8(ITournament.TournamentStanding.ROOT_WINNER)
            );
            assertTrue(dangling(root).eq(sybil.root()));
            return false;
        }
    }

    function testOneLevelInclusiveLatenciesLoseByOneBlock() public {
        assertFalse(_oneLevel(G, G), "both latencies at the bound");
        assertTrue(_oneLevel(G - 1, G), "join one block inside");
        assertTrue(_oneLevel(G, G - 1), "response one block inside");
        assertTrue(_oneLevel(G - 1, G - 1), "the strict strategy");
    }

    function testTwoLevelsInclusiveLatenciesKeepMarginG() public {
        uint64 allowance = C + 2 * G + (T + 2 * G);
        vm.roll(1000);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, allowance));
        uint64 start = uint64(vm.getBlockNumber());

        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 15, 2);
        SmallFullTree.Data memory h = rootTreeOf(honest);
        SmallFullTree.Data memory s = rootTreeOf(sybil);

        join(root, s, SYBIL);
        rollTo(start + G);
        join(root, h, HONEST);
        assertEq(allowanceOf(root, h.root()), allowance - G);
        // The Sybil burns its clock, so the envelope is the honest one.
        rollBy(allowance - 1);
        advance(root, s, h);
        rollBy(G);
        (InspectableTournament child, uint256 seg) = sealInner(root, s, h);
        uint64 envelope = allowanceOf(root, h.root());
        assertEq(envelope, allowance - G);

        SmallFullTree.Data memory hc = childTreeOf(honest, seg);
        SmallFullTree.Data memory sc = childTreeOf(sybil, seg);
        join(child, sc, SYBIL);
        // The child join at its bound plus the whole censorship budget.
        rollBy(T + G + C);
        join(child, hc, HONEST);
        assertEq(allowanceOf(child, hc.root()), 2 * G, "leaf clock");

        rollBy(envelope - 1);
        advance(child, sc, hc);
        assertEq(allowanceOf(child, sc.root()), G + 1);
        rollBy(G);
        uint256 d = sealLeaf(child, sc, hc);
        rollBy(G);
        assertEq(
            uint8(classify(child, sc, hc)),
            uint8(ITournament.MatchTimeoutOutcome.NONE)
        );
        prove(child, sc, hc, hc, d);
        assertEq(allowanceOf(child, hc.root()), 2 * G);
        assertTrue(vm.getBlockNumber() >= closureOf(child));
        rollBy(G);
        propagate(root, child, h);
        assertEq(allowanceOf(root, h.root()), T + 3 * G);
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(dangling(root).eq(h.root()));
    }

    /// @dev One unopposed delegation at C = 0 with every honest action
    /// landing `latency` after it falls due: the root join and the seal
    /// `latency` blocks late, the child join `T + latency`, the propagation
    /// `latency`.
    /// @return propagated Whether the propagation was accepted
    function _oneDelegation(uint64 allowance, uint64 latency)
        internal
        returns (bool propagated)
    {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, allowance));
        Tree.Node[] memory honest = fineLeaves(1);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(fineLeaves(1, 10, 2));

        rollBy(latency);
        join(root, sRoot, SYBIL);
        join(root, hRoot, HONEST);
        advance(root, sRoot, hRoot);
        rollBy(latency);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, sRoot, hRoot);
        rollBy(T + latency);
        join(child, childTreeOf(honest, segment), HONEST);
        rollTo(closureOf(child));
        rollBy(latency);

        (Tree.Node l, Tree.Node r) = hRoot.children(ROOT_HEIGHT, 0);
        try root.winInnerTournament(child, l, r) {
            return true;
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason),
                ITournament.ChildTournamentMustBeEliminated.selector
            );
            return false;
        }
    }

    /// @dev The child winner carries the allowance less T and two latencies.
    /// One inclusion below the formula that is G when the latencies are G:
    /// it equals the propagation latency, and expiry is inclusive.
    function testTwoLevelsInclusiveLatenciesNeedTheWholeFormula() public {
        uint64 formula = 2 * G + (T + 2 * G);
        uint256 snap = vm.snapshotState();
        assertTrue(_oneDelegation(formula, G), "formula, latency G");
        vm.revertToState(snap);
        assertFalse(_oneDelegation(formula - G, G), "formula - G, latency G");
        vm.revertToState(snap);
        assertTrue(
            _oneDelegation(formula - G, G - 1), "formula - G, latency G - 1"
        );
    }
}
