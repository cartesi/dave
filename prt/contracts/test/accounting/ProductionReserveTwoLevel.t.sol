// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Gas} from "src/tournament/libs/Gas.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev The reserve identities of prt-refund-accounting.md on the production
/// Tournament over two levels: a non-leaf root of height two with five
/// claims, where every sealed root match spawns a real leaf child with up
/// to four claims, two in each contested class. Schedules interleave joins,
/// advances, inner and leaf seals, leaf proofs, timeouts, prompt and late
/// propagations and child eliminations, each at a random fee regime, with
/// one caller collecting every refund.
///
/// After every step, for the root and for every child separately: the
/// balance is this test's own count of joins times the bond, minus the
/// refunds that clone paid; each refund is within its action cap; each
/// match's refunds are within one bond; and, by the clone's count of
/// created matches, there is at least one match fewer than joins and the
/// balance holds one bond for every join not yet matched. A fresh child
/// holds nothing and a parent verb moves nothing out of its child. At the
/// end every clone pays its winner one bond plus a tenth of the residual
/// and accounts for every bond, or has no winner and keeps its balance.
///
/// A fuzz property over this generator, not every schedule: one caller,
/// plain recipients, and a stub for the leaf proof. The sample test shows
/// which operations a fixed set of seeds executes.
///
/// Deeper campaign, one run being one schedule:
///   FOUNDRY_FUZZ_RUNS=2500 FOUNDRY_FUZZ_SEED=<seed> forge test \
///     --match-contract ProductionReserveTwoLevelTest --match-test testFuzz
/// The 2026-11-10 contracts audit recorded 2,500 passing runs.
contract ProductionReserveTwoLevelTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;
    using Match for Match.State;

    uint256 constant ROOT_CLAIMS = 5;
    uint256 constant CHILD_CLAIMS = 4;
    uint256 constant MAX_CHILDREN = 10;
    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 240;
    uint256 constant SAMPLE_SEEDS = 8;

    uint8 constant TIMEOUT_WIN = 0;
    uint8 constant ELIMINATE = 1;
    uint8 constant ADVANCE = 2;
    uint8 constant SEAL_LEAF = 3;
    uint8 constant PROVE = 4;
    uint8 constant SEAL_INNER = 5;
    uint8 constant PROPAGATE = 6;
    uint8 constant ELIMINATE_CHILD = 7;
    uint8 constant JOIN = 8;

    /// @dev One clone with the claims that may join it and this test's own
    /// ledger of what was paid in and refunded.
    struct Ledger {
        InspectableTournament t;
        SmallFullTree.Data[] trees;
        bool[] joined;
        uint256 joins;
        uint256 refunds;
        uint256 bond;
        // Children only: the root claims of the sealed match.
        uint256 parentOne;
        uint256 parentTwo;
        bool resolved;
    }

    mapping(bytes32 => uint256) perMatchRefund;

    uint256[9] actionCount;
    uint256 capHits;
    uint256 winners;
    uint256 noWinners;

    receive() external payable {}

    function _claimer(uint256 salt) internal pure returns (address) {
        return address(uint160(0xD00000 + salt));
    }

    function _randomPrice(uint256 r) internal {
        uint256[6] memory bases =
            [uint256(0), 1 gwei, 20 gwei, 45 gwei, 60 gwei, 10_000_000 gwei];
        uint256[4] memory tips = [uint256(0), 1 gwei, 10 gwei, 100 gwei];
        uint256 base = bases[r % 6];
        vm.fee(base);
        vm.txGasPrice(base + tips[(r >> 8) % 4]);
    }

    function _key(InspectableTournament t, Match.Id memory id)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(address(t), Match.IdHash.unwrap(id.hashFromId()))
        );
    }

    function _account(
        Ledger memory c,
        bytes32 key,
        uint256 before,
        uint256 allocation
    ) internal {
        uint256 refund = address(this).balance - before;
        assertLe(refund, Bond.actionRefundCap(allocation), "action cap");
        if (refund == Bond.actionRefundCap(allocation)) {
            ++capHits;
        }
        perMatchRefund[key] += refund;
        assertLe(perMatchRefund[key], c.bond, "one bond per match");
        c.refunds += refund;
    }

    function _check(Ledger memory c) internal view {
        uint256 balance = address(c.t).balance;
        assertEq(balance, c.joins * c.bond - c.refunds, "exact balance");
        uint256 created = c.t.getMatchCreatedCount();
        if (c.joins > 0) {
            assertLe(created, c.joins - 1, "one match fewer than joins");
            assertGe(balance, (c.joins - created) * c.bond, "reserve");
        } else {
            assertEq(created, 0);
        }
    }

    function _pick(Ledger memory c, uint256 r)
        internal
        view
        returns (bool found, uint256 i, uint256 j)
    {
        uint256 n = c.trees.length;
        uint256 start = r % (n * n);
        for (uint256 q; q < n * n; ++q) {
            uint256 p = (start + q) % (n * n);
            i = p / n;
            j = p % n;
            if (i == j || !c.joined[i] || !c.joined[j]) {
                continue;
            }
            if (c.t.getMatch(matchId(c.trees[i], c.trees[j]).hashFromId())
                    .exists()) {
                return (true, i, j);
            }
        }
        return (false, 0, 0);
    }

    function _join(Ledger memory c, uint256 k, uint256 salt) internal {
        if (c.joined[k] || vm.getBlockNumber() >= closureOf(c.t)) {
            return;
        }
        address who = _claimer(salt);
        vm.deal(who, 10 ether);
        join(c.t, c.trees[k], who);
        c.joined[k] = true;
        ++c.joins;
        ++actionCount[JOIN];
    }

    /// @dev The timeout verb the classifier selects, at either level.
    /// A sealed inner match has no local timeout: the view says NONE.
    /// @return acted Whether a timeout verb was called
    function _timeouts(Ledger memory c, uint256 i, uint256 j)
        internal
        returns (bool acted)
    {
        SmallFullTree.Data memory one = c.trees[i];
        SmallFullTree.Data memory two = c.trees[j];
        ITournament.MatchTimeoutOutcome outcome = classify(c.t, one, two);
        if (outcome == ITournament.MatchTimeoutOutcome.NONE) {
            return false;
        }
        bytes32 key = _key(c.t, matchId(one, two));
        uint256 before = address(this).balance;
        if (outcome == ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH) {
            eliminate(c.t, one, two);
            _account(c, key, before, Gas.ELIMINATE_MATCH_BY_TIMEOUT);
            ++actionCount[ELIMINATE];
        } else {
            timeoutWin(
                c.t,
                one,
                two,
                outcome == ITournament.MatchTimeoutOutcome.ONE_WINS ? one : two
            );
            _account(c, key, before, Gas.WIN_MATCH_BY_TIMEOUT);
            ++actionCount[TIMEOUT_WIN];
        }
        return true;
    }

    function _actLeaf(Ledger memory c, uint256 i, uint256 j, uint256 r)
        internal
    {
        if (_timeouts(c, i, j)) {
            return;
        }
        SmallFullTree.Data memory one = c.trees[i];
        SmallFullTree.Data memory two = c.trees[j];
        Match.Id memory id = matchId(one, two);
        Match.State memory s = c.t.getMatch(id.hashFromId());
        bytes32 key = _key(c.t, id);
        uint256 before = address(this).balance;
        if (s.currentHeight > 1) {
            advance(c.t, one, two);
            _account(c, key, before, Gas.ADVANCE_MATCH);
            ++actionCount[ADVANCE];
        } else if (s.currentHeight == 1) {
            sealLeaf(c.t, one, two);
            _account(c, key, before, Gas.SEAL_LEAF_MATCH);
            ++actionCount[SEAL_LEAF];
        } else {
            prove(
                c.t, one, two, (r & 1) == 0 ? one : two, s.runningLeafPosition
            );
            _account(c, key, before, Gas.WIN_LEAF_MATCH);
            ++actionCount[PROVE];
        }
    }

    /// @dev A root action. A seal creates a child, returned through `made`.
    /// A sealed inner match has no move here: its child owns the progress.
    function _actRoot(
        Ledger memory c,
        uint256 i,
        uint256 j,
        Tree.Node[][] memory fines,
        uint256 seed
    ) internal returns (bool made, Ledger memory child) {
        if (_timeouts(c, i, j)) {
            return (false, child);
        }
        SmallFullTree.Data memory one = c.trees[i];
        SmallFullTree.Data memory two = c.trees[j];
        Match.Id memory id = matchId(one, two);
        Match.State memory s = c.t.getMatch(id.hashFromId());
        bytes32 key = _key(c.t, id);
        uint256 before = address(this).balance;
        if (s.currentHeight > 1) {
            advance(c.t, one, two);
            _account(c, key, before, Gas.ADVANCE_MATCH);
            ++actionCount[ADVANCE];
        } else if (s.currentHeight == 1) {
            (InspectableTournament ct, uint256 segment) =
                sealInner(c.t, one, two);
            _account(
                c, key, before, Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
            );
            ++actionCount[SEAL_INNER];
            assertEq(address(ct).balance, 0, "child starts unfunded");
            child = _newChild(ct, fines, i, j, segment, seed);
            made = true;
        }
    }

    /// @dev `base` with its first leaf replaced: another root with the same
    /// final state.
    function _variant(SmallFullTree.Data memory base, bytes32 tag)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        uint256 n = base.leafCount();
        Tree.Node[] memory leaves = new Tree.Node[](n);
        for (uint256 x; x < n; ++x) {
            leaves[x] = base.leaf(x);
        }
        leaves[0] = Tree.Node.wrap(keccak256(abi.encode("variant", tag)));
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _newChild(
        InspectableTournament ct,
        Tree.Node[][] memory fines,
        uint256 i,
        uint256 j,
        uint256 segment,
        uint256 seed
    ) internal view returns (Ledger memory child) {
        child.t = ct;
        child.bond = ct.bondValue();
        child.parentOne = i;
        child.parentTwo = j;
        child.trees = new SmallFullTree.Data[](CHILD_CLAIMS);
        child.joined = new bool[](CHILD_CLAIMS);
        child.trees[0] = childTreeOf(fines[i], segment);
        child.trees[1] = childTreeOf(fines[j], segment);
        child.trees[2] = _variant(
            child.trees[0], keccak256(abi.encode(seed, address(ct), "a"))
        );
        child.trees[3] = _variant(
            child.trees[1], keccak256(abi.encode(seed, address(ct), "b"))
        );
    }

    /// @dev Consume a finished child through the parent verb legal now.
    function _resolve(Ledger memory root, Ledger memory child) internal {
        if (child.resolved) {
            return;
        }
        ITournament.InnerResultView memory res = child.t.innerResult();
        if (res.disposition == ITournament.InnerTournamentDisposition.UNSETTLED)
        {
            return;
        }
        bytes32 key = _key(
            root.t,
            matchId(root.trees[child.parentOne], root.trees[child.parentTwo])
        );
        uint256 before = address(this).balance;
        uint256 childBalance = address(child.t).balance;
        if (res.disposition == ITournament.InnerTournamentDisposition.WINNER) {
            uint256 w = res.parentCommitment
            .eq(root.trees[child.parentOne].root())
                ? child.parentOne
                : child.parentTwo;
            assertTrue(res.parentCommitment.eq(root.trees[w].root()));
            propagate(root.t, child.t, root.trees[w]);
            _account(root, key, before, Gas.WIN_INNER_TOURNAMENT);
            ++actionCount[PROPAGATE];
        } else {
            eliminateChild(root.t, child.t);
            _account(root, key, before, Gas.ELIMINATE_INNER_TOURNAMENT);
            ++actionCount[ELIMINATE_CHILD];
        }
        assertEq(address(child.t).balance, childBalance, "child untouched");
        child.resolved = true;
    }

    /// @dev First block at which a running clock of the match has expired,
    /// or with `elimination` at which both sides are eliminable. Zero for a
    /// sealed inner match, whose clocks are both paused.
    function _deadline(Ledger memory c, uint256 i, uint256 j, bool elimination)
        internal
        view
        returns (uint256)
    {
        Clock.State memory c1 = clockOf(c.t, c.trees[i].root());
        Clock.State memory c2 = clockOf(c.t, c.trees[j].root());
        uint256 a1 = Time.Duration.unwrap(c1.allowance);
        uint256 a2 = Time.Duration.unwrap(c2.allowance);
        uint256 s1 = Time.Instant.unwrap(c1.startInstant);
        uint256 s2 = Time.Instant.unwrap(c2.startInstant);
        bool r1 = Clock.isRunning(c1);
        bool r2 = Clock.isRunning(c2);
        if (!r1 && !r2) {
            return 0;
        }
        if (r1 && r2) {
            uint256 lo = s1 + a1 < s2 + a2 ? s1 + a1 : s2 + a2;
            uint256 hi = s1 + a1 < s2 + a2 ? s2 + a2 : s1 + a1;
            return elimination ? hi : lo;
        }
        if (r1) {
            return elimination ? s1 + a1 + a2 : s1 + a1;
        }
        return elimination ? s2 + a2 + a1 : s2 + a2;
    }

    function _finishAndCheck(Ledger memory c) internal {
        assertEq(liveMatches(c.t), 0, "drained");
        if (vm.getBlockNumber() < closureOf(c.t)) {
            rollTo(closureOf(c.t));
        }
        Tree.Node winner = dangling(c.t);
        uint256 pre = address(c.t).balance;
        assertEq(pre, c.joins * c.bond - c.refunds);
        if (winner.isZero()) {
            vm.expectRevert(ITournament.NoWinner.selector);
            c.t.tryRecoveringBond();
            ++noWinners;
            return;
        }
        address claimer = c.t.observedClaimer(winner);
        assertTrue(claimer != address(0));
        uint256 claimer0 = claimer.balance;
        uint256 burn0 = address(0).balance;
        assertGe(pre, c.bond, "winner reserve");
        assertTrue(c.t.tryRecoveringBond());
        uint256 paid = claimer.balance - claimer0;
        assertEq(paid, c.bond + (pre - c.bond) / 10);
        assertEq(address(c.t).balance, 0);
        assertEq(
            c.refunds + paid + (address(0).balance - burn0),
            c.joins * c.bond,
            "conserved"
        );
        ++winners;
    }

    function _run(uint256 seed) internal {
        vm.roll(100);
        Ledger memory root;
        root.t = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        root.bond = root.t.bondValue();
        root.trees = new SmallFullTree.Data[](ROOT_CLAIMS);
        root.joined = new bool[](ROOT_CLAIMS);
        Tree.Node[][] memory fines = new Tree.Node[][](ROOT_CLAIMS);
        for (uint256 k; k < ROOT_CLAIMS; ++k) {
            // Claim k follows family 1 up to a point of its own, then its
            // own family: any two claims are distinct roots.
            uint256 d = 1 + uint256(keccak256(abi.encode(seed, "d", k))) % 15;
            fines[k] = fineLeaves(1, d, 2 + k);
            root.trees[k] = rootTreeOf(fines[k]);
        }
        Ledger[] memory children = new Ledger[](MAX_CHILDREN);
        uint256 nChildren;

        uint256 steps = 30 + (uint256(keccak256(abi.encode(seed, "n"))) % 130);
        for (uint256 step; step < steps; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            _randomPrice(r >> 200);
            uint256 what = r % 12;
            if (what < 3) {
                _join(root, (r >> 16) % ROOT_CLAIMS, (r >> 16) % ROOT_CLAIMS);
            } else if (what < 6) {
                (bool f, uint256 i, uint256 j) = _pick(root, r >> 16);
                if (f && nChildren < MAX_CHILDREN) {
                    (bool made, Ledger memory ch) =
                        _actRoot(root, i, j, fines, seed);
                    if (made) {
                        children[nChildren++] = ch;
                    }
                }
            } else if (what < 8 && nChildren > 0) {
                Ledger memory ch = children[(r >> 16) % nChildren];
                _join(
                    ch,
                    (r >> 32) % CHILD_CLAIMS,
                    1000 + uint160(address(ch.t)) % 1000 * CHILD_CLAIMS
                        + (r >> 32) % CHILD_CLAIMS
                );
            } else if (what < 10 && nChildren > 0) {
                Ledger memory ch = children[(r >> 16) % nChildren];
                (bool f, uint256 i, uint256 j) = _pick(ch, r >> 32);
                if (f) {
                    _actLeaf(ch, i, j, r >> 64);
                }
            } else if (what < 11 && nChildren > 0) {
                _resolve(root, children[(r >> 16) % nChildren]);
            } else {
                rollBy((r >> 16) % 60);
            }
            _check(root);
            for (uint256 x; x < nChildren; ++x) {
                _check(children[x]);
            }
        }

        // Drain: children first, then the parent verb, then root matches.
        // A root seal in the drain makes a new child, so iterate.
        for (uint256 guard; guard < 600; ++guard) {
            bool busy;
            for (uint256 x; x < nChildren; ++x) {
                if (children[x].resolved) {
                    continue;
                }
                busy = true;
                _drainChild(root, children[x], seed, guard, x);
            }
            (bool rf, uint256 ri, uint256 rj) = _pick(root, guard * 3);
            if (rf) {
                busy = true;
                uint256 dl = _deadline(root, ri, rj, guard % 4 == 1);
                if (dl != 0 && nChildren < MAX_CHILDREN) {
                    // Not sealed inner: settle by time or by moves.
                    if (
                        classify(root.t, root.trees[ri], root.trees[rj])
                                == ITournament.MatchTimeoutOutcome.NONE
                            && guard % 4 != 0
                    ) {
                        if (dl > vm.getBlockNumber()) {
                            rollTo(dl);
                        }
                    }
                    _randomPrice(
                        uint256(keccak256(abi.encode(seed, "qp", guard)))
                    );
                    (bool made, Ledger memory ch) =
                        _actRoot(root, ri, rj, fines, seed);
                    if (made) {
                        children[nChildren++] = ch;
                    }
                } else if (dl != 0) {
                    // The child table is full: only time settles this match.
                    uint256 el = _deadline(root, ri, rj, true);
                    if (el > vm.getBlockNumber()) {
                        rollTo(el);
                    }
                    _timeouts(root, ri, rj);
                }
                _check(root);
            }
            if (!busy) {
                break;
            }
        }

        for (uint256 x; x < nChildren; ++x) {
            assertTrue(children[x].resolved, "child consumed by its parent");
            _finishAndCheck(children[x]);
        }
        _finishAndCheck(root);
    }

    /// @dev One drain step of an unresolved child: settle one of its
    /// matches at a deadline, or with none left, close it and resolve it
    /// through the parent, sometimes after the winner's window lapsed.
    function _drainChild(
        Ledger memory root,
        Ledger memory ch,
        uint256 seed,
        uint256 guard,
        uint256 x
    ) internal {
        uint256 v = uint256(keccak256(abi.encode(seed, "cv", guard, x))) % 5;
        (bool f, uint256 i, uint256 j) = _pick(ch, guard);
        if (f) {
            if (
                classify(ch.t, ch.trees[i], ch.trees[j])
                        == ITournament.MatchTimeoutOutcome.NONE && v != 0
            ) {
                uint256 dl = _deadline(ch, i, j, v == 2);
                if (v == 3) {
                    dl += 1 + (guard % (G + 2));
                }
                if (dl > vm.getBlockNumber()) {
                    rollTo(dl);
                }
            }
            _randomPrice(uint256(keccak256(abi.encode(seed, "cp", guard, x))));
            _actLeaf(ch, i, j, guard);
        } else {
            if (vm.getBlockNumber() < closureOf(ch.t)) {
                rollTo(closureOf(ch.t));
            }
            if (v == 4) {
                uint256 expiry = Time.Instant
                    .unwrap(ch.t.tournamentStanding().winnerExpiresAt);
                if (expiry > vm.getBlockNumber()) {
                    rollTo(expiry);
                }
            }
            _randomPrice(uint256(keccak256(abi.encode(seed, "rp", guard, x))));
            _resolve(root, ch);
        }
        _check(ch);
        _check(root);
    }

    function testFuzzProductionReserveTwoLevel(uint256 seed) public {
        _run(seed);
    }

    /// @dev The fuzz property is not vacuous: a fixed set of seeds executes
    /// every action kind at both levels, binds action caps, and ends clones
    /// both with a winner and without one.
    function testSampleExecutesEveryActionAtBothLevels() public {
        for (uint256 seed = 1; seed <= SAMPLE_SEEDS; ++seed) {
            _run(seed);
        }
        emit log_named_uint("schedules", SAMPLE_SEEDS);
        emit log_named_uint("joins (root and children)", actionCount[JOIN]);
        emit log_named_uint("advances", actionCount[ADVANCE]);
        emit log_named_uint("inner seals", actionCount[SEAL_INNER]);
        emit log_named_uint("leaf seals", actionCount[SEAL_LEAF]);
        emit log_named_uint("leaf proofs", actionCount[PROVE]);
        emit log_named_uint("timeout wins", actionCount[TIMEOUT_WIN]);
        emit log_named_uint("double eliminations", actionCount[ELIMINATE]);
        emit log_named_uint("propagations", actionCount[PROPAGATE]);
        emit log_named_uint("child eliminations", actionCount[ELIMINATE_CHILD]);
        emit log_named_uint("refunds at cap", capHits);
        emit log_named_uint("clones finished with winner", winners);
        emit log_named_uint("clones finished without winner", noWinners);

        for (uint256 kind; kind < actionCount.length; ++kind) {
            assertGt(actionCount[kind], 0, "an action kind never executed");
        }
        assertGt(capHits, 0, "no refund at its cap");
        assertGt(winners, 0, "no clone ended with a winner");
        assertGt(noWinners, 0, "no clone ended without a winner");
    }
}
