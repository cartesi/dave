// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Lead, not a defect: a priced work regime the docs describe
/// differently (dispute-game.md, Delay, work, and bracket shape):
/// "only the claims that fit the join window meet [the correct survivor] one
/// by one. Further claims pair with each other and reach the survivor through
/// a bracket, adding matches logarithmically".
///
/// Trace (small two-level fixture, NON_LEAF root of height 2):
/// - start: H and S0 join; S0 holds H for its whole clock (one fresh claim
///   per join window at a non-leaf level: a fresh claim cannot lose faster
///   than its own clock, and sealing opens a child of allowance >= rH).
/// - join window: k Sybil pairs join at staggered blocks u_j. In each pair the
///   elder burns its clock to G + 1 at block start + A - 1, so the pair's
///   timeout releases the burned elder at start + 2A - 1 - u_j.
/// - after closure: each released survivor pairs with the dangling H, H
///   advances once, the survivor lets its G + 1 clock expire at the seal turn,
///   H claims, re-dangles, and the next pair releases in the same block.
/// H meets k = ~A / (G + 2) claims one by one, all after the join window
/// closed, at two root bonds each; the finish time stays start + 2A + O(G).
contract StaggeredReleaseWorkTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;
    using TournamentInspector for InspectableTournament;

    uint64 constant START = 100;
    uint64 constant G = 5;
    uint64 constant T = 20;

    function testTraceStaggeredReleaseFeedsHonestOneByOneAfterClosure() public {
        (uint256 metOne, uint256 afterClosure, uint64 finish) = _run(200);
        assertEq(metOne, 30);
        assertEq(afterClosure, 29);
        assertEq(finish, START + 2 * 200 + G);

        (metOne, afterClosure, finish) = _run(400);
        assertEq(metOne, 58);
        assertEq(afterClosure, 57);
        assertEq(finish, START + 2 * 400 + 1);
    }

    function _run(uint64 allowance)
        private
        returns (uint256 metOneByOne, uint256 metAfterClosure, uint64 finish)
    {
        vm.roll(START);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, allowance));
        uint64 closure = START + allowance;
        uint64 step = G + 2;
        // u_j = A - 3 - step * (j - 1) >= 0, released at start + A + 2 + step*(j-1)
        uint256 k = (allowance - 3) / step + 1;

        SmallFullTree.Data memory h = seededTree(bytes32(uint256(0x1)), 2);
        SmallFullTree.Data memory s0 = seededTree(bytes32(uint256(0x2)), 2);
        SmallFullTree.Data[] memory sa = new SmallFullTree.Data[](k);
        SmallFullTree.Data[] memory sb = new SmallFullTree.Data[](k);
        for (uint256 j; j < k; ++j) {
            sa[j] = seededTree(bytes32(uint256(0x1000 + j)), 2);
            sb[j] = seededTree(bytes32(uint256(0x2000 + j)), 2);
        }

        join(root, h, HONEST);
        join(root, s0, SYBIL);
        rollTo(START + 1);
        advance(root, h, s0); // H's response; S0 now holds H at its seal turn

        // Storage pairs, latest release first.
        for (uint256 i; i < k; ++i) {
            uint256 j = k - 1 - i;
            uint64 u = allowance - 3 - step * uint64(j);
            rollTo(START + u);
            join(root, sa[j], SYBIL);
            join(root, sb[j], SYBIL_TWO);
        }

        // Every elder burns to G + 1 one block before closure.
        rollTo(closure - 1);
        for (uint256 j; j < k; ++j) {
            advance(root, sa[j], sb[j]);
            assertLe(allowanceOf(root, sa[j].root()), G + 1);
        }
        assertEq(liveMatches(root), k + 1);

        // S0 expires; H becomes dangling.
        rollTo(START + 1 + allowance);
        timeoutWin(root, h, s0, h);
        metOneByOne = 1;

        for (uint256 j; j < k; ++j) {
            uint64 release = closure + 2 + step * uint64(j);
            rollTo(release);
            assertTrue(dangling(root).eq(h.root()));
            timeoutWin(root, sa[j], sb[j], sa[j]); // pairs with dangling H
            assertEq(liveMatches(root), k - j);
            rollBy(1);
            advance(root, h, sa[j]);
            rollTo(release + step);
            timeoutWin(root, h, sa[j], h);
            ++metOneByOne;
            if (release >= closure) {
                ++metAfterClosure;
            }
            assertEq(allowanceOf(root, h.root()), allowance);
        }

        assertTrue(root.isFinished());
        (, Tree.Node winner,) = root.arbitrationResult();
        assertTrue(winner.eq(h.root()));
        (bool known, Time.Instant at) = root.timeFinished();
        assertTrue(known);
        finish = Time.Instant.unwrap(at);
        assertEq(root.getMatchCreatedCount(), 2 * k + 1);
        assertEq(root.getCommitmentJoinedCount(), 2 * k + 2);
    }
}
