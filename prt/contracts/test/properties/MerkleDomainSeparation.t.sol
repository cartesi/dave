// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Exploit-class transfer, Merkle domain separation. Tree.join is
/// keccak(left, right) with no leaf or node prefix, a machine hash is itself
/// a 64-byte keccak root, and Match.hashFromId is keccak(abi.encode(one,
/// two)), byte-identical to Tree.join(one, two). Each test below is the
/// sharpest shape confusion found for one target and documents why it
/// fails: every proof and every bisection comparison runs at the clone's
/// fixed height, so no node is ever compared or proven at a depth other than
/// its own, and the match and commitment key spaces live in separate
/// mappings.
contract MerkleDomainSeparationTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;
    using Clock for Clock.State;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;
    uint64 constant SINGLE_HEIGHT = 3;

    /// @dev Eight leaves for the single-level height-3 tree.
    function leaves8(uint256 fam, uint256 divergeAt, uint256 altFam)
        internal
        pure
        returns (Tree.Node[] memory leaves)
    {
        leaves = new Tree.Node[](8);
        for (uint256 i; i < 8; ++i) {
            uint256 family = i < divergeAt ? fam : altFam;
            leaves[i] = Tree.Node.wrap(bytes32((family << 16) | (0x200 + i)));
        }
    }

    /// @dev The height-3 tree whose root is join(one.root, two.root): its
    /// leaves are the two trees' height-1 nodes, so it claims internal
    /// nodes of real commitments as its leaves and as its final state.
    function aliasOf(
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal pure returns (SmallFullTree.Data memory) {
        Tree.Node[] memory leaves = new Tree.Node[](8);
        for (uint256 i; i < 4; ++i) {
            leaves[i] = one.node(1, i);
            leaves[4 + i] = two.node(1, i);
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function sealedOf(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal view returns (ITournament.SealedMatchView memory value) {
        (, value) = t.sealedMatch(matchId(one, two).hashFromId());
    }

    /// Target: tree-shape confusion through the match id. The commitment
    /// join(H, S) has the live match (H, S)'s id as its root, the honest and
    /// Sybil roots as its children, their height-1 nodes as its leaves, and
    /// an internal node of S as its final state. It joins (the root accepts
    /// any final state) without touching the match keyed by the same 32
    /// bytes, and when it meets the honest commitment the bisection compares
    /// its depth-3 "leaves" with real leaves at depth 3: it diverges at
    /// position 0 against the initial hash and is a plain wrong claim.
    function testRefutedMatchIdAliasCommitment() public {
        vm.roll(100);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory h =
            SmallFullTree.buildFromLeaves(leaves8(1, 8, 1));
        SmallFullTree.Data memory s =
            SmallFullTree.buildFromLeaves(leaves8(1, 5, 2));
        SmallFullTree.Data memory a = aliasOf(h, s);

        join(t, h, HONEST);
        join(t, s, SYBIL);
        Match.IdHash hsId = matchId(h, s).hashFromId();
        assertEq(
            Match.IdHash.unwrap(hsId),
            Tree.Node.unwrap(h.root().join(s.root())),
            "match id and Tree.join share one hash domain"
        );
        assertEq(Tree.Node.unwrap(a.root()), Match.IdHash.unwrap(hsId));
        assertEq(
            Machine.Hash.unwrap(a.finalState()),
            Tree.Node.unwrap(s.node(1, 3)),
            "the alias's final state is an internal node of S"
        );
        Match.State memory before = t.getMatch(hsId);

        join(t, a, THIRD);
        assertTrue(dangling(t).eq(a.root()));
        Match.State memory afterJoin = t.getMatch(hsId);
        assertEq(
            keccak256(abi.encode(afterJoin)),
            keccak256(abi.encode(before)),
            "the commitment keyed by the match id leaves the match intact"
        );

        advanceToSeal(t, h, s);
        uint256 d = sealLeaf(t, h, s);
        assertEq(d, 5);
        prove(t, h, s, h, d);

        // The honest winner re-pairs with the alias, the elder.
        assertEq(liveMatches(t), 1);
        advanceToSeal(t, a, h);
        uint256 d2 = sealLeaf(t, a, h);
        ITournament.SealedMatchView memory sv = sealedOf(t, a, h);
        assertEq(d2, 0);
        assertEq(sv.divergencePosition, 0);
        assertEq(
            Machine.Hash.unwrap(sv.agreeState),
            Machine.Hash.unwrap(INITIAL_STATE),
            "the step starts from the true initial state"
        );
        assertEq(
            Machine.Hash.unwrap(sv.finalStateOne),
            Tree.Node.unwrap(h.node(1, 0)),
            "the alias offers an honest internal node as a leaf"
        );
        assertEq(
            Machine.Hash.unwrap(sv.finalStateTwo), Tree.Node.unwrap(h.leaf(0))
        );
        prove(t, a, h, h, d2);

        rollTo(closureOf(t));
        ITournament.TournamentStandingView memory st = t.tournamentStanding();
        assertEq(
            uint8(st.standing),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(st.candidate.eq(h.root()));
    }

    /// Target: a seal that proves a wrong agree state. The Sybil is
    /// commitment one at odd height, so it is the final revealer and the
    /// agree state is proven against its own root. A valid proof for any
    /// position other than divergence - 1 fails, so it cannot offer its own
    /// divergent leaf or an earlier leaf; the only acceptable value is the
    /// shared prefix leaf. At divergence 0 no proof is read and only the
    /// initial hash is accepted.
    function testRefutedSealAgreeStateFromWrongPosition() public {
        vm.roll(100);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory h =
            SmallFullTree.buildFromLeaves(leaves8(1, 8, 1));
        SmallFullTree.Data memory s =
            SmallFullTree.buildFromLeaves(leaves8(1, 5, 2));
        join(t, s, SYBIL);
        join(t, h, HONEST);
        advanceToSeal(t, s, h);

        Match.Id memory id = matchId(s, h);
        (Tree.Node left, Tree.Node right) = s.children(1, 2);

        // Its own divergent leaf, with a valid proof for position 5.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.CommitmentStateMismatch.selector,
                s.root(),
                _rootAt(s, 4, s.leaf(5), s.proof(5))
            )
        );
        t.sealLeafMatch(id, left, right, s.leaf(5).toMachineHash(), s.proof(5));

        // An earlier leaf, with a valid proof for position 3.
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.CommitmentStateMismatch.selector,
                s.root(),
                _rootAt(s, 4, s.leaf(3), s.proof(3))
            )
        );
        t.sealLeafMatch(id, left, right, s.leaf(3).toMachineHash(), s.proof(3));

        // The shared leaf with its own proof is the only accepted value.
        t.sealLeafMatch(id, left, right, s.leaf(4).toMachineHash(), s.proof(4));
        ITournament.SealedMatchView memory sv = sealedOf(t, s, h);
        assertEq(sv.divergencePosition, 5);
        assertEq(
            Machine.Hash.unwrap(sv.agreeState), Tree.Node.unwrap(h.leaf(4))
        );
        assertEq(
            Machine.Hash.unwrap(sv.finalStateOne), Tree.Node.unwrap(s.leaf(5))
        );
        assertEq(
            Machine.Hash.unwrap(sv.finalStateTwo), Tree.Node.unwrap(h.leaf(5))
        );

        // Divergence at 0: a fresh pair, the Sybil revealing again.
        InspectableTournament t0 = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory s0 =
            SmallFullTree.buildFromLeaves(leaves8(3, 0, 3));
        join(t0, s0, SYBIL);
        join(t0, h, HONEST);
        advanceToSeal(t0, s0, h);
        Match.Id memory id0 = matchId(s0, h);
        (Tree.Node l0, Tree.Node r0) = s0.children(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.IncorrectAgreeState.selector,
                INITIAL_STATE,
                s0.leaf(0).toMachineHash()
            )
        );
        t0.sealLeafMatch(id0, l0, r0, s0.leaf(0).toMachineHash(), s0.proof(0));
        t0.sealLeafMatch(id0, l0, r0, INITIAL_STATE, new bytes32[](0));
    }

    /// Target: a child commitment that claims a parent's nodes as leaves.
    /// The divergence is in the last root segment, so the honest contested
    /// state is the honest root tree's last leaf, and the honest root tree
    /// is itself a valid child-height commitment ending there. (a) A child
    /// commitment whose final state is a parent internal node is refused.
    /// (b) The honest parent tree joins the child on the honest side
    /// (classification is by final state); after it beats the Sybil child by
    /// timeout it meets the honest child commitment, the bisection compares
    /// its coarse states with fine states at child depth, divergence is at
    /// child position 0 against the parent's agree state, and only the
    /// honest fine leaf is a provable successor there.
    function testRefutedChildClaimsParentNodesAsLeaves() public {
        vm.roll(100);
        InspectableTournament root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 12, 2);
        SmallFullTree.Data memory hRoot = rootTreeOf(honest);
        SmallFullTree.Data memory sRoot = rootTreeOf(sybil);
        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        assertEq(segment, 3);

        // (a) A parent internal node as the claimed final state.
        {
            Tree.Node[] memory leaves = new Tree.Node[](4);
            leaves[0] = honest[12];
            leaves[1] = honest[13];
            leaves[2] = honest[14];
            leaves[3] = hRoot.node(1, 1);
            SmallFullTree.Data memory bad =
                SmallFullTree.buildFromLeaves(leaves);
            (Tree.Node bl, Tree.Node br) = bad.children(LEAF_HEIGHT, 0);
            uint256 bond = child.bondValue();
            vm.prank(THIRD);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ITournament.InvalidContestedFinalState.selector,
                    hRoot.finalState(),
                    sRoot.finalState(),
                    bad.finalState()
                )
            );
            child.joinTournament{value: bond}(
                bad.finalState(), bad.finalProof(), bl, br
            );
        }

        // (b) The honest parent tree as an honest-side child commitment.
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        assertEq(
            Machine.Hash.unwrap(hRoot.finalState()),
            Machine.Hash.unwrap(hChild.finalState())
        );
        join(child, sChild, SYBIL);
        join(child, hRoot, THIRD);
        join(child, hChild, HONEST);
        assertTrue(dangling(child).eq(hChild.root()));

        // The adversary lets its honest-side alias beat its Sybil child.
        rollTo(Time.Instant.unwrap(clockOf(child, sChild.root()).deadline()));
        timeoutWin(child, sChild, hRoot, hRoot);

        advanceToSeal(child, hChild, hRoot);
        uint256 d = sealLeaf(child, hChild, hRoot);
        ITournament.SealedMatchView memory sv = sealedOf(child, hChild, hRoot);
        assertEq(d, 0);
        assertEq(
            Machine.Hash.unwrap(sv.agreeState),
            Tree.Node.unwrap(hRoot.leaf(2)),
            "the child step starts from the parent's proven agree state"
        );
        assertEq(
            Machine.Hash.unwrap(sv.finalStateOne), Tree.Node.unwrap(honest[12])
        );
        assertEq(
            Machine.Hash.unwrap(sv.finalStateTwo),
            Tree.Node.unwrap(hRoot.leaf(0)),
            "the alias offers a coarse parent state at a fine position"
        );
        prove(child, hChild, hRoot, hChild, d);

        rollTo(closureOf(child));
        propagate(root, child, hRoot);
        assertTrue(dangling(root).eq(hRoot.root()));
    }

    /// Target: proof-length truncation. Commitment.getRoot casts
    /// siblings.length to uint64 before comparing it with the height, so a
    /// calldata length of 2^64 + 3 would truncate to 3. The ABI decoder
    /// rejects any dynamic calldata array longer than 2^64 - 1 (and any that
    /// overruns calldata) before the body runs, so the cast never sees one.
    function testRefutedProofLengthTruncation() public {
        vm.roll(100);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory h =
            SmallFullTree.buildFromLeaves(leaves8(1, 8, 1));
        SmallFullTree.Data memory s =
            SmallFullTree.buildFromLeaves(leaves8(1, 5, 2));
        join(t, s, SYBIL);
        join(t, h, HONEST);
        advanceToSeal(t, s, h);
        Match.Id memory id = matchId(s, h);
        (Tree.Node left, Tree.Node right) = s.children(1, 2);
        bytes32[] memory proof = s.proof(4);

        uint256 forgedLength = (uint256(1) << 64) + SINGLE_HEIGHT;
        assertEq(uint64(forgedLength), SINGLE_HEIGHT, "the cast would truncate");

        bytes memory head = abi.encodeWithSelector(
            ITournament.sealLeafMatch.selector,
            id,
            left,
            right,
            s.leaf(4).toMachineHash(),
            proof
        );
        // Overwrite the array length word: selector, six head words, length.
        bytes memory forged = abi.encodePacked(head);
        uint256 lengthOffset = 4 + 6 * 32;
        assembly {
            mstore(add(add(forged, 32), lengthOffset), forgedLength)
        }
        (bool ok, bytes memory ret) = address(t).call(forged);
        assertFalse(ok, "the decoder rejects the oversized length");
        assertEq(ret.length, 0, "a decoder revert, not a body error");
        Match.State memory st = t.getMatch(id.hashFromId());
        assertEq(st.currentHeight, 1, "still ready to seal");

        (ok,) = address(t).call(head);
        assertTrue(ok, "the same siblings at their true length seal");
    }

    function _rootAt(
        SmallFullTree.Data memory,
        uint256 position,
        Tree.Node leaf,
        bytes32[] memory siblings
    ) private pure returns (Tree.Node) {
        bytes32 node = Tree.Node.unwrap(leaf);
        for (uint256 i; i < siblings.length; ++i) {
            if ((position >> i) % 2 == 0) {
                node = keccak256(abi.encodePacked(node, siblings[i]));
            } else {
                node = keccak256(abi.encodePacked(siblings[i], node));
            }
        }
        return Tree.Node.wrap(node);
    }
}
