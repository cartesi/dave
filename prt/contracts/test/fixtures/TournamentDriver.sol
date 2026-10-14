// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {MatchClocks} from "src/tournament/libs/MatchClocks.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {SmallSingleLevelTournamentFactory} from "test/fixtures/SmallSingleLevelTournament.sol";
import {
    SmallTwoLevelGeometry,
    SmallTwoLevelTournamentFactory
} from "test/fixtures/SmallTwoLevelTournament.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

/// @dev Harness for the 2026-10-13 Cyber Verification campaign
/// (docs/reviews/2026-10-13-prt-cyber-verification). It drives any match
/// between two complete small trees without the test knowing whose turn it
/// is, and reads clocks and topology through the white-box inspector. The
/// settlement stub returns whatever leaf the caller supplies, so which side
/// is "correct" is the test's choice; this harness proves tournament
/// plumbing, never transition semantics.
abstract contract TournamentDriver is Test {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for ITournament;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Time for Time.Duration;
    using Match for Match.Id;
    using Match for Match.State;

    uint64 internal constant ROOT_HEIGHT = SmallTwoLevelGeometry.ROOT_HEIGHT;
    uint64 internal constant LEAF_HEIGHT = SmallTwoLevelGeometry.LEAF_HEIGHT;
    uint64 internal constant FINE_HEIGHT = ROOT_HEIGHT + LEAF_HEIGHT;
    uint256 internal constant SEGMENT_SIZE = uint256(1) << LEAF_HEIGHT;
    uint256 internal constant SEGMENT_COUNT = uint256(1) << ROOT_HEIGHT;

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x0abc)));

    address internal constant HONEST = address(0xa11ce);
    address internal constant SYBIL = address(0xbad);
    address internal constant SYBIL_TWO = address(0xbad2);
    address internal constant THIRD = address(0xca11);

    constructor() {
        vm.deal(HONEST, 1000 ether);
        vm.deal(SYBIL, 1000 ether);
        vm.deal(SYBIL_TWO, 1000 ether);
        vm.deal(THIRD, 1000 ether);
    }

    //
    // Factories and roots
    //

    /// @dev Two levels: root (height 2, stride 2^2) over leaf (height 2,
    /// stride 1). A fine computation has 16 transitions.
    function twoLevelFactory(uint64 g, uint64 t, uint64 allowance)
        internal
        returns (SmallTwoLevelTournamentFactory)
    {
        return new SmallTwoLevelTournamentFactory(
            Time.Duration.wrap(g),
            Time.Duration.wrap(t),
            Time.Duration.wrap(allowance)
        );
    }

    /// @dev One leaf level of height 3, stride 1.
    function singleLevelFactory(uint64 g, uint64 allowance)
        internal
        returns (SmallSingleLevelTournamentFactory)
    {
        return new SmallSingleLevelTournamentFactory(
            Time.Duration.wrap(g), Time.Duration.wrap(allowance)
        );
    }

    function newRoot(MultiLevelTournamentFactory factory)
        internal
        returns (InspectableTournament)
    {
        return InspectableTournament(
            address(
                factory.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
    }

    //
    // Claims: fine state tables and their root and child trees
    //

    /// @dev Sixteen fine leaves. Leaves before `divergeAt` belong to family
    /// `fam`, the rest to `altFam`; `fam == altFam` gives one family.
    function fineLeaves(uint256 fam, uint256 divergeAt, uint256 altFam)
        internal
        pure
        returns (Tree.Node[] memory fine)
    {
        fine = new Tree.Node[](uint256(1) << FINE_HEIGHT);
        for (uint256 i; i < fine.length; ++i) {
            uint256 family = i < divergeAt ? fam : altFam;
            fine[i] = Tree.Node.wrap(bytes32((family << 8) | (0x100 + i)));
        }
    }

    function fineLeaves(uint256 fam)
        internal
        pure
        returns (Tree.Node[] memory)
    {
        return fineLeaves(fam, 0, fam);
    }

    /// @dev The root tree samples every segment's last fine leaf.
    function rootTreeOf(Tree.Node[] memory fine)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory coarse = new Tree.Node[](SEGMENT_COUNT);
        for (uint256 s; s < SEGMENT_COUNT; ++s) {
            coarse[s] = fine[(s + 1) * SEGMENT_SIZE - 1];
        }
        return SmallFullTree.buildFromLeaves(coarse);
    }

    /// @dev The child tree of one root segment: its fine leaves.
    function childTreeOf(Tree.Node[] memory fine, uint256 segment)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory leaves = new Tree.Node[](SEGMENT_SIZE);
        for (uint256 i; i < SEGMENT_SIZE; ++i) {
            leaves[i] = fine[segment * SEGMENT_SIZE + i];
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    /// @dev A one-level tree of `height` from a seed, for single-level
    /// tournaments and for distinct-root entrants.
    function seededTree(bytes32 seed, uint64 height)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        return SmallFullTree.build(seed, height);
    }

    //
    // Actions. `one` is the elder (commitment one), `two` the newcomer.
    //

    function join(
        InspectableTournament t,
        SmallFullTree.Data memory tree,
        address claimer
    ) internal returns (Tree.Node root) {
        (,,, uint64 height) = t.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = tree.children(height, 0);
        uint256 bond = t.bondValue();
        vm.prank(claimer);
        t.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), left, right
        );
        root = tree.root();
    }

    function matchId(
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal pure returns (Match.Id memory) {
        return Match.Id(one.root(), two.root());
    }

    /// @dev One advance by whichever side must reveal now.
    function advance(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal {
        Match.Id memory id = matchId(one, two);
        Match.State memory s = t.getMatch(id.hashFromId());
        require(s.currentHeight > 1, "harness: not bisecting");
        (SmallFullTree.Data memory r, SmallFullTree.Data memory w) =
            _roles(t, s, one, two);
        uint64 h = s.currentHeight;
        uint256 idx = s.runningLeafPosition >> h;
        (Tree.Node left, Tree.Node right) = r.children(h, idx);
        uint256 selected = 2 * idx;
        if (left.eq(w.node(h - 1, selected))) {
            selected += 1;
        }
        (Tree.Node nextLeft, Tree.Node nextRight) = r.children(h - 1, selected);
        t.advanceMatch(id, left, right, nextLeft, nextRight);
    }

    /// @dev Advance until the match is ready to seal.
    function advanceToSeal(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal {
        Match.Id memory id = matchId(one, two);
        while (t.getMatch(id.hashFromId()).currentHeight > 1) {
            advance(t, one, two);
        }
    }

    /// @dev The final reveal's arguments: the revealer's leaf pair, the
    /// agree state and its proof, and the divergence position.
    function sealArguments(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    )
        internal
        view
        returns (
            Tree.Node left,
            Tree.Node right,
            Machine.Hash agree,
            bytes32[] memory proof,
            uint256 divergence
        )
    {
        Match.Id memory id = matchId(one, two);
        Match.State memory s = t.getMatch(id.hashFromId());
        require(s.currentHeight == 1, "harness: not ready to seal");
        (SmallFullTree.Data memory r, SmallFullTree.Data memory w) =
            _roles(t, s, one, two);
        uint256 idx = s.runningLeafPosition >> 1;
        (left, right) = r.children(1, idx);
        divergence = 2 * idx;
        if (left.eq(w.leaf(divergence))) {
            divergence += 1;
        }
        if (divergence == 0) {
            agree = t.tournamentArguments().commitmentArgs.initialHash;
            proof = new bytes32[](0);
        } else {
            agree = r.leaf(divergence - 1).toMachineHash();
            proof = r.proof(divergence - 1);
        }
    }

    function sealLeaf(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal returns (uint256 divergence) {
        (
            Tree.Node left,
            Tree.Node right,
            Machine.Hash agree,
            bytes32[] memory proof,
            uint256 d
        ) = sealArguments(t, one, two);
        t.sealLeafMatch(matchId(one, two), left, right, agree, proof);
        divergence = d;
    }

    function sealInner(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal returns (InspectableTournament child, uint256 divergence) {
        (
            Tree.Node left,
            Tree.Node right,
            Machine.Hash agree,
            bytes32[] memory proof,
            uint256 d
        ) = sealArguments(t, one, two);
        Match.Id memory id = matchId(one, two);
        vm.recordLogs();
        t.sealInnerMatchAndCreateInnerTournament(id, left, right, agree, proof);
        child = recordedChild(t, id, vm.getRecordedLogs());
        divergence = d;
    }

    /// @dev Prove the sealed leaf for `winner`, one of the two sides. The
    /// stub returns the winner's own divergent leaf, so it always matches.
    function prove(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two,
        SmallFullTree.Data memory winner,
        uint256 divergence
    ) internal {
        (,,, uint64 height) = t.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = winner.children(height, 0);
        t.winLeafMatch(
            matchId(one, two),
            left,
            right,
            abi.encode(Tree.Node.unwrap(winner.leaf(divergence)))
        );
    }

    function timeoutWin(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two,
        SmallFullTree.Data memory winner
    ) internal {
        (,,, uint64 height) = t.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = winner.children(height, 0);
        t.winMatchByTimeout(matchId(one, two), left, right);
    }

    function eliminate(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal {
        t.eliminateMatchByTimeout(matchId(one, two));
    }

    function propagate(
        InspectableTournament parent,
        InspectableTournament child,
        SmallFullTree.Data memory winnerParentTree
    ) internal {
        (,,, uint64 height) = parent.tournamentLevelConstants();
        (Tree.Node left, Tree.Node right) = winnerParentTree.children(height, 0);
        parent.winInnerTournament(child, left, right);
    }

    function eliminateChild(
        InspectableTournament parent,
        InspectableTournament child
    ) internal {
        parent.eliminateInnerTournament(child);
    }

    //
    // Observation
    //

    function clockOf(InspectableTournament t, Tree.Node root)
        internal
        view
        returns (Clock.State memory clock)
    {
        (clock,) = t.getCommitment(root);
    }

    function allowanceOf(InspectableTournament t, Tree.Node root)
        internal
        view
        returns (uint64)
    {
        return Time.Duration.unwrap(clockOf(t, root).allowance);
    }

    function classify(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal view returns (ITournament.MatchTimeoutOutcome outcome) {
        (, outcome,) = t.classifyMatchTimeout(matchId(one, two));
    }

    /// @dev First block at which the tournament is closed to joins.
    function closureOf(InspectableTournament t) internal view returns (uint64) {
        ITournament.TournamentArguments memory args = t.tournamentArguments();
        return Time.Instant.unwrap(args.startInstant.add(args.allowance));
    }

    function standing(InspectableTournament t)
        internal
        view
        returns (ITournament.TournamentStanding)
    {
        return t.tournamentStanding().standing;
    }

    function dangling(InspectableTournament t)
        internal
        view
        returns (Tree.Node d)
    {
        (d,,) = t.observedTopology();
    }

    function liveMatches(InspectableTournament t)
        internal
        view
        returns (uint256 n)
    {
        (, n,) = t.observedTopology();
    }

    function rollTo(uint256 blockNumber) internal {
        require(blockNumber >= block.number, "harness: time runs forward");
        vm.roll(blockNumber);
    }

    function rollBy(uint256 blocks) internal {
        vm.roll(block.number + blocks);
    }

    function recordedChild(
        InspectableTournament parent,
        Match.Id memory origin,
        Vm.Log[] memory logs
    ) internal pure returns (InspectableTournament child) {
        bytes32 wanted = Match.IdHash.unwrap(origin.hashFromId());
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == address(parent) && entry.topics.length == 3
                    && entry.topics[0]
                        == ITournament.NewInnerTournament.selector
                    && entry.topics[1] == wanted
            ) {
                return InspectableTournament(
                    address(uint160(uint256(entry.topics[2])))
                );
            }
        }
        revert("harness: no child recorded");
    }

    //
    // Private
    //

    /// @dev Revealer and waiting trees for the match's current height.
    function _roles(
        InspectableTournament t,
        Match.State memory s,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    )
        private
        view
        returns (SmallFullTree.Data memory r, SmallFullTree.Data memory w)
    {
        (,,, uint64 total) = t.tournamentLevelConstants();
        bool oneReveals = Match.responder(total, s.currentHeight)
            == ITournament.CommitmentSide.ONE;
        r = oneReveals ? one : two;
        w = oneReveals ? two : one;
    }
}
