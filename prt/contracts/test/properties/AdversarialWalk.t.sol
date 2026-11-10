// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {ProofSelectedStateTransition} from "test/fixtures/ProofSelectedStateTransition.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev A tiling table of two or three levels with one budget pair.
contract WalkParametersProvider is ITournamentParametersProvider {
    uint64 immutable LEVELS;
    uint64 immutable H0;
    uint64 immutable H1;
    uint64 immutable H2;
    Time.Duration immutable G;
    Time.Duration immutable T;
    Time.Duration immutable A;

    constructor(
        uint64 levels,
        uint64[3] memory heights,
        uint64 g,
        uint64 t,
        uint64 a
    ) {
        LEVELS = levels;
        H0 = heights[0];
        H1 = heights[1];
        H2 = heights[2];
        G = Time.Duration.wrap(g);
        T = Time.Duration.wrap(t);
        A = Time.Duration.wrap(a);
    }

    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        require(level < LEVELS, "walk: level");
        uint64 height = level == 0 ? H0 : (level == 1 ? H1 : H2);
        uint64 below = level == 0 ? H1 + H2 : (level == 1 ? H2 : 0);
        return TournamentParameters({
            levels: LEVELS,
            log2step: below,
            height: height,
            responseBudget: G,
            commitmentBudget: T,
            maxAllowance: A
        });
    }
}

/// @dev A random walk over a two- or three-level tournament tree against an
/// independent model. Any of four callers performs any verb, legal or not,
/// on the root and on every descendant it creates, and time moves in small
/// steps or to one block before, at, or after a boundary. The walk folds a
/// ghost of the live matches from events, predicts from raw clocks and
/// topology whether each call must succeed and what it must leave behind,
/// and checks after every step:
///  - every call succeeds exactly when the model says it is legal, and no
///    call or view reverts with Panic or without a typed error;
///  - the timeout view equals a classification recomputed from raw clocks,
///    the clock shape matches the match phase, and every response, win and
///    child return charges or refills the clock the model computes;
///  - at every seal, an independent scan of the two claim tables agrees
///    with the sealed divergence, agree state and contested states, which
///    always differ;
///  - a child's arguments equal its parent's sealed match and clocks;
///  - a parent links exactly the children of its live sealed matches and
///    rejects byte-identical orphan twins;
///  - a commitment is in at most one live match and never also dangling, a
///    survivor re-enters pairing as the model says, losers lose their claimer;
///  - `tournamentStanding` and `innerResult` equal a model recomputed from
///    raw topology, raw clocks and the claim tables, field by field;
///  - a decided root standing never changes and is decided over no live
///    descendant match; a child's disposition only moves
///    UNSETTLED -> WINNER -> ELIMINABLE with a fixed winner;
///  - per-clone ETH conservation and the one-bond reserve at recovery, with
///    refunds priced above the work-price cap.
abstract contract AdversarialWalkBase is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for ITournament;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;
    using Time for Time.Instant;
    using Time for Time.Duration;

    uint256 constant CLAIMS = 8;
    uint256 constant STEPS = 500;
    uint256 constant STEPS_AFTER_DECISION = 12;
    /// @dev In half of the runs the first steps are root joins, so that the
    /// run starts with several claims holding full clocks; in the other half
    /// claims arrive whenever the walk picks a join, with shorter clocks.
    uint256 constant OPENING_JOINS = 5;
    bytes4 constant PANIC = 0x4e487b71;

    uint8 constant NONE = 0;
    uint8 constant ONE_WINS = 1;
    uint8 constant TWO_WINS = 2;
    uint8 constant ELIMINATE_BOTH = 3;

    uint8 constant V_NONE = 0;
    uint8 constant V_ADVANCE = 1;
    uint8 constant V_SEAL_LEAF = 2;
    uint8 constant V_SEAL_INNER = 3;
    uint8 constant V_WIN_ONE = 4;
    uint8 constant V_WIN_TWO = 5;
    uint8 constant V_ELIMINATE = 6;

    error PanicReached(address target, bytes data, bytes ret);
    error UntypedRevert(address target, bytes data);
    error ViewReverted(address target, bytes data, bytes ret);
    error Unexpected(string what, bool ok, bytes ret);

    struct ClaimSpec {
        uint256 fam;
        uint256 divergeAt;
        uint256 altFam;
        bool mutated;
        uint256 mutIdx;
    }

    /// @dev Where a tournament sits: its level and the fine index of its
    /// first transition.
    struct Info {
        bool known;
        uint64 level;
        uint256 base;
    }

    struct LiveMatch {
        address t;
        Tree.Node one;
        Tree.Node two;
        uint256 c1;
        uint256 c2;
    }

    struct Kid {
        InspectableTournament t;
        InspectableTournament parent;
        Tree.Node pOne;
        Tree.Node pTwo;
        uint256 c1;
        uint256 c2;
        uint8 lastDisposition;
        Tree.Node lastParent;
        uint64 lastCarried;
    }

    struct Snap {
        Clock.State c1;
        Clock.State c2;
        Tree.Node dangling;
    }

    MultiLevelTournamentFactory factory;
    InspectableTournament root;
    uint64 levels;
    uint64[3] heights;
    uint64 budgetG;
    uint64 budgetT;
    ClaimSpec[CLAIMS] specs;
    mapping(address => Info) infos;
    LiveMatch[] live;
    Kid[] kids;
    mapping(address => uint256) paidIn;
    mapping(address => uint256) kidIndexPlusOne;
    address[4] actors;

    bool rootDecided;
    bytes32 rootDecisionHash;
    uint256 stepIndex;
    uint256 openingJoins;

    // Coverage counters.
    uint256 nJoins;
    uint256 nAdvances;
    uint256 nLeafSeals;
    uint256 nInnerSeals;
    uint256 nDeepKids;
    uint256 nDeepLeafSeals;
    uint256 nDeepPropagations;
    uint256 nStepWins;
    uint256 nTimeoutWins;
    uint256 nTimeoutEliminations;
    uint256 nPropagations;
    uint256 nChildEliminations;
    uint256 nRecoveries;
    uint256 nTypedReverts;
    uint256 nCalls;
    mapping(string => uint256) okBy;
    mapping(string => uint256) revertBy;

    string[11] labels = [
        "join",
        "advance",
        "seal",
        "leaf proof",
        "timeout win",
        "timeout elimination",
        "wrong phase",
        "propagate",
        "eliminate child",
        "recover",
        "garbage"
    ];

    //
    // Geometry and claims
    //

    /// @dev Fine transitions per leaf of a level-`level` tree.
    function _stride(uint64 level) internal view returns (uint256) {
        uint64 below;
        for (uint64 j = level + 1; j < levels; ++j) {
            below += heights[j];
        }
        return uint256(1) << below;
    }

    function _fineCount() internal view returns (uint256) {
        return _stride(0) << heights[0];
    }

    function _fineLeaf(ClaimSpec memory c, uint256 k, uint256 i)
        internal
        pure
        returns (Tree.Node)
    {
        if (c.mutated && i == c.mutIdx) {
            return Tree.Node.wrap(bytes32(uint256(0xdead0000) + k));
        }
        return fineLeaf(i < c.divergeAt ? c.fam : c.altFam, i);
    }

    /// @dev Claim `k`'s commitment for tournament `t`: one leaf per stride
    /// of `t`'s level, sampled at the stride's last fine transition.
    function _treeIn(address t, uint256 k)
        internal
        view
        returns (SmallFullTree.Data memory)
    {
        Info memory info = infos[t];
        require(info.known, "walk: unknown tournament");
        ClaimSpec memory c = specs[k];
        uint256 stride = _stride(info.level);
        uint256 count = uint256(1) << heights[info.level];
        Tree.Node[] memory leaves = new Tree.Node[](count);
        for (uint256 j; j < count; ++j) {
            leaves[j] = _fineLeaf(c, k, info.base + (j + 1) * stride - 1);
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    function _claimOf(address t, Tree.Node node)
        internal
        view
        returns (uint256)
    {
        for (uint256 k; k < CLAIMS; ++k) {
            if (_treeIn(t, k).root().eq(node)) {
                return k;
            }
        }
        revert("walk: unknown commitment");
    }

    function _heightOf(address t) internal view returns (uint64) {
        return heights[infos[t].level];
    }

    function _isLeafLevel(address t) internal view returns (bool) {
        return infos[t].level == levels - 1;
    }

    //
    // Setup
    //

    function _init(uint256 seed) internal {
        actors = [HONEST, SYBIL, SYBIL_TWO, THIRD];
        openingJoins = (seed >> 200) % 2 == 0 ? OPENING_JOINS : 0;
        levels = 2 + uint64(seed % 2);
        heights[0] = 2 + uint64((seed >> 1) & 1);
        if (levels == 3) {
            heights[1] = 1 + uint64((seed >> 3) & 1);
            heights[2] = 2 + uint64((seed >> 2) & 1);
        } else {
            heights[1] = 2 + uint64((seed >> 2) & 1);
            heights[2] = 0;
        }
        uint64 a;
        (budgetG, budgetT, a) = _chooseBudgets(seed);
        vm.roll(100 + ((seed >> 16) % 50));
        vm.fee(Bond.WORK_PRICE_CAP);
        vm.txGasPrice(Bond.WORK_PRICE_CAP + 5 gwei);

        factory = new MultiLevelTournamentFactory(
            new InspectableTournament(),
            new WalkParametersProvider(levels, heights, budgetG, budgetT, a),
            _newStateTransition()
        );
        root = InspectableTournament(
            address(
                factory.instantiate(INITIAL_STATE, IDataProvider(address(0)))
            )
        );
        infos[address(root)] = Info(true, 0, 0);
        vm.recordLogs();

        uint256 n = _fineCount();
        // Fine transitions per leaf-level tree, and per tree one level up.
        uint256 leafSpan = uint256(1) << heights[levels - 1];
        uint256 upSpan = leafSpan << heights[levels - 2];
        specs[0] = ClaimSpec(1, 0, 1, false, 0);
        specs[1] = ClaimSpec(1, (seed >> 24) % n, 2, false, 0);
        specs[2] = ClaimSpec(1, (seed >> 40) % n, 3, false, 0);
        specs[3] = ClaimSpec(2, 0, 2, false, 0);
        // Leaf-level impostor of claim 0: one interior fine leaf changed, so
        // every tree above the leaf level is claim 0's and one leaf-level
        // tree differs but ends in the same state.
        specs[4] = ClaimSpec(
            1,
            0,
            1,
            true,
            ((seed >> 56) % (n / leafSpan)) * leafSpan
                + ((seed >> 72) % (leafSpan - 1))
        );
        if (levels == 3) {
            // Middle-level impostor of claim 1: the last fine leaf of a leaf
            // tree that is not the last of its middle tree, so the root tree
            // is claim 1's and one middle tree differs in one leaf.
            specs[5] = ClaimSpec(
                1,
                specs[1].divergeAt,
                2,
                true,
                ((seed >> 88) % (n / upSpan)) * upSpan
                    + ((seed >> 104) % ((upSpan / leafSpan) - 1)) * leafSpan
                    + leafSpan - 1
            );
        } else {
            specs[5] = ClaimSpec(
                1,
                specs[1].divergeAt,
                2,
                true,
                ((seed >> 88) % (n / leafSpan)) * leafSpan
                    + ((seed >> 104) % (leafSpan - 1))
            );
        }
        specs[6] = ClaimSpec(1, (seed >> 120) % n, 4, false, 0);
        if (levels == 3) {
            // Middle-level impostor of claim 0: same root tree, one middle
            // tree with one foreign leaf and claim 0's final state.
            specs[7] = ClaimSpec(
                1,
                0,
                1,
                true,
                ((seed >> 136) % (n / upSpan)) * upSpan
                    + ((seed >> 152) % ((upSpan / leafSpan) - 1)) * leafSpan
                    + leafSpan - 1
            );
        } else {
            specs[7] = ClaimSpec(3, 0, 3, false, 0);
        }
    }

    //
    // Execution and event folding
    //

    function _exec(address t, address actor, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        ++nCalls;
        vm.prank(actor);
        (ok, ret) = t.call{value: value}(data);
        if (!ok) {
            if (ret.length < 4) {
                revert UntypedRevert(t, data);
            }
            if (bytes4(ret) == PANIC) {
                revert PanicReached(t, data, ret);
            }
            ++nTypedReverts;
        }
        _ingest(vm.getRecordedLogs());
    }

    function _expect(
        string memory what,
        bool ok,
        bool expected,
        bytes memory ret
    ) internal {
        if (ok != expected) {
            revert Unexpected(what, ok, ret);
        }
        if (ok) {
            ++okBy[what];
        } else {
            ++revertBy[what];
        }
    }

    function _view(address t, bytes memory data)
        internal
        view
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = t.staticcall(data);
        if (!ok) {
            revert ViewReverted(t, data, ret);
        }
    }

    function _ingest(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory e = logs[i];
            if (e.topics.length == 0) {
                continue;
            }
            bytes32 sig = e.topics[0];
            if (sig == ITournament.MatchCreated.selector) {
                Tree.Node one = Tree.Node.wrap(e.topics[2]);
                Tree.Node two = Tree.Node.wrap(e.topics[3]);
                live.push(
                    LiveMatch(
                        e.emitter,
                        one,
                        two,
                        _claimOf(e.emitter, one),
                        _claimOf(e.emitter, two)
                    )
                );
            } else if (sig == ITournament.MatchDeleted.selector) {
                _forget(e);
            } else if (sig == ITournament.NewInnerTournament.selector) {
                _registerKid(e);
            } else if (sig == ITournament.LeafMatchSealed.selector) {
                _checkLeafSeal(e);
            } else if (sig == ITournament.MatchAdvanced.selector) {
                ++nAdvances;
            } else if (sig == ITournament.CommitmentJoined.selector) {
                ++nJoins;
            } else if (sig == ITournament.BondRecovered.selector) {
                ++nRecoveries;
            }
        }
    }

    function _forget(Vm.Log memory e) internal {
        (
            ITournament.MatchDeletionReason reason,
            ITournament.WinnerCommitment winner
        ) = abi.decode(
            e.data,
            (ITournament.MatchDeletionReason, ITournament.WinnerCommitment)
        );
        bool none = winner == ITournament.WinnerCommitment.NONE;
        if (reason == ITournament.MatchDeletionReason.STEP) {
            ++nStepWins;
        } else if (reason == ITournament.MatchDeletionReason.TIMEOUT) {
            if (none) {
                ++nTimeoutEliminations;
            } else {
                ++nTimeoutWins;
            }
        } else {
            if (none) {
                ++nChildEliminations;
            } else {
                ++nPropagations;
                if (infos[e.emitter].level != 0) {
                    ++nDeepPropagations;
                }
            }
        }
        for (uint256 j; j < live.length; ++j) {
            if (
                live[j].t == e.emitter
                    && Tree.Node.unwrap(live[j].one) == e.topics[2]
                    && Tree.Node.unwrap(live[j].two) == e.topics[3]
            ) {
                live[j] = live[live.length - 1];
                live.pop();
                return;
            }
        }
        revert("walk: deleted an unknown match");
    }

    function _registerKid(Vm.Log memory e) internal {
        ++nInnerSeals;
        Info memory pinfo = infos[e.emitter];
        require(
            pinfo.known && pinfo.level + 1 < levels,
            "walk: a child of an unknown or leaf tournament"
        );
        InspectableTournament parent = InspectableTournament(e.emitter);
        InspectableTournament child =
            InspectableTournament(address(uint160(uint256(e.topics[2]))));
        (
            Tree.Node one,
            Tree.Node two,
            Machine.Hash f1,
            Machine.Hash f2,
            ITournament.TournamentDescriptor memory d,
            uint256 bond
        ) = abi.decode(
            e.data,
            (
                Tree.Node,
                Tree.Node,
                Machine.Hash,
                Machine.Hash,
                ITournament.TournamentDescriptor,
                uint256
            )
        );
        uint256 stride = _stride(pinfo.level);
        require(
            d.baseCycle >= pinfo.base
                && (d.baseCycle - pinfo.base) % stride == 0,
            "child base cycle is not a parent leaf boundary"
        );
        uint256 seg = (d.baseCycle - pinfo.base) / stride;
        uint256 c1 = _claimOf(e.emitter, one);
        uint256 c2 = _claimOf(e.emitter, two);
        _checkInnerSeal(parent, c1, c2, seg, f1, f2, d);

        // Envelope and frozen parent clocks.
        Clock.State memory k1 = clockOf(parent, one);
        Clock.State memory k2 = clockOf(parent, two);
        require(_st(k1) == 0 && _st(k2) == 0, "sealed inner clocks not paused");
        require(
            Time.Duration.unwrap(d.allowance)
                == (_al(k1) > _al(k2) ? _al(k1) : _al(k2)),
            "child allowance is not the pair envelope"
        );
        require(bond == child.bondValue(), "published bond");

        ITournament.TournamentArguments memory args =
            child.tournamentArguments();
        require(
            args.nestedDispute.contestedCommitmentOne.eq(one)
                && args.nestedDispute.contestedCommitmentTwo.eq(two)
                && Machine.Hash
                    .unwrap(args.nestedDispute.contestedFinalStateOne)
                == Machine.Hash.unwrap(f1)
                && Machine.Hash
                    .unwrap(args.nestedDispute.contestedFinalStateTwo)
                == Machine.Hash.unwrap(f2),
            "nested dispute"
        );

        infos[address(child)] = Info(true, pinfo.level + 1, d.baseCycle);
        if (pinfo.level != 0) {
            ++nDeepKids;
        }
        kids.push(
            Kid(
                child,
                parent,
                one,
                two,
                c1,
                c2,
                0,
                Tree.ZERO_NODE,
                type(uint64).max
            )
        );
        kidIndexPlusOne[address(child)] = kids.length;
        _kidRegistered(kids.length - 1);
    }

    /// @dev Independent divergence oracle for an inner seal, and the child's
    /// geometry.
    function _checkInnerSeal(
        InspectableTournament parent,
        uint256 c1,
        uint256 c2,
        uint256 seg,
        Machine.Hash f1,
        Machine.Hash f2,
        ITournament.TournamentDescriptor memory d
    ) internal view {
        SmallFullTree.Data memory t1 = _treeIn(address(parent), c1);
        SmallFullTree.Data memory t2 = _treeIn(address(parent), c2);
        require(
            Machine.Hash.unwrap(f1) != Machine.Hash.unwrap(f2),
            "equal contested states"
        );
        require(
            Machine.Hash.unwrap(f1) == Tree.Node.unwrap(t1.leaf(seg)),
            "contested state one"
        );
        require(
            Machine.Hash.unwrap(f2) == Tree.Node.unwrap(t2.leaf(seg)),
            "contested state two"
        );
        for (uint256 s; s < seg; ++s) {
            require(t1.leaf(s).eq(t2.leaf(s)), "not the first divergence");
        }
        bytes32 agree = seg == 0
            ? Machine.Hash
                .unwrap(parent.tournamentArguments().commitmentArgs.initialHash)
            : Tree.Node.unwrap(t1.leaf(seg - 1));
        require(Machine.Hash.unwrap(d.initialHash) == agree, "child initial");

        uint64 childLevel = infos[address(parent)].level + 1;
        bool leaf = childLevel == levels - 1;
        require(
            d.level == childLevel
                && d.kind
                    == (leaf
                            ? ITournament.TournamentKind.LEAF
                            : ITournament.TournamentKind.NON_LEAF)
                && d.height == heights[childLevel]
                && (uint256(1) << d.log2Stride) == _stride(childLevel),
            "child geometry"
        );
        require(
            Time.Instant.unwrap(d.startInstant) == vm.getBlockNumber(),
            "child start"
        );
    }

    function _checkLeafSeal(Vm.Log memory e) internal {
        ++nLeafSeals;
        if (infos[e.emitter].level == 2) {
            ++nDeepLeafSeals;
        }
        require(_isLeafLevel(e.emitter), "walk: leaf seal above the leaf level");
        (
            Tree.Node one,
            Tree.Node two,
            Machine.Hash agree,
            uint256 d,
            Machine.Hash f1,
            Machine.Hash f2,
            uint64 deadlineOne,
            uint64 deadlineTwo,
            uint64 eliminableAt
        ) = abi.decode(
            e.data,
            (
                Tree.Node,
                Tree.Node,
                Machine.Hash,
                uint256,
                Machine.Hash,
                Machine.Hash,
                uint64,
                uint64,
                uint64
            )
        );
        SmallFullTree.Data memory t1 =
            _treeIn(e.emitter, _claimOf(e.emitter, one));
        SmallFullTree.Data memory t2 =
            _treeIn(e.emitter, _claimOf(e.emitter, two));
        require(
            Machine.Hash.unwrap(f1) != Machine.Hash.unwrap(f2),
            "leaf: equal contested states"
        );
        require(
            Machine.Hash.unwrap(f1) == Tree.Node.unwrap(t1.leaf(d))
                && Machine.Hash.unwrap(f2) == Tree.Node.unwrap(t2.leaf(d)),
            "leaf: contested states"
        );
        for (uint256 i; i < d; ++i) {
            require(t1.leaf(i).eq(t2.leaf(i)), "leaf: not first divergence");
        }
        bytes32 expected = d == 0
            ? Machine.Hash
                .unwrap(
                    InspectableTournament(e.emitter).tournamentArguments()
                        .commitmentArgs.initialHash
                )
            : Tree.Node.unwrap(t1.leaf(d - 1));
        require(Machine.Hash.unwrap(agree) == expected, "leaf: agree state");
        require(
            deadlineOne > vm.getBlockNumber()
                && deadlineTwo > vm.getBlockNumber()
                && eliminableAt
                    == (deadlineOne > deadlineTwo ? deadlineOne : deadlineTwo),
            "leaf: schedule"
        );
    }

    //
    // The clock model, from raw storage
    //

    function _al(Clock.State memory c) internal pure returns (uint64) {
        return Time.Duration.unwrap(c.allowance);
    }

    function _st(Clock.State memory c) internal pure returns (uint64) {
        return Time.Instant.unwrap(c.startInstant);
    }

    function _remaining(Clock.State memory c) internal view returns (uint64) {
        if (_st(c) == 0) {
            return _al(c);
        }
        uint64 elapsed = uint64(vm.getBlockNumber()) - _st(c);
        return elapsed >= _al(c) ? 0 : _al(c) - elapsed;
    }

    function _modelOutcome(address t, Tree.Node one, Tree.Node two)
        internal
        view
        returns (uint8)
    {
        Clock.State memory c1 = clockOf(InspectableTournament(t), one);
        Clock.State memory c2 = clockOf(InspectableTournament(t), two);
        uint64 r1 = _remaining(c1);
        uint64 r2 = _remaining(c2);
        if (r1 != 0 && r2 != 0) {
            return NONE;
        }
        if (r1 == 0 && r2 == 0) {
            return ELIMINATE_BOTH;
        }
        Clock.State memory survivor = r1 == 0 ? c2 : c1;
        Clock.State memory expired = r1 == 0 ? c1 : c2;
        uint8 win = r1 == 0 ? TWO_WINS : ONE_WINS;
        if (_st(survivor) != 0) {
            return win;
        }
        uint64 overdue =
            uint64(vm.getBlockNumber()) - _st(expired) - _al(expired);
        return _al(survivor) > overdue ? win : ELIMINATE_BOTH;
    }

    function _charged(uint64 allowance, uint64 cost)
        internal
        view
        returns (uint64)
    {
        return allowance - (cost > budgetG ? cost - budgetG : 0);
    }

    //
    // Actions
    //

    function _actor(uint256 x) internal view returns (address) {
        return actors[x % 4];
    }

    function _roll(uint256 x) internal {
        uint256 p = x % 10;
        uint256 y = x >> 8;
        uint256 d = p < 7 ? y % 3 : 3 + y % 6;
        _advanceTo(vm.getBlockNumber() + d);
    }

    /// @dev Jump to one block before, at, or after a boundary: a running
    /// clock's deadline, a bisection's double-elimination instant, a
    /// tournament's closure, or a child winner's expiry.
    function _rollToBoundary(uint256 x) internal {
        uint256 target;
        uint256 pick = x % 8;
        if (pick < 4 && live.length != 0) {
            LiveMatch memory m = live[(x >> 8) % live.length];
            Clock.State memory c1 = clockOf(InspectableTournament(m.t), m.one);
            Clock.State memory c2 = clockOf(InspectableTournament(m.t), m.two);
            if (_st(c1) != 0 && _st(c2) != 0) {
                target = ((x >> 40) & 1) == 0
                    ? _st(c1) + _al(c1)
                    : _st(c2) + _al(c2);
            } else if (_st(c1) != 0) {
                target =
                    _st(c1) + _al(c1) + (((x >> 40) & 1) == 0 ? 0 : _al(c2));
            } else if (_st(c2) != 0) {
                target =
                    _st(c2) + _al(c2) + (((x >> 40) & 1) == 0 ? 0 : _al(c1));
            }
        } else if (
            pick < 6 && kids.length != 0
                && _ghostCount(address(_recentKid(x >> 8))) == 0
        ) {
            target = closureOf(_recentKid(x >> 8));
        } else if (pick == 6 && kids.length != 0) {
            target = Time.Instant
                .unwrap(_recentKid(x >> 8).tournamentStanding().winnerExpiresAt);
        } else if (pick == 7 && ((x >> 40) & 1) == 0) {
            target = closureOf(root);
        }
        if (target == 0) {
            _advanceTo(vm.getBlockNumber() + 1 + ((x >> 56) % 2));
            return;
        }
        target = target + ((x >> 48) % 3) - 1;
        _advanceTo(target);
    }

    /// @dev Mostly a child that is still linked to a live parent match.
    function _recentKid(uint256 x)
        internal
        view
        returns (InspectableTournament)
    {
        uint256 n = kids.length;
        if (x % 8 != 0) {
            // Newest first among the children whose parent match is live;
            // sometimes the second newest, one level up a three-level chain.
            uint256 skip = (x >> 8) % 3 == 0 ? 1 : 0;
            for (uint256 j = n; j > 0; --j) {
                Kid storage kid = kids[j - 1];
                if (_isLive(address(kid.parent), kid.pOne, kid.pTwo)) {
                    if (skip == 0) {
                        return kid.t;
                    }
                    --skip;
                }
            }
        }
        return kids[(x >> 16) % n].t;
    }

    function _joinRoot(uint256 x) internal {
        uint256 k = x % CLAIMS;
        // Mostly a claim that has not joined yet.
        if ((x >> 180) % 4 != 0) {
            for (uint256 j; j < CLAIMS; ++j) {
                uint256 cand = (k + j) % CLAIMS;
                if (!root.commitmentStanding(
                        _treeIn(address(root), cand).root()
                    )
                    .joined) {
                    k = cand;
                    break;
                }
            }
        }
        _join(root, k, x);
    }

    function _joinKid(uint256 x) internal {
        Kid memory kid =
            kids[kidIndexPlusOne[address(_recentKid(x >> 200))] - 1];
        uint256 k = x % CLAIMS;
        // Mostly one of the two parent claims, whose child trees end in the
        // contested states.
        uint256 q = (x >> 180) % 8;
        if (q < 3) {
            k = kid.c1;
        } else if (q < 6) {
            k = kid.c2;
        }
        _join(kid.t, k, x);
    }

    function _join(InspectableTournament t, uint256 k, uint256 x) internal {
        SmallFullTree.Data memory tree = _treeIn(address(t), k);
        ITournament.TournamentArguments memory args = t.tournamentArguments();
        (Tree.Node l, Tree.Node r) =
            tree.children(args.commitmentArgs.height, 0);
        uint256 bond = t.bondValue();
        uint256 value = bond;
        uint256 q = (x >> 8) % 16;
        if (q == 0) {
            value -= 1;
        }
        if (q == 1) {
            value += 1 ether;
        }

        bytes32 fs = Machine.Hash.unwrap(tree.finalState());
        bool contested = args.level == 0
            || fs
                == Machine.Hash
                .unwrap(args.nestedDispute.contestedFinalStateOne)
            || fs
                == Machine.Hash
                    .unwrap(args.nestedDispute.contestedFinalStateTwo);
        bool expected = !t.isClosed() && value >= bond && contested
            && !t.commitmentStanding(tree.root()).joined;

        (bool ok, bytes memory ret) = _exec(
            address(t),
            _actor(x >> 16),
            value,
            abi.encodeCall(
                ITournament.joinTournament,
                (tree.finalState(), tree.finalProof(), l, r)
            )
        );
        _expect("join", ok, expected, ret);
        if (ok) {
            paidIn[address(t)] += value;
            // Joined clocks are the tournament's remaining window, paused,
            // whether the newcomer waits or is paired.
            Clock.State memory c = clockOf(t, tree.root());
            require(
                _al(c) == closureOf(t) - uint64(vm.getBlockNumber()),
                "join clock is not the remaining window"
            );
            require(_st(c) == 0, "newcomer clock is running");
        }
    }

    function _isSealedInner(LiveMatch memory m) internal view returns (bool) {
        if (_isLeafLevel(m.t)) {
            return false;
        }
        return InspectableTournament(m.t)
            .getMatch(Match.Id(m.one, m.two).hashFromId())
            .currentHeight == 0;
    }

    /// @dev Every live match waits on a child: join it while it is open,
    /// otherwise act on its result.
    function _childFlow(uint256 x) internal {
        if (!_recentKid(x >> 200).isClosed() && (x >> 70) % 4 != 0) {
            _joinKid(x);
        } else {
            _kidAction(x);
        }
    }

    function _matchAction(uint256 x) internal {
        if (live.length == 0) {
            return;
        }
        uint256 pickIdx = x % live.length;
        if ((x >> 60) % 8 != 0) {
            // Prefer a match that can move locally over a sealed inner one,
            // whose progress belongs to its child.
            bool found;
            for (uint256 j; j < live.length; ++j) {
                uint256 cand = (pickIdx + j) % live.length;
                if (!_isSealedInner(live[cand])) {
                    pickIdx = cand;
                    found = true;
                    break;
                }
            }
            if (!found) {
                _childFlow(x);
                return;
            }
        }
        LiveMatch memory m = live[pickIdx];
        InspectableTournament t = InspectableTournament(m.t);
        SmallFullTree.Data memory a = _treeIn(m.t, m.c1);
        SmallFullTree.Data memory b = _treeIn(m.t, m.c2);
        Match.Id memory id = Match.Id(m.one, m.two);
        Match.State memory s = t.getMatch(id.hashFromId());
        uint64 total = _heightOf(m.t);
        bool isLeaf = _isLeafLevel(m.t);
        uint8 out = _modelOutcome(m.t, m.one, m.two);
        uint256 sub = (x >> 8) % 16;
        // Once a timeout arm is open, mostly take it.
        if (out != NONE && sub >= 6) {
            sub = out == ONE_WINS ? 0 : (out == TWO_WINS ? 1 : 2);
        }
        bytes memory data;
        bool expected;
        string memory what;
        uint8 verb;

        if (sub == 0 || sub == 1) {
            (Tree.Node l, Tree.Node r) = (sub == 0 ? a : b).children(total, 0);
            data = abi.encodeCall(ITournament.winMatchByTimeout, (id, l, r));
            expected = out == (sub == 0 ? ONE_WINS : TWO_WINS);
            what = "timeout win";
            verb = sub == 0 ? V_WIN_ONE : V_WIN_TWO;
        } else if (sub == 2) {
            data = abi.encodeCall(ITournament.eliminateMatchByTimeout, (id));
            expected = out == ELIMINATE_BOTH;
            what = "timeout elimination";
            verb = V_ELIMINATE;
        } else if (sub == 3) {
            // Wrong-phase verb with empty nodes.
            what = "wrong phase";
            if (s.currentHeight > 1) {
                data = abi.encodeCall(
                    ITournament.sealLeafMatch,
                    (
                        id,
                        Tree.ZERO_NODE,
                        Tree.ZERO_NODE,
                        Machine.ZERO_STATE,
                        new bytes32[](0)
                    )
                );
            } else {
                data = abi.encodeCall(
                    ITournament.advanceMatch,
                    (
                        id,
                        Tree.ZERO_NODE,
                        Tree.ZERO_NODE,
                        Tree.ZERO_NODE,
                        Tree.ZERO_NODE
                    )
                );
            }
        } else if (s.currentHeight > 1) {
            data = _advanceData(id, s, total, a, b);
            expected = out == NONE;
            what = "advance";
            verb = V_ADVANCE;
        } else if (s.currentHeight == 1) {
            (
                Tree.Node l,
                Tree.Node r,
                Machine.Hash agree,
                bytes32[] memory proof,
            ) = sealArguments(t, a, b);
            // sub 4 seals with the other kind's verb.
            bool rightVerb = sub != 4;
            if (isLeaf == rightVerb) {
                data = abi.encodeCall(
                    ITournament.sealLeafMatch, (id, l, r, agree, proof)
                );
            } else {
                data = abi.encodeCall(
                    ITournament.sealInnerMatchAndCreateInnerTournament,
                    (id, l, r, agree, proof)
                );
            }
            expected = rightVerb && out == NONE;
            what = "seal";
            verb = isLeaf ? V_SEAL_LEAF : V_SEAL_INNER;
        } else {
            SmallFullTree.Data memory w = ((x >> 24) & 1) == 0 ? a : b;
            (Tree.Node l, Tree.Node r) = w.children(total, 0);
            data = abi.encodeCall(
                ITournament.winLeafMatch,
                (
                    id,
                    l,
                    r,
                    abi.encode(Tree.Node.unwrap(w.leaf(s.runningLeafPosition)))
                )
            );
            expected = isLeaf && out == NONE
                && _proofAccepted(m.t, a, w, s.runningLeafPosition);
            what = "leaf proof";
            verb = ((x >> 24) & 1) == 0 ? V_WIN_ONE : V_WIN_TWO;
        }
        Snap memory before = _snap(m.t, m.one, m.two);
        (bool ok, bytes memory ret) = _exec(m.t, _actor(x >> 16), 0, data);
        _expect(what, ok, expected, ret);
        if (ok) {
            _postMatch(verb, m, before, total);
        }
    }

    function _advanceData(
        Match.Id memory id,
        Match.State memory s,
        uint64 total,
        SmallFullTree.Data memory a,
        SmallFullTree.Data memory b
    ) internal pure returns (bytes memory) {
        bool oneReveals = Match.responder(total, s.currentHeight)
        == ITournament.CommitmentSide.ONE;
        SmallFullTree.Data memory rv = oneReveals ? a : b;
        SmallFullTree.Data memory w = oneReveals ? b : a;
        uint64 h = s.currentHeight;
        uint256 idx = s.runningLeafPosition >> h;
        (Tree.Node l, Tree.Node r) = rv.children(h, idx);
        uint256 selected = 2 * idx;
        if (l.eq(w.node(h - 1, selected))) {
            selected += 1;
        }
        (Tree.Node nl, Tree.Node nr) = rv.children(h - 1, selected);
        return abi.encodeCall(ITournament.advanceMatch, (id, l, r, nl, nr));
    }

    function _snap(address t, Tree.Node one, Tree.Node two)
        internal
        view
        returns (Snap memory snap)
    {
        snap.c1 = clockOf(InspectableTournament(t), one);
        snap.c2 = clockOf(InspectableTournament(t), two);
        (snap.dangling,,) = InspectableTournament(t).observedTopology();
    }

    /// @dev The model of what a successful match verb leaves behind:
    /// clock charges and shapes, who keeps a claimer, and where the survivor
    /// goes.
    function _postMatch(
        uint8 verb,
        LiveMatch memory m,
        Snap memory b,
        uint64 total
    ) internal view {
        InspectableTournament t = InspectableTournament(m.t);
        Clock.State memory n1 = clockOf(t, m.one);
        Clock.State memory n2 = clockOf(t, m.two);
        uint64 nowB = uint64(vm.getBlockNumber());
        (Tree.Node d,,) = t.observedTopology();

        if (verb == V_ADVANCE || verb == V_SEAL_LEAF || verb == V_SEAL_INNER) {
            bool oneResponded = _st(b.c1) != 0;
            Clock.State memory br = oneResponded ? b.c1 : b.c2;
            Clock.State memory bo = oneResponded ? b.c2 : b.c1;
            Clock.State memory nr = oneResponded ? n1 : n2;
            Clock.State memory no = oneResponded ? n2 : n1;
            require(
                _al(nr) == _charged(_al(br), nowB - _st(br)), "responder charge"
            );
            require(_al(no) == _al(bo), "idle clock balance changed");
            if (verb == V_ADVANCE) {
                require(_st(nr) == 0 && _st(no) == nowB, "advance: turn");
            } else if (verb == V_SEAL_LEAF) {
                require(_st(nr) == nowB && _st(no) == nowB, "leaf race start");
            } else {
                require(_st(nr) == 0 && _st(no) == 0, "inner seal pauses");
            }
            require(d.eq(b.dangling), "progress moved the dangling slot");
            return;
        }
        if (verb == V_ELIMINATE) {
            require(
                t.observedClaimer(m.one) == address(0)
                    && t.observedClaimer(m.two) == address(0),
                "eliminated side keeps a claimer"
            );
            require(d.eq(b.dangling), "elimination moved the dangling slot");
            return;
        }

        // A single winner, by proof or by timeout.
        bool oneWon = verb == V_WIN_ONE;
        Clock.State memory bw = oneWon ? b.c1 : b.c2;
        Clock.State memory bl = oneWon ? b.c2 : b.c1;
        Clock.State memory nw = oneWon ? n1 : n2;
        Tree.Node winner = oneWon ? m.one : m.two;
        Tree.Node loser = oneWon ? m.two : m.one;
        uint64 cost = _st(bw) != 0 ? nowB - _st(bw) : nowB - _st(bl) - _al(bl);
        require(_al(nw) == _charged(_al(bw), cost), "winner charge");
        require(_st(nw) == 0, "winner not paused");
        require(
            t.observedClaimer(loser) == address(0), "loser keeps its claimer"
        );
        require(
            t.observedClaimer(winner) != address(0), "winner lost its claimer"
        );
        _requireRepaired(t, winner, b.dangling, total);
    }

    /// @dev A survivor takes the empty dangling slot, or becomes the
    /// newcomer of a fresh match against the commitment that waited there.
    function _requireRepaired(
        InspectableTournament t,
        Tree.Node winner,
        Tree.Node danglingBefore,
        uint64 total
    ) internal view {
        (Tree.Node d,,) = t.observedTopology();
        if (danglingBefore.isZero()) {
            require(d.eq(winner), "survivor is not dangling");
        } else {
            require(d.isZero(), "dangling slot not consumed");
            Match.State memory ns =
                t.getMatch(Match.Id(danglingBefore, winner).hashFromId());
            require(
                ns.isInit && ns.currentHeight == total
                    && ns.runningLeafPosition == 0,
                "survivor not re-paired as the newcomer"
            );
            require(
                _st(clockOf(t, danglingBefore)) == uint64(vm.getBlockNumber()),
                "elder clock not started by the re-pairing"
            );
        }
    }

    function _propagate(Kid memory kid, uint256 c, address actor) internal {
        InspectableTournament parent = kid.parent;
        SmallFullTree.Data memory tree = _treeIn(address(parent), c);
        uint64 total = _heightOf(address(parent));
        (Tree.Node l, Tree.Node r) = tree.children(total, 0);
        ITournament.InnerResultView memory res = kid.t.innerResult();
        bool expected = _isLive(address(parent), kid.pOne, kid.pTwo)
            && res.disposition == ITournament.InnerTournamentDisposition.WINNER
            && res.parentCommitment.eq(tree.root());
        uint64 a1 = allowanceOf(parent, kid.pOne);
        uint64 a2 = allowanceOf(parent, kid.pTwo);
        (Tree.Node danglingBefore,,) = parent.observedTopology();
        (bool ok, bytes memory ret) = _exec(
            address(parent),
            actor,
            0,
            abi.encodeCall(
                ITournament.winInnerTournament,
                (ITournament(address(kid.t)), l, r)
            )
        );
        _expect("propagate", ok, expected, ret);
        if (ok) {
            uint64 envelope = a1 > a2 ? a1 : a2;
            uint64 want = Time.Duration.unwrap(res.pausedAllowance) + budgetT
                + 2 * budgetG;
            if (want > envelope) {
                want = envelope;
            }
            require(
                allowanceOf(parent, tree.root()) == want,
                "returned clock is not min(carried + T + 2G, envelope)"
            );
            Tree.Node loser = tree.root().eq(kid.pOne) ? kid.pTwo : kid.pOne;
            require(
                parent.observedClaimer(loser) == address(0)
                    && parent.observedClaimer(tree.root()) != address(0),
                "propagation claimers"
            );
            _requireRepaired(parent, tree.root(), danglingBefore, total);
        }
    }

    function _kidAction(uint256 x) internal {
        if (kids.length == 0) {
            return;
        }
        Kid memory kid = kids[kidIndexPlusOne[address(_recentKid(x >> 32))] - 1];
        uint256 sub = (x >> 8) % 10;
        address actor = _actor(x >> 16);
        if ((x >> 100) % 10 < 6) {
            // The verb the child's disposition calls for, if any.
            ITournament.InnerResultView memory res = kid.t.innerResult();
            if (
                res.disposition == ITournament.InnerTournamentDisposition.WINNER
            ) {
                _propagate(
                    kid,
                    res.parentCommitment.eq(kid.pOne) ? kid.c1 : kid.c2,
                    actor
                );
                return;
            }
            if (
                res.disposition
                    == ITournament.InnerTournamentDisposition.ELIMINABLE
            ) {
                sub = 6;
            } else {
                _rollToBoundary(x >> 110);
                return;
            }
        }
        if (sub < 6) {
            uint256 c =
                sub < 3 ? kid.c1 : (sub < 5 ? kid.c2 : (x >> 24) % CLAIMS);
            _propagate(kid, c, actor);
        } else if (sub < 8) {
            bool expected = _isLive(address(kid.parent), kid.pOne, kid.pTwo)
                && kid.t.innerResult().disposition
                    == ITournament.InnerTournamentDisposition.ELIMINABLE;
            (bool ok, bytes memory ret) = _exec(
                address(kid.parent),
                actor,
                0,
                abi.encodeCall(
                    ITournament.eliminateInnerTournament,
                    (ITournament(address(kid.t)))
                )
            );
            _expect("eliminate child", ok, expected, ret);
            if (ok) {
                require(
                    kid.parent.observedClaimer(kid.pOne) == address(0)
                        && kid.parent.observedClaimer(kid.pTwo) == address(0),
                    "child elimination keeps a parent claimer"
                );
            }
        } else {
            _impostorChild(kid, sub == 8, actor);
        }
    }

    /// @dev A byte-identical orphan twin, or the parent posing as its own
    /// child: neither is linked, so both parent verbs must reject it.
    function _impostorChild(Kid memory kid, bool twin, address actor) internal {
        ITournament impostor = ITournament(address(kid.parent));
        if (twin) {
            ITournament.TournamentArguments memory args =
                kid.t.tournamentArguments();
            vm.prank(actor);
            (impostor,) = factory.instantiateInner(
                args.commitmentArgs.initialHash,
                args.nestedDispute.contestedCommitmentOne,
                args.nestedDispute.contestedFinalStateOne,
                args.nestedDispute.contestedCommitmentTwo,
                args.nestedDispute.contestedFinalStateTwo,
                args.allowance,
                args.commitmentArgs.startCycle,
                args.level,
                args.provider
            );
        }
        (Tree.Node l, Tree.Node r) = _treeIn(address(kid.parent), kid.c1)
            .children(_heightOf(address(kid.parent)), 0);
        (bool ok, bytes memory ret) = _exec(
            address(kid.parent),
            actor,
            0,
            abi.encodeCall(ITournament.winInnerTournament, (impostor, l, r))
        );
        _requireUnlinked(kid.parent, ok, ret, "unlinked child accepted by win");
        (ok, ret) = _exec(
            address(kid.parent),
            actor,
            0,
            abi.encodeCall(ITournament.eliminateInnerTournament, (impostor))
        );
        _requireUnlinked(
            kid.parent, ok, ret, "unlinked child accepted by eliminate"
        );
    }

    /// @dev An unlinked child fails with MatchDoesNotExist, or with the
    /// finished gate when the parent is already finished.
    function _requireUnlinked(
        InspectableTournament parent,
        bool ok,
        bytes memory ret,
        string memory what
    ) internal view {
        require(!ok, what);
        bytes4 sel = bytes4(ret);
        if (sel == ITournament.TournamentIsFinished.selector) {
            require(parent.isFinished(), what);
        } else {
            require(sel == ITournament.MatchDoesNotExist.selector, what);
        }
    }

    function _anyTournament(uint256 x) internal view returns (address) {
        uint256 i = x % (kids.length + 1);
        return i == 0 ? address(root) : address(kids[i - 1].t);
    }

    function _recover(uint256 x) internal {
        address t = _anyTournament(x);
        (ITournament.BondDisposition disp,,) = ITournament(t).bondRecovery();
        bool expected = disp == ITournament.BondDisposition.RECOVERABLE
            || disp == ITournament.BondDisposition.RECOVERED;
        uint256 before = t.balance;
        (bool ok, bytes memory ret) = _exec(
            t,
            _actor(x >> 16),
            0,
            abi.encodeCall(ITournament.tryRecoveringBond, ())
        );
        _expect("recover", ok, expected, ret);
        if (ok) {
            require(abi.decode(ret, (bool)), "plain claimer rejected payment");
            if (disp == ITournament.BondDisposition.RECOVERABLE) {
                require(t.balance == 0, "residual survived recovery");
            } else {
                require(t.balance == before, "second recovery moved value");
            }
        }
    }

    function _garbage(uint256 x) internal {
        address t = _anyTournament(x);
        Match.Id memory id = Match.Id(
            Tree.Node.wrap(keccak256(abi.encode(x, "one"))),
            Tree.Node.wrap(keccak256(abi.encode(x, "two")))
        );
        // Half the time, aim at a live match with its sides swapped, or at a
        // live match of another tournament.
        if (live.length != 0 && (x >> 24) % 2 == 0) {
            LiveMatch memory m = live[(x >> 32) % live.length];
            id = (m.t == t || ((x >> 40) & 1) == 0)
                ? Match.Id(m.two, m.one)
                : Match.Id(m.one, m.two);
        }
        Tree.Node n = Tree.Node.wrap(bytes32(x));
        uint256 sub = (x >> 8) % 8;
        bytes memory data;
        if (sub == 0) {
            data = abi.encodeCall(ITournament.advanceMatch, (id, n, n, n, n));
        } else if (sub == 1) {
            data = abi.encodeCall(ITournament.winMatchByTimeout, (id, n, n));
        } else if (sub == 2) {
            data = abi.encodeCall(ITournament.eliminateMatchByTimeout, (id));
        } else if (sub == 3) {
            data = abi.encodeCall(
                ITournament.sealLeafMatch,
                (id, n, n, Machine.ZERO_STATE, new bytes32[](1))
            );
        } else if (sub == 4) {
            data = abi.encodeCall(
                ITournament.sealInnerMatchAndCreateInnerTournament,
                (id, n, n, Machine.ZERO_STATE, new bytes32[](1))
            );
        } else if (sub == 5) {
            data = abi.encodeCall(
                ITournament.winLeafMatch, (id, n, n, abi.encode(n))
            );
        } else if (sub == 6) {
            data = abi.encodeCall(
                ITournament.winInnerTournament,
                (ITournament(address(uint160(x))), n, n)
            );
        } else {
            data = abi.encodeCall(
                ITournament.eliminateInnerTournament,
                (ITournament(address(uint160(x))))
            );
        }
        (bool ok, bytes memory ret) = _exec(t, _actor(x >> 16), 0, data);
        _expect("garbage", ok, false, ret);
    }

    //
    // Invariants
    //

    function _ghostCount(address t) internal view returns (uint256 n) {
        for (uint256 i; i < live.length; ++i) {
            if (live[i].t == t) {
                ++n;
            }
        }
    }

    function _isLive(address t, Tree.Node one, Tree.Node two)
        internal
        view
        returns (bool)
    {
        for (uint256 i; i < live.length; ++i) {
            if (live[i].t == t && live[i].one.eq(one) && live[i].two.eq(two)) {
                return true;
            }
        }
        return false;
    }

    function _checkTournament(InspectableTournament t) internal view {
        _view(address(t), abi.encodeCall(ITournament.tournamentStanding, ()));
        _view(address(t), abi.encodeCall(ITournament.tournamentDescriptor, ()));
        bytes memory ret =
            _view(address(t), abi.encodeCall(ITournament.bondRecovery, ()));
        (ITournament.BondDisposition disp, address claimer, uint256 payment) =
            abi.decode(ret, (ITournament.BondDisposition, address, uint256));

        (Tree.Node dangling_, uint256 n,) = t.observedTopology();
        require(n == _ghostCount(address(t)), "matchCount differs from events");
        if (!dangling_.isZero()) {
            Clock.State memory c = clockOf(t, dangling_);
            require(_st(c) == 0 && _al(c) != 0, "dangling clock is not paused");
        }

        uint256 balance = address(t).balance;
        require(balance <= paidIn[address(t)], "balance above paid-in value");
        if (disp == ITournament.BondDisposition.RECOVERABLE) {
            uint256 bond = t.bondValue();
            require(balance >= bond, "one-bond reserve broken");
            require(payment >= bond && payment <= balance, "winner payment");
            require(claimer != address(0), "recoverable without claimer");
            require(!dangling_.isZero(), "recoverable without winner");
        }
    }

    /// @dev The model of `tournamentStanding` and, for a child, of
    /// `innerResult`, from raw topology, raw clocks and the claim trees.
    function _checkStanding(InspectableTournament t) internal view {
        ITournament.TournamentStandingView memory s = t.tournamentStanding();
        ITournament.TournamentArguments memory args = t.tournamentArguments();
        (Tree.Node dangling_, uint256 n, Time.Instant lastDeleted) =
            t.observedTopology();
        uint64 nowB = uint64(vm.getBlockNumber());
        uint64 closure = closureOf(t);
        bool closed = nowB >= closure;
        bool finished = closed && n == 0;
        uint64 resultAt = closure > Time.Instant.unwrap(lastDeleted)
            ? closure
            : Time.Instant.unwrap(lastDeleted);

        require(s.acceptsJoins == !closed, "standing: acceptsJoins");
        require(
            s.hasCandidate == !dangling_.isZero() && s.candidate.eq(dangling_),
            "standing: candidate"
        );
        require(
            Time.Instant.unwrap(s.finishedAt) == (finished ? resultAt : 0),
            "standing: finishedAt"
        );

        ITournament.TournamentStanding want;
        bytes32 wantFinal;
        Tree.Node wantParent;
        uint64 wantExpiry;
        uint64 wantCarried;
        if (n != 0) {
            want = ITournament.TournamentStanding.MATCHES_ACTIVE;
        } else if (!closed) {
            want = ITournament.TournamentStanding.AWAITING_CLOSURE;
        } else if (args.level == 0) {
            if (dangling_.isZero()) {
                want = ITournament.TournamentStanding.ROOT_FAILED;
            } else {
                want = ITournament.TournamentStanding.ROOT_WINNER;
                wantFinal = _finalOf(address(t), dangling_);
            }
        } else if (dangling_.isZero()) {
            want = ITournament.TournamentStanding.INNER_ELIMINABLE_NO_WINNER;
        } else {
            uint64 expiry = resultAt + _al(clockOf(t, dangling_));
            if (nowB >= expiry) {
                want =
                ITournament.TournamentStanding.INNER_ELIMINABLE_WINNER_EXPIRED;
            } else {
                want = ITournament.TournamentStanding.INNER_WINNER;
                wantFinal = _finalOf(address(t), dangling_);
                wantParent = wantFinal
                    == Machine.Hash
                        .unwrap(args.nestedDispute.contestedFinalStateOne)
                    ? args.nestedDispute.contestedCommitmentOne
                    : args.nestedDispute.contestedCommitmentTwo;
                wantExpiry = expiry;
                wantCarried = expiry - nowB;
            }
        }
        require(s.standing == want, "standing: disposition");
        require(
            Machine.Hash.unwrap(s.finalState) == wantFinal, "standing: result"
        );
        require(
            s.parentCommitment.eq(wantParent), "standing: parent commitment"
        );
        require(
            Time.Instant.unwrap(s.winnerExpiresAt) == wantExpiry,
            "standing: winner expiry"
        );

        if (args.level == 0) {
            return;
        }
        ITournament.InnerResultView memory r = t.innerResult();
        ITournament.InnerTournamentDisposition wantInner = !finished
            ? ITournament.InnerTournamentDisposition.UNSETTLED
            : (want == ITournament.TournamentStanding.INNER_WINNER
                    ? ITournament.InnerTournamentDisposition.WINNER
                    : ITournament.InnerTournamentDisposition.ELIMINABLE);
        require(r.disposition == wantInner, "inner result: disposition");
        require(r.parentCommitment.eq(wantParent), "inner result: parent");
        require(
            Time.Duration.unwrap(r.pausedAllowance) == wantCarried,
            "inner result: carried allowance"
        );
    }

    /// @dev The claimed final state of a joined commitment: its tree's last
    /// leaf, from the claim tables rather than from contract storage.
    function _finalOf(address t, Tree.Node commitment)
        internal
        view
        returns (bytes32)
    {
        return Machine.Hash
            .unwrap(_treeIn(t, _claimOf(t, commitment)).finalState());
    }

    function _checkMatches() internal view {
        for (uint256 i; i < live.length; ++i) {
            LiveMatch memory m = live[i];
            InspectableTournament t = InspectableTournament(m.t);
            Match.Id memory id = Match.Id(m.one, m.two);
            Match.IdHash h = id.hashFromId();
            (, ITournament.MatchTimeoutOutcome viewOutcome,) = abi.decode(
                _view(
                    m.t, abi.encodeCall(ITournament.classifyMatchTimeout, (id))
                ),
                (Match.Phase, ITournament.MatchTimeoutOutcome, Time.Duration)
            );
            _view(m.t, abi.encodeCall(ITournament.bisectingMatch, (h)));
            _view(m.t, abi.encodeCall(ITournament.readyToSealMatch, (h)));
            _view(m.t, abi.encodeCall(ITournament.sealedMatch, (h)));
            _view(m.t, abi.encodeCall(ITournament.commitmentStanding, (m.one)));
            _view(m.t, abi.encodeCall(ITournament.commitmentStanding, (m.two)));

            Match.State memory s = t.getMatch(h);
            require(s.isInit, "ghost match is not stored");
            require(
                uint8(viewOutcome) == _modelOutcome(m.t, m.one, m.two),
                "timeout view differs from the raw-clock model"
            );

            // Clock shape by phase.
            uint64 s1 = _st(clockOf(t, m.one));
            uint64 s2 = _st(clockOf(t, m.two));
            if (s.currentHeight != 0) {
                require((s1 != 0) != (s2 != 0), "bisection: one running clock");
                bool oneRuns = Match.responder(_heightOf(m.t), s.currentHeight)
                    == ITournament.CommitmentSide.ONE;
                require(oneRuns == (s1 != 0), "running clock is not revealer");
            } else if (_isLeafLevel(m.t)) {
                require(s1 != 0 && s1 == s2, "sealed leaf: two running clocks");
            } else {
                require(s1 == 0 && s2 == 0, "sealed inner: two paused clocks");
            }

            // A commitment is in one live match at most, and not dangling.
            (Tree.Node dangling_,,) = t.observedTopology();
            require(
                !dangling_.eq(m.one) && !dangling_.eq(m.two),
                "matched commitment is dangling"
            );
            for (uint256 j = i + 1; j < live.length; ++j) {
                if (live[j].t != m.t) {
                    continue;
                }
                require(
                    !live[j].one.eq(m.one) && !live[j].one.eq(m.two)
                        && !live[j].two.eq(m.one) && !live[j].two.eq(m.two),
                    "commitment in two live matches"
                );
            }
        }
    }

    function _checkKids() internal {
        for (uint256 i; i < kids.length; ++i) {
            Kid storage kid = kids[i];
            ITournament.InnerResultView memory r = abi.decode(
                _view(
                    address(kid.t), abi.encodeCall(ITournament.innerResult, ())
                ),
                (ITournament.InnerResultView)
            );
            uint8 d = uint8(r.disposition);
            require(d >= kid.lastDisposition, "child disposition went back");
            if (r.disposition == ITournament.InnerTournamentDisposition.WINNER)
            {
                require(
                    r.parentCommitment.eq(kid.pOne)
                        || r.parentCommitment.eq(kid.pTwo),
                    "child winner maps outside the parent match"
                );
                uint64 carried = Time.Duration.unwrap(r.pausedAllowance);
                require(carried > 0, "zero carried allowance");
                if (kid.lastDisposition == 1) {
                    require(
                        r.parentCommitment.eq(kid.lastParent),
                        "child winner changed"
                    );
                    require(carried <= kid.lastCarried, "carried grew");
                }
                kid.lastParent = r.parentCommitment;
                kid.lastCarried = carried;
            }
            kid.lastDisposition = d;

            Match.Id memory origin = kid.parent.observedOriginatingMatch(kid.t);
            if (_isLive(address(kid.parent), kid.pOne, kid.pTwo)) {
                require(
                    origin.commitmentOne.eq(kid.pOne)
                        && origin.commitmentTwo.eq(kid.pTwo),
                    "live sealed match lost its child"
                );
                Match.State memory s = kid.parent.getMatch(origin.hashFromId());
                require(s.isInit && s.currentHeight == 0, "parent not sealed");
                // The frozen pair: nothing but the child can end it.
                require(
                    _modelOutcome(address(kid.parent), kid.pOne, kid.pTwo)
                        == NONE,
                    "sealed inner match has a timeout arm"
                );
                // While the pair is sealed its tournament cannot finish.
                require(
                    !kid.parent.isFinished(),
                    "tournament finished over a sealed match"
                );
            } else {
                require(
                    origin.commitmentOne.isZero()
                        && origin.commitmentTwo.isZero(),
                    "child link outlived its match"
                );
            }
        }
    }

    function _checkRoot() internal {
        ITournament.TournamentStandingView memory s = root.tournamentStanding();
        bool terminal = s.standing == ITournament.TournamentStanding.ROOT_WINNER
            || s.standing == ITournament.TournamentStanding.ROOT_FAILED;
        if (terminal) {
            bytes32 h = keccak256(abi.encode(s));
            if (rootDecided) {
                require(h == rootDecisionHash, "decided root standing changed");
            } else {
                rootDecided = true;
                rootDecisionHash = h;
                // No live match anywhere the root's descendants reach.
                require(live.length == 0, "root decided over a live match");
                if (s.standing == ITournament.TournamentStanding.ROOT_WINNER) {
                    uint256 c = _claimOf(address(root), s.candidate);
                    require(
                        Machine.Hash.unwrap(s.finalState)
                            == Machine.Hash
                                .unwrap(_treeIn(address(root), c).finalState()),
                        "root result is not the winner's last leaf"
                    );
                }
            }
        } else {
            require(!rootDecided, "decided root became undecided");
        }
    }

    function _check() internal {
        _checkTournament(root);
        _checkStanding(root);
        for (uint256 i; i < kids.length; ++i) {
            _checkTournament(kids[i].t);
            _checkStanding(kids[i].t);
        }
        _checkMatches();
        _checkKids();
        _checkRoot();
    }

    //
    // Walk
    //

    function step(uint256 r) external {
        require(msg.sender == address(this), "walk: self only");
        uint256 kind = r % 100;
        uint256 x = r >> 8;
        _beforeStep(x);
        bool rootOpen = !root.isClosed();
        bool hasLive = live.length != 0;
        bool hasKids = kids.length != 0;
        if (stepIndex++ < openingJoins && rootOpen) {
            _joinRoot(x);
        } else if (kind < 6) {
            _roll(x);
        } else if (kind < 16) {
            _rollToBoundary(x);
        } else if (kind < 28) {
            // A quarter of the joins still go to a closed root.
            if (rootOpen || (x >> 190) % 4 == 0) {
                _joinRoot(x);
            } else if (hasLive) {
                _matchAction(x);
            } else {
                _rollToBoundary(x);
            }
        } else if (kind < 42) {
            if (hasKids) {
                _joinKid(x);
            } else if (rootOpen) {
                _joinRoot(x);
            } else {
                _roll(x);
            }
        } else if (kind < 82) {
            if (hasLive) {
                _matchAction(x);
            } else if (rootOpen) {
                _joinRoot(x);
            } else {
                _rollToBoundary(x);
            }
        } else if (kind < 92) {
            if (hasKids) {
                _kidAction(x);
            } else {
                _roll(x);
            }
        } else if (kind < 95) {
            _recover(x);
        } else {
            _garbage(x);
        }
        _check();
        _afterStep();
    }

    //
    // Hooks
    //

    function _newStateTransition() internal virtual returns (IStateTransition) {
        return new ProofSelectedStateTransition();
    }

    /// @return g Response budget, t commitment budget, a root allowance
    function _chooseBudgets(uint256 seed)
        internal
        virtual
        returns (uint64 g, uint64 t, uint64 a)
    {
        g = uint64((seed >> 4) % 4);
        t = 1 + uint64((seed >> 6) % 6);
        a = 40 + uint64((seed >> 9) % 120);
    }

    /// @dev The only way the walk moves time.
    function _advanceTo(uint256 target) internal virtual {
        if (target > vm.getBlockNumber()) {
            vm.roll(target);
        }
    }

    /// @dev Whether the state transition accepts `w`'s leaf `d` after the
    /// agree state of trees `a` and `w`. The default stub accepts any leaf.
    function _proofAccepted(
        address,
        SmallFullTree.Data memory,
        SmallFullTree.Data memory,
        uint256
    ) internal view virtual returns (bool) {
        return true;
    }

    function _kidRegistered(uint256) internal virtual {}

    function _beforeStep(uint256) internal virtual {}

    function _afterStep() internal virtual {}

    function _run(uint256 seed) internal {
        _init(seed);
        uint256 afterDecision;
        for (uint256 i; i < STEPS; ++i) {
            this.step(uint256(keccak256(abi.encode(seed, i))));
            if (rootDecided && ++afterDecision > STEPS_AFTER_DECISION) {
                break;
            }
        }
    }
}

/// @dev Legal and rejected operation sequences against a model written from
/// the code, on real clones: two or three levels, heights one to three in
/// mixed parity, and eight claim tables that include same-root impostors at
/// the leaf and middle levels.
///
/// It establishes that legality, the three observer views, clock effects,
/// child linkage, root finality and balances agree with that model along
/// every walk. It does not establish that the model is the intended
/// protocol; the 2026-11-10 contracts audit made the agreement informative
/// with 21 single-line mutants of `src`, of which 20 fail the walk and the
/// last only drops an assert. The model reads raw clocks and topology from
/// production storage, the leaf step is a stub, recipients are plain
/// accounts, and geometry and population are small. Honest survival under
/// this adversary is DefendedWalk.t.sol's.
///
/// Deeper campaign, one run being one walk:
///   FOUNDRY_FUZZ_RUNS=10000 FOUNDRY_FUZZ_SEED=0x5172756374757265 forge test \
///     --match-contract AdversarialWalkTest --match-test testFuzz
/// The audit recorded 10,001 passing runs under that seed, about 43 calls a
/// run.
contract AdversarialWalkTest is AdversarialWalkBase {
    using TournamentInspector for ITournament;
    using TournamentInspector for InspectableTournament;

    uint256 constant SAMPLE_SEEDS = 16;

    function testFuzzAdversarialWalk(uint256 seed) public {
        _run(seed);
    }

    /// @dev The walk is not vacuous: over a fixed set of seeds it reaches
    /// every transition class at two and at three levels and decides roots.
    function testSampleReachesEveryTransitionClass() public {
        uint256[16] memory total;
        uint256[11] memory okT;
        uint256[11] memory rvT;
        uint256 decided;
        uint256 winners;
        for (uint256 seed = 1; seed <= SAMPLE_SEEDS; ++seed) {
            uint256 snap = vm.snapshotState();
            _run(uint256(keccak256(abi.encode("coverage", seed))));
            total[0] += nJoins;
            total[1] += nAdvances;
            total[2] += nInnerSeals;
            total[3] += nLeafSeals;
            total[4] += nStepWins;
            total[5] += nTimeoutWins;
            total[6] += nTimeoutEliminations;
            total[7] += nPropagations;
            total[8] += nChildEliminations;
            total[9] += nRecoveries;
            total[10] += nDeepKids;
            total[11] += nTypedReverts;
            total[12] += nCalls;
            total[13] += levels == 3 ? 1 : 0;
            total[14] += nDeepLeafSeals;
            total[15] += nDeepPropagations;
            for (uint256 i; i < labels.length; ++i) {
                okT[i] += okBy[labels[i]];
                rvT[i] += revertBy[labels[i]];
            }
            if (rootDecided) {
                ++decided;
                if (
                    root.tournamentStanding().standing
                        == ITournament.TournamentStanding.ROOT_WINNER
                ) {
                    ++winners;
                }
            }
            vm.revertToState(snap);
        }
        for (uint256 i; i < labels.length; ++i) {
            emit log_named_uint(string.concat(labels[i], " ok"), okT[i]);
            emit log_named_uint(string.concat(labels[i], " revert"), rvT[i]);
        }
        emit log_named_uint("runs with three levels", total[13]);
        emit log_named_uint("calls", total[12]);
        emit log_named_uint("typed reverts", total[11]);
        emit log_named_uint("joins", total[0]);
        emit log_named_uint("advances", total[1]);
        emit log_named_uint("inner seals (children)", total[2]);
        emit log_named_uint("grandchildren (level 2 of 3)", total[10]);
        emit log_named_uint("leaf seals at level 2 of 3", total[14]);
        emit log_named_uint("propagations into a middle level", total[15]);
        emit log_named_uint("leaf seals", total[3]);
        emit log_named_uint("step wins", total[4]);
        emit log_named_uint("timeout wins", total[5]);
        emit log_named_uint("timeout double eliminations", total[6]);
        emit log_named_uint("child propagations", total[7]);
        emit log_named_uint("child eliminations", total[8]);
        emit log_named_uint("bond recoveries", total[9]);
        emit log_named_uint("decided roots", decided);
        emit log_named_uint("root winners", winners);
        for (uint256 i; i < 11; ++i) {
            assertGt(total[i], 0, "walk never reached a transition class");
        }
        assertGt(decided, 0, "walk never decided a root");
    }
}
