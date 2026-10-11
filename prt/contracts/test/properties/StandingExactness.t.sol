// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {SmallTwoLevelTournamentFactory} from "test/fixtures/SmallTwoLevelTournament.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {StandingProbe} from "test/fixtures/StandingProbe.sol";

contract DoubleJoiner {
    function joinTwice(
        ITournament t,
        Machine.Hash[2] calldata finals,
        bytes32[][2] calldata proofs,
        Tree.Node[2] calldata lefts,
        Tree.Node[2] calldata rights,
        uint256 bond
    ) external payable {
        t.joinTournament{value: bond}(finals[0], proofs[0], lefts[0], rights[0]);
        t.joinTournament{value: bond}(finals[1], proofs[1], lefts[1], rights[1]);
    }
}

/// @dev Adversarial scenarios for `StandingChanged`: each emission is
/// checked against the views at every boundary it claims.
contract StandingExactnessTest is StandingProbe {
    using SmallFullTree for SmallFullTree.Data;
    using Match for Match.Id;
    using Tree for Tree.Node;
    using TournamentInspector for ITournament;

    uint64 internal constant START = 100;
    uint64 internal constant RB = 5;
    uint64 internal constant CB = 20;
    uint64 internal constant A0 = 200;
    uint64 internal constant HEIGHT = 2;
    Machine.Hash internal constant INITIAL =
        Machine.Hash.wrap(bytes32(uint256(0x1234)));
    Tree.Node internal constant C1 = Tree.Node.wrap(bytes32(uint256(0xc1)));
    Tree.Node internal constant C2 = Tree.Node.wrap(bytes32(uint256(0xc2)));
    Tree.Node internal constant F1 = Tree.Node.wrap(bytes32(uint256(0xf1)));
    Tree.Node internal constant F2 = Tree.Node.wrap(bytes32(uint256(0xf2)));

    SmallTwoLevelTournamentFactory internal factory;
    address internal constant P = address(0xbeef);

    function setUp() public {
        vm.roll(START);
        vm.fee(0);
        vm.txGasPrice(0);
        vm.deal(P, 1000 ether);
        factory = new SmallTwoLevelTournamentFactory(
            Time.Duration.wrap(RB),
            Time.Duration.wrap(CB),
            Time.Duration.wrap(A0)
        );
    }

    function _orphan() internal returns (ITournament orphan) {
        (orphan,) = factory.instantiateInner(
            INITIAL,
            C1,
            F1.toMachineHash(),
            C2,
            F2.toMachineHash(),
            Time.Duration.wrap(A0),
            0,
            1,
            IDataProvider(address(0))
        );
    }

    function _tree(uint256 seed, Tree.Node finalLeaf)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory leaves = new Tree.Node[](4);
        for (uint256 i; i < 3; ++i) {
            leaves[i] = Tree.Node.wrap(keccak256(abi.encode(seed, i)));
        }
        leaves[3] = finalLeaf;
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _join(ITournament t, SmallFullTree.Data memory tree) internal {
        (Tree.Node l, Tree.Node r) = tree.children(HEIGHT, 0);
        uint256 bond = t.bondValue();
        vm.prank(P);
        t.joinTournament{value: bond}(
            tree.finalState(), tree.finalProof(), l, r
        );
    }

    function _children(SmallFullTree.Data memory tree)
        internal
        pure
        returns (Tree.Node l, Tree.Node r)
    {
        return tree.children(HEIGHT, 0);
    }

    // A fresh joiner at the last open block of an inner tournament.
    function testLateSingleJoinerAtLastOpenBlock() public {
        ITournament t = _orphan();
        vm.roll(START + A0 - 1);
        SmallFullTree.Data memory a = _tree(1, F1);
        vm.recordLogs();
        _join(t, a);
        (uint256 n, Standing memory s) =
            _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 0);
        assertEq(Tree.Node.unwrap(s.dangling), Tree.Node.unwrap(a.root()));
        assertEq(Tree.Node.unwrap(s.parentCommitment), Tree.Node.unwrap(C1));
        assertEq(s.resultAt, START + A0);
        assertEq(s.winnerExpiresAt, START + A0 + 1);
        _probe(t, s);

        // A join exactly at the deadline is rejected (inclusive expiry).
        vm.roll(START + A0);
        SmallFullTree.Data memory b = _tree(2, F2);
        (Tree.Node l, Tree.Node r) = _children(b);
        uint256 bond = t.bondValue();
        vm.prank(P);
        vm.expectRevert(ITournament.TournamentIsClosed.selector);
        t.joinTournament{value: bond}(b.finalState(), b.finalProof(), l, r);
    }

    // Paused timeout winner after close, deferred charge > budget.
    function testPausedTimeoutWinnerAfterClose() public {
        ITournament t = _orphan();
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        _join(t, a);
        _join(t, b);
        vm.roll(START + A0 + 50);
        (Tree.Node l, Tree.Node r) = _children(b);
        vm.recordLogs();
        t.winMatchByTimeout(Match.Id(a.root(), b.root()), l, r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n, Standing memory s) = _standings(logs, address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 0);
        assertEq(Tree.Node.unwrap(s.dangling), Tree.Node.unwrap(b.root()));
        assertEq(Tree.Node.unwrap(s.parentCommitment), Tree.Node.unwrap(C2));
        assertEq(s.resultAt, START + A0 + 50);
        // 200 - (50 - 5) = 155
        assertEq(s.winnerExpiresAt, START + A0 + 50 + 155);
        // Ordering: MatchDeleted < StandingChanged < PartialBondRefund.
        uint256 iDel =
            _indexOf(logs, address(t), ITournament.MatchDeleted.selector);
        uint256 iStd = _indexOf(logs, address(t), STANDING_TOPIC);
        uint256 iRef =
            _indexOf(logs, address(t), ITournament.PartialBondRefund.selector);
        assertLt(iDel, iStd);
        assertLt(iStd, iRef);
        _probe(t, s);

        // Bond recovery changes no standing field and emits no standing.
        vm.recordLogs();
        assertTrue(t.tryRecoveringBond());
        (n,) = _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 0);
        _probe(t, s);
    }

    // Eliminate both with a third dangling commitment that is itself a
    // discounted survivor; the last MatchDeleted has no winner.
    function testEliminateBothWithSurvivorDangling() public {
        ITournament t = _orphan();
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        SmallFullTree.Data memory c = _tree(3, F1);
        SmallFullTree.Data memory d = _tree(4, F2);
        _join(t, a);
        _join(t, b);
        _join(t, c);
        _join(t, d);
        vm.roll(START + A0 + 10);
        (Tree.Node l, Tree.Node r) = _children(b);
        vm.recordLogs();
        t.winMatchByTimeout(Match.Id(a.root(), b.root()), l, r);
        (uint256 n, Standing memory s) =
            _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 1);
        assertEq(Tree.Node.unwrap(s.dangling), Tree.Node.unwrap(b.root()));
        // Like the views, parentCommitment is zero while matches remain.
        assertEq(Tree.Node.unwrap(s.parentCommitment), 0);
        assertEq(s.resultAt, 0);
        assertEq(s.winnerExpiresAt, 0);
        _probe(t, s);

        // C runs since START (deadline 300); D paused at 200 survives until
        // its overdue charge reaches 200.
        vm.roll(START + A0 + A0);
        vm.recordLogs();
        t.eliminateMatchByTimeout(Match.Id(c.root(), d.root()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (n, s) = _standings(logs, address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 0);
        assertEq(Tree.Node.unwrap(s.dangling), Tree.Node.unwrap(b.root()));
        assertEq(s.resultAt, START + A0 + A0);
        assertEq(Tree.Node.unwrap(s.parentCommitment), Tree.Node.unwrap(C2));
        // B kept 200 - (10 - 5) = 195 from the earlier win.
        assertEq(s.winnerExpiresAt, START + A0 + A0 + 195);
        _probe(t, s);
    }

    // A leaf proof before close keeps close as resultAt; a later
    // join supersedes the earlier prospective values.
    function testLeafProofWinBeforeClose() public {
        ITournament t = _orphan();
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        _join(t, a);
        _join(t, b);
        Match.Id memory id = Match.Id(a.root(), b.root());
        vm.roll(START + 10);
        (Tree.Node al, Tree.Node ar) = a.children(2, 0);
        (Tree.Node a0, Tree.Node a1) = a.children(1, 0);
        t.advanceMatch(id, al, ar, a0, a1);
        vm.roll(START + 20);
        (Tree.Node b0, Tree.Node b1) = b.children(1, 0);
        t.sealLeafMatch(id, b0, b1, INITIAL, new bytes32[](0));
        vm.roll(START + 30);
        (Tree.Node bl, Tree.Node br) = b.children(2, 0);
        vm.recordLogs();
        t.winLeafMatch(id, bl, br, abi.encode(Tree.Node.unwrap(b0)));
        (uint256 n, Standing memory s) =
            _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 0);
        assertEq(Tree.Node.unwrap(s.dangling), Tree.Node.unwrap(b.root()));
        assertEq(s.resultAt, START + A0);
        // B: 200, -5 at seal (10 elapsed), -5 at proof (10 elapsed) = 190.
        assertEq(s.winnerExpiresAt, START + A0 + 190);
        _probe(t, s);

        vm.roll(START + 100);
        SmallFullTree.Data memory e = _tree(5, F1);
        vm.recordLogs();
        _join(t, e);
        (n, s) = _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 1);
        assertEq(Tree.Node.unwrap(s.dangling), 0);
        _probe(t, s);
    }

    // Two joins in one transaction emit twice; the latest wins.
    function testTwoJoinsInOneTransaction() public {
        ITournament t = _orphan();
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        DoubleJoiner dj = new DoubleJoiner();
        uint256 bond = t.bondValue();
        Machine.Hash[2] memory finals = [a.finalState(), b.finalState()];
        bytes32[][2] memory proofs = [a.finalProof(), b.finalProof()];
        (Tree.Node al, Tree.Node ar) = _children(a);
        (Tree.Node bl, Tree.Node br) = _children(b);
        vm.recordLogs();
        vm.prank(P);
        dj.joinTwice{value: 2 * bond}(
            t, finals, proofs, [al, bl], [ar, br], bond
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n, Standing memory s) = _standings(logs, address(t));
        assertEq(n, 2);
        assertEq(s.matchCount, 1);
        assertEq(Tree.Node.unwrap(s.dangling), 0);
        _probe(t, s);
    }

    // A re-pairing win emits once, after MatchCreated and
    // MatchDeleted.
    function testRepairingWinEmitsOnceAfterCreateAndDelete() public {
        ITournament t = _orphan();
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        SmallFullTree.Data memory c = _tree(3, F1);
        _join(t, a);
        _join(t, b);
        _join(t, c);
        vm.roll(START + A0 + 10);
        (Tree.Node l, Tree.Node r) = _children(b);
        vm.recordLogs();
        t.winMatchByTimeout(Match.Id(a.root(), b.root()), l, r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n, Standing memory s) = _standings(logs, address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 1);
        assertEq(Tree.Node.unwrap(s.dangling), 0);
        uint256 iCre =
            _indexOf(logs, address(t), ITournament.MatchCreated.selector);
        uint256 iDel =
            _indexOf(logs, address(t), ITournament.MatchDeleted.selector);
        uint256 iStd = _indexOf(logs, address(t), STANDING_TOPIC);
        assertLt(iCre, iDel);
        assertLt(iDel, iStd);
        _probe(t, s);
    }

    // Root after a timeout win: no expiry, no parent commitment.
    function testRootTimeoutWinner() public {
        ITournament t = factory.instantiate(INITIAL, IDataProvider(address(0)));
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        _join(t, a);
        _join(t, b);
        vm.roll(START + A0 + 50);
        (Tree.Node l, Tree.Node r) = _children(b);
        vm.recordLogs();
        t.winMatchByTimeout(Match.Id(a.root(), b.root()), l, r);
        (uint256 n, Standing memory s) =
            _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 1);
        assertEq(s.matchCount, 0);
        assertEq(s.resultAt, START + A0 + 50);
        assertEq(s.winnerExpiresAt, 0);
        assertEq(Tree.Node.unwrap(s.parentCommitment), 0);
        _probe(t, s);
    }

    // An empty child never emits: its descriptor alone gives the boundary
    // from which the parent may eliminate it.
    function testEmptyChildIsEliminableAtItsJoiningDeadline() public {
        vm.recordLogs();
        ITournament t = _orphan();
        (uint256 n,) = _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 0);
        ITournament.TournamentDescriptor memory d = t.tournamentDescriptor();
        uint64 close = Time.Instant.unwrap(d.startInstant)
            + Time.Duration.unwrap(d.allowance);
        vm.roll(close - 1);
        assertEq(
            uint8(t.innerResult().disposition),
            uint8(ITournament.InnerTournamentDisposition.UNSETTLED)
        );
        vm.roll(close);
        assertEq(
            uint8(t.innerResult().disposition),
            uint8(ITournament.InnerTournamentDisposition.ELIMINABLE)
        );
    }

    // The documented completeness check: one emission per join and per
    // deletion, so the counters bound the expected events.
    function testEmissionCountIsJoinsPlusDeletions() public {
        vm.recordLogs();
        ITournament t = _orphan();
        SmallFullTree.Data memory a = _tree(1, F1);
        SmallFullTree.Data memory b = _tree(2, F2);
        SmallFullTree.Data memory c = _tree(3, F1);
        SmallFullTree.Data memory d = _tree(4, F2);
        _join(t, a);
        _join(t, b);
        _join(t, c);
        _join(t, d);
        vm.roll(START + A0 + 10);
        (Tree.Node l, Tree.Node r) = _children(b);
        t.winMatchByTimeout(Match.Id(a.root(), b.root()), l, r);
        vm.roll(START + A0 + A0);
        t.eliminateMatchByTimeout(Match.Id(c.root(), d.root()));
        (uint256 n,) = _standings(vm.getRecordedLogs(), address(t));
        assertEq(n, 6);
        assertEq(n, t.getCommitmentJoinedCount() + t.getMatchDeletedCount());
    }
}
