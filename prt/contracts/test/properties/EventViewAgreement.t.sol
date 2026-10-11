// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {ITournamentFactory} from "src/ITournamentFactory.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {ProofSelectedStateTransition} from "test/fixtures/ProofSelectedStateTransition.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

contract EventAgreementProvider is ITournamentParametersProvider {
    uint64 immutable HEIGHT;

    constructor(uint64 height) {
        HEIGHT = height;
    }

    function tournamentParameters(uint64)
        external
        view
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: 1,
            log2step: 0,
            height: HEIGHT,
            responseBudget: Time.Duration.wrap(5),
            commitmentBudget: Time.ZERO_DURATION,
            maxAllowance: Time.Duration.wrap(1000)
        });
    }
}

contract EventAgreementFactory is MultiLevelTournamentFactory {
    constructor(uint64 height)
        MultiLevelTournamentFactory(
            new InspectableTournament(),
            new EventAgreementProvider(height),
            new ProofSelectedStateTransition()
        )
    {}
}

/// @dev Drives a single-level dispute at heights 2 to 6 and compares every
/// event field with the view that reports the same quantity at the emitting
/// block, plus the timeout classifier at each emitted boundary. Each move is
/// also driven through its mutator at the deadline the previous event
/// published. Both responder parities, every divergence position, both
/// winners, and a winner re-paired with a waiting commitment are covered.
contract EventViewAgreementTest is Test {
    using Match for Match.Id;
    using SmallFullTree for SmallFullTree.Data;
    using Time for Time.Instant;
    using Tree for Tree.Node;

    Machine.Hash constant INITIAL = Machine.Hash.wrap(bytes32(uint256(0x1234)));

    ITournament t;
    Match.Id id;
    uint64 H;
    uint256 standingEvents;
    // The latest published deadline of the next move: the responder's during
    // bisection, the earlier of the two in a sealed leaf race.
    Time.Instant moveDeadline;

    function setUp() public {
        vm.roll(100);
        vm.deal(address(this), 100 ether);
    }

    function testOddHeightOneWins() public {
        _probe(3, 5, 7, true, false);
    }

    function testOddHeightTwoWinsAtZero() public {
        _probe(5, 0, 6, false, false);
    }

    function testEvenHeightOneWins() public {
        _probe(4, 9, 6, true, false);
    }

    function testEvenHeightTwoWinsLast() public {
        _probe(6, 63, 8, false, false);
    }

    function testWinnerRepairsWithWaitingCommitment() public {
        _probe(3, 2, 5, true, true);
        _probe(4, 15, 3, false, true);
    }

    function testFuzzEventsEqualViews(
        uint8 h,
        uint8 div,
        uint8 step,
        bool oneWins,
        bool thirdWaits
    ) public {
        uint64 height = uint64(bound(h, 2, 6));
        uint256 d = bound(div, 0, (uint256(1) << height) - 1);
        uint64 s = uint64(bound(step, 1, 12));
        _probe(height, d, s, oneWins, thirdWaits);
    }

    function _trees(uint256 div)
        internal
        view
        returns (SmallFullTree.Data memory one, SmallFullTree.Data memory two)
    {
        uint256 n = uint256(1) << H;
        Tree.Node[] memory a = new Tree.Node[](n);
        Tree.Node[] memory b = new Tree.Node[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = Tree.Node.wrap(keccak256(abi.encode(uint256(1), i)));
            b[i] = i < div
                ? a[i]
                : Tree.Node.wrap(keccak256(abi.encode(uint256(2), i)));
        }
        one = SmallFullTree.buildFromLeaves(a);
        two = SmallFullTree.buildFromLeaves(b);
    }

    function _third() internal view returns (SmallFullTree.Data memory) {
        uint256 n = uint256(1) << H;
        Tree.Node[] memory c = new Tree.Node[](n);
        for (uint256 i; i < n; ++i) {
            c[i] = Tree.Node.wrap(keccak256(abi.encode(uint256(3), i)));
        }
        return SmallFullTree.buildFromLeaves(c);
    }

    function _join(SmallFullTree.Data memory m) internal {
        (Tree.Node l, Tree.Node r) = m.children(H, 0);
        t.joinTournament{value: t.bondValue()}(
            m.finalState(), m.finalProof(), l, r
        );
    }

    function _find(Vm.Log[] memory logs, bytes32 topic0)
        internal
        view
        returns (Vm.Log memory found, uint256 count, uint256 index)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic0 && logs[i].emitter == address(t)) {
                found = logs[i];
                index = i;
                ++count;
            }
        }
    }

    function _standing(Vm.Log[] memory logs)
        internal
        returns (
            uint256 mc,
            Tree.Node dangling,
            Tree.Node parentC,
            Time.Instant resultAt,
            Time.Instant expires
        )
    {
        (Vm.Log memory l, uint256 c,) =
            _find(logs, ITournament.StandingChanged.selector);
        assertEq(c, 1, "exactly one StandingChanged");
        ++standingEvents;
        (mc, dangling, parentC, resultAt, expires) = abi.decode(
            l.data, (uint256, Tree.Node, Tree.Node, Time.Instant, Time.Instant)
        );
        (Tree.Node d, uint256 m,) =
            InspectableTournament(address(t)).observedTopology();
        assertEq(mc, m, "matchCount == storage");
        assertEq(Tree.Node.unwrap(dangling), Tree.Node.unwrap(d), "dangling");
        assertEq(Tree.Node.unwrap(parentC), 0, "root parentCommitment zero");
        assertEq(Time.Instant.unwrap(expires), 0, "root winnerExpiresAt zero");
        if (mc != 0) {
            assertEq(Time.Instant.unwrap(resultAt), 0, "no result while live");
        }
    }

    function _assertNoStanding(Vm.Log[] memory logs) internal view {
        (, uint256 c,) = _find(logs, ITournament.StandingChanged.selector);
        assertEq(c, 0, "advances and seals leave the standing unchanged");
    }

    function _probe(
        uint64 h,
        uint256 div,
        uint64 step,
        bool oneWins,
        bool thirdWaits
    ) internal {
        H = h;
        standingEvents = 0;
        EventAgreementFactory f = new EventAgreementFactory(h);
        vm.recordLogs();
        t = f.instantiate(INITIAL, IDataProvider(address(0)));
        _checkCreated(vm.getRecordedLogs());
        (SmallFullTree.Data memory one, SmallFullTree.Data memory two) =
            _trees(div);
        SmallFullTree.Data memory third = _third();
        ITournament.TournamentDescriptor memory desc = t.tournamentDescriptor();
        Time.Instant close = desc.startInstant.add(desc.allowance);

        vm.recordLogs();
        _join(one);
        {
            (uint256 mc, Tree.Node dg,, Time.Instant ra,) =
                _standing(vm.getRecordedLogs());
            assertEq(mc, 0);
            assertTrue(dg.eq(one.root()));
            assertEq(Time.Instant.unwrap(ra), Time.Instant.unwrap(close));
        }

        vm.roll(vm.getBlockNumber() + step);
        vm.recordLogs();
        _join(two);
        id = Match.Id(one.root(), two.root());
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _checkMatchCreated(logs, two);
            (uint256 mc, Tree.Node dg,, Time.Instant ra,) = _standing(logs);
            assertEq(mc, 1);
            assertTrue(dg.isZero());
            assertEq(Time.Instant.unwrap(ra), 0);
        }

        if (thirdWaits) {
            vm.roll(vm.getBlockNumber() + step);
            vm.recordLogs();
            _join(third);
            (uint256 mc, Tree.Node dg,,,) = _standing(vm.getRecordedLogs());
            assertEq(mc, 1);
            assertTrue(dg.eq(third.root()));
        }

        uint64 cur = h;
        uint256 pos;
        while (cur > 1) {
            vm.roll(vm.getBlockNumber() + step);
            SmallFullTree.Data memory r = ((h - cur) % 2 == 0) ? one : two;
            uint256 idx = pos >> cur;
            (Tree.Node rl, Tree.Node rr) = r.children(cur, idx);
            Match.State memory st = t.getMatch(id.hashFromId());
            bool left = !rl.eq(st.leftNode);
            (Tree.Node nl, Tree.Node nr) =
                r.children(cur - 1, 2 * idx + (left ? 0 : 1));
            _assertMoveOnlyBeforeDeadline(
                abi.encodeCall(ITournament.advanceMatch, (id, rl, rr, nl, nr))
            );
            vm.recordLogs();
            t.advanceMatch(id, rl, rr, nl, nr);
            if (!left) {
                pos += uint256(1) << (cur - 1);
            }
            --cur;
            _checkAdvanced(vm.getRecordedLogs(), cur, pos);
        }

        vm.roll(vm.getBlockNumber() + step);
        {
            SmallFullTree.Data memory r = ((h - 1) % 2 == 0) ? one : two;
            (Tree.Node ll, Tree.Node lr) = r.children(1, pos >> 1);
            Match.State memory st = t.getMatch(id.hashFromId());
            uint256 dpos = !ll.eq(st.leftNode) ? pos : pos + 1;
            assertEq(dpos, div, "bisection found the first divergence");
            Machine.Hash agree =
                dpos == 0 ? INITIAL : r.leaf(dpos - 1).toMachineHash();
            bytes32[] memory proof =
                dpos == 0 ? new bytes32[](0) : r.proof(dpos - 1);
            _assertMoveOnlyBeforeDeadline(
                abi.encodeCall(
                    ITournament.sealLeafMatch, (id, ll, lr, agree, proof)
                )
            );
            vm.recordLogs();
            t.sealLeafMatch(id, ll, lr, agree, proof);
        }
        _checkSealed(vm.getRecordedLogs());

        vm.roll(vm.getBlockNumber() + 1);
        SmallFullTree.Data memory w = oneWins ? one : two;
        (Tree.Node wl, Tree.Node wr) = w.children(H, 0);
        bytes memory leafProof = abi.encode(Tree.Node.unwrap(w.leaf(div)));
        _assertMoveOnlyBeforeDeadline(
            abi.encodeCall(ITournament.winLeafMatch, (id, wl, wr, leafProof))
        );
        vm.recordLogs();
        t.winLeafMatch(id, wl, wr, leafProof);
        Vm.Log[] memory winLogs = vm.getRecordedLogs();
        (uint256 mcw, Tree.Node dgw,, Time.Instant raw,) = _standing(winLogs);
        if (thirdWaits) {
            _checkRepair(winLogs, third.root(), w);
            assertEq(mcw, 1);
            assertTrue(dgw.isZero());
        } else {
            assertEq(mcw, 0);
            assertTrue(dgw.eq(w.root()));
            Time.Instant expected = close.max(Time.currentTime());
            assertEq(Time.Instant.unwrap(raw), Time.Instant.unwrap(expected));
            vm.roll(Time.Instant.unwrap(raw));
            ITournament.TournamentStandingView memory sv =
                t.tournamentStanding();
            assertEq(
                uint8(sv.standing),
                uint8(ITournament.TournamentStanding.ROOT_WINNER)
            );
            assertEq(
                Time.Instant.unwrap(sv.finishedAt), Time.Instant.unwrap(raw)
            );
            vm.roll(Time.Instant.unwrap(raw) - 1);
            assertTrue(
                t.tournamentStanding().standing
                    != ITournament.TournamentStanding.ROOT_WINNER
            );
        }
        assertEq(
            standingEvents,
            t.getCommitmentJoinedCount() + t.getMatchDeletedCount(),
            "StandingChanged count identity"
        );
    }

    function _checkCreated(Vm.Log[] memory logs) internal view {
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics[0]
                    == ITournamentFactory.TournamentCreated.selector
            ) {
                (
                    address a,
                    ITournament.TournamentDescriptor memory d,
                    uint256 bond
                ) = abi.decode(
                    logs[i].data,
                    (address, ITournament.TournamentDescriptor, uint256)
                );
                assertEq(a, address(t));
                assertEq(abi.encode(d), abi.encode(t.tournamentDescriptor()));
                assertEq(bond, t.bondValue());
                seen = true;
            }
        }
        assertTrue(seen);
    }

    /// @param two The tree of commitment #2, the joiner or the survivor
    function _checkMatchCreated(
        Vm.Log[] memory logs,
        SmallFullTree.Data memory two
    ) internal {
        (Vm.Log memory l, uint256 c,) =
            _find(logs, ITournament.MatchCreated.selector);
        assertEq(c, 1);
        assertEq(l.topics[1], Match.IdHash.unwrap(id.hashFromId()));
        assertEq(l.topics[2], Tree.Node.unwrap(id.commitmentOne));
        assertEq(l.topics[3], Tree.Node.unwrap(id.commitmentTwo));
        (Tree.Node leftOfTwo, Time.Instant rd, Time.Instant ea) =
            abi.decode(l.data, (Tree.Node, Time.Instant, Time.Instant));
        (Tree.Node twoLeft,) = two.children(H, 0);
        assertTrue(leftOfTwo.eq(twoLeft), "leftOfTwo is #2's left child");
        _assertBisectionSchedule(rd, ea);
    }

    /// @dev The survivor's discounted clock is the paused side of the new
    /// match, created before the old match is deleted.
    function _checkRepair(
        Vm.Log[] memory logs,
        Tree.Node waiting,
        SmallFullTree.Data memory winner
    ) internal {
        (,, uint256 created) = _find(logs, ITournament.MatchCreated.selector);
        (,, uint256 deleted) = _find(logs, ITournament.MatchDeleted.selector);
        (,, uint256 standing) =
            _find(logs, ITournament.StandingChanged.selector);
        assertLt(created, deleted);
        assertLt(deleted, standing);
        id = Match.Id(waiting, winner.root());
        _checkMatchCreated(logs, winner);
    }

    /// @dev The mutator itself, not only the classifier, accepts the next
    /// move one block before the published deadline and rejects it there.
    function _assertMoveOnlyBeforeDeadline(bytes memory move) internal {
        uint256 snap = vm.snapshotState();
        vm.roll(Time.Instant.unwrap(moveDeadline) - 1);
        (bool accepted,) = address(t).call(move);
        assertTrue(accepted, "move accepted one block before the deadline");
        vm.revertToState(snap);
        snap = vm.snapshotState();
        vm.roll(Time.Instant.unwrap(moveDeadline));
        (accepted,) = address(t).call(move);
        assertFalse(accepted, "move rejected at the deadline");
        vm.revertToState(snap);
    }

    function _assertBisectionSchedule(Time.Instant rd, Time.Instant ea)
        internal
    {
        moveDeadline = rd;
        Match.State memory st = t.getMatch(id.hashFromId());
        ITournament.CommitmentSide side = Match.responder(H, st.currentHeight);
        Tree.Node responder = side == ITournament.CommitmentSide.ONE
            ? id.commitmentOne
            : id.commitmentTwo;
        Tree.Node waiting = side == ITournament.CommitmentSide.ONE
            ? id.commitmentTwo
            : id.commitmentOne;
        ITournament.CommitmentStandingView memory rs =
            t.commitmentStanding(responder);
        ITournament.CommitmentStandingView memory ws =
            t.commitmentStanding(waiting);
        assertTrue(rs.clockRunning, "parity responder is the running clock");
        assertFalse(ws.clockRunning);
        assertEq(
            Time.Instant.unwrap(rd),
            Time.Instant.unwrap(rs.clockDeadline),
            "responderDeadline == commitmentStanding.clockDeadline"
        );
        assertEq(
            Time.Instant.unwrap(ea) - Time.Instant.unwrap(rd),
            Time.Duration.unwrap(ws.clockAllowance),
            "eliminableAt - responderDeadline == waiting paused allowance"
        );
        uint256 snap = vm.snapshotState();
        vm.roll(Time.Instant.unwrap(rd) - 1);
        (, ITournament.MatchTimeoutOutcome o,) = t.classifyMatchTimeout(id);
        assertEq(uint8(o), uint8(ITournament.MatchTimeoutOutcome.NONE));
        vm.roll(Time.Instant.unwrap(rd));
        (, o,) = t.classifyMatchTimeout(id);
        assertEq(
            uint8(o),
            uint8(
                side == ITournament.CommitmentSide.ONE
                    ? ITournament.MatchTimeoutOutcome.TWO_WINS
                    : ITournament.MatchTimeoutOutcome.ONE_WINS
            )
        );
        vm.roll(Time.Instant.unwrap(ea) - 1);
        (, o,) = t.classifyMatchTimeout(id);
        assertTrue(o != ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH);
        vm.roll(Time.Instant.unwrap(ea));
        (, o,) = t.classifyMatchTimeout(id);
        assertEq(
            uint8(o), uint8(ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH)
        );
        vm.revertToState(snap);
    }

    function _checkAdvanced(Vm.Log[] memory logs, uint64 cur, uint256 pos)
        internal
    {
        _assertNoStanding(logs);
        (Vm.Log memory l, uint256 c,) =
            _find(logs, ITournament.MatchAdvanced.selector);
        assertEq(c, 1);
        assertEq(l.topics[1], Match.IdHash.unwrap(id.hashFromId()));
        (
            Tree.Node a,
            Tree.Node b,
            Tree.Node otherParent,
            Tree.Node leftNode,
            uint256 sp,
            uint64 ch,
            Time.Instant rd,
            Time.Instant ea
        ) = abi.decode(
            l.data,
            (
                Tree.Node,
                Tree.Node,
                Tree.Node,
                Tree.Node,
                uint256,
                uint64,
                Time.Instant,
                Time.Instant
            )
        );
        assertTrue(a.eq(id.commitmentOne) && b.eq(id.commitmentTwo));
        Match.State memory st = t.getMatch(id.hashFromId());
        assertTrue(otherParent.eq(st.otherParent));
        assertTrue(leftNode.eq(st.leftNode));
        assertEq(ch, st.currentHeight, "currentHeight == storage");
        assertEq(ch, cur, "currentHeight is post-decrement");
        assertEq(sp, pos);
        assertEq(sp % (uint256(1) << ch), 0, "aligned to 2^currentHeight");
        ITournament.CommitmentSide expected = (H - ch) % 2 == 0
            ? ITournament.CommitmentSide.ONE
            : ITournament.CommitmentSide.TWO;
        if (ch > 1) {
            (Match.Phase ph, ITournament.BisectingMatchView memory bv) =
                t.bisectingMatch(id.hashFromId());
            assertEq(uint8(ph), uint8(Match.Phase.BISECTING));
            assertEq(bv.currentHeight, ch);
            assertEq(bv.segmentStartPosition, sp);
            assertTrue(bv.revealingParent.eq(otherParent));
            assertTrue(bv.waitingLeft.eq(leftNode));
            assertEq(uint8(bv.responder), uint8(expected), "parity rule");
        } else {
            (Match.Phase ph, ITournament.ReadyToSealMatchView memory rv) =
                t.readyToSealMatch(id.hashFromId());
            assertEq(uint8(ph), uint8(Match.Phase.READY_TO_SEAL));
            assertEq(rv.segmentStartPosition, sp);
            assertEq(uint8(rv.responder), uint8(expected), "parity rule");
        }
        _assertBisectionSchedule(rd, ea);
    }

    function _checkSealed(Vm.Log[] memory logs) internal {
        _assertNoStanding(logs);
        (Vm.Log memory l, uint256 c,) =
            _find(logs, ITournament.LeafMatchSealed.selector);
        assertEq(c, 1);
        assertEq(l.topics[1], Match.IdHash.unwrap(id.hashFromId()));
        (
            Tree.Node a,
            Tree.Node b,
            Machine.Hash agree,
            uint256 dp,
            Machine.Hash f1,
            Machine.Hash f2,
            Time.Instant d1,
            Time.Instant d2,
            Time.Instant ea
        ) = abi.decode(
            l.data,
            (
                Tree.Node,
                Tree.Node,
                Machine.Hash,
                uint256,
                Machine.Hash,
                Machine.Hash,
                Time.Instant,
                Time.Instant,
                Time.Instant
            )
        );
        assertTrue(a.eq(id.commitmentOne) && b.eq(id.commitmentTwo));
        (Match.Phase ph, ITournament.SealedMatchView memory sv) =
            t.sealedMatch(id.hashFromId());
        assertEq(uint8(ph), uint8(Match.Phase.SEALED));
        assertEq(Machine.Hash.unwrap(agree), Machine.Hash.unwrap(sv.agreeState));
        assertEq(dp, sv.divergencePosition);
        assertEq(Machine.Hash.unwrap(f1), Machine.Hash.unwrap(sv.finalStateOne));
        assertEq(Machine.Hash.unwrap(f2), Machine.Hash.unwrap(sv.finalStateTwo));
        ITournament.CommitmentStandingView memory s1 =
            t.commitmentStanding(id.commitmentOne);
        ITournament.CommitmentStandingView memory s2 =
            t.commitmentStanding(id.commitmentTwo);
        assertTrue(s1.clockRunning && s2.clockRunning);
        assertEq(Time.Instant.unwrap(d1), Time.Instant.unwrap(s1.clockDeadline));
        assertEq(Time.Instant.unwrap(d2), Time.Instant.unwrap(s2.clockDeadline));
        uint64 mx = Time.Instant.unwrap(d1) > Time.Instant.unwrap(d2)
            ? Time.Instant.unwrap(d1)
            : Time.Instant.unwrap(d2);
        uint64 mn = Time.Instant.unwrap(d1) > Time.Instant.unwrap(d2)
            ? Time.Instant.unwrap(d2)
            : Time.Instant.unwrap(d1);
        assertEq(Time.Instant.unwrap(ea), mx, "eliminableAt == max(d1, d2)");
        moveDeadline = Time.Instant.wrap(mn);
        uint256 snap = vm.snapshotState();
        vm.roll(mn - 1);
        (, ITournament.MatchTimeoutOutcome o,) = t.classifyMatchTimeout(id);
        assertEq(uint8(o), uint8(ITournament.MatchTimeoutOutcome.NONE));
        vm.roll(mn);
        (, o,) = t.classifyMatchTimeout(id);
        if (mn == mx) {
            assertEq(
                uint8(o), uint8(ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH)
            );
        } else {
            assertTrue(
                o == ITournament.MatchTimeoutOutcome.ONE_WINS
                    || o == ITournament.MatchTimeoutOutcome.TWO_WINS
            );
            vm.roll(mx - 1);
            (, o,) = t.classifyMatchTimeout(id);
            assertTrue(o != ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH);
            vm.roll(mx);
            (, o,) = t.classifyMatchTimeout(id);
            assertEq(
                uint8(o), uint8(ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH)
            );
        }
        vm.revertToState(snap);
    }
}
