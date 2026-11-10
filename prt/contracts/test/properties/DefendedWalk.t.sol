// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {AdversarialWalkBase} from "./AdversarialWalk.t.sol";

/// @dev Honest survival at two and three levels under the adversarial walk
/// of AdversarialWalkBase, with one defended claim. The adversary is the
/// walk itself: every caller, every verb, any order, including the honest
/// side's own forced moves and its exact commitments. The honest party is
/// claim 0, the one correct computation, and this contract is the state
/// transition the clones call: a leaf is provable only as the step from the
/// correct pre-state to the correct post-state. The honest party follows
/// the latency model of dispute-game.md ("Security statement and
/// assumptions"), read inclusively:
///  - the root join within G of the root's start;
///  - a child join within T + G of the seal that created the child, and no
///    action in a child before T (the build);
///  - every other action within G of becoming due; at a sealed leaf, the
///    proof or the timeout claim, whichever the classifier selects;
///  - cumulative censorship of those actions at most C, charged block by
///    block for as long as an honest action stays pending beyond its
///    deadline, whoever lands that action in the end.
/// The root allowance is the formula C + 2G + (levels - 1) * (T + 2G), with
/// G of one to three blocks, T of one to four and C of zero to six. Time
/// moves only through `_advanceTo`, which lands the pending honest action
/// no later than its deadline plus the censorship spent on it. The walk
/// fails if an honest action reverts, the honest commitment is eliminated
/// or locked out of a child on its path, or a decided root is not
/// ROOT_WINNER with the honest final state.
///
/// Inclusive latencies are more than the strict security statement asks
/// for; at two and three levels the formula has the margin for them
/// (InclusiveLatencyBoundary.t.sol), and the control shows it has no more:
/// one inclusion below it a recorded walk loses.
///
/// A random search in a small box, not a proof: at most three levels and
/// eight claims, plain recipients, and an oracle for the leaf step rather
/// than the real adapter. MultiLevelHonestSurvival.t.sol searches one to
/// four levels under strict latencies with a different adversary.
///
/// Deeper campaign, one run being one walk:
///   FOUNDRY_FUZZ_RUNS=14000 FOUNDRY_FUZZ_SEED=0x5172756374757265 forge test \
///     --match-contract DefendedWalkTest --match-test testFuzz
/// The 2026-11-10 contracts audit recorded 14,001 passing runs under that
/// seed.
contract DefendedWalkTest is AdversarialWalkBase, IStateTransition {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for ITournament;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;
    using Time for Time.Instant;
    using Time for Time.Duration;

    uint8 constant OB_NONE = 0;
    uint8 constant OB_JOIN = 1;
    uint8 constant OB_RESPOND = 2;
    uint8 constant OB_LEAF = 3;
    uint8 constant OB_CLAIM = 4;
    uint8 constant OB_PROPAGATE = 5;
    uint256 constant NO_KID = type(uint256).max;

    error HonestFailure(string what, bytes ret);

    struct Obligation {
        uint8 kind;
        address t;
        uint64 dueAt;
        uint64 deadline;
        Tree.Node one;
        Tree.Node two;
        uint256 kidIdx;
    }

    /// @dev A walk the formula survives and one inclusion less loses: the
    /// honest propagation lands at the child winner's expiry. Found by
    /// fuzzing `extRun` with `inclusionsBelow` at one, about one loss in
    /// 2,700 walks; a change that moves the walk needs a new one.
    uint256 constant LOSING_WALK =
        0x5238cc6f1ace92492ea1887c7a901d8d7a5cb4c823bb9816658923875e;
    uint256 constant SAMPLE_SEEDS = 12;

    /// @dev Inclusions the root allowance sits below the formula: none in
    /// the walk, one in its control.
    uint64 inclusionsBelow;
    uint64 budgetC;
    uint64 censorshipLeft;
    uint256 walkSeed;
    mapping(address => bool) onPathKid;
    /// @dev Censorship planned for one obligation (plus one), and the part
    /// of it already charged as time passed.
    mapping(bytes32 => uint64) planPlusOne;
    mapping(bytes32 => uint64) chargedOn;

    // Coverage.
    uint256[6] nHonest;
    uint256 nCensoredBlocks;
    uint256 nForcedLandings;

    //
    // Hooks
    //

    function _newStateTransition()
        internal
        view
        override
        returns (IStateTransition)
    {
        return IStateTransition(address(this));
    }

    /// @dev The leaf step of the one correct computation. From any other
    /// pre-state it yields a value nobody claims, so a wrong side never
    /// wins by proof.
    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata,
        IDataProvider
    ) external pure override returns (bytes32) {
        return _transition(machineState, counter);
    }

    function _transition(bytes32 machineState, uint256 counter)
        internal
        pure
        returns (bytes32)
    {
        bytes32 pre = counter == 0
            ? Machine.Hash.unwrap(INITIAL_STATE)
            : Tree.Node.unwrap(fineLeaf(1, counter - 1));
        if (machineState == pre) {
            return Tree.Node.unwrap(fineLeaf(1, counter));
        }
        return keccak256(abi.encode("unprovable", machineState, counter));
    }

    function _chooseBudgets(uint256 seed)
        internal
        override
        returns (uint64 g, uint64 t, uint64 a)
    {
        walkSeed = seed;
        g = 1 + uint64((seed >> 4) % 3);
        t = 1 + uint64((seed >> 6) % 4);
        budgetC = uint64((seed >> 9) % 7);
        censorshipLeft = budgetC;
        a = budgetC + 2 * g + (levels - 1) * (t + 2 * g) - inclusionsBelow * g;
    }

    function _proofAccepted(
        address t,
        SmallFullTree.Data memory a,
        SmallFullTree.Data memory w,
        uint256 d
    ) internal view override returns (bool) {
        bytes32 agree = d == 0
            ? Machine.Hash
                .unwrap(
                    InspectableTournament(t).tournamentArguments()
                        .commitmentArgs.initialHash
                )
            : Tree.Node.unwrap(a.leaf(d - 1));
        return
            _transition(agree, infos[t].base + d) == Tree.Node.unwrap(w.leaf(d));
    }

    function _kidRegistered(uint256 kidIdx) internal override {
        Kid storage kid = kids[kidIdx];
        Tree.Node h = _honestIn(address(kid.parent));
        onPathKid[address(kid.t)] =
            _onPath(address(kid.parent)) && (kid.pOne.eq(h) || kid.pTwo.eq(h));
    }

    function _beforeStep(uint256 x) internal override {
        // The honest transaction may land at any block up to its limit.
        if ((x >> 220) % 8 == 0) {
            this.honestLandIfDue();
        }
    }

    /// @dev External so that the walk's step keeps a shallow stack.
    function honestLandIfDue() external {
        require(msg.sender == address(this), "walk: self only");
        Obligation memory ob = _honestObligation();
        if (ob.kind != OB_NONE && ob.dueAt <= vm.getBlockNumber()) {
            _honestPerform();
        }
    }

    function _afterStep() internal view override {
        // Reverts if the honest commitment was eliminated or locked out.
        _honestObligation();
        if (rootDecided) {
            ITournament.TournamentStandingView memory s =
                root.tournamentStanding();
            if (
                s.standing != ITournament.TournamentStanding.ROOT_WINNER
                    || Machine.Hash.unwrap(s.finalState)
                        != Machine.Hash
                            .unwrap(_treeIn(address(root), 0).finalState())
            ) {
                revert HonestFailure(
                    "root decided against the honest claim", ""
                );
            }
        }
    }

    function _advanceTo(uint256 target) internal override {
        for (uint256 guard; guard < 64; ++guard) {
            Obligation memory ob = _honestObligation();
            if (ob.kind == OB_NONE) {
                break;
            }
            uint64 limit = ob.deadline + _plan(_key(ob));
            if (target <= limit) {
                // The obligation stays pending while time passes: every
                // block beyond its deadline is censorship, whoever lands
                // the action in the end.
                _chargeUpTo(_key(ob), ob.deadline, target);
                break;
            }
            // Time would pass the honest limit: the honest action lands
            // first, at some block between due and the limit.
            uint256 landing = _landingBlock(ob, limit);
            if (landing > vm.getBlockNumber()) {
                vm.roll(landing);
            }
            ++nForcedLandings;
            _honestPerform();
        }
        if (target > vm.getBlockNumber()) {
            vm.roll(target);
        }
    }

    function _landingBlock(Obligation memory ob, uint64 limit)
        internal
        view
        returns (uint256)
    {
        uint256 lo =
            ob.dueAt > vm.getBlockNumber() ? ob.dueAt : vm.getBlockNumber();
        if (lo > limit) {
            revert HonestFailure("model: obligation past its limit", "");
        }
        uint256 h =
            uint256(keccak256(abi.encode(walkSeed, ob.t, ob.dueAt, "at")));
        // Half of the forced landings take the worst latency the model
        // allows; the rest are uniform between due and the limit.
        if (h % 2 == 0) {
            return limit;
        }
        return lo + (h >> 8) % (limit - lo + 1);
    }

    //
    // The honest party
    //

    function _honestIn(address t) internal view returns (Tree.Node) {
        return _treeIn(t, 0).root();
    }

    function _onPath(address t) internal view returns (bool) {
        return t == address(root) || onPathKid[t];
    }

    function _key(Obligation memory ob) internal pure returns (bytes32) {
        return keccak256(abi.encode(ob.t, ob.kind, ob.dueAt));
    }

    /// @dev Blocks of censorship the adversary plans to spend on the
    /// obligation keyed `k`: decided once, a pseudo-random share of what is
    /// left, zero most of the time, and never more than the ledger can pay.
    function _plan(bytes32 k) internal returns (uint64 share) {
        uint64 p = planPlusOne[k];
        if (p == 0) {
            uint256 h = uint256(keccak256(abi.encode(walkSeed, k, "censor")));
            if (h % 3 == 0) {
                share = uint64((h >> 8) % (uint256(censorshipLeft) + 1));
            }
            planPlusOne[k] = share + 1;
        } else {
            share = p - 1;
            uint64 room = chargedOn[k] + censorshipLeft;
            if (share > room) {
                share = room;
            }
        }
    }

    /// @dev Charge the ledger for every block the obligation keyed `k` has
    /// been kept waiting beyond `deadline`, up to `blockNumber`.
    function _chargeUpTo(bytes32 k, uint64 deadline, uint256 blockNumber)
        internal
    {
        if (blockNumber <= deadline) {
            return;
        }
        uint64 late = uint64(blockNumber) - deadline;
        uint64 done = chargedOn[k];
        if (late <= done) {
            return;
        }
        late -= done;
        if (late > censorshipLeft) {
            revert HonestFailure("model: censorship overdrawn", "");
        }
        censorshipLeft -= late;
        nCensoredBlocks += late;
        chargedOn[k] = done + late;
    }

    function _honestObligation()
        internal
        view
        returns (Obligation memory best)
    {
        best.deadline = type(uint64).max;
        _consider(best, address(root), NO_KID);
        for (uint256 i; i < kids.length; ++i) {
            if (onPathKid[address(kids[i].t)]) {
                _consider(best, address(kids[i].t), i);
            }
        }
    }

    function _consider(Obligation memory best, address t, uint256 kidIdx)
        internal
        view
    {
        Obligation memory o = _obligationIn(t, kidIdx);
        if (o.kind != OB_NONE && o.deadline < best.deadline) {
            best.kind = o.kind;
            best.t = o.t;
            best.dueAt = o.dueAt;
            best.deadline = o.deadline;
            best.one = o.one;
            best.two = o.two;
            best.kidIdx = o.kidIdx;
        }
    }

    function _max(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a : b;
    }

    /// @dev What the honest party owes in tournament `t`, which is on its
    /// path, or a failure if it can no longer defend there.
    function _obligationIn(address t, uint256 kidIdx)
        internal
        view
        returns (Obligation memory o)
    {
        InspectableTournament tt = InspectableTournament(t);
        Tree.Node h = _honestIn(t);
        uint64 start =
            Time.Instant.unwrap(tt.tournamentArguments().startInstant);
        // No action in a child before its commitment is built.
        uint64 ready = kidIdx == NO_KID ? start : start + budgetT;
        o.t = t;
        o.kidIdx = kidIdx;

        if (!tt.commitmentStanding(h).joined) {
            if (kidIdx != NO_KID) {
                Kid storage kid = kids[kidIdx];
                if (!_isLive(address(kid.parent), kid.pOne, kid.pTwo)) {
                    revert HonestFailure(
                        "child resolved before the honest join", ""
                    );
                }
            }
            if (tt.isClosed()) {
                revert HonestFailure("closed before the honest join", "");
            }
            o.kind = OB_JOIN;
            o.dueAt = ready;
            o.deadline = ready + budgetG;
            return o;
        }

        (bool found, LiveMatch memory m) = _liveMatchOf(t, h);
        if (!found) {
            (Tree.Node dangling_, uint256 n, Time.Instant lastDeleted) =
                tt.observedTopology();
            if (!dangling_.eq(h)) {
                revert HonestFailure("honest commitment eliminated", "");
            }
            if (kidIdx == NO_KID) {
                return o;
            }
            Kid storage kid = kids[kidIdx];
            if (!_isLive(address(kid.parent), kid.pOne, kid.pTwo)) {
                return o;
            }
            // Other live matches: the finish instant is the adversary's.
            if (n != 0) {
                return o;
            }
            uint64 resultAt =
                _max(closureOf(tt), Time.Instant.unwrap(lastDeleted));
            o.kind = OB_PROPAGATE;
            o.dueAt = resultAt;
            o.deadline = resultAt + budgetG;
            return o;
        }

        Match.State memory s = tt.getMatch(Match.Id(m.one, m.two).hashFromId());
        Clock.State memory hc = clockOf(tt, h);
        Clock.State memory oc = clockOf(tt, m.one.eq(h) ? m.two : m.one);
        o.one = m.one;
        o.two = m.two;
        if (s.currentHeight != 0) {
            if (_st(hc) != 0) {
                o.kind = OB_RESPOND;
                o.dueAt = _max(_st(hc), ready);
            } else {
                // Its opponent's turn: the claim falls due at the
                // opponent's deadline.
                o.kind = OB_CLAIM;
                o.dueAt = _max(_st(oc) + _al(oc), ready);
            }
            o.deadline = o.dueAt + budgetG;
        } else if (_isLeafLevel(t)) {
            o.kind = OB_LEAF;
            o.dueAt = _max(_st(hc), ready);
            o.deadline = o.dueAt + budgetG;
        }
        // A sealed inner match owes nothing here: its child carries the
        // obligation.
    }

    function _liveMatchOf(address t, Tree.Node h)
        internal
        view
        returns (bool, LiveMatch memory m)
    {
        for (uint256 i; i < live.length; ++i) {
            if (live[i].t == t && (live[i].one.eq(h) || live[i].two.eq(h))) {
                return (true, live[i]);
            }
        }
        return (false, m);
    }

    /// @dev Land the pending honest action now, after charging the blocks
    /// it waited beyond its deadline to the censorship budget.
    function _honestPerform() internal {
        Obligation memory ob = _honestObligation();
        if (ob.kind == OB_NONE || ob.dueAt > vm.getBlockNumber()) {
            revert HonestFailure("model: nothing to perform", "");
        }
        _chargeUpTo(_key(ob), ob.deadline, vm.getBlockNumber());
        ++nHonest[ob.kind];

        (address target, uint256 value, bytes memory data) = _honestCall(ob);
        (bool ok, bytes memory ret) = _exec(target, HONEST, value, data);
        if (!ok) {
            revert HonestFailure("honest action reverted", ret);
        }
    }

    function _honestCall(Obligation memory ob)
        internal
        returns (address target, uint256 value, bytes memory data)
    {
        target = ob.t;
        if (ob.kind == OB_JOIN) {
            SmallFullTree.Data memory tree = _treeIn(ob.t, 0);
            (Tree.Node l, Tree.Node r) = tree.children(_heightOf(ob.t), 0);
            value = InspectableTournament(ob.t).bondValue();
            paidIn[ob.t] += value;
            data = abi.encodeCall(
                ITournament.joinTournament,
                (tree.finalState(), tree.finalProof(), l, r)
            );
        } else if (ob.kind == OB_PROPAGATE) {
            Kid storage kid = kids[ob.kidIdx];
            target = address(kid.parent);
            (Tree.Node l, Tree.Node r) =
                _treeIn(target, 0).children(_heightOf(target), 0);
            data = abi.encodeCall(
                ITournament.winInnerTournament,
                (ITournament(address(kid.t)), l, r)
            );
        } else {
            data = _honestMatchData(ob);
        }
    }

    function _honestMatchData(Obligation memory ob)
        internal
        view
        returns (bytes memory)
    {
        if (ob.kind == OB_RESPOND) {
            return _honestResponse(ob);
        }
        return _honestWin(ob);
    }

    /// @dev The forced reveal of the honest side: an advance, or the seal.
    function _honestResponse(Obligation memory ob)
        internal
        view
        returns (bytes memory)
    {
        Match.Id memory id = Match.Id(ob.one, ob.two);
        Match.State memory s =
            InspectableTournament(ob.t).getMatch(id.hashFromId());
        SmallFullTree.Data memory a = _treeIn(ob.t, _claimOf(ob.t, ob.one));
        SmallFullTree.Data memory b = _treeIn(ob.t, _claimOf(ob.t, ob.two));
        if (s.currentHeight > 1) {
            return _advanceData(id, s, _heightOf(ob.t), a, b);
        }
        return _sealData(ob.t, id, a, b);
    }

    function _sealData(
        address t,
        Match.Id memory id,
        SmallFullTree.Data memory a,
        SmallFullTree.Data memory b
    ) internal view returns (bytes memory) {
        (
            Tree.Node sl,
            Tree.Node sr,
            Machine.Hash agree,
            bytes32[] memory proof,
        ) = sealArguments(InspectableTournament(t), a, b);
        if (_isLeafLevel(t)) {
            return abi.encodeCall(
                ITournament.sealLeafMatch, (id, sl, sr, agree, proof)
            );
        }
        return abi.encodeCall(
            ITournament.sealInnerMatchAndCreateInnerTournament,
            (id, sl, sr, agree, proof)
        );
    }

    /// @dev A bisection timeout claim, or at a sealed leaf the proof while
    /// no clock has expired and otherwise the timeout claim the classifier
    /// selects for the honest side.
    function _honestWin(Obligation memory ob)
        internal
        view
        returns (bytes memory)
    {
        Match.Id memory id = Match.Id(ob.one, ob.two);
        (Tree.Node l, Tree.Node r) =
            _treeIn(ob.t, 0).children(_heightOf(ob.t), 0);
        if (ob.kind == OB_LEAF) {
            uint8 out = _modelOutcome(ob.t, ob.one, ob.two);
            if (out == NONE) {
                return abi.encodeCall(ITournament.winLeafMatch, (id, l, r, ""));
            }
            bool honestIsOne = ob.one.eq(_honestIn(ob.t));
            if (out != (honestIsOne ? ONE_WINS : TWO_WINS)) {
                revert HonestFailure("honest side lost the leaf race", "");
            }
        }
        return abi.encodeCall(ITournament.winMatchByTimeout, (id, l, r));
    }

    function extRun(uint256 seed) external {
        require(msg.sender == address(this), "walk: self only");
        _run(seed);
    }

    function testFuzzDefendedWalk(uint256 seed) public {
        _run(seed);
    }

    function testControlOneInclusionBelowTheFormulaLoses() public {
        uint256 snap = vm.snapshotState();
        this.extRun(LOSING_WALK);
        vm.revertToState(snap);

        inclusionsBelow = 1;
        try this.extRun(LOSING_WALK) {
            revert("the walk survived below the formula");
        } catch (bytes memory err) {
            assertEq(
                err,
                abi.encodeWithSelector(
                    HonestFailure.selector,
                    "honest action reverted",
                    abi.encodePacked(
                        ITournament.ChildTournamentMustBeEliminated.selector
                    )
                )
            );
        }
    }

    /// @dev The defended walk is not vacuous: over a fixed set of seeds the
    /// honest party performs every kind of action, censorship is spent,
    /// and roots are decided at two and at three levels, all for the honest
    /// claim.
    function testSampleExercisesEveryHonestAction() public {
        uint256[6] memory honest;
        uint256[10] memory total;
        for (uint256 seed = 1; seed <= SAMPLE_SEEDS; ++seed) {
            uint256 snap = vm.snapshotState();
            _run(uint256(keccak256(abi.encode("defended", seed))));
            for (uint256 i; i < 6; ++i) {
                honest[i] += nHonest[i];
            }
            total[0] += nCensoredBlocks;
            total[1] += nForcedLandings;
            total[2] += rootDecided ? 1 : 0;
            total[3] += rootDecided && levels == 3 ? 1 : 0;
            total[4] += nInnerSeals;
            total[5] += nDeepKids;
            total[6] += nJoins;
            total[7] += nCalls;
            total[8] += nDeepLeafSeals;
            total[9] += nDeepPropagations;
            vm.revertToState(snap);
        }
        emit log_named_uint("honest joins", honest[OB_JOIN]);
        emit log_named_uint("honest responses", honest[OB_RESPOND]);
        emit log_named_uint("honest leaf proofs or claims", honest[OB_LEAF]);
        emit log_named_uint("honest bisection timeout claims", honest[OB_CLAIM]);
        emit log_named_uint("honest propagations", honest[OB_PROPAGATE]);
        emit log_named_uint("censored blocks charged", total[0]);
        emit log_named_uint("landings forced at the limit", total[1]);
        emit log_named_uint("decided roots (all honest)", total[2]);
        emit log_named_uint("decided three-level roots", total[3]);
        emit log_named_uint("children", total[4]);
        emit log_named_uint("grandchildren", total[5]);
        emit log_named_uint("leaf seals at level 2 of 3", total[8]);
        emit log_named_uint("propagations into a middle level", total[9]);
        emit log_named_uint("joins by anyone", total[6]);
        emit log_named_uint("calls", total[7]);
        for (uint256 i = 1; i < 6; ++i) {
            assertGt(honest[i], 0, "an honest action kind never happened");
        }
        assertGt(total[0], 0, "no censorship was ever charged");
        assertGt(total[2], 0, "no root was decided");
        assertGt(total[3], 0, "no three-level root was decided");
    }
}
