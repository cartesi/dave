// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {console2} from "forge-std-1.9.6/src/console2.sol";

import {ITournament} from "src/ITournament.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {ProofSelectedStateTransition} from "test/fixtures/ProofSelectedStateTransition.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

/// @dev A tiling table from a list of heights: each stride is the sum of the
/// heights below it, and the leaf stride is zero. It serves any allowance,
/// including ones the table validator rejects, since the search probes
/// below the formula.
contract MultiLevelTableProvider is ITournamentParametersProvider {
    error UnknownLevel(uint64 level);

    uint64[] internal _heights;
    uint64[] internal _log2steps;
    Time.Duration internal immutable RESPONSE_BUDGET;
    Time.Duration internal immutable COMMITMENT_BUDGET;
    Time.Duration internal immutable MAX_ALLOWANCE;

    constructor(uint64[] memory heights, uint64 g, uint64 t, uint64 allowance) {
        uint64 acc;
        uint64[] memory steps = new uint64[](heights.length);
        for (uint256 i = heights.length; i > 0; --i) {
            steps[i - 1] = acc;
            acc += heights[i - 1];
        }
        for (uint256 i; i < heights.length; ++i) {
            _heights.push(heights[i]);
            _log2steps.push(steps[i]);
        }
        RESPONSE_BUDGET = Time.Duration.wrap(g);
        COMMITMENT_BUDGET = Time.Duration.wrap(t);
        MAX_ALLOWANCE = Time.Duration.wrap(allowance);
    }

    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        if (level >= _heights.length) {
            revert UnknownLevel(level);
        }
        return TournamentParameters({
            levels: uint64(_heights.length),
            log2step: _log2steps[level],
            height: _heights[level],
            responseBudget: RESPONSE_BUDGET,
            commitmentBudget: COMMITMENT_BUDGET,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}

contract MultiLevelFactory is MultiLevelTournamentFactory {
    constructor(uint64[] memory heights, uint64 g, uint64 t, uint64 allowance)
        MultiLevelTournamentFactory(
            new InspectableTournament(),
            new MultiLevelTableProvider(heights, g, t, allowance),
            new ProofSelectedStateTransition()
        )
    {}
}

/// @dev The handler of HonestSurvivalInvariant.t.sol generalized to any
/// level count and any small heights: the same eager honest strategy
/// derived from production state, the same adversary moves, the same single
/// censorship ledger. It adds:
///  - a build model: the honest party builds one commitment at a time, T
///    per level, so after an adversarial pre-join its first action in a
///    child cannot start before the build is done;
///  - a `plunge` move with which the adversary drives the deepest honest
///    dispute down within one block (pre-joining the honest child
///    commitment, pairing a Sybil, revealing for either side);
///  - clock and topology invariants over every commitment ever joined,
///    Sybils included (`checkStructure`);
///  - a termination probe (`drain`).
contract MultiLevelSurvivalHandler is TournamentDriver {
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
        uint256 index;
        uint64 available; // first block the action is valid on chain
        uint64 ready; // first block the honest party can start on it
        uint64 bound;
        bytes32 key;
    }

    struct Tourn {
        InspectableTournament t;
        bool isRoot;
        uint64 level;
        uint256 parent;
        Match.Id origin;
        Tree.Node honest; // zero when the honest party has no stake here
        bool honestJoined;
        bool settled;
        uint64 buildStart; // when the honest build for this child starts
        Match.Id[] live;
    }

    uint64 public immutable G;
    uint64 public immutable T;
    uint64 public immutable C;
    uint64 public immutable ALLOWANCE;
    uint64 public immutable START;
    bool public immutable SYBIL_FIRST;
    uint64 public immutable LEVELS;
    uint256 public immutable FINE;
    uint64 internal immutable ROOT_H;
    uint64 internal immutable ROOT_LOG2STEP;

    Tourn[] internal tourns;
    mapping(address => mapping(bytes32 => bytes32[])) internal leavesOf;
    mapping(address => mapping(bytes32 => uint256)) internal childByOrigin;

    mapping(bytes32 => bool) internal scheduled;
    mapping(bytes32 => uint64) internal landingOf;
    uint256 internal seed;

    // Structural ghosts: every root joined per tournament, the allowance
    // each held at the last check, and the cap a child return may raise
    // it to (the sealed pair maximum, read before the propagation).
    mapping(uint256 => bytes32[]) internal rootsOf;
    // Terminal observations, which must never change once made.
    mapping(uint256 => uint64) internal finishedAtSeen;
    mapping(uint256 => bytes32) internal winnerSeen;
    mapping(uint256 => bool) internal terminalSeen;
    mapping(uint256 => mapping(bytes32 => uint64)) internal lastAllowance;
    mapping(uint256 => mapping(bytes32 => uint64)) internal raiseCap;

    uint64 public censorshipUsed;
    uint256 public honestActions;
    uint256 public rootFinishes;
    uint256 public applied;
    uint256 public discarded;
    uint256 public deepestHonestLevel;
    uint256 public honestLeafResolutions;
    uint256 public honestLeafTimeoutClaims;
    uint256 public honestPropagations;
    uint256 public honestChildJoins;
    uint256 public preJoins;
    uint64 public minHonestSlack = type(uint64).max;

    receive() external payable {}

    constructor(
        uint64[] memory heights,
        uint64 g,
        uint64 t,
        uint64 c,
        uint64 below,
        bool sybilFirst
    ) {
        G = g;
        T = t;
        C = c;
        LEVELS = uint64(heights.length);
        uint64 total;
        for (uint256 i; i < heights.length; ++i) {
            total += heights[i];
        }
        FINE = uint256(1) << total;
        ROOT_H = heights[0];
        ROOT_LOG2STEP = total - heights[0];
        // ClockBudgets.maxAllowance in blocks, minus `below` inclusions.
        ALLOWANCE =
            c + 2 * g + (uint64(heights.length) - 1) * (t + 2 * g) - below * g;
        SYBIL_FIRST = sybilFirst;
        vm.roll(1000);
        START = _now();
        InspectableTournament root =
            newRoot(new MultiLevelFactory(heights, g, t, ALLOWANCE));
        tourns.push();
        Tourn storage r = tourns[0];
        r.t = root;
        r.isRoot = true;
        SmallFullTree.Data memory h = _honestTree(root);
        r.honest = h.root();
        _storeLeaves(root, h);
        seed = uint256(keccak256("ml-honest-survival"));
        if (sybilFirst) {
            _joinRootSybil(0, uint8(FINE - 1), 0);
        }
    }

    //
    // Adversary moves
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
            _discard();
            return;
        }
        if (late && p1 % 4 == 0) {
            _lateTo(closureOf(tourns[0].t), p2 >> 4);
        }
        try this.extJoinRootSybil(kind % 3, p1, p2) {
            _apply();
        } catch {
            _discard();
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
            _discard();
            return;
        }
        uint256 ti = 1 + (childSel % (tourns.length - 1));
        if (late) {
            _lateTo(closureOf(tourns[ti].t), fam >> 2);
        }
        try this.extJoinChildSybil(ti, honestClass, mask, fam % 4) {
            _apply();
        } catch {
            _discard();
        }
    }

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
            _discard();
            return;
        }
        if (late) {
            Tourn storage c = tourns[ti];
            Match.Id memory id = c.live[mi];
            Clock.State memory one = clockOf(c.t, id.commitmentOne);
            Clock.State memory two = clockOf(c.t, id.commitmentTwo);
            if (one.isRunning() != two.isRunning()) {
                Clock.State memory running = one.isRunning() ? one : two;
                _lateTo(Time.Instant.unwrap(running.deadline()), slack);
                (ok, ti, mi) = _selectMatch(tSel, mSel);
                if (!ok) {
                    _discard();
                    return;
                }
            }
        }
        try this.extSybilRespond(ti, mi) {
            _apply();
        } catch {
            _discard();
        }
    }

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
            _discard();
            return;
        }
        try this.extClaimTimeout(ti, mi) {
            _apply();
        } catch {
            _discard();
        }
    }

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
            _discard();
            return;
        }
        try this.extProveSybil(ti, mi, sideOne) {
            _apply();
        } catch {
            _discard();
        }
    }

    function settleChild(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 childSel,
        bool late
    ) external {
        _step(delta, honestFirst, entropy);
        if (tourns.length < 2) {
            _discard();
            return;
        }
        uint256 ti = 1 + (childSel % (tourns.length - 1));
        if (late) {
            ITournament.TournamentStandingView memory sv =
                tourns[ti].t.tournamentStanding();
            if (sv.standing == ITournament.TournamentStanding.INNER_WINNER) {
                _lateTo(Time.Instant.unwrap(sv.winnerExpiresAt), childSel >> 4);
            }
        }
        try this.extSettleChild(ti) {
            _apply();
        } catch {
            _discard();
        }
    }

    /// @dev The adversary performs the honest side's next due action itself,
    /// as soon as the chain allows it (it needs no build).
    function actForHonest(uint8 delta, bool honestFirst, uint256 entropy)
        external
    {
        _step(delta, honestFirst, entropy);
        Obligation[] memory obs = _derive();
        if (obs.length == 0) {
            _discard();
            return;
        }
        Obligation memory ob = obs[uint256(seed) % obs.length];
        if (ob.available > _now()) {
            _discard();
            return;
        }
        try this.extExecuteHonest(ob, SYBIL) {
            _apply();
        } catch {
            _discard();
        }
    }

    function elapse(uint8 delta, bool honestFirst, uint256 entropy) external {
        _step(delta, honestFirst, entropy);
        _apply();
    }

    /// @dev Drive the deepest honest dispute down within the current block.
    function plunge(
        uint8 delta,
        bool honestFirst,
        uint256 entropy,
        uint8 steps,
        bool forHonest
    ) external {
        _step(delta, honestFirst, entropy);
        uint256 n = 1 + (steps % 12);
        bool any;
        for (uint256 i; i < n; ++i) {
            uint8 r = uint8(uint256(keccak256(abi.encode(seed, "plunge", i))));
            try this.extPlungeStep(forHonest, r) returns (bool progressed) {
                if (!progressed) {
                    break;
                }
                any = true;
            } catch {
                break;
            }
        }
        if (any) {
            _apply();
        } else {
            _discard();
        }
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
        _joinChildSybil(ti, honestClass, mask, fam);
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

    function extPlungeStep(bool forHonest, uint8 r) external returns (bool) {
        require(msg.sender == address(this));
        (bool found, uint256 ti) = _deepestHonest();
        if (!found) {
            return false;
        }
        Tourn storage c = tourns[ti];
        if (!c.honestJoined) {
            if (c.isRoot || !forHonest) {
                return false;
            }
            if (_closedAt(c.t, _now())) {
                return false;
            }
            ++preJoins;
            _joinAs(ti, _honestTree(c.t), SYBIL);
            return true;
        }
        (bool inMatch, uint256 mi) = _matchOf(ti, c.honest);
        if (!inMatch) {
            if (!dangling(c.t).eq(c.honest)) {
                return false;
            }
            if (_closedAt(c.t, _now())) {
                return false;
            }
            if (c.isRoot) {
                _joinRootSybil(r % 2, r, r >> 3);
            } else {
                _joinChildSybil(ti, (r & 1) == 1, 1 + (r >> 1), (r >> 4) % 4);
            }
            return true;
        }
        Match.Id memory id = c.live[mi];
        Match.State memory s = c.t.getMatch(id.hashFromId());
        if (s.currentHeight == 0) {
            return false;
        }
        (,,, uint64 height) = c.t.tournamentLevelConstants();
        bool oneResponds = Match.responder(height, s.currentHeight)
            == ITournament.CommitmentSide.ONE;
        bool honestResponds = id.commitmentOne.eq(c.honest) == oneResponds;
        if (honestResponds && !forHonest) {
            return false;
        }
        _respond(ti, mi);
        return true;
    }

    //
    // Time and the honest actor
    //

    function _step(uint8 delta, bool honestFirst, uint256 entropy) internal {
        seed = uint256(keccak256(abi.encode(seed, entropy)));
        uint256 pick = uint256(keccak256(abi.encode(seed, "span"))) % 100;
        uint64 span = pick < 62
            ? 0
            : pick < 76
                ? 1
                : pick < 86
                    ? G
                    : pick < 93 ? T + G : pick < 97 ? 3 * G : ALLOWANCE;
        uint64 target = _now() + (delta % (span + 1));
        _advanceTo(target, honestFirst);
    }

    function _lateTo(uint64 deadline, uint8 slack) internal {
        uint64 back = 1 + (slack % G);
        if (deadline <= back) {
            return;
        }
        uint64 target = deadline - back;
        if (target > _now()) {
            _advanceTo(target, true);
        }
    }

    function _advanceTo(uint64 target, bool honestFirst) internal {
        for (uint256 guard; guard < 96; ++guard) {
            Obligation[] memory obs = _derive();
            (bool found, Obligation memory ob, uint64 landing) = _earliest(obs);
            bool due = found
                && (landing < target || (honestFirst && landing <= target));
            if (!due) {
                break;
            }
            require(landing >= _now(), "model: obligation derived late");
            if (landing > _now()) {
                vm.roll(landing);
            }
            _executeHonest(ob, HONEST);
        }
        if (target > _now()) {
            vm.roll(target);
        }
    }

    function _earliest(Obligation[] memory obs)
        internal
        returns (bool found, Obligation memory best, uint64 landing)
    {
        for (uint256 i; i < obs.length; ++i) {
            Obligation memory ob = obs[i];
            if (!scheduled[ob.key]) {
                scheduled[ob.key] = true;
                uint64 from = ob.available > ob.ready ? ob.available : ob.ready;
                landingOf[ob.key] =
                    from + _drawLatency(ob) + _drawCensorship(ob);
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
            return ob.bound - 1;
        }
        return uint64((seed >> 8) % ob.bound);
    }

    /// @dev Censorship from the single ledger, biased to spend it all.
    function _drawCensorship(Obligation memory ob) internal returns (uint64) {
        uint64 left = C - censorshipUsed;
        if (left == 0) {
            return 0;
        }
        seed = uint256(keccak256(abi.encode(seed, ob.key, "censor")));
        uint64 c;
        uint256 pick = seed % 4;
        if (pick == 0) {
            c = 0;
        } else if (pick == 1 || pick == 2) {
            c = left;
        } else {
            c = uint64((seed >> 8) % (left + 1));
        }
        censorshipUsed += c;
        return c;
    }

    function _readyOf(Tourn storage c) internal view returns (uint64) {
        return c.isRoot ? START : c.buildStart + T;
    }

    function _derive() internal view returns (Obligation[] memory obs) {
        Obligation[] memory buf = new Obligation[](tourns.length + 1);
        uint256 n;
        Tourn storage root = tourns[0];
        if (!root.honestJoined && !_closedAt(root.t, _now())) {
            buf[n++] = Obligation({
                kind: Kind.JOIN_ROOT,
                tourn: 0,
                index: 0,
                available: START,
                ready: START,
                bound: G,
                key: keccak256("join-root")
            });
        }
        for (uint256 ti; ti < tourns.length; ++ti) {
            Tourn storage c = tourns[ti];
            if (c.honest.isZero() || !c.honestJoined || c.settled) {
                continue;
            }
            uint64 ready = _readyOf(c);
            (bool inMatch, uint256 mi) = _matchOf(ti, c.honest);
            if (!inMatch) {
                if (c.isRoot || c.live.length != 0) {
                    continue;
                }
                if (!dangling(c.t).eq(c.honest)) {
                    continue;
                }
                (uint64 closedAt, uint64 lastDeleted) = _closure(c.t);
                uint64 resultAt =
                    closedAt > lastDeleted ? closedAt : lastDeleted;
                uint64 pready = _readyOf(tourns[c.parent]);
                buf[n++] = Obligation({
                    kind: Kind.PROPAGATE,
                    tourn: ti,
                    index: 0,
                    available: resultAt,
                    ready: pready > ready ? pready : ready,
                    bound: G,
                    key: keccak256(abi.encode("propagate", ti, resultAt))
                });
                continue;
            }
            buf[n] = _matchObligation(ti, mi, ready);
            if (buf[n].bound != 0) {
                ++n;
            }
        }
        obs = new Obligation[](n);
        for (uint256 i; i < n; ++i) {
            obs[i] = buf[i];
        }
    }

    /// @dev The obligation the honest side has in its live match, if any;
    /// `bound == 0` means none.
    function _matchObligation(uint256 ti, uint256 mi, uint64 ready)
        internal
        view
        returns (Obligation memory ob)
    {
        Tourn storage c = tourns[ti];
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
                ob = Obligation({
                    kind: Kind.RESPOND,
                    tourn: ti,
                    index: mi,
                    available: Time.Instant.unwrap(h.startInstant),
                    ready: ready,
                    bound: G,
                    key: keccak256(
                        abi.encode("respond", ti, id, s.currentHeight)
                    )
                });
            } else {
                Clock.State memory o = clockOf(
                    c.t, honestIsOne ? id.commitmentTwo : id.commitmentOne
                );
                ob = Obligation({
                    kind: Kind.TIMEOUT,
                    tourn: ti,
                    index: mi,
                    available: Time.Instant.unwrap(o.deadline()),
                    ready: ready,
                    bound: G,
                    key: keccak256(
                        abi.encode("timeout", ti, id, s.currentHeight)
                    )
                });
            }
        } else if (kind == ITournament.TournamentKind.LEAF) {
            ob = Obligation({
                kind: Kind.RESOLVE_LEAF,
                tourn: ti,
                index: mi,
                available: Time.Instant.unwrap(h.startInstant),
                ready: ready,
                bound: G,
                key: keccak256(abi.encode("resolve", ti, id))
            });
        } else {
            uint256 ci = childByOrigin[
                address(c.t)
            ][Match.IdHash.unwrap(id.hashFromId())];
            Tourn storage child = tourns[ci];
            if (!child.honestJoined) {
                ob = Obligation({
                    kind: Kind.JOIN_CHILD,
                    tourn: ci,
                    index: 0,
                    available: Time.Instant
                        .unwrap(child.t.tournamentArguments().startInstant),
                    ready: child.buildStart,
                    bound: T + G,
                    key: keccak256(abi.encode("join-child", ci))
                });
            }
        }
    }

    function _executeHonest(Obligation memory ob, address claimer) internal {
        Tourn storage c = tourns[ob.tourn];
        if (claimer == HONEST) {
            ++honestActions;
        }
        if (ob.kind == Kind.JOIN_ROOT) {
            _joinAs(0, _honestTree(c.t), claimer);
        } else if (ob.kind == Kind.JOIN_CHILD) {
            if (claimer == HONEST) {
                ++honestChildJoins;
            } else {
                ++preJoins;
            }
            _joinAs(ob.tourn, _honestTree(c.t), claimer);
        } else if (ob.kind == Kind.RESPOND) {
            _noteSlack(c, claimer);
            _respond(ob.tourn, ob.index);
        } else if (ob.kind == Kind.TIMEOUT) {
            _timeoutWin(ob.tourn, ob.index, c.honest);
        } else if (ob.kind == Kind.RESOLVE_LEAF) {
            _noteSlack(c, claimer);
            Match.Id memory id = c.live[ob.index];
            ITournament.MatchTimeoutOutcome outcome = classify(
                c.t, _tree(c.t, id.commitmentOne), _tree(c.t, id.commitmentTwo)
            );
            bool honestIsOne = id.commitmentOne.eq(c.honest);
            if (outcome == ITournament.MatchTimeoutOutcome.NONE) {
                if (claimer == HONEST) {
                    ++honestLeafResolutions;
                }
                _prove(ob.tourn, ob.index, c.honest);
            } else if (
                (outcome == ITournament.MatchTimeoutOutcome.ONE_WINS)
                        == honestIsOne
                    && outcome != ITournament.MatchTimeoutOutcome.ELIMINATE_BOTH
            ) {
                if (claimer == HONEST) {
                    ++honestLeafTimeoutClaims;
                }
                _timeoutWin(ob.tourn, ob.index, c.honest);
            } else {
                revert("honest leaf eliminated");
            }
        } else {
            if (claimer == HONEST) {
                ++honestPropagations;
            }
            _propagate(ob.tourn, tourns[c.parent].honest);
        }
    }

    /// @dev Blocks left on the running honest clock when its action lands.
    function _noteSlack(Tourn storage c, address claimer) internal {
        if (claimer != HONEST) {
            return;
        }
        Clock.State memory h = clockOf(c.t, c.honest);
        if (!h.isRunning()) {
            return;
        }
        uint64 d = Time.Instant.unwrap(h.deadline());
        uint64 current = _now();
        uint64 slack = d > current ? d - current : 0;
        if (slack < minHonestSlack) {
            minHonestSlack = slack;
        }
    }

    //
    // Claims
    //

    function _honestFine() internal view returns (Tree.Node[] memory fine) {
        fine = new Tree.Node[](FINE);
        for (uint256 i; i < FINE; ++i) {
            fine[i] = fineLeaf(1, i);
        }
    }

    /// @dev The commitment a fine state table gives for tournament `t`:
    /// leaf i is the state after `start + (i + 1) * stride` fine steps.
    function _treeFrom(Tree.Node[] memory fine, InspectableTournament t)
        internal
        view
        returns (SmallFullTree.Data memory)
    {
        ITournament.TournamentArguments memory a = t.tournamentArguments();
        uint256 start = a.commitmentArgs.startCycle;
        uint256 stride = uint256(1) << a.commitmentArgs.log2step;
        uint256 n = uint256(1) << a.commitmentArgs.height;
        Tree.Node[] memory leaves = new Tree.Node[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = fine[start + (i + 1) * stride - 1];
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _honestTree(InspectableTournament t)
        internal
        view
        returns (SmallFullTree.Data memory)
    {
        return _treeFrom(_honestFine(), t);
    }

    function _joinRootSybil(uint8 kind, uint8 p1, uint8 p2) internal {
        Tree.Node[] memory fine = _honestFine();
        if (kind == 0) {
            // Wrong final state, diverging at fine leaf p1.
            uint256 family = 2 + 2 * (uint256(p2) % 4);
            for (uint256 i = uint256(p1) % FINE; i < FINE; ++i) {
                fine[i] = fineLeaf(family, i);
            }
        } else if (kind == 1) {
            // Honest final state, foreign interior covering a segment end.
            uint256 segments = uint256(1) << ROOT_H;
            uint256 size = uint256(1) << ROOT_LOG2STEP;
            uint256 s = uint256(p1) % (segments - 1);
            uint256 from = s * size + (uint256(p2) % size);
            uint256 family = 2 + 2 * ((uint256(p2) >> 2) % 4);
            for (uint256 i = from; i < (s + 1) * size; ++i) {
                fine[i] = fineLeaf(family, i);
            }
        }
        // kind 2: an identical copy of the honest root.
        _joinAs(0, _treeFrom(fine, tourns[0].t), SYBIL);
    }

    function _joinChildSybil(
        uint256 ti,
        bool honestClass,
        uint8 mask,
        uint8 fam
    ) internal {
        Tourn storage c = tourns[ti];
        require(!c.isRoot, "root");
        ITournament.TournamentArguments memory a = c.t.tournamentArguments();
        ITournament.NestedDispute memory nd = a.nestedDispute;
        SmallFullTree.Data memory hTree = _honestTree(c.t);
        Machine.Hash honestState =
            c.honest.isZero() ? nd.contestedFinalStateOne : hTree.finalState();
        Machine.Hash last = nd.contestedFinalStateOne.eq(honestState)
            ? (honestClass
                    ? nd.contestedFinalStateOne
                    : nd.contestedFinalStateTwo)
            : (honestClass
                    ? nd.contestedFinalStateTwo
                    : nd.contestedFinalStateOne);
        uint256 n = hTree.leafCount();
        Tree.Node[] memory leaves = new Tree.Node[](n);
        uint256 family = 2 + 2 * uint256(fam);
        uint256 stride = uint256(1) << a.commitmentArgs.log2step;
        for (uint256 j; j + 1 < n; ++j) {
            uint256 i = a.commitmentArgs.startCycle + (j + 1) * stride - 1;
            leaves[j] =
                (mask >> j) & 1 == 1 ? fineLeaf(family, i) : hTree.leaf(j);
        }
        leaves[n - 1] = Tree.Node.wrap(Machine.Hash.unwrap(last));
        _joinAs(ti, SmallFullTree.buildFromLeaves(leaves), SYBIL);
    }

    //
    // Production actions with topology bookkeeping
    //

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
        rootsOf[ti].push(Tree.Node.unwrap(r));
        if (r.eq(c.honest)) {
            c.honestJoined = true;
            if (c.level > deepestHonestLevel) {
                deepestHonestLevel = c.level;
            }
        }
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
            (InspectableTournament child,) = sealInner(c.t, one, two);
            _recordChild(ti, id, child);
        }
    }

    function _recordChild(
        uint256 ti,
        Match.Id memory id,
        InspectableTournament child
    ) internal {
        tourns.push();
        uint256 ci = tourns.length - 1;
        Tourn storage c = tourns[ti];
        Tourn storage k = tourns[ci];
        k.t = child;
        k.parent = ti;
        k.origin = id;
        k.level = c.level + 1;
        childByOrigin[address(c.t)][Match.IdHash.unwrap(id.hashFromId())] = ci;
        if (id.commitmentOne.eq(c.honest) || id.commitmentTwo.eq(c.honest)) {
            SmallFullTree.Data memory hc = _honestTree(child);
            k.honest = hc.root();
            _storeLeaves(child, hc);
            // One build at a time: this one starts when the child exists
            // and the parent level's own build is done.
            uint64 prevDone = c.isRoot ? 0 : c.buildStart + T;
            uint64 current = _now();
            k.buildStart = current > prevDone ? current : prevDone;
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
        {
            uint64 r1 = allowanceOf(p.t, k.origin.commitmentOne);
            uint64 r2 = allowanceOf(p.t, k.origin.commitmentTwo);
            raiseCap[k.parent][Tree.Node.unwrap(parentWinner)] =
                r1 > r2 ? r1 : r2;
        }
        propagate(p.t, k.t, _tree(p.t, parentWinner));
        _dropMatchById(k.parent, k.origin);
        k.settled = true;
        _recordPairing(k.parent, before, parentWinner);
        if (k.parent == 0 && p.t.isFinished()) {
            ++rootFinishes;
        }
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

    function _storeLeaves(
        InspectableTournament t,
        SmallFullTree.Data memory tree
    ) internal {
        bytes32[] storage slot = leavesOf[
            address(t)
        ][Tree.Node.unwrap(tree.root())];
        if (slot.length != 0) {
            return;
        }
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

    function _deepestHonest() internal view returns (bool, uint256) {
        for (uint256 k = tourns.length; k > 0; --k) {
            Tourn storage c = tourns[k - 1];
            if (!c.honest.isZero() && !c.settled) {
                return (true, k - 1);
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

    function _closedAt(InspectableTournament t, uint64 instant)
        internal
        view
        returns (bool)
    {
        return instant >= closureOf(t);
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockNumber());
    }

    function _apply() internal {
        ++applied;
    }

    function _discard() internal {
        ++discarded;
    }

    //
    // Invariant checks
    //

    function checkHonestSurvives() external view {
        for (uint256 ti; ti < tourns.length; ++ti) {
            Tourn storage c = tourns[ti];
            if (c.honest.isZero() || !c.honestJoined || c.settled) {
                continue;
            }
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
                        && s.finalState.eq(_honestTree(c.t).finalState()),
                    "root winner is not the honest commitment"
                );
            }
        }
    }

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

    /// @dev Clock and topology invariants over every tournament and every
    /// commitment ever joined, Sybils included.
    function checkStructure() external {
        for (uint256 ti; ti < tourns.length; ++ti) {
            Tourn storage c = tourns[ti];
            ITournament.TournamentArguments memory a = c.t.tournamentArguments();
            uint64 cap = Time.Duration.unwrap(a.allowance);
            (Tree.Node d, uint256 n,) = c.t.observedTopology();
            require(n == c.live.length, "structure: match count");
            bytes32[] storage roots = rootsOf[ti];
            for (uint256 i; i < roots.length; ++i) {
                uint64 al = allowanceOf(c.t, Tree.Node.wrap(roots[i]));
                require(al != 0, "structure: zero clock");
                require(al <= cap, "structure: clock above tournament");
                uint64 prev = lastAllowance[ti][roots[i]];
                if (prev != 0 && al > prev) {
                    require(
                        al <= raiseCap[ti][roots[i]],
                        "structure: clock raised outside a child return"
                    );
                }
                lastAllowance[ti][roots[i]] = al;
                raiseCap[ti][roots[i]] = 0;
            }
            uint64 closure = closureOf(c.t);
            if (!d.isZero()) {
                require(
                    !clockOf(c.t, d).isRunning(), "structure: dangling runs"
                );
                _checkVirtualDeadline(c.t, d, closure);
            }
            for (uint256 mi; mi < c.live.length; ++mi) {
                _checkMatchShape(ti, mi, a);
                _checkVirtualDeadline(c.t, c.live[mi].commitmentOne, closure);
                _checkVirtualDeadline(c.t, c.live[mi].commitmentTwo, closure);
            }
            _checkStanding(ti);
        }
    }

    /// @dev The observer views are total, agree with each other, and a
    /// finished tournament's finish instant and candidate never change.
    function _checkStanding(uint256 ti) internal {
        Tourn storage c = tourns[ti];
        ITournament.TournamentStandingView memory s = c.t.tournamentStanding();
        bool finished = c.t.isFinished();
        require(
            finished == (Time.Instant.unwrap(s.finishedAt) != 0),
            "standing: finishedAt does not track finish"
        );
        if (!c.isRoot) {
            ITournament.InnerResultView memory r = c.t.innerResult();
            bool winner =
                r.disposition == ITournament.InnerTournamentDisposition.WINNER;
            require(
                winner
                    == (s.standing
                        == ITournament.TournamentStanding.INNER_WINNER),
                "standing: innerResult disagrees"
            );
            if (winner) {
                require(
                    r.parentCommitment.eq(s.parentCommitment),
                    "standing: parent commitment disagrees"
                );
                require(
                    Time.Duration.unwrap(r.pausedAllowance) != 0
                        && Time.Instant.unwrap(s.winnerExpiresAt) > _now(),
                    "standing: live winner without time"
                );
            }
        }
        if (!finished) {
            require(!terminalSeen[ti], "standing: finished tournament reopened");
            return;
        }
        if (terminalSeen[ti]) {
            require(
                finishedAtSeen[ti] == Time.Instant.unwrap(s.finishedAt),
                "standing: finishedAt moved"
            );
            require(
                winnerSeen[ti] == Tree.Node.unwrap(s.candidate),
                "standing: terminal candidate changed"
            );
        } else {
            terminalSeen[ti] = true;
            finishedAtSeen[ti] = Time.Instant.unwrap(s.finishedAt);
            winnerSeen[ti] = Tree.Node.unwrap(s.candidate);
        }
    }

    /// @dev For every live commitment, the block at which its clock would
    /// expire if it ran from now on is never before its tournament's
    /// closure. So no timeout can fire in a tournament that still accepts
    /// joins, and a child (seal + max of the pair) never closes before its
    /// parent.
    function _checkVirtualDeadline(
        InspectableTournament t,
        Tree.Node root,
        uint64 closure
    ) internal view {
        Clock.State memory k = clockOf(t, root);
        uint64 from =
            k.isRunning() ? Time.Instant.unwrap(k.startInstant) : _now();
        require(
            from + Time.Duration.unwrap(k.allowance) >= closure,
            "structure: clock can expire before closure"
        );
    }

    function _checkMatchShape(
        uint256 ti,
        uint256 mi,
        ITournament.TournamentArguments memory a
    ) internal view {
        Tourn storage c = tourns[ti];
        Match.Id memory id = c.live[mi];
        Match.State memory s = c.t.getMatch(id.hashFromId());
        require(s.isInit, "structure: live match missing");
        Clock.State memory one = clockOf(c.t, id.commitmentOne);
        Clock.State memory two = clockOf(c.t, id.commitmentTwo);
        if (s.currentHeight > 0) {
            require(
                one.isRunning() != two.isRunning(), "structure: bisection shape"
            );
            bool oneResponds = Match.responder(
                a.commitmentArgs.height, s.currentHeight
            ) == ITournament.CommitmentSide.ONE;
            require(
                one.isRunning() == oneResponds, "structure: wrong clock runs"
            );
        } else if (a.kind == ITournament.TournamentKind.LEAF) {
            require(
                one.isRunning() && two.isRunning()
                    && Time.Instant.unwrap(one.startInstant)
                        == Time.Instant.unwrap(two.startInstant),
                "structure: leaf race shape"
            );
        } else {
            require(
                !one.isRunning() && !two.isRunning(),
                "structure: sealed inner shape"
            );
            uint256 ci = childByOrigin[
                address(c.t)
            ][Match.IdHash.unwrap(id.hashFromId())];
            uint64 r1 = Time.Duration.unwrap(one.allowance);
            uint64 r2 = Time.Duration.unwrap(two.allowance);
            require(
                Time.Duration
                        .unwrap(tourns[ci].t.tournamentArguments().allowance)
                    == (r1 > r2 ? r1 : r2),
                "structure: child allowance is not the pair maximum"
            );
        }
    }

    /// @dev Termination probe. No Sybil acts any more. The honest party
    /// keeps its strategy and a cleanup agent uses only the permissionless
    /// timeout, elimination and child-settlement verbs. Returns true once
    /// the root is finished.
    function drain(uint256 maxRounds) external returns (bool) {
        for (uint256 round; round < maxRounds; ++round) {
            bool progress;
            for (uint256 k = tourns.length; k > 1; --k) {
                if (tourns[k - 1].settled) {
                    continue;
                }
                try this.extSettleChild(k - 1) {
                    progress = true;
                } catch {}
            }
            for (uint256 ti; ti < tourns.length; ++ti) {
                uint256 mi;
                while (mi < tourns[ti].live.length) {
                    try this.extClaimTimeout(ti, mi) {
                        progress = true;
                    } catch {
                        ++mi;
                    }
                }
            }
            if (tourns[0].t.isFinished()) {
                return true;
            }
            if (!progress) {
                _advanceTo(_now() + 1, true);
            }
        }
        return false;
    }

    function checkFinal() external view {
        Tourn storage r = tourns[0];
        require(r.t.isFinished(), "final: root not finished");
        for (uint256 ti; ti < tourns.length; ++ti) {
            (, uint256 n,) = tourns[ti].t.observedTopology();
            require(n == 0, "final: live match left behind");
            require(tourns[ti].live.length == 0, "final: ghost match left");
        }
        ITournament.TournamentStandingView memory s = r.t.tournamentStanding();
        if (r.honestJoined) {
            require(
                s.standing == ITournament.TournamentStanding.ROOT_WINNER
                    && s.candidate.eq(r.honest),
                "final: root winner is not the honest commitment"
            );
        }
    }

    function rootFinished() external view returns (bool) {
        return tourns[0].t.isFinished();
    }

    function nowBlock() external view returns (uint64) {
        return _now();
    }

    function tournamentCount() external view returns (uint256) {
        return tourns.length;
    }
}

/// @dev One schedule of the search: a fresh handler, a keccak stream of
/// adversary moves with every invariant checked after each move, and the
/// termination probe.
abstract contract MultiLevelSurvivalSearch is Test {
    uint64 internal constant G = 3;
    uint64 internal constant T = 6;

    /// @dev Moves a schedule keeps making once its root has finished. A
    /// finished root has no live match in any descendant and accepts no
    /// join, so later moves only pass time; these re-check that nothing
    /// decided changes while it does.
    uint256 internal constant MOVES_AFTER_FINISH = 24;

    struct Stats {
        uint256 schedules;
        uint256 rootsFinishedByPropagation;
        uint256 honestActions;
        uint256 leafProofs;
        uint256 leafClaims;
        uint256 propagations;
        uint256 childJoins;
        uint256 preJoins;
        uint256 reachedLeafLevel;
        uint256 tournaments;
        uint64 minSlack;
        uint64 maxDrainBlocks;
    }

    function _move(MultiLevelSurvivalHandler h, uint256 r) internal {
        uint256 sel = r % 20;
        uint8 delta = uint8(r >> 8);
        bool hf = (r >> 16) & 1 == 1;
        uint256 e = r >> 24;
        uint8 a = uint8(r >> 32);
        uint8 b = uint8(r >> 40);
        uint8 c = uint8(r >> 48);
        bool late = (r >> 56) & 1 == 1;
        if (sel < 2) {
            h.joinRootSybil(delta, hf, e, a, b, c, late);
        } else if (sel < 5) {
            h.joinChildSybil(delta, hf, e, a, b & 1 == 1, b, c, late);
        } else if (sel < 9) {
            h.sybilRespond(delta, hf, e, a, b, late, c);
        } else if (sel < 11) {
            h.claimTimeout(delta, hf, e, a, b);
        } else if (sel < 12) {
            h.proveSybil(delta, hf, e, a, b, c & 1 == 1);
        } else if (sel < 14) {
            h.settleChild(delta, hf, e, a, late);
        } else if (sel < 15) {
            h.actForHonest(delta, hf, e);
        } else if (sel < 17) {
            h.elapse(delta, hf, e);
        } else {
            h.plunge(delta, hf, e, a, b & 1 == 1);
        }
    }

    /// @dev Runs the schedule named by (`seed`, `c`, `sybilFirst`) and
    /// reverts with the violated invariant's reason. With `probe`, an odd
    /// seed stops at a random prefix, so that the termination probe starts
    /// from a mid-dispute state, and the probe then runs to the root's end.
    /// @param below Inclusions the root allowance sits under the formula
    /// @return h The handler the schedule ran on
    /// @return drainBlocks Blocks the termination probe took
    function _schedule(
        uint64[] memory heights,
        uint64 below,
        uint64 c,
        bool sybilFirst,
        uint256 seed,
        uint256 steps,
        bool probe
    ) internal returns (MultiLevelSurvivalHandler h, uint64 drainBlocks) {
        h = new MultiLevelSurvivalHandler(heights, G, T, c, below, sybilFirst);
        uint256 r = uint256(keccak256(abi.encode("ml", seed, c, sybilFirst)));
        uint256 length = (probe && seed % 2 == 1)
            ? 1 + (uint256(keccak256(abi.encode("len", r))) % steps)
            : steps;
        uint256 afterFinish;
        for (uint256 i; i < length; ++i) {
            r = uint256(keccak256(abi.encode(r)));
            _move(h, r);
            h.checkHonestSurvives();
            h.checkClocksCover();
            h.checkStructure();
            if (h.rootFinished() && ++afterFinish > MOVES_AFTER_FINISH) {
                break;
            }
        }
        if (probe) {
            uint64 before = h.nowBlock();
            require(h.drain(20000), "drain: root never finished");
            h.checkHonestSurvives();
            h.checkStructure();
            h.checkFinal();
            drainBlocks = h.nowBlock() - before;
        }
    }

    function extSchedule(
        uint64[] memory heights,
        uint64 below,
        uint64 c,
        bool sybilFirst,
        uint256 seed,
        uint256 steps
    ) external {
        require(msg.sender == address(this));
        _schedule(heights, below, c, sybilFirst, seed, steps, false);
    }

    /// @dev One fuzz run is one schedule. The fuzz input names the move
    /// stream and draws the censorship budget, the orientation, and the
    /// allowance from `belows`.
    function _fuzzSchedule(
        uint64[] memory heights,
        uint64[] memory belows,
        uint256 steps,
        uint256 seed
    ) internal {
        uint256 pick = uint256(keccak256(abi.encode("configuration", seed)));
        uint64 c = [uint64(0), 2, 5][pick % 3];
        bool sybilFirst = (pick >> 8) & 1 == 1;
        uint64 below = belows[(pick >> 16) % belows.length];
        // Shown with the counterexample when a run fails.
        console2.log("C", c, "below", below);
        console2.log("sybilFirst", sybilFirst);
        _schedule(heights, below, c, sybilFirst, seed, steps, true);
    }

    function _accumulate(
        Stats memory st,
        MultiLevelSurvivalHandler h,
        uint64 drainBlocks
    ) internal view {
        ++st.schedules;
        st.rootsFinishedByPropagation += h.rootFinishes();
        st.honestActions += h.honestActions();
        st.leafProofs += h.honestLeafResolutions();
        st.leafClaims += h.honestLeafTimeoutClaims();
        st.propagations += h.honestPropagations();
        st.childJoins += h.honestChildJoins();
        st.preJoins += h.preJoins();
        st.tournaments += h.tournamentCount();
        if (h.deepestHonestLevel() + 1 == h.LEVELS()) {
            ++st.reachedLeafLevel;
        }
        if (h.minHonestSlack() < st.minSlack) {
            st.minSlack = h.minHonestSlack();
        }
        if (drainBlocks > st.maxDrainBlocks) {
            st.maxDrainBlocks = drainBlocks;
        }
    }

    function _report(string memory name, Stats memory st) internal pure {
        console2.log(name);
        console2.log("  schedules", st.schedules);
        console2.log("  reachedLeafLevel", st.reachedLeafLevel);
        console2.log(
            "  rootsFinishedByPropagation", st.rootsFinishedByPropagation
        );
        console2.log(
            "  honestActions", st.honestActions, "tournaments", st.tournaments
        );
        console2.log("  leafProofs", st.leafProofs, "leafClaims", st.leafClaims);
        console2.log(
            "  propagations", st.propagations, "childJoins", st.childJoins
        );
        console2.log("  preJoins", st.preJoins);
        console2.log(
            "  minHonestSlack", st.minSlack, "maxDrainBlocks", st.maxDrainBlocks
        );
    }

    function _heights(uint64 a) internal pure returns (uint64[] memory h) {
        h = new uint64[](1);
        h[0] = a;
    }

    function _heights(uint64 a, uint64 b)
        internal
        pure
        returns (uint64[] memory h)
    {
        h = new uint64[](2);
        h[0] = a;
        h[1] = b;
    }

    function _heights(uint64 a, uint64 b, uint64 c)
        internal
        pure
        returns (uint64[] memory h)
    {
        h = new uint64[](3);
        h[0] = a;
        h[1] = b;
        h[2] = c;
    }

    function _heights(uint64 a, uint64 b, uint64 c, uint64 d)
        internal
        pure
        returns (uint64[] memory h)
    {
        h = new uint64[](4);
        h[0] = a;
        h[1] = b;
        h[2] = c;
        h[3] = d;
    }

    function _belows(uint64 a) internal pure returns (uint64[] memory b) {
        b = new uint64[](1);
        b[0] = a;
    }

    function _belows(uint64 a, uint64 b_)
        internal
        pure
        returns (uint64[] memory b)
    {
        b = new uint64[](2);
        b[0] = a;
        b[1] = b_;
    }
}

/// @dev Honest survival under the budgets (dimensioning.md) at one to four
/// levels, in a small box: heights one to three, G = 3, T = 6, C of 0, 2
/// or 5, both orientations, and the root allowance at the deployed formula
/// C + 2G + (L - 1)(T + 2G) or a stated number of inclusions below it.
///
/// One fuzz run is one schedule. A schedule fails if the honest commitment
/// is eliminated, if a pending honest action would land after the clock it
/// draws on, if a clock or topology invariant breaks, or if, once no Sybil
/// acts any more, the root does not finish with the honest commitment as
/// its winner.
///
/// The predicted margin on a running honest clock is
/// (L - 1)(G + 1) + 2 blocks, less G per inclusion below the formula. Each
/// level count is also searched at the last allowance that keeps it
/// positive: the formula at one level, then one, three and four inclusions
/// below it at two, three and four levels. The controls replay recorded
/// schedules that survive there and lose one inclusion further down, so
/// the search fails where the closed form says it must.
///
/// A seeded random search in a small box, not a proof for any level count:
/// the general recursive result stays open (dimensioning.md). The honest
/// leaf resolution is one landing that picks the verb, which is the
/// documented joint bound; LeafHandover.t.sol prices the per-action
/// reading. Sybil-versus-Sybil leaves are provable for either side.
///
/// Deeper campaign:
///   FOUNDRY_FUZZ_RUNS=<n> FOUNDRY_FUZZ_SEED=<seed> forge test \
///     --match-contract MultiLevelHonestSurvivalTest --match-test testFuzz
/// The 2026-11-10 contracts audit recorded 14,400 schedules without a loss:
/// seeds 1 to 300 of each table, censorship budget and orientation, in a
/// loop that needed forge's gas limit raised. `_schedule` replays any of
/// them by seed, C and orientation, except that it stops shortly after the
/// root finishes where the loop ran its 300 to 500 moves out.
contract MultiLevelHonestSurvivalTest is MultiLevelSurvivalSearch {
    function testFuzzOneLevelHeightThree(uint256 seed) public {
        _fuzzSchedule(_heights(3), _belows(0), 300, seed);
    }

    function testFuzzOneLevelHeightTwo(uint256 seed) public {
        _fuzzSchedule(_heights(2), _belows(0), 300, seed);
    }

    function testFuzzTwoLevelsHeights22OneBelow(uint256 seed) public {
        _fuzzSchedule(_heights(2, 2), _belows(1), 300, seed);
    }

    /// @dev At the formula or three inclusions below it.
    function testFuzzThreeLevelsHeights112(uint256 seed) public {
        _fuzzSchedule(_heights(1, 1, 2), _belows(0, 3), 400, seed);
    }

    function testFuzzThreeLevelsHeights211(uint256 seed) public {
        _fuzzSchedule(_heights(2, 1, 1), _belows(0), 400, seed);
    }

    function testFuzzThreeLevelsHeights121OneBelow(uint256 seed) public {
        _fuzzSchedule(_heights(1, 2, 1), _belows(1), 400, seed);
    }

    /// @dev At the formula or four inclusions below it.
    function testFuzzFourLevelsHeights1111(uint256 seed) public {
        _fuzzSchedule(_heights(1, 1, 1, 1), _belows(0, 4), 500, seed);
    }

    function testFuzzFourLevelsHeights1112OneBelow(uint256 seed) public {
        _fuzzSchedule(_heights(1, 1, 1, 2), _belows(1), 500, seed);
    }

    //
    // Samples: what a fixed set of schedules executes.
    //

    /// @dev Six schedules of one table, one per censorship budget and
    /// orientation, half of them cut at a random prefix.
    function _sample(
        Stats memory st,
        uint64[] memory heights,
        uint64 below,
        uint256 steps
    ) internal {
        uint64[3] memory cs = [uint64(0), 2, 5];
        for (uint256 k; k < 6; ++k) {
            (MultiLevelSurvivalHandler h, uint64 drainBlocks) =
                _schedule(heights, below, cs[k % 3], k >= 3, k + 1, steps, true);
            _accumulate(st, h, drainBlocks);
        }
    }

    function _newStats() internal pure returns (Stats memory st) {
        st.minSlack = type(uint64).max;
    }

    function testSampleOneLevelResolvesLeaves() public {
        Stats memory st = _newStats();
        _sample(st, _heights(3), 0, 300);
        _sample(st, _heights(2), 0, 300);
        _report("one level", st);
        assertEq(st.reachedLeafLevel, st.schedules);
        assertGt(st.leafProofs, 0, "no honest leaf proof");
    }

    function testSampleTwoLevelsReachTheLeafAndReturn() public {
        Stats memory st = _newStats();
        _sample(st, _heights(2, 2), 1, 300);
        _report("two levels", st);
        _assertRecursionSampled(st);
    }

    function testSampleThreeLevelsReachTheLeafAndReturn() public {
        Stats memory st = _newStats();
        _sample(st, _heights(1, 1, 2), 0, 400);
        _sample(st, _heights(1, 2, 1), 1, 400);
        _report("three levels", st);
        _assertRecursionSampled(st);
    }

    function testSampleFourLevelsReachTheLeafAndReturn() public {
        Stats memory st = _newStats();
        _sample(st, _heights(1, 1, 1, 1), 0, 500);
        _report("four levels", st);
        _assertRecursionSampled(st);
    }

    function _assertRecursionSampled(Stats memory st) internal pure {
        assertGt(st.reachedLeafLevel, 0, "honest side never at the leaf level");
        assertGt(st.leafProofs, 0, "no honest leaf proof");
        assertGt(st.childJoins, 0, "no honest child join");
        assertGt(st.preJoins, 0, "no adversarial pre-join");
        assertGt(st.propagations, 0, "no honest propagation");
        assertGt(
            st.rootsFinishedByPropagation, 0, "no root finished by a return"
        );
    }

    //
    // Controls: the search loses where the closed form says it must. The
    // schedules are ones the audit's sensitivity runs recorded.
    //

    /// @dev The schedule named by (`seed`, `c`, `sybilFirst`) survives at
    /// `lastMargin` inclusions below the formula and violates `reason` one
    /// inclusion further down.
    function _assertTight(
        uint64[] memory heights,
        uint64 lastMargin,
        uint64 c,
        bool sybilFirst,
        uint256 seed,
        string memory reason
    ) internal {
        this.extSchedule(heights, lastMargin, c, sybilFirst, seed, 400);
        try this.extSchedule(
            heights, lastMargin + 1, c, sybilFirst, seed, 400
        ) {
            revert("the schedule survived below the margin");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSignature("Error(string)", reason));
        }
    }

    function testControlOneLevelLosesOneInclusionBelowTheFormula() public {
        _assertTight(
            _heights(3),
            0,
            0,
            false,
            1,
            "honest response lands after its deadline"
        );
    }

    function testControlTwoLevelsLoseTwoInclusionsBelowTheFormula() public {
        _assertTight(
            _heights(2, 2),
            1,
            2,
            true,
            2,
            "honest response lands after its deadline"
        );
    }

    function testControlThreeLevelsLoseFourInclusionsBelowTheFormula() public {
        _assertTight(
            _heights(1, 1, 2),
            3,
            2,
            true,
            18,
            "honest response lands after its deadline"
        );
    }

    function testControlFourLevelsLoseFiveInclusionsBelowTheFormula() public {
        _assertTight(
            _heights(1, 1, 1, 1), 4, 2, true, 56, "honest child eliminable"
        );
    }
}
