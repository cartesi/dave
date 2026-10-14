// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// Price of root settlement delay per root bond, two-level small geometry.
contract DelayPerRootBondTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant A = 200;
    uint64 constant START = 100;

    function _assertActive(InspectableTournament root) internal view {
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.MATCHES_ACTIVE)
        );
    }

    function _assertWon(InspectableTournament root) internal view {
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
    }

    // One root Sybil, zero child bonds: settlement at START + 2A - 1.
    function testOneRootBond() public {
        vm.roll(START);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, A));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory s1 = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hR = rootTreeOf(honest);
        SmallFullTree.Data memory s1R = rootTreeOf(s1);

        join(root, s1R, SYBIL); // dangling, paused at A
        join(root, hR, HONEST); // pairs; S1 is one and runs
        rollTo(START + A - 1);
        advance(root, s1R, hR); // S1 spends its whole clock
        (InspectableTournament child, uint256 seg) = sealInner(root, s1R, hR); // H seals at e = 0
        assertEq(allowanceOf(root, hR.root()), A);
        // the child allowance is the honest remainder, not the Sybil's 6
        assertEq(closureOf(child), START + A - 1 + A);
        rollBy(T + G);
        join(child, childTreeOf(honest, seg), HONEST); // alone
        rollTo(closureOf(child) - 1);
        _assertActive(root);
        rollTo(closureOf(child));
        propagate(root, child, hR);
        assertEq(allowanceOf(root, hR.root()), A); // refilled to full
        _assertWon(root);
        emit log_named_uint("undisputed settlement", START + A);
        emit log_named_uint("one root bond settlement", block.number);
    }

    // Two root Sybils, zero child bonds: the second waits dangling with a
    // full paused clock; settlement at START + 4A - 2.
    function testTwoRootBonds() public {
        vm.roll(START);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, A));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory s1 = fineLeaves(1, 10, 2);
        Tree.Node[] memory s2 = fineLeaves(1, 6, 3);
        SmallFullTree.Data memory hR = rootTreeOf(honest);
        SmallFullTree.Data memory s1R = rootTreeOf(s1);
        SmallFullTree.Data memory s2R = rootTreeOf(s2);

        join(root, s1R, SYBIL);
        join(root, hR, HONEST);
        join(root, s2R, SYBIL_TWO); // dangling, paused at A
        assertTrue(dangling(root).eq(s2R.root()));

        rollTo(START + A - 1);
        advance(root, s1R, hR);
        (InspectableTournament c1, uint256 seg1) = sealInner(root, s1R, hR);
        rollBy(T + G);
        join(c1, childTreeOf(honest, seg1), HONEST);
        rollTo(closureOf(c1));
        propagate(root, c1, hR); // H re-pairs with S2 (one)
        assertEq(liveMatches(root), 1);
        assertEq(allowanceOf(root, s2R.root()), A);

        rollBy(A - 1);
        advance(root, s2R, hR); // S2 spends its whole clock
        (InspectableTournament c2, uint256 seg2) = sealInner(root, s2R, hR);
        assertEq(closureOf(c2), block.number + A);
        rollBy(T + G);
        join(c2, childTreeOf(honest, seg2), HONEST);
        rollTo(closureOf(c2) - 1);
        _assertActive(root);
        rollTo(closureOf(c2));
        propagate(root, c2, hR);
        _assertWon(root);
        assertEq(block.number, START + 4 * A - 2);
        emit log_named_uint("two root bonds settlement", block.number);
    }

    // A Sybil that joins G + 1 blocks before closure (clock G + 1) still
    // forces a full-A child: settlement at START + 2A - 2.
    function testLateTinyClockRootBond() public {
        vm.roll(START);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, A));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory s1 = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hR = rootTreeOf(honest);
        SmallFullTree.Data memory s1R = rootTreeOf(s1);

        join(root, hR, HONEST);
        rollTo(START + A - G - 1);
        join(root, s1R, SYBIL);
        assertEq(allowanceOf(root, s1R.root()), G + 1);
        advance(root, hR, s1R); // honest at e = 0
        rollBy(G - 1);
        (InspectableTournament child, uint256 seg) = sealInner(root, hR, s1R); // sybil seals, e = G - 1
        assertEq(closureOf(child), block.number + A);
        rollBy(T + G);
        join(child, childTreeOf(honest, seg), HONEST);
        rollTo(closureOf(child));
        propagate(root, child, hR);
        _assertWon(root);
        emit log_named_uint("late tiny-clock bond settlement", block.number);
    }

    // One root bond plus two leaf bonds in the honest child: the child's own
    // dangling slot adds one more full child clock; settlement ~START + 3A.
    function testOneRootTwoLeafBonds() public {
        vm.roll(START);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, A));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory s1 = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hR = rootTreeOf(honest);
        SmallFullTree.Data memory s1R = rootTreeOf(s1);

        join(root, s1R, SYBIL);
        join(root, hR, HONEST);
        rollTo(START + A - 1);
        advance(root, s1R, hR);
        (InspectableTournament child, uint256 seg) = sealInner(root, s1R, hR);
        uint64 t0 = uint64(block.number);
        uint64 e = A;
        SmallFullTree.Data memory hC = childTreeOf(honest, seg);
        // child Sybils in S1's class: same final state, distinct trees
        Tree.Node[] memory sa = fineLeaves(1, 10, 2);
        Tree.Node[] memory sb = fineLeaves(4, 10, 2);
        SmallFullTree.Data memory saC = childTreeOf(sa, seg);
        SmallFullTree.Data memory sbC = childTreeOf(sb, seg);
        // sbC must end at S1's contested final state: rebuild with the same last leaf
        join(child, saC, SYBIL); // dangling at t0, clock E
        rollBy(T + G);
        join(child, hC, HONEST); // pairs: saC is one
        join(child, sbC, SYBIL_TWO); // dangling, clock E - T - G
        rollTo(t0 + e - 1);
        advance(child, saC, hC);
        uint256 d = sealLeaf(child, saC, hC);
        prove(child, saC, hC, hC, d);
        // honest re-paired with sbC (one)
        assertEq(liveMatches(child), 1);
        rollBy(allowanceOf(child, sbC.root()) - 1);
        advance(child, sbC, hC);
        d = sealLeaf(child, sbC, hC);
        prove(child, sbC, hC, hC, d);
        assertEq(liveMatches(child), 0);
        emit log_named_uint("child finished at", block.number);
        propagate(root, child, hR);
        _assertWon(root);
        emit log_named_uint(
            "one root + two leaf bonds settlement", block.number
        );
    }
}
