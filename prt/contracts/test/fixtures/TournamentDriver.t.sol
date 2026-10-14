// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Proves the campaign harness drives a two-level dispute end to end:
/// root pairing, bisection by turn, inner seal, child dispute, leaf proof,
/// propagation, and the final timeout. Not an exploit.
contract TournamentDriverTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    function testHarnessDrivesTwoLevelDispute() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));

        // Honest family 1 everywhere; the Sybil agrees through fine leaf 9
        // and diverges from leaf 10, inside root segment 2.
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);

        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        assertEq(liveMatches(root), 1);

        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        assertEq(segment, 2);
        assertEq(liveMatches(root), 1);

        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        rollBy(T + 1);
        join(child, sChild, SYBIL);
        join(child, hChild, HONEST);

        advanceToSeal(child, sChild, hChild);
        uint256 divergence = sealLeaf(child, sChild, hChild);
        assertEq(divergence, 2, "fine leaf 10 is leaf 2 of segment 2");
        assertEq(
            uint8(classify(child, sChild, hChild)),
            uint8(ITournament.MatchTimeoutOutcome.NONE)
        );
        prove(child, sChild, hChild, hChild, divergence);
        assertTrue(dangling(child).eq(hChild.root()));

        rollTo(closureOf(child));
        assertEq(
            uint8(child.innerResult().disposition),
            uint8(ITournament.InnerTournamentDisposition.WINNER)
        );
        propagate(root, child, hRoot);
        assertTrue(dangling(root).eq(hRoot.root()));
        assertEq(liveMatches(root), 0);

        rollTo(closureOf(root));
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertEq(allowanceOf(root, hRoot.root()), ALLOWANCE);
    }
}
