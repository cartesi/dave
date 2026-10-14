// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {StdInvariant} from "forge-std-1.9.6/src/StdInvariant.sol";
import {console2} from "forge-std-1.9.6/src/console2.sol";

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

/// @dev R19 honest-survival search (dimensioning.md, "Honest survival under
/// the budgets") over the small two-level geometry with budgets one
/// inclusion below ClockBudgets' C + 2G + (L - 1)(T + 2G): the formula
/// before the in-flight reserve was added, kept as the tighter search.
///
/// Every handler call is one adversary move. Before the move lands, the
/// handler advances the chain to the move's block, firing every honest
/// obligation whose scheduled landing block is reached on the way. An
/// obligation is derived from production state alone (which clock runs,
/// which side must reveal, when a child was created or finished) and lands
/// at `available + latency + censorship`, with `latency < bound` (G, or
/// T + G for a child join) and censorship drawn from one ledger capped at C
/// shared by every tournament. The honest actor is eager: a sealed leaf is
/// resolved by a proof when the classification is NONE and by a timeout
/// claim when the opponent has already expired (the CF-01 latency
/// assumption: proof plus fallback within one G).
///
/// Adversary moves: join Sybils at either level, in either final-state class
/// (honest-class copies with foreign interiors, identical copies of the
/// honest commitment, distinct-root entrants), respond in its own matches at
/// a chosen latency or never, seal, claim timeouts and eliminations anywhere,
/// prove in Sybil-versus-Sybil leaves (either side, an over-approximation of
/// a Sybil that holds the correct leaf), propagate or eliminate children, act
/// on the honest side's behalf at a chosen block, and order itself before or
/// after the honest landing within one block.
///
/// Invariants: the honest commitment keeps its claimer at every level, a
/// finished child that held it carries it as a live winner, every pending
/// honest obligation fits the clock it will be charged to, and a finished
/// root carries the honest final state. Honest actions are called directly,
/// so a production revert on an honest landing fails the run.
contract HonestSurvivalHandler is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Machine for Machine.Hash;
    using Match for Match.Id;
    using Match for Match.State;
    using Clock for Clock.State;
    using Time for Time.Instant;
    using Time for Time.Duration;

    enum Kind {
        JOIN_ROOT,
        JOIN_CHILD,
        RESPOND,
        TIMEOUT,
        RESOLVE_LEAF,
        PROPAGATE
    }

    struct Obligation {
        Kind kind;
        uint256 tourn;
        uint256 index; // live match index, or child tournament index
        uint64 available;
        uint64 bound;
        bytes32 key;
    }

    struct Tourn {
        InspectableTournament t;
        bool isRoot;
        uint256 parent;
        Match.Id origin;
        uint256 segment;
        Tree.Node honest; // zero when the honest party has no stake here
        bool honestJoined;
        bool settled; // the origin match in the parent is gone
        Match.Id[] live;
    }

    uint64 public immutable G;
    uint64 public immutable T;
    uint64 public immutable C;
    uint64 public immutable ALLOWANCE;
    uint64 public immutable START;
    bool public immutable SYBIL_FIRST;

    Tourn[] internal tourns;
    mapping(address => mapping(bytes32 => bytes32[])) internal leavesOf;
    mapping(address => mapping(bytes32 => bool)) internal joinedRoot;
    mapping(address => mapping(bytes32 => uint256)) internal childByOrigin;

    mapping(bytes32 => bool) internal scheduled;
    mapping(bytes32 => uint64) internal landingOf;
    uint256 internal seed;

    // Ghost ledger and search statistics.
    uint64 public censorshipUsed;
    uint256 public honestActions;
    uint256 public honestMaxLatencyDraws;
    uint256 public honestJoinedAsOne;
    uint256 public honestJoinedAsTwo;
    uint256 public childHonestAsOne;
    uint256 public childHonestAsTwo;
    uint256 public childrenWithHonest;
    uint256 public rootFinishes;
    uint256 public applied;
    uint256 public discarded;
    mapping(string => uint256) public appliedBy;
    mapping(string => uint256) public discardedBy;

    receive() external payable {}

    constructor(uint64 g, uint64 t, uint64 c, bool sybilFirst) {
        G = g;
        T = t;
        C = c;
        // One inclusion below ClockBudgets.maxAllowance at L = 2, in blocks.
        ALLOWANCE = c + g + (t + 2 * g);
        SYBIL_FIRST = sybilFirst;
        vm.roll(1000);
        START = _now();
        InspectableTournament root = newRoot(twoLevelFactory(g, t, ALLOWANCE));
        tourns.push();
        Tourn storage r = tourns[0];
        r.t = root;
        r.isRoot = true;
        r.honest = _honestRoot().root();
        _storeLeaves(root, _honestRoot());
        seed = uint256(keccak256("honest-survival"));
        if (sybilFirst) {
            // Orientation two: a Sybil holds the dangling slot before the
            // honest root join can land, so the honest root is commitment two.
            _joinRootSybil(0, 15, 0);
        }
    }

    //
    // Adversary moves. Each lands at `now + delta`, after (or, with
    // `honestFirst` false, before) the honest obligations due by then.
    //

    function joinRootSybil(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 kind,
        uint8 p1,
        uint8 p2,
        bool late
    ) external {
        _step(delta, honestFirst, entropy);
        if (!SYBIL_FIRST && !tourns[0].honestJoined && kind % 3 != 2) {
            // Orientation one: the honest root join lands first.
            _discard("joinRootSybil");
            return;
        }
        // A late root join ends the root's join window for every later
        // Sybil, so it is taken only on a quarter of the late flags.
        if (late && p1 % 4 == 0) _lateTo(closureOf(tourns[0].t), p2 >> 4);
        try this.extJoinRootSybil(kind % 3, p1, p2) {
            _apply("joinRootSybil");
        } catch {
            _discard("joinRootSybil");
        }
    }

    function joinChildSybil(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 childSel,
        bool honestClass,
        uint8 mask,
        uint8 fam,
        bool late
    ) external {
        _step(delta, honestFirst, entropy);
        if (tourns.length < 2) {
            _discard("joinChildSybil");
            return;
        }
        uint256 ti = 1 + (childSel % (tourns.length - 1));
        if (late) _lateTo(closureOf(tourns[ti].t), fam >> 2);
        try this.extJoinChildSybil(ti, honestClass, mask % 8, fam % 4) {
            _apply("joinChildSybil");
        } catch {
            _discard("joinChildSybil");
        }
    }

    /// @dev The Sybil side of a chosen match reveals (advance or seal). In a
    /// Sybil-versus-Sybil match the responder is a Sybil by definition.
    function sybilRespond(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 tSel,
        uint8 mSel,
        bool late,
        uint8 slack
    ) external {
        _step(delta, honestFirst, entropy);
        (bool ok, uint256 ti, uint256 mi) = _selectMatch(tSel, mSel);
        if (!ok) {
            _discard("sybilRespond");
            return;
        }
        if (late) {
            // Reveal just before the responder's own deadline.
            Tourn storage c = tourns[ti];
            Match.Id memory id = c.live[mi];
            Clock.State memory one = clockOf(c.t, id.commitmentOne);
            Clock.State memory two = clockOf(c.t, id.commitmentTwo);
            if (one.isRunning() != two.isRunning()) {
                Clock.State memory running = one.isRunning() ? one : two;
                _lateTo(Time.Instant.unwrap(running.deadline()), slack);
                (ok, ti, mi) = _selectMatch(tSel, mSel);
                if (!ok) {
                    _discard("sybilRespond");
                    return;
                }
            }
        }
        try this.extSybilRespond(ti, mi) {
            _apply("sybilRespond");
        } catch {
            _discard("sybilRespond");
        }
    }

    /// @dev Any timeout resolution the classifier allows, for either side.
    function claimTimeout(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 tSel,
        uint8 mSel
    ) external {
        _step(delta, honestFirst, entropy);
        (bool ok, uint256 ti, uint256 mi) = _selectMatch(tSel, mSel);
        if (!ok) {
            _discard("claimTimeout");
            return;
        }
        try this.extClaimTimeout(ti, mi) {
            _apply("claimTimeout");
        } catch {
            _discard("claimTimeout");
        }
    }

    /// @dev Prove either side of a sealed Sybil-versus-Sybil leaf.
    function proveSybil(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 tSel,
        uint8 mSel,
        bool sideOne
    ) external {
        _step(delta, honestFirst, entropy);
        (bool ok, uint256 ti, uint256 mi) = _selectMatch(tSel, mSel);
        if (!ok) {
            _discard("proveSybil");
            return;
        }
        try this.extProveSybil(ti, mi, sideOne) {
            _apply("proveSybil");
        } catch {
            _discard("proveSybil");
        }
    }

    /// @dev Propagate or eliminate any child, whoever its winner is.
    function settleChild(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 childSel,
        bool late
    ) external {
        _step(delta, honestFirst, entropy);
        if (tourns.length < 2) {
            _discard("settleChild");
            return;
        }
        uint256 ti = 1 + (childSel % (tourns.length - 1));
        if (late) {
            // Propagate just before the child winner's window closes.
            ITournament.TournamentStandingView memory sv =
                tourns[ti].t.tournamentStanding();
            if (sv.standing == ITournament.TournamentStanding.INNER_WINNER) {
                _lateTo(Time.Instant.unwrap(sv.winnerExpiresAt), childSel >> 4);
            }
        }
        try this.extSettleChild(ti) {
            _apply("settleChild");
        } catch {
            _discard("settleChild");
        }
    }

    /// @dev The adversary performs the honest side's next due action itself,
    /// at its own chosen block.
    function actForHonest(uint8 delta, bool honestFirst, uint256 entropy)
        external
    {
        _step(delta, honestFirst, entropy);
        Obligation[] memory obs = _derive();
        if (obs.length == 0) {
            _discard("actForHonest");
            return;
        }
        Obligation memory ob = obs[uint256(seed) % obs.length];
        if (ob.available > _now()) {
            _discard("actForHonest");
            return;
        }
        try this.extExecuteHonest(ob, SYBIL) {
            _apply("actForHonest");
        } catch {
            _discard("actForHonest");
        }
    }

    function elapse(uint8 delta, bool honestFirst, uint256 entropy) external {
        _step(delta, honestFirst, entropy);
        _apply("elapse");
    }

    //
    // External self-calls, so a production revert becomes a discard.
    //

    function extJoinRootSybil(uint8 kind, uint8 p1, uint8 p2) external {
        require(msg.sender == address(this));
        _joinRootSybil(kind, p1, p2);
    }

    function extJoinChildSybil(
        uint256 ti,
        bool honestClass,
        uint8 mask,
        uint8 fam
    ) external {
        require(msg.sender == address(this));
        Tourn storage c = tourns[ti];
        ITournament.NestedDispute memory nd =
        c.t.tournamentArguments().nestedDispute;
        Machine.Hash honestState = c.honest.isZero()
            ? nd.contestedFinalStateOne
            : _tree(c.t, c.honest).finalState();
        Machine.Hash last = nd.contestedFinalStateOne.eq(honestState)
            ? (honestClass
                    ? nd.contestedFinalStateOne
                    : nd.contestedFinalStateTwo)
            : (honestClass
                    ? nd.contestedFinalStateTwo
                    : nd.contestedFinalStateOne);
        Tree.Node[] memory leaves = new Tree.Node[](SEGMENT_SIZE);
        Tree.Node[] memory honestFine = fineLeaves(1);
        uint256 family = 2 + 2 * uint256(fam);
        for (uint256 j; j + 1 < SEGMENT_SIZE; ++j) {
            uint256 i = c.segment * SEGMENT_SIZE + j;
            leaves[j] = (mask >> j) & 1 == 1
                ? Tree.Node.wrap(bytes32((family << 8) | (0x100 + i)))
                : honestFine[i];
        }
        leaves[SEGMENT_SIZE - 1] = Tree.Node.wrap(Machine.Hash.unwrap(last));
        SmallFullTree.Data memory tree = SmallFullTree.buildFromLeaves(leaves);
        _joinAs(ti, tree, SYBIL);
    }

    function extSybilRespond(uint256 ti, uint256 mi) external {
        require(msg.sender == address(this));
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        Match.State memory s = c.t.getMatch(id.hashFromId());
        (,,, uint64 height) = c.t.tournamentLevelConstants();
        require(s.currentHeight > 0, "sealed");
        ITournament.CommitmentSide side =
            Match.responder(height, s.currentHeight);
        Tree.Node responder = side == ITournament.CommitmentSide.ONE
            ? id.commitmentOne
            : id.commitmentTwo;
        require(!responder.eq(c.honest), "honest responds");
        _respond(ti, mi);
    }

    function extClaimTimeout(uint256 ti, uint256 mi) external {
        require(msg.sender == address(this));
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        SmallFullTree.Data memory one = _tree(c.t, id.commitmentOne);
        SmallFullTree.Data memory two = _tree(c.t, id.commitmentTwo);
        ITournament.MatchTimeoutOutcome outcome = classify(c.t, one, two);
        if (outcome == ITournament.MatchTimeoutOutcome.ONE_WINS) {
            _timeoutWin(ti, mi, id.commitmentOne);
        } else if (outcome == ITournament.MatchTimeoutOutcome.TWO_WINS) {
            _timeoutWin(ti, mi, id.commitmentTwo);
        } else if (outcome == ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH) {
            eliminate(c.t, one, two);
            _dropMatch(ti, mi);
        } else {
            revert("none");
        }
    }

    function extProveSybil(uint256 ti, uint256 mi, bool sideOne) external {
        require(msg.sender == address(this));
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        require(
            !id.commitmentOne.eq(c.honest) && !id.commitmentTwo.eq(c.honest),
            "honest match"
        );
        _prove(ti, mi, sideOne ? id.commitmentOne : id.commitmentTwo);
    }

    function extSettleChild(uint256 ti) external {
        require(msg.sender == address(this));
        Tourn storage c = tourns[ti];
        require(!c.settled, "settled");
        ITournament.InnerResultView memory r = c.t.innerResult();
        if (r.disposition == ITournament.InnerTournamentDisposition.WINNER) {
            _propagate(ti, r.parentCommitment);
        } else if (
            r.disposition == ITournament.InnerTournamentDisposition.ELIMINABLE
        ) {
            Tourn storage p = tourns[c.parent];
            eliminateChild(p.t, c.t);
            _dropMatchById(c.parent, c.origin);
            c.settled = true;
        } else {
            revert("unsettled");
        }
    }

    function extExecuteHonest(Obligation memory ob, address claimer) external {
        require(msg.sender == address(this));
        _executeHonest(ob, claimer);
    }

    //
    // Time and the honest actor
    //

    function _step(uint8 delta, bool honestFirst, uint256 entropy) internal {
        seed = uint256(keccak256(abi.encode(seed, entropy)));
        // Mostly same-block or short waits: the root is open for only
        // ALLOWANCE blocks, and every clock is of that order.
        uint256 pick = uint256(keccak256(abi.encode(seed, "span"))) % 100;
        uint64 span = pick < 75
            ? 0
            : pick < 90 ? 1 : pick < 97 ? G : pick < 99 ? 3 * G : ALLOWANCE;
        uint64 target = _now() + (delta % (span + 1));
        _advanceTo(target, honestFirst);
    }

    /// @dev Advance to `1 + slack % G` blocks before `deadline`, if that is
    /// still ahead; honest obligations due on the way land first.
    function _lateTo(uint64 deadline, uint8 slack) internal {
        uint64 back = 1 + (slack % G);
        if (deadline <= back) return;
        uint64 target = deadline - back;
        if (target > _now()) _advanceTo(target, true);
    }

    function _advanceTo(uint64 target, bool honestFirst) internal {
        for (uint256 guard; guard < 64; ++guard) {
            Obligation[] memory obs = _derive();
            (bool found, Obligation memory ob, uint64 landing) = _earliest(obs);
            bool due = found
                && (landing < target || (honestFirst && landing <= target));
            if (!due) break;
            require(landing >= _now(), "model: obligation derived late");
            if (landing > _now()) vm.roll(landing);
            _executeHonest(ob, HONEST);
        }
        if (target > _now()) vm.roll(target);
    }

    /// @dev Schedules every unscheduled obligation and returns the earliest.
    function _earliest(Obligation[] memory obs)
        internal
        returns (bool found, Obligation memory best, uint64 landing)
    {
        for (uint256 i; i < obs.length; ++i) {
            Obligation memory ob = obs[i];
            if (!scheduled[ob.key]) {
                scheduled[ob.key] = true;
                landingOf[ob.key] =
                    ob.available + _drawLatency(ob) + _drawCensorship(ob);
            }
            uint64 l = landingOf[ob.key];
            if (!found || l < landing) {
                found = true;
                best = ob;
                landing = l;
            }
        }
    }

    /// @dev Latency strictly below the bound, biased to the maximum.
    function _drawLatency(Obligation memory ob) internal returns (uint64) {
        seed = uint256(keccak256(abi.encode(seed, ob.key, "latency")));
        if (seed % 2 == 0) {
            ++honestMaxLatencyDraws;
            return ob.bound - 1;
        }
        return uint64((seed >> 8) % ob.bound);
    }

    /// @dev Censorship from the single ledger, biased to spend it all.
    function _drawCensorship(Obligation memory ob) internal returns (uint64) {
        uint64 left = C - censorshipUsed;
        if (left == 0) return 0;
        seed = uint256(keccak256(abi.encode(seed, ob.key, "censor")));
        uint64 c;
        uint256 pick = seed % 4;
        if (pick == 0) c = 0;
        else if (pick == 1 || pick == 2) c = left;
        else c = uint64((seed >> 8) % (left + 1));
        censorshipUsed += c;
        return c;
    }

    /// @dev Every honest obligation implied by production state, including
    /// ones that become actionable only later (an opponent's deadline).
    function _derive() internal view returns (Obligation[] memory obs) {
        Obligation[] memory buf = new Obligation[](8);
        uint256 n;
        Tourn storage root = tourns[0];
        if (!root.honestJoined && !_closedAt(root.t, _now())) {
            buf[n++] = Obligation({
                kind: Kind.JOIN_ROOT,
                tourn: 0,
                index: 0,
                available: START,
                bound: G,
                key: keccak256("join-root")
            });
        }
        for (uint256 ti; ti < tourns.length; ++ti) {
            Tourn storage c = tourns[ti];
            if (c.honest.isZero() || !c.honestJoined || c.settled) continue;
            (bool inMatch, uint256 mi) = _matchOf(ti, c.honest);
            if (!inMatch) {
                if (c.isRoot || c.live.length != 0) continue;
                if (!dangling(c.t).eq(c.honest)) continue;
                (uint64 closedAt, uint64 lastDeleted) = _closure(c.t);
                uint64 at = closedAt > lastDeleted ? closedAt : lastDeleted;
                buf[n++] = Obligation({
                    kind: Kind.PROPAGATE,
                    tourn: ti,
                    index: 0,
                    available: at,
                    bound: G,
                    key: keccak256(abi.encode("propagate", ti, at))
                });
                continue;
            }
            Match.Id memory id = c.live[mi];
            Match.State memory s = c.t.getMatch(id.hashFromId());
            (ITournament.TournamentKind kind,,, uint64 height) =
                c.t.tournamentLevelConstants();
            Clock.State memory h = clockOf(c.t, c.honest);
            if (s.currentHeight > 0) {
                bool honestIsOne = id.commitmentOne.eq(c.honest);
                bool oneResponds = Match.responder(height, s.currentHeight)
                    == ITournament.CommitmentSide.ONE;
                if (honestIsOne == oneResponds) {
                    buf[n++] = Obligation({
                        kind: Kind.RESPOND,
                        tourn: ti,
                        index: mi,
                        available: Time.Instant.unwrap(h.startInstant),
                        bound: G,
                        key: keccak256(
                            abi.encode("respond", ti, id, s.currentHeight)
                        )
                    });
                } else {
                    Clock.State memory o = clockOf(
                        c.t, honestIsOne ? id.commitmentTwo : id.commitmentOne
                    );
                    buf[n++] = Obligation({
                        kind: Kind.TIMEOUT,
                        tourn: ti,
                        index: mi,
                        available: Time.Instant.unwrap(o.deadline()),
                        bound: G,
                        key: keccak256(
                            abi.encode("timeout", ti, id, s.currentHeight)
                        )
                    });
                }
            } else if (kind == ITournament.TournamentKind.LEAF) {
                buf[n++] = Obligation({
                    kind: Kind.RESOLVE_LEAF,
                    tourn: ti,
                    index: mi,
                    available: Time.Instant.unwrap(h.startInstant),
                    bound: G,
                    key: keccak256(abi.encode("resolve", ti, id))
                });
            } else {
                uint256 ci = childByOrigin[
                    address(c.t)
                ][Match.IdHash.unwrap(id.hashFromId())];
                Tourn storage child = tourns[ci];
                if (!child.honestJoined) {
                    buf[n++] = Obligation({
                        kind: Kind.JOIN_CHILD,
                        tourn: ci,
                        index: 0,
                        available: Time.Instant
                            .unwrap(child.t.tournamentArguments().startInstant),
                        bound: T + G,
                        key: keccak256(abi.encode("join-child", ci))
                    });
                }
            }
        }
        obs = new Obligation[](n);
        for (uint256 i; i < n; ++i) {
            obs[i] = buf[i];
        }
    }

    function _executeHonest(Obligation memory ob, address claimer) internal {
        Tourn storage c = tourns[ob.tourn];
        ++honestActions;
        if (ob.kind == Kind.JOIN_ROOT) {
            _joinAs(0, _honestRoot(), claimer);
            if (dangling(c.t).eq(c.honest)) ++honestJoinedAsOne;
            else ++honestJoinedAsTwo;
        } else if (ob.kind == Kind.JOIN_CHILD) {
            _joinAs(ob.tourn, childTreeOf(fineLeaves(1), c.segment), claimer);
            if (dangling(c.t).eq(c.honest)) ++childHonestAsOne;
            else ++childHonestAsTwo;
        } else if (ob.kind == Kind.RESPOND) {
            _respond(ob.tourn, ob.index);
        } else if (ob.kind == Kind.TIMEOUT) {
            _timeoutWin(ob.tourn, ob.index, c.honest);
        } else if (ob.kind == Kind.RESOLVE_LEAF) {
            Match.Id memory id = c.live[ob.index];
            ITournament.MatchTimeoutOutcome outcome = classify(
                c.t, _tree(c.t, id.commitmentOne), _tree(c.t, id.commitmentTwo)
            );
            bool honestIsOne = id.commitmentOne.eq(c.honest);
            if (outcome == ITournament.MatchTimeoutOutcome.NONE) {
                _prove(ob.tourn, ob.index, c.honest);
            } else if (
                (outcome == ITournament.MatchTimeoutOutcome.ONE_WINS)
                        == honestIsOne
                    && outcome != ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH
            ) {
                _timeoutWin(ob.tourn, ob.index, c.honest);
            } else {
                revert("honest leaf eliminated");
            }
        } else {
            _propagate(ob.tourn, tourns[c.parent].honest);
        }
    }

    //
    // Production actions with topology bookkeeping
    //

    function _joinRootSybil(uint8 kind, uint8 p1, uint8 p2) internal {
        Tree.Node[] memory fine;
        if (kind == 0) {
            // Wrong final state, diverging at fine leaf p1.
            fine = fineLeaves(1, p1 % 16, 2 + 2 * (p2 % 4));
        } else if (kind == 1) {
            // Honest final state, foreign interior covering a segment end.
            fine = fineLeaves(1);
            uint256 s = p1 % 3;
            uint256 from = s * SEGMENT_SIZE + (p2 % 4);
            uint256 family = 2 + 2 * ((p2 >> 2) % 4);
            for (uint256 i = from; i < (s + 1) * SEGMENT_SIZE; ++i) {
                fine[i] = Tree.Node.wrap(bytes32((family << 8) | (0x100 + i)));
            }
        } else {
            // An identical copy of the honest root, claimed by the Sybil.
            fine = fineLeaves(1);
        }
        _joinAs(0, rootTreeOf(fine), SYBIL);
        if (kind == 2) {
            if (dangling(tourns[0].t).eq(tourns[0].honest)) {
                ++honestJoinedAsOne;
            } else {
                ++honestJoinedAsTwo;
            }
        }
    }

    function _joinAs(
        uint256 ti,
        SmallFullTree.Data memory tree,
        address claimer
    ) internal {
        Tourn storage c = tourns[ti];
        Tree.Node before = dangling(c.t);
        join(c.t, tree, claimer);
        Tree.Node r = tree.root();
        _storeLeaves(c.t, tree);
        joinedRoot[address(c.t)][Tree.Node.unwrap(r)] = true;
        if (r.eq(c.honest)) c.honestJoined = true;
        _recordPairing(ti, before, r);
    }

    function _respond(uint256 ti, uint256 mi) internal {
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        SmallFullTree.Data memory one = _tree(c.t, id.commitmentOne);
        SmallFullTree.Data memory two = _tree(c.t, id.commitmentTwo);
        Match.State memory s = c.t.getMatch(id.hashFromId());
        (ITournament.TournamentKind kind,,,) = c.t.tournamentLevelConstants();
        if (s.currentHeight > 1) {
            advance(c.t, one, two);
        } else if (kind == ITournament.TournamentKind.LEAF) {
            sealLeaf(c.t, one, two);
        } else {
            (InspectableTournament child, uint256 segment) =
                sealInner(c.t, one, two);
            tourns.push();
            uint256 ci = tourns.length - 1;
            Tourn storage k = tourns[ci];
            k.t = child;
            k.parent = ti;
            k.origin = id;
            k.segment = segment;
            childByOrigin[address(c.t)][Match.IdHash.unwrap(id.hashFromId())] =
                ci;
            if (id.commitmentOne.eq(c.honest) || id.commitmentTwo.eq(c.honest))
            {
                SmallFullTree.Data memory hc =
                    childTreeOf(fineLeaves(1), segment);
                k.honest = hc.root();
                _storeLeaves(child, hc);
                ++childrenWithHonest;
            }
        }
    }

    function _timeoutWin(uint256 ti, uint256 mi, Tree.Node winner) internal {
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        Tree.Node before = dangling(c.t);
        timeoutWin(
            c.t,
            _tree(c.t, id.commitmentOne),
            _tree(c.t, id.commitmentTwo),
            _tree(c.t, winner)
        );
        _dropMatch(ti, mi);
        _recordPairing(ti, before, winner);
    }

    function _prove(uint256 ti, uint256 mi, Tree.Node winner) internal {
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        SmallFullTree.Data memory one = _tree(c.t, id.commitmentOne);
        SmallFullTree.Data memory two = _tree(c.t, id.commitmentTwo);
        Match.State memory s = c.t.getMatch(id.hashFromId());
        require(s.currentHeight == 0 && s.isInit, "not sealed");
        Tree.Node before = dangling(c.t);
        prove(c.t, one, two, _tree(c.t, winner), s.runningLeafPosition);
        _dropMatch(ti, mi);
        _recordPairing(ti, before, winner);
    }

    function _propagate(uint256 ci, Tree.Node parentWinner) internal {
        Tourn storage k = tourns[ci];
        Tourn storage p = tourns[k.parent];
        Tree.Node before = dangling(p.t);
        propagate(p.t, k.t, _tree(p.t, parentWinner));
        _dropMatchById(k.parent, k.origin);
        k.settled = true;
        _recordPairing(k.parent, before, parentWinner);
        if (k.parent == 0 && p.t.isFinished()) ++rootFinishes;
    }

    function _recordPairing(uint256 ti, Tree.Node before, Tree.Node actor)
        internal
    {
        Tourn storage c = tourns[ti];
        if (!before.isZero() && !before.eq(actor) && dangling(c.t).isZero()) {
            c.live.push(Match.Id({commitmentOne: before, commitmentTwo: actor}));
        }
    }

    function _dropMatch(uint256 ti, uint256 mi) internal {
        Tourn storage c = tourns[ti];
        c.live[mi] = c.live[c.live.length - 1];
        c.live.pop();
    }

    function _dropMatchById(uint256 ti, Match.Id memory id) internal {
        Tourn storage c = tourns[ti];
        bytes32 want = Match.IdHash.unwrap(id.hashFromId());
        for (uint256 i; i < c.live.length; ++i) {
            if (Match.IdHash.unwrap(c.live[i].hashFromId()) == want) {
                _dropMatch(ti, i);
                return;
            }
        }
        revert("model: unknown match");
    }

    //
    // Lookups
    //

    function _honestRoot() internal pure returns (SmallFullTree.Data memory) {
        return rootTreeOf(fineLeaves(1));
    }

    function _storeLeaves(
        InspectableTournament t,
        SmallFullTree.Data memory tree
    ) internal {
        bytes32[] storage slot = leavesOf[
            address(t)
        ][Tree.Node.unwrap(tree.root())];
        if (slot.length != 0) return;
        for (uint256 i; i < tree.leafCount(); ++i) {
            slot.push(Tree.Node.unwrap(tree.leaf(i)));
        }
    }

    function _tree(InspectableTournament t, Tree.Node root)
        internal
        view
        returns (SmallFullTree.Data memory)
    {
        bytes32[] storage slot = leavesOf[address(t)][Tree.Node.unwrap(root)];
        require(slot.length != 0, "model: unknown tree");
        Tree.Node[] memory leaves = new Tree.Node[](slot.length);
        for (uint256 i; i < slot.length; ++i) {
            leaves[i] = Tree.Node.wrap(slot[i]);
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _matchOf(uint256 ti, Tree.Node who)
        internal
        view
        returns (bool, uint256)
    {
        Tourn storage c = tourns[ti];
        for (uint256 i; i < c.live.length; ++i) {
            if (
                c.live[i].commitmentOne.eq(who)
                    || c.live[i].commitmentTwo.eq(who)
            ) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function _selectMatch(uint8 tSel, uint8 mSel)
        internal
        view
        returns (bool, uint256, uint256)
    {
        uint256 n = tourns.length;
        for (uint256 k; k < n; ++k) {
            uint256 ti = (uint256(tSel) + k) % n;
            if (tourns[ti].live.length != 0) {
                return (true, ti, mSel % tourns[ti].live.length);
            }
        }
        return (false, 0, 0);
    }

    function _closure(InspectableTournament t)
        internal
        view
        returns (uint64 closedAt, uint64 lastDeleted)
    {
        closedAt = closureOf(t);
        (,, Time.Instant d) = t.observedTopology();
        lastDeleted = Time.Instant.unwrap(d);
    }

    function _closedAt(InspectableTournament t, uint64 at)
        internal
        view
        returns (bool)
    {
        return at >= closureOf(t);
    }

    /// @dev The optimizer may reuse one `block.number` read across a call;
    /// after `vm.roll` only the cheatcode is reliable.
    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockNumber());
    }

    function _apply(string memory name) internal {
        ++applied;
        ++appliedBy[name];
    }

    function _discard(string memory name) internal {
        ++discarded;
        ++discardedBy[name];
    }

    //
    // Invariant checks, read by the test contract.
    //

    function checkHonestSurvives() external view {
        for (uint256 ti; ti < tourns.length; ++ti) {
            Tourn storage c = tourns[ti];
            if (c.honest.isZero() || !c.honestJoined || c.settled) continue;
            require(
                c.t.observedClaimer(c.honest) != address(0),
                "honest commitment eliminated"
            );
            if (!c.isRoot) {
                ITournament.InnerResultView memory r = c.t.innerResult();
                require(
                    r.disposition
                        != ITournament.InnerTournamentDisposition.ELIMINABLE,
                    "honest child eliminable"
                );
            } else if (c.t.isFinished()) {
                ITournament.TournamentStandingView memory s =
                    c.t.tournamentStanding();
                require(
                    s.standing == ITournament.TournamentStanding.ROOT_WINNER
                        && s.candidate.eq(c.honest)
                        && s.finalState.eq(_honestRoot().finalState()),
                    "root winner is not the honest commitment"
                );
            }
        }
    }

    /// @dev Every pending obligation lands before the clock it draws on
    /// expires: the ghost schedule is covered by production state.
    function checkClocksCover() external {
        Obligation[] memory obs = _derive();
        _earliest(obs);
        for (uint256 i; i < obs.length; ++i) {
            Obligation memory ob = obs[i];
            uint64 landing = landingOf[ob.key];
            Tourn storage c = tourns[ob.tourn];
            if (ob.kind == Kind.JOIN_ROOT || ob.kind == Kind.JOIN_CHILD) {
                require(landing < closureOf(c.t), "join after closure");
            } else if (ob.kind == Kind.RESPOND || ob.kind == Kind.RESOLVE_LEAF)
            {
                Clock.State memory h = clockOf(c.t, c.honest);
                require(h.isRunning(), "honest clock not running");
                require(
                    Time.Instant.unwrap(h.deadline()) > landing,
                    "honest response lands after its deadline"
                );
            } else if (ob.kind == Kind.TIMEOUT) {
                Clock.State memory h = clockOf(c.t, c.honest);
                require(!h.isRunning(), "honest clock running while waiting");
                require(
                    Time.Duration.unwrap(h.allowance) > landing - ob.available,
                    "timeout claim lands after the deferred charge"
                );
            } else {
                Clock.State memory h = clockOf(c.t, c.honest);
                require(
                    ob.available + Time.Duration.unwrap(h.allowance) > landing,
                    "propagation lands after the winner expires"
                );
            }
        }
    }

    function tournamentCount() external view returns (uint256) {
        return tourns.length;
    }
}

abstract contract HonestSurvivalInvariantBase is
    StdInvariant,
    TournamentDriver
{
    HonestSurvivalHandler internal handler;

    function _setUpSearch(uint64 g, uint64 t, uint64 c, bool sybilFirst)
        internal
    {
        handler = new HonestSurvivalHandler(g, t, c, sybilFirst);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = HonestSurvivalHandler.joinRootSybil.selector;
        selectors[1] = HonestSurvivalHandler.joinChildSybil.selector;
        selectors[2] = HonestSurvivalHandler.sybilRespond.selector;
        selectors[3] = HonestSurvivalHandler.claimTimeout.selector;
        selectors[4] = HonestSurvivalHandler.proveSybil.selector;
        selectors[5] = HonestSurvivalHandler.settleChild.selector;
        selectors[6] = HonestSurvivalHandler.actForHonest.selector;
        selectors[7] = HonestSurvivalHandler.elapse.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    function _check() internal {
        handler.checkHonestSurvives();
        handler.checkClocksCover();
    }

    function afterInvariant() public view {
        console2.log("applied", handler.applied());
        console2.log("discarded", handler.discarded());
        console2.log("honestActions", handler.honestActions());
        console2.log("censorshipUsed", handler.censorshipUsed());
        console2.log("tournaments", handler.tournamentCount());
        console2.log("childrenWithHonest", handler.childrenWithHonest());
        console2.log("rootFinishes", handler.rootFinishes());
        console2.log("block", vm.getBlockNumber());
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract HonestSurvivalC0OneTest is HonestSurvivalInvariantBase {
    function setUp() public {
        _setUpSearch(3, 6, 0, false);
    }

    function invariantHonestSurvives() public {
        _check();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract HonestSurvivalC0TwoTest is HonestSurvivalInvariantBase {
    function setUp() public {
        _setUpSearch(3, 6, 0, true);
    }

    function invariantHonestSurvives() public {
        _check();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract HonestSurvivalC2OneTest is HonestSurvivalInvariantBase {
    function setUp() public {
        _setUpSearch(3, 6, 2, false);
    }

    function invariantHonestSurvives() public {
        _check();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract HonestSurvivalC2TwoTest is HonestSurvivalInvariantBase {
    function setUp() public {
        _setUpSearch(3, 6, 2, true);
    }

    function invariantHonestSurvives() public {
        _check();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract HonestSurvivalC5OneTest is HonestSurvivalInvariantBase {
    function setUp() public {
        _setUpSearch(3, 6, 5, false);
    }

    function invariantHonestSurvives() public {
        _check();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract HonestSurvivalC5TwoTest is HonestSurvivalInvariantBase {
    function setUp() public {
        _setUpSearch(3, 6, 5, true);
    }

    function invariantHonestSurvives() public {
        _check();
    }
}
