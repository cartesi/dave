// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Evidence for HONEST-NODE-CONTRACT.md: each test pins one contract
/// behavior the honest node must compose with. None is an exploit; each
/// passes on the current tree and documents an obligation or a refutation.
contract HonestNodeObligationsTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Time for Time.Duration;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    function _joinReverts(
        InspectableTournament t,
        SmallFullTree.Data memory tree,
        address claimer,
        bytes4 selector
    ) internal {
        (,,, uint64 height) = t.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = tree.children(height, 0);
        uint256 bond = t.bondValue();
        bytes32[] memory proof = tree.finalProof();
        vm.prank(claimer);
        vm.expectRevert(selector);
        t.joinTournament{value: bond}(tree.finalState(), proof, left, right);
    }

    function _deadline(InspectableTournament t, Tree.Node root)
        internal
        view
        returns (uint64)
    {
        Clock.State memory c = clockOf(t, root);
        return Time.Instant.unwrap(c.startInstant.add(c.allowance));
    }

    /// Obligation: defend the correct commitment even when another address
    /// joined it first. The honest join reverts (Clock.sol:130), progress
    /// stays permissionless, and the payment slot belongs to the first
    /// claimer (Tournament.sol:241, :497).
    function testContractHonestJoinRevertsButDefenseWins() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);

        join(root, hRoot, THIRD);
        _joinReverts(
            root, hRoot, HONEST, ITournament.ClockAlreadyInitialized.selector
        );
        join(root, sRoot, SYBIL);

        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        rollBy(T + 1);
        join(child, sChild, SYBIL);
        join(child, hChild, HONEST);
        advanceToSeal(child, sChild, hChild);
        uint256 d = sealLeaf(child, sChild, hChild);
        prove(child, sChild, hChild, hChild, d);
        rollTo(closureOf(child));
        propagate(root, child, hRoot);
        rollTo(closureOf(root));
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        (ITournament.BondDisposition disp, address claimer,) =
            root.bondRecovery();
        assertEq(uint8(disp), uint8(ITournament.BondDisposition.RECOVERABLE));
        assertEq(claimer, THIRD, "the first joiner owns the payment slot");
        assertEq(root.observedClaimer(hRoot.root()), THIRD);
    }

    /// Obligation: a child is classified by final state, not lineage. A
    /// distinct-root entrant with the honest final state can win the child,
    /// and its win propagates to the honest parent (Tournament.sol:758-771,
    /// :1161-1171). The node must propagate it, and must not treat the loss
    /// or absence of its own child commitment as terminal for the parent.
    function testContractSameClassDistinctRootChildWinSavesHonestParent()
        public
    {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        Tree.Node[] memory sameClass = fineLeaves(1);
        sameClass[8] = Tree.Node.wrap(bytes32(uint256(0xdead)));
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);
        assertTrue(rootTreeOf(sameClass).root().eq(hRoot.root()));

        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        assertEq(segment, 2);

        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        SmallFullTree.Data memory xChild = childTreeOf(sameClass, segment);
        assertFalse(xChild.root().eq(childTreeOf(honest, segment).root()));
        assertEq(
            Tree.Node.unwrap(xChild.leaf(SEGMENT_SIZE - 1)),
            Tree.Node
            .unwrap(childTreeOf(honest, segment).leaf(SEGMENT_SIZE - 1))
        );

        // The honest node never joins the child.
        join(child, sChild, SYBIL);
        join(child, xChild, SYBIL_TWO);
        advanceToSeal(child, sChild, xChild);
        uint256 d = sealLeaf(child, sChild, xChild);
        prove(child, sChild, xChild, xChild, d);
        rollTo(closureOf(child));
        ITournament.InnerResultView memory r = child.innerResult();
        assertEq(
            uint8(r.disposition),
            uint8(ITournament.InnerTournamentDisposition.WINNER)
        );
        assertTrue(r.parentCommitment.eq(hRoot.root()));

        propagate(root, child, hRoot);
        rollTo(closureOf(root));
        ITournament.TournamentStandingView memory s = root.tournamentStanding();
        assertEq(
            uint8(s.standing), uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(s.candidate.eq(hRoot.root()));
    }

    /// Obligation: a dangling candidate is not safe until closure. A join in
    /// the last open block pairs it as the elder and starts its clock
    /// (Tournament.sol:1190-1202); progress continues after closure
    /// (advance is gated on finished, not closed, Tournament.sol:254).
    function testContractLateJoinStartsDanglingHonestClock() public {
        vm.roll(100);
        InspectableTournament root = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory h = seededTree("honest", 3);
        SmallFullTree.Data memory s = seededTree("sybil", 3);
        join(root, h, HONEST);
        rollTo(closureOf(root) - 1);
        join(root, s, SYBIL);
        Clock.State memory c = clockOf(root, h.root());
        assertEq(Time.Instant.unwrap(c.startInstant), block.number);

        rollTo(closureOf(root));
        ITournament.TournamentStandingView memory st = root.tournamentStanding();
        assertFalse(st.acceptsJoins);
        assertEq(
            uint8(st.standing),
            uint8(ITournament.TournamentStanding.MATCHES_ACTIVE)
        );
        advance(root, h, s);
    }

    /// Refuted: an adversary that joins the honest child commitment before
    /// the honest build finishes, and pairs it at once, starts the honest
    /// clock early, but the honest side keeps at least what its own join at
    /// T + G would leave (Clock.sol:131, :159).
    function testRefutedPreJoinBeforeBuildDrainsHonestChildClock() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);
        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        uint64 s0 = uint64(block.number);
        uint64 envelope =
            Time.Duration.unwrap(child.tournamentArguments().allowance);
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);

        rollBy(1);
        join(child, hChild, THIRD);
        join(child, sChild, SYBIL);
        // The honest build takes T, then one inclusion below G.
        rollTo(s0 + T + G - 1);
        _joinReverts(
            child, hChild, HONEST, ITournament.ClockAlreadyInitialized.selector
        );
        advance(child, hChild, sChild);
        assertGe(allowanceOf(child, hChild.root()), envelope - (T + G));
    }

    /// Obligation: propagate strictly before resultAt + carried. The carried
    /// clock decays from resultAt, which can be the child's closure rather
    /// than its last deletion (Tournament.sol:1085-1092, :1358-1371); at the
    /// boundary the child is ELIMINABLE and elimination removes both parent
    /// sides (Tournament.sol:749-752, :829-834).
    function testContractPropagationDeadlineIsHard() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);
        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        rollBy(T + 1);
        join(child, sChild, SYBIL);
        join(child, hChild, HONEST);
        advanceToSeal(child, sChild, hChild);
        uint256 d = sealLeaf(child, sChild, hChild);
        prove(child, sChild, hChild, hChild, d);
        uint64 carried = allowanceOf(child, hChild.root());
        uint64 closure = closureOf(child);
        assertLt(block.number, closure, "won before closure");

        rollTo(closure + carried - 1);
        ITournament.InnerResultView memory r = child.innerResult();
        assertEq(
            uint8(r.disposition),
            uint8(ITournament.InnerTournamentDisposition.WINNER)
        );
        assertEq(Time.Duration.unwrap(r.pausedAllowance), 1);

        rollBy(1);
        (,,, uint64 height) = root.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = hRoot.children(height, 0);
        vm.expectRevert(ITournament.ChildTournamentMustBeEliminated.selector);
        root.winInnerTournament(child, left, right);
        eliminateChild(root, child);
        assertEq(liveMatches(root), 0);
        assertTrue(dangling(root).isZero());
        assertEq(root.observedClaimer(hRoot.root()), address(0));
    }

    /// Obligation: when the opponent expires in bisection, claim within G of
    /// its deadline; later claims are charged the overdue beyond G, and from
    /// deadline + own remainder both are eliminable by anyone
    /// (MatchClocks.sol:229-249, Clock.sol:170-183).
    function testContractTimeoutClaimWindow() public {
        vm.roll(100);
        InspectableTournament root = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory h = seededTree("honest", 3);
        SmallFullTree.Data memory s = seededTree("sybil", 3);
        join(root, h, HONEST);
        join(root, s, SYBIL);
        advance(root, h, s); // honest responds; Sybil's clock runs
        uint64 sd = _deadline(root, s.root());
        uint64 ha = allowanceOf(root, h.root());

        uint256 snap = vm.snapshotState();
        rollTo(sd + G);
        timeoutWin(root, h, s, h);
        assertEq(allowanceOf(root, h.root()), ha, "within G: free");
        vm.revertToState(snap);

        rollTo(sd + G + 7);
        timeoutWin(root, h, s, h);
        assertEq(allowanceOf(root, h.root()), ha - 7, "charged beyond G");
        vm.revertToState(snap);

        rollTo(sd + ha);
        assertEq(
            uint8(classify(root, h, s)),
            uint8(ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH)
        );
        (,,, uint64 height) = root.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = h.children(height, 0);
        vm.expectRevert(ITournament.MatchCannotBeWonByTimeout.selector);
        root.winMatchByTimeout(matchId(h, s), left, right);
        vm.prank(SYBIL);
        eliminate(root, h, s);
    }
}
