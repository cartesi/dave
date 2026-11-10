// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Lead, not a defect: the leaf proof-to-timeout handover, an accepted
/// limitation (dispute-game.md, "Resolution and winner re-entry", CF-01 and
/// "Why the handover stays"; reviews/2026-11-10-contracts-audit, N-01),
/// priced at the deployed formula C + 2G + (L - 1)(T + 2G) with L = 2 and
/// C = 0. Every honest action lands strictly inside its own bound: G for
/// an advance, a seal, a proof and a timeout claim, T + G for the child
/// join.
///
/// Two Sybils enter the leaf child nine blocks before it closes, so each
/// holds a clock of 9 = G - 1, which in-time responses never reduce. The
/// first pairs with the dangling honest commitment at once. The second is
/// parked: a Sybil holder with a full clock is released from its own match
/// by a leaf proof in the same block and takes the dangling slot, and the
/// second late Sybil pairs under it as the paused side. After the first
/// handover, a leaf proof for the parked Sybil finishes the holder's match
/// and re-pairs it with the dangling honest commitment inside that call,
/// its clock of 9 intact.
///
/// Each handover: the honest proof lands G - 1 after the seal, exactly at
/// the Sybil's deadline, and reverts; the timeout claim lands G - 1 after
/// it became possible. The first costs the honest leaf clock G - 2 blocks.
/// The second cannot land before the honest clock itself expires: the
/// match is eliminated, then the child, and the root finishes with a wrong
/// final state. Price: two root bonds and four leaf bonds, one leaf bond
/// for the first occurrence and three for the next.
///
/// The control lands proof and claim within one G of the seal together,
/// the bound the security statement requires, and both handovers are free.
/// One trace in the small two-level geometry: it prices the limitation and
/// does not bound how often it can be staged at canonical heights.
contract LeafHandoverTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 10;
    uint64 constant T = 20;
    uint64 constant C = 0;
    uint64 constant ALLOWANCE = C + 2 * G + (T + 2 * G); // 60

    uint256 constant SEGMENT = 3;

    Tree.Node[] honest;
    Tree.Node[] sybil;

    function _leaves(Tree.Node a, Tree.Node b, Tree.Node c, Tree.Node d)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory l = new Tree.Node[](4);
        l[0] = a;
        l[1] = b;
        l[2] = c;
        l[3] = d;
        return SmallFullTree.buildFromLeaves(l);
    }

    /// @dev A leaf no computation claims.
    function _foreign(uint256 tag) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(bytes32(uint256(0xbad0000) + tag));
    }

    /// @param claimLatency Blocks between the Sybil's deadline, where the
    /// timeout claim becomes possible, and the honest claim landing.
    function _run(uint64 claimLatency)
        internal
        returns (InspectableTournament root, bool honestSurvived)
    {
        vm.roll(1000);
        root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        honest = fineLeaves(1);
        sybil = fineLeaves(1, 15, 2);
        SmallFullTree.Data memory h = rootTreeOf(honest);
        SmallFullTree.Data memory s = rootTreeOf(sybil);
        // A second wrong root claim that only waits in the dangling slot.
        SmallFullTree.Data memory w = rootTreeOf(fineLeaves(1, 3, 6));

        join(root, s, SYBIL);
        rollTo(1000 + G - 1);
        join(root, h, HONEST);
        rollBy(1);
        join(root, w, SYBIL_TWO);

        // The root Sybil reveals one block before its deadline (keeps
        // G + 1), so the child envelope is the honest remainder.
        rollTo(1000 + G - 1 + ALLOWANCE - 1);
        advance(root, s, h);
        rollBy(G - 1);
        (InspectableTournament child, uint256 segment) = sealInner(root, s, h);
        assertEq(segment, SEGMENT);
        uint64 sealBlock = uint64(vm.getBlockNumber());
        uint64 envelope = allowanceOf(root, h.root());
        assertEq(envelope, ALLOWANCE - (G - 1), "envelope");
        uint64 closure = closureOf(child);
        assertEq(closure, sealBlock + envelope);

        // Leaf commitments over fine leaves 12 to 15. Each is correct up to
        // one leaf further than the one it will lose to, so every Sybil
        // proof below is a proof of a correct transition.
        SmallFullTree.Data memory hc = childTreeOf(honest, SEGMENT);
        Tree.Node sLast = sybil[15];
        SmallFullTree.Data memory b0 =
            _leaves(_foreign(1), _foreign(2), _foreign(3), sLast);
        SmallFullTree.Data memory hold =
            _leaves(honest[12], _foreign(4), _foreign(5), sLast);
        SmallFullTree.Data memory x0 =
            _leaves(honest[12], honest[13], _foreign(6), sLast);
        SmallFullTree.Data memory x1 =
            _leaves(honest[12], honest[13], _foreign(7), sLast);

        // Two early Sybils pair with each other; the honest join then
        // lands at its bound and waits dangling.
        join(child, b0, SYBIL);
        join(child, hold, SYBIL);
        rollTo(sealBlock + T + G - 1);
        join(child, hc, HONEST);
        assertEq(allowanceOf(child, hc.root()), 2 * G + 2, "leaf clock");
        assertTrue(dangling(child).eq(hc.root()));

        // Nine blocks before closure: the first late Sybil pairs with the
        // honest commitment; the holder is released by a proof and takes
        // the dangling slot; the second late Sybil pairs under it.
        rollTo(closure - (G - 1));
        join(child, x0, SYBIL);
        assertEq(allowanceOf(child, x0.root()), G - 1);
        advance(child, b0, hold);
        uint256 d = sealLeaf(child, b0, hold);
        prove(child, b0, hold, hold, d);
        assertTrue(dangling(child).eq(hold.root()));
        assertEq(allowanceOf(child, hold.root()), envelope, "holder clock");
        join(child, x1, SYBIL_TWO);
        assertEq(allowanceOf(child, x1.root()), G - 1);
        assertEq(liveMatches(child), 2);

        // Handover one.
        honestSurvived = _handover(child, hc, x0, claimLatency);
        if (!honestSurvived) {
            return (root, false);
        }
        uint64 afterOne = allowanceOf(child, hc.root());
        assertEq(
            afterOne,
            claimLatency + (G - 1) > G
                ? 2 * G + 2 - (claimLatency + (G - 1) - G)
                : 2 * G + 2,
            "charge of handover one"
        );
        assertTrue(dangling(child).eq(hc.root()));

        // Release the parked Sybil: the holder reveals, the parked Sybil
        // seals and is proven, and it re-pairs with the honest commitment
        // inside that call, clock intact.
        assertGt(vm.getBlockNumber(), closure, "release is after closure");
        advance(child, hold, x1);
        d = sealLeaf(child, hold, x1);
        prove(child, hold, x1, x1, d);
        assertEq(allowanceOf(child, x1.root()), G - 1, "parked clock intact");
        assertEq(liveMatches(child), 1);
        assertTrue(dangling(child).isZero());

        // Handover two.
        honestSurvived = _handover(child, hc, x1, claimLatency);
        if (!honestSurvived) {
            // The child has no winner; the root pair goes with it and the
            // waiting wrong claim is the root winner.
            assertEq(liveMatches(child), 0);
            assertTrue(dangling(child).isZero());
            eliminateChild(root, child);
            assertEq(root.observedClaimer(h.root()), address(0));
            ITournament.TournamentStandingView memory st =
                root.tournamentStanding();
            assertEq(
                uint8(st.standing),
                uint8(ITournament.TournamentStanding.ROOT_WINNER)
            );
            assertTrue(st.candidate.eq(w.root()));
            assertFalse(
                Tree.Node.unwrap(st.candidate) == Tree.Node.unwrap(h.root())
            );
        }
    }

    /// @dev One match of the honest commitment (elder) against a late
    /// Sybil: honest advance at G - 1, Sybil seal in the same block, honest
    /// proof at G - 1 after the seal (reverts at the Sybil's deadline),
    /// honest claim `claimLatency` after the deadline.
    function _handover(
        InspectableTournament child,
        SmallFullTree.Data memory hc,
        SmallFullTree.Data memory x,
        uint64 claimLatency
    ) internal returns (bool survived) {
        rollBy(G - 1);
        advance(child, hc, x);
        uint256 d = sealLeaf(child, hc, x);
        uint64 seal = uint64(vm.getBlockNumber());
        uint64 honestClock = allowanceOf(child, hc.root());

        // The proof lands inside its own bound and reverts.
        rollBy(G - 1);
        assertEq(
            uint8(classify(child, hc, x)),
            uint8(ITournament.MatchTimeoutOutcome.ONE_WINS)
        );
        vm.expectRevert(ITournament.CannotAdvanceTimedOutClock.selector);
        this.extProve(child, hc, x, d);

        // The claim became possible at this block and lands
        // `claimLatency` later, inside its own bound.
        rollBy(claimLatency);
        if (vm.getBlockNumber() - seal >= honestClock) {
            assertEq(
                uint8(classify(child, hc, x)),
                uint8(ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH)
            );
            vm.expectRevert(ITournament.MatchCannotBeWonByTimeout.selector);
            this.extTimeoutWin(child, hc, x);
            vm.prank(SYBIL);
            eliminate(child, hc, x);
            return false;
        }
        timeoutWin(child, hc, x, hc);
        return true;
    }

    function extProve(
        InspectableTournament child,
        SmallFullTree.Data memory hc,
        SmallFullTree.Data memory x,
        uint256 d
    ) external {
        (Tree.Node left, Tree.Node right) = hc.children(LEAF_HEIGHT, 0);
        child.winLeafMatch(
            matchId(hc, x),
            left,
            right,
            abi.encode(Tree.Node.unwrap(hc.leaf(d)))
        );
    }

    function extTimeoutWin(
        InspectableTournament child,
        SmallFullTree.Data memory hc,
        SmallFullTree.Data memory x
    ) external {
        (Tree.Node left, Tree.Node right) = hc.children(LEAF_HEIGHT, 0);
        child.winMatchByTimeout(matchId(hc, x), left, right);
    }

    /// @dev Every honest action within its own G: the second handover
    /// eliminates the honest commitment and the root reports a wrong winner.
    function testTracePerActionLatencyLosesAtDeployedFormulaC0() public {
        (, bool survived) = _run(G - 1);
        assertFalse(survived);
    }

    /// @dev The claim lands with the proof inside one G of the seal, the
    /// documented joint bound: both handovers are free.
    function testControlJointLatencySurvivesBothHandovers() public {
        (, bool survived) = _run(1);
        assertTrue(survived);
    }
}
