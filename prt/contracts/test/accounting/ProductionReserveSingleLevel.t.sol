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
import {SmallSingleLevelGeometry} from "test/fixtures/SmallSingleLevelTournament.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev The reserve identities of prt-refund-accounting.md on the production
/// Tournament, one leaf level of height three, under random schedules:
/// joins, advances, leaf seals, leaf proofs for either side, timeout wins
/// and double eliminations, each at a random fee regime from zero to far
/// above the cap, with one caller collecting every refund.
///
/// After every step: the balance is this test's own count of joins times
/// the bond, minus the refunds it received; each refund is within its
/// action cap; each match's refunds are within one bond; and, by the
/// tournament's count of created matches, there is at least one match
/// fewer than joins and the balance holds one bond for every join not yet
/// matched. At the end recovery pays the winner one bond plus a tenth of
/// the residual and every bond is accounted for, or there is no winner and
/// the balance stays.
///
/// A fuzz property over this generator, not every schedule: seven claims,
/// one caller, plain recipients, and a stub for the leaf proof. The sample
/// test shows which operations a fixed set of seeds executes.
///
/// Deeper campaign, one run being one schedule:
///   FOUNDRY_FUZZ_RUNS=3000 FOUNDRY_FUZZ_SEED=<seed> forge test \
///     --match-contract ProductionReserveSingleLevelTest --match-test testFuzz
/// The 2026-11-10 contracts audit recorded 3,000 passing runs.
contract ProductionReserveSingleLevelTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;
    using Match for Match.State;

    uint256 constant CLAIMS = 7;
    uint256 constant LEAVES = uint256(1) << SmallSingleLevelGeometry.HEIGHT;
    uint64 constant G = 5;
    uint64 constant ALLOWANCE = 300;
    uint256 constant SAMPLE_SEEDS = 12;

    uint8 constant WIN_ONE = 0;
    uint8 constant WIN_TWO = 1;
    uint8 constant ELIMINATE = 2;
    uint8 constant ADVANCE = 3;
    uint8 constant SEAL = 4;
    uint8 constant PROVE = 5;

    mapping(bytes32 => uint256) perMatchRefund;

    // One schedule.
    uint256 joins;
    uint256 refunds;

    // Across the schedules of one test.
    uint256[6] actionCount;
    uint256 capHits;
    uint256 winners;
    uint256 noWinners;
    uint256 totalJoins;
    uint256 totalRefunds;
    uint256 totalPaid;
    uint256 totalBurned;

    receive() external payable {}

    function _claimer(uint256 k) internal pure returns (address) {
        return address(uint160(0xC0000 + k));
    }

    /// @dev Claim `k` shares the base leaves before `d` and owns the rest,
    /// so two claims first differ at the smaller `d`: every descent occurs.
    function _claim(uint256 k, uint256 d)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory leaves = new Tree.Node[](LEAVES);
        for (uint256 i; i < LEAVES; ++i) {
            leaves[i] = i < d
                ? Tree.Node.wrap(keccak256(abi.encode("base", i)))
                : Tree.Node.wrap(keccak256(abi.encode("own", k, i)));
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _randomPrice(uint256 r) internal {
        uint256[6] memory bases =
            [uint256(0), 1 gwei, 20 gwei, 45 gwei, 60 gwei, 10_000_000 gwei];
        uint256[4] memory tips = [uint256(0), 1 gwei, 10 gwei, 100 gwei];
        uint256 base = bases[r % 6];
        vm.fee(base);
        vm.txGasPrice(base + tips[(r >> 8) % 4]);
    }

    function _exists(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal view returns (bool) {
        return t.getMatch(matchId(one, two).hashFromId()).exists();
    }

    function _pickMatch(
        InspectableTournament t,
        SmallFullTree.Data[] memory trees,
        bool[] memory joined,
        uint256 r
    ) internal view returns (bool found, uint256 i, uint256 j) {
        uint256 pairs = CLAIMS * CLAIMS;
        uint256 start = r % pairs;
        for (uint256 n; n < pairs; ++n) {
            uint256 p = (start + n) % pairs;
            i = p / CLAIMS;
            j = p % CLAIMS;
            if (i == j || !joined[i] || !joined[j]) {
                continue;
            }
            if (_exists(t, trees[i], trees[j])) {
                return (true, i, j);
            }
        }
        return (false, 0, 0);
    }

    /// @dev The one verb legal for the match now: the timeout verb the
    /// classifier selects, else the next move of its phase.
    function _act(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two,
        uint256 r
    ) internal {
        Match.Id memory id = matchId(one, two);
        bytes32 key = keccak256(
            abi.encode(address(t), Match.IdHash.unwrap(id.hashFromId()))
        );
        Match.State memory s = t.getMatch(id.hashFromId());
        ITournament.MatchTimeoutOutcome outcome = classify(t, one, two);
        uint256 before = address(this).balance;
        uint256 allocation;
        if (outcome == ITournament.MatchTimeoutOutcome.ONE_WINS) {
            timeoutWin(t, one, two, one);
            allocation = Gas.WIN_MATCH_BY_TIMEOUT;
            ++actionCount[WIN_ONE];
        } else if (outcome == ITournament.MatchTimeoutOutcome.TWO_WINS) {
            timeoutWin(t, one, two, two);
            allocation = Gas.WIN_MATCH_BY_TIMEOUT;
            ++actionCount[WIN_TWO];
        } else if (outcome == ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH) {
            eliminate(t, one, two);
            allocation = Gas.ELIMINATE_MATCH_BY_TIMEOUT;
            ++actionCount[ELIMINATE];
        } else if (s.currentHeight > 1) {
            advance(t, one, two);
            allocation = Gas.ADVANCE_MATCH;
            ++actionCount[ADVANCE];
        } else if (s.currentHeight == 1) {
            sealLeaf(t, one, two);
            allocation = Gas.SEAL_LEAF_MATCH;
            ++actionCount[SEAL];
        } else {
            prove(t, one, two, (r & 1) == 0 ? one : two, s.runningLeafPosition);
            allocation = Gas.WIN_LEAF_MATCH;
            ++actionCount[PROVE];
        }
        uint256 refund = address(this).balance - before;
        assertLe(refund, Bond.actionRefundCap(allocation), "action cap");
        if (refund == Bond.actionRefundCap(allocation)) {
            ++capHits;
        }
        perMatchRefund[key] += refund;
        assertLe(perMatchRefund[key], t.bondValue(), "one bond per match");
        refunds += refund;
    }

    function _check(InspectableTournament t, uint256 bond) internal view {
        uint256 balance = address(t).balance;
        assertEq(balance, joins * bond - refunds, "exact balance");
        uint256 created = t.getMatchCreatedCount();
        if (joins > 0) {
            assertLe(created, joins - 1, "one match fewer than joins");
            assertGe(balance, (joins - created) * bond, "reserve");
        } else {
            assertEq(created, 0);
        }
    }

    /// @dev First block at which a running clock of the match has expired.
    function _earliestDeadline(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal view returns (uint256 d) {
        d = type(uint256).max;
        Clock.State memory c1 = clockOf(t, one.root());
        Clock.State memory c2 = clockOf(t, two.root());
        if (Clock.isRunning(c1)) {
            d = uint256(Time.Instant.unwrap(c1.startInstant))
                + Time.Duration.unwrap(c1.allowance);
        }
        if (Clock.isRunning(c2)) {
            uint256 d2 = uint256(Time.Instant.unwrap(c2.startInstant))
                + Time.Duration.unwrap(c2.allowance);
            if (d2 < d) {
                d = d2;
            }
        }
    }

    /// @dev First block at which both sides are eliminable.
    function _eliminationBoundary(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two
    ) internal view returns (uint256) {
        Clock.State memory c1 = clockOf(t, one.root());
        Clock.State memory c2 = clockOf(t, two.root());
        uint256 a1 = Time.Duration.unwrap(c1.allowance);
        uint256 a2 = Time.Duration.unwrap(c2.allowance);
        uint256 s1 = Time.Instant.unwrap(c1.startInstant);
        uint256 s2 = Time.Instant.unwrap(c2.startInstant);
        if (Clock.isRunning(c1) && Clock.isRunning(c2)) {
            return (s1 + a1) > (s2 + a2) ? s1 + a1 : s2 + a2;
        } else if (Clock.isRunning(c1)) {
            return s1 + a1 + a2;
        } else {
            return s2 + a2 + a1;
        }
    }

    function _run(uint256 seed) internal {
        joins = 0;
        refunds = 0;
        vm.roll(100);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        uint256 bond = t.bondValue();
        SmallFullTree.Data[] memory trees = new SmallFullTree.Data[](CLAIMS);
        bool[] memory joined = new bool[](CLAIMS);
        for (uint256 k; k < CLAIMS; ++k) {
            trees[k] = _claim(
                k, uint256(keccak256(abi.encode(seed, "d", k))) % LEAVES
            );
            vm.deal(_claimer(k), 10 ether);
        }
        uint256 burn0 = address(0).balance;

        // The step count varies how much is live at closure. No clock can
        // expire in a root before it closes, so timeouts occur in the drain.
        uint256 steps = 12 + (uint256(keccak256(abi.encode(seed, "n"))) % 70);
        for (uint256 step; step < steps; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            _randomPrice(r >> 200);
            uint256 kind = r % 10;
            if (kind < 3) {
                uint256 k = (r >> 16) % CLAIMS;
                if (!joined[k] && vm.getBlockNumber() < closureOf(t)) {
                    join(t, trees[k], _claimer(k));
                    joined[k] = true;
                    ++joins;
                }
            } else if (kind < 4) {
                rollBy((r >> 16) % 50);
            } else {
                (bool found, uint256 i, uint256 j) =
                    _pickMatch(t, trees, joined, r >> 16);
                if (found) {
                    _act(t, trees[i], trees[j], r >> 64);
                }
            }
            _check(t, bond);
        }

        // Drain: close, then settle every remaining match at its first
        // timeout boundary, or by whatever is legal where the roll lands.
        if (vm.getBlockNumber() < closureOf(t)) {
            rollTo(closureOf(t));
        }
        for (uint256 guard; guard < 400 && liveMatches(t) > 0; ++guard) {
            (bool found, uint256 i, uint256 j) =
                _pickMatch(t, trees, joined, guard * 7);
            assertTrue(found, "live match must be among the joined pairs");
            if (
                classify(t, trees[i], trees[j])
                    == ITournament.MatchTimeoutOutcome.NONE
            ) {
                uint256 v =
                    uint256(keccak256(abi.encode(seed, "v", guard))) % 4;
                uint256 d;
                if (v == 1) {
                    d = _earliestDeadline(t, trees[i], trees[j]);
                } else if (v == 2) {
                    d = _eliminationBoundary(t, trees[i], trees[j]);
                } else if (v == 3) {
                    d = _earliestDeadline(t, trees[i], trees[j]) + 1
                        + (guard % (G + 2));
                }
                if (d > vm.getBlockNumber()) {
                    rollTo(d);
                }
            }
            _randomPrice(uint256(keccak256(abi.encode(seed, "drain", guard))));
            _act(t, trees[i], trees[j], guard);
            _check(t, bond);
        }
        assertEq(liveMatches(t), 0, "drained");

        Tree.Node winner = dangling(t);
        uint256 pre = address(t).balance;
        if (!winner.isZero()) {
            uint256 w = CLAIMS;
            for (uint256 k; k < CLAIMS; ++k) {
                if (joined[k] && trees[k].root().eq(winner)) {
                    w = k;
                }
            }
            assertLt(w, CLAIMS);
            address claimer = _claimer(w);
            uint256 claimer0 = claimer.balance;
            assertGe(pre, bond, "winner reserve");
            assertTrue(t.tryRecoveringBond());
            uint256 paid = claimer.balance - claimer0;
            assertEq(paid, bond + (pre - bond) / 10);
            assertEq(address(t).balance, 0);
            uint256 burned = address(0).balance - burn0;
            assertEq(refunds + paid + burned, joins * bond, "conserved");
            ++winners;
            totalPaid += paid;
            totalBurned += burned;
            // Recovery is idempotent.
            assertTrue(t.tryRecoveringBond());
            assertEq(claimer.balance - claimer0, paid);
        } else {
            vm.expectRevert(ITournament.NoWinner.selector);
            t.tryRecoveringBond();
            assertEq(address(t).balance, joins * bond - refunds);
            ++noWinners;
        }
        totalJoins += joins;
        totalRefunds += refunds;
    }

    function testFuzzProductionReserveSingleLevel(uint256 seed) public {
        _run(seed);
    }

    /// @dev The fuzz property is not vacuous: a fixed set of seeds executes
    /// every action kind, binds action caps, and ends both with a winner
    /// and without one.
    function testSampleExecutesEveryActionAndBothEndings() public {
        for (uint256 seed = 1; seed <= SAMPLE_SEEDS; ++seed) {
            _run(seed);
        }
        uint256 actions;
        for (uint256 kind; kind < actionCount.length; ++kind) {
            actions += actionCount[kind];
        }
        emit log_named_uint("schedules", SAMPLE_SEEDS);
        emit log_named_uint("joins", totalJoins);
        emit log_named_uint("actions", actions);
        emit log_named_uint("timeout wins (one)", actionCount[WIN_ONE]);
        emit log_named_uint("timeout wins (two)", actionCount[WIN_TWO]);
        emit log_named_uint("double eliminations", actionCount[ELIMINATE]);
        emit log_named_uint("advances", actionCount[ADVANCE]);
        emit log_named_uint("leaf seals", actionCount[SEAL]);
        emit log_named_uint("leaf proofs", actionCount[PROVE]);
        emit log_named_uint("refunds at cap", capHits);
        emit log_named_uint("finished with winner", winners);
        emit log_named_uint("finished without winner", noWinners);
        emit log_named_uint("refunds wei", totalRefunds);
        emit log_named_uint("winner payments wei", totalPaid);
        emit log_named_uint("burned wei", totalBurned);

        assertGt(
            actionCount[WIN_ONE] + actionCount[WIN_TWO], 0, "no timeout win"
        );
        assertGt(actionCount[ELIMINATE], 0, "no double elimination");
        assertGt(actionCount[ADVANCE], 0, "no advance");
        assertGt(actionCount[SEAL], 0, "no leaf seal");
        assertGt(actionCount[PROVE], 0, "no leaf proof");
        assertGt(capHits, 0, "no refund at its cap");
        assertGt(winners, 0, "no schedule ended with a winner");
        assertGt(noWinners, 0, "no schedule ended without a winner");
    }
}
