// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev The worst honest schedule the R19 search (HonestSurvivalInvariant)
/// targets, written out deterministically: budget C + G + (T + 2G) at
/// L = 2, one inclusion below the deployed formula so the margin shown is
/// the one the in-flight reserve adds to, the honest commitment as commitment two at
/// every level, every honest latency at its bound minus one, the whole
/// censorship budget spent on the first child join, and two consecutive
/// delegations against Sybils that reveal one block before their own
/// deadlines. The honest commitment survives with a margin of two blocks
/// in the leaf race and the second child join; with the child-return
/// refill removed (the rule before cartesi/dave#287) the second child join
/// lands after the child's closure and the honest commitment is eliminated.
/// Not an exploit: this is the regression the refill protects.
contract HonestSurvivalScheduleTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 3;
    uint64 constant T = 6;

    function _run(uint64 c) internal {
        // One inclusion below ClockBudgets.maxAllowance at L = 2.
        uint64 allowance = c + G + (T + 2 * G);
        vm.roll(1000);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, allowance));
        uint64 start = uint64(vm.getBlockNumber());

        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybilOne = fineLeaves(1, 15, 2);
        Tree.Node[] memory sybilTwo = fineLeaves(1, 7, 4);
        SmallFullTree.Data memory h = rootTreeOf(honest);
        SmallFullTree.Data memory s1 = rootTreeOf(sybilOne);
        SmallFullTree.Data memory s2 = rootTreeOf(sybilTwo);

        // Sybil one takes the dangling slot at the start; the honest join
        // lands at its latency bound.
        join(root, s1, SYBIL);
        rollTo(start + G - 1);
        join(root, h, HONEST);
        assertEq(allowanceOf(root, h.root()), allowance - (G - 1));
        // Sybil two waits dangling for the honest winner's return.
        rollBy(1);
        join(root, s2, SYBIL);

        // Sybil one reveals one block before its deadline, keeping G + 1.
        rollTo(start + G - 1 + allowance - 1);
        advance(root, s1, h);
        assertEq(allowanceOf(root, s1.root()), G + 1);
        // The honest seal lands at its bound and is fully discounted.
        rollBy(G - 1);
        (InspectableTournament child, uint256 seg) = sealInner(root, s1, h);
        uint64 envelope = allowanceOf(root, h.root());
        assertEq(envelope, allowance - (G - 1));
        uint64 sealBlock = uint64(vm.getBlockNumber());
        assertEq(sealBlock, start + G - 1 + allowance - 1 + G - 1);
        assertEq(closureOf(child), sealBlock + envelope);

        // First child: the Sybil joins at creation; the honest join lands
        // at T + G - 1 plus the whole censorship budget.
        SmallFullTree.Data memory hc = childTreeOf(honest, seg);
        SmallFullTree.Data memory sc = childTreeOf(sybilOne, seg);
        join(child, sc, SYBIL);
        rollBy(T + G - 1 + c);
        join(child, hc, HONEST);
        assertEq(allowanceOf(child, hc.root()), G + 2, "child join margin");

        rollBy(envelope - 1);
        advance(child, sc, hc);
        rollBy(G - 1);
        uint256 d = sealLeaf(child, sc, hc);
        rollBy(G - 1);
        assertEq(
            uint8(classify(child, sc, hc)),
            uint8(ITournament.MatchTimeoutOutcome.NONE),
            "leaf race still open"
        );
        prove(child, sc, hc, hc, d);
        assertEq(allowanceOf(child, hc.root()), G + 2);
        assertTrue(vm.getBlockNumber() >= closureOf(child), "child closed");
        rollBy(G - 1);
        propagate(root, child, h);
        uint64 returned = allowanceOf(root, h.root());
        assertEq(returned, envelope < T + 3 * G ? envelope : T + 3 * G);
        assertEq(liveMatches(root), 1, "re-paired with Sybil two");

        // Second delegation, censorship exhausted, same Sybil timing. Sybil
        // two joined three blocks after the start, so it holds
        // allowance - 3 and reveals one block before that runs out.
        rollBy(allowance - 3 - 1);
        advance(root, s2, h);
        assertEq(allowanceOf(root, s2.root()), G + 1);
        rollBy(G - 1);
        (InspectableTournament child2, uint256 seg2) = sealInner(root, s2, h);
        uint64 envelope2 = allowanceOf(root, h.root());
        assertEq(envelope2, returned);

        SmallFullTree.Data memory hc2 = childTreeOf(honest, seg2);
        SmallFullTree.Data memory sc2 = childTreeOf(sybilTwo, seg2);
        join(child2, sc2, SYBIL);
        rollBy(T + G - 1);
        join(child2, hc2, HONEST);
        assertGe(allowanceOf(child2, hc2.root()), G + 2, "second join margin");

        rollBy(envelope2 - 1);
        advance(child2, sc2, hc2);
        rollBy(G - 1);
        uint256 d2 = sealLeaf(child2, sc2, hc2);
        rollBy(G - 1);
        prove(child2, sc2, hc2, hc2, d2);
        rollBy(G - 1);
        propagate(root, child2, h);

        assertEq(liveMatches(root), 0);
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(dangling(root).eq(h.root()));
    }

    function testTraceWorstScheduleTwoDelegationsC0() public {
        _run(0);
    }

    function testTraceWorstScheduleTwoDelegationsC2() public {
        _run(2);
    }

    function testTraceWorstScheduleTwoDelegationsC5() public {
        _run(5);
    }
}
