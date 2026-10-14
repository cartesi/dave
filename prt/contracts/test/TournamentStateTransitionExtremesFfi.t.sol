// Copyright Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.22;

import {Hashes} from "@openzeppelin-contracts-5.5.0/utils/cryptography/Hashes.sol";
import {console} from "forge-std-1.9.6/src/console.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "./Util.sol";

/// At most one epoch input, a single 32-byte Merkle leaf; every other index
/// is absent and answers the zero root.
contract OneInputProvider is IDataProvider {
    bool private immutable PRESENT;
    uint256 private immutable INDEX;
    bytes32 private immutable WORD;

    error UnexpectedInput(uint256 index, bytes input);

    constructor(bool present, uint256 index, bytes32 word) {
        PRESENT = present;
        INDEX = index;
        WORD = word;
    }

    function provideMerkleRootOfInput(uint256 index, bytes calldata input)
        external
        view
        returns (bytes32)
    {
        if (!PRESENT || index != INDEX) {
            return bytes32(0);
        }
        require(
            input.length == 32 && bytes32(input) == WORD,
            UnexpectedInput(index, input)
        );
        return keccak256(input);
    }
}

/// A commitment tree of uniform background leaves with a few overrides.
/// Only the leaves the dispute opens need real machine states; the contract
/// checks nothing else.
library SparseTree {
    struct T {
        uint64 height;
        bytes32[] uniform; // uniform[k]: a height-k subtree of background
        uint256[] positions;
        bytes32[] values;
    }

    function create(
        uint64 height,
        bytes32 background,
        uint256[] memory positions,
        bytes32[] memory values
    ) internal pure returns (T memory t) {
        t.height = height;
        t.uniform = new bytes32[](height + 1);
        t.uniform[0] = background;
        for (uint256 k = 1; k <= height; ++k) {
            t.uniform[k] =
                Hashes.efficientKeccak256(t.uniform[k - 1], t.uniform[k - 1]);
        }
        t.positions = positions;
        t.values = values;
    }

    function node(T memory t, uint64 level, uint256 index)
        internal
        pure
        returns (bytes32)
    {
        uint256 lo = index << level;
        uint256 hi = lo + (uint256(1) << level);
        bool touched;
        for (uint256 i; i < t.positions.length; ++i) {
            if (t.positions[i] >= lo && t.positions[i] < hi) {
                if (level == 0) return t.values[i];
                touched = true;
            }
        }
        if (!touched) return t.uniform[level];
        // Scratch-space hashing: recursion must not grow memory.
        return Hashes.efficientKeccak256(
            node(t, level - 1, 2 * index), node(t, level - 1, 2 * index + 1)
        );
    }

    function root(T memory t) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(node(t, t.height, 0));
    }

    function child(T memory t, uint256 side) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(node(t, t.height - 1, side));
    }

    function proof(T memory t, uint256 position)
        internal
        pure
        returns (bytes32[] memory siblings)
    {
        siblings = new bytes32[](t.height);
        for (uint64 i; i < t.height; ++i) {
            siblings[i] = node(t, i, (position >> i) ^ 1);
        }
    }
}

/// Composes Tournament.winLeafMatch with the real CartesiStateTransition and
/// real Lua proofs at the coordinate extremes of docs/computation-hash.md.
/// Fixtures are orphan leaf clones from the permissionless instantiateInner,
/// in the canonical (height 38, even) and historical three-level (height 27,
/// odd) leaf geometries, each sealed with the honest side as commitment one
/// and as commitment two.
contract TournamentStateTransitionExtremesFfiTest is Util {
    using Tree for Tree.Node;
    using Match for Match.Id;
    using SparseTree for SparseTree.T;

    enum Branch {
        OPENING,
        CLOSING,
        PLAIN
    }

    // The meta-cycle layout as the doc states it, held to the step's
    // constants in testDocLayoutMatchesStepConstants.
    uint256 constant LOG2_UCYCLES = 20;
    uint256 constant LOG2_BIG_CYCLES = 48;
    uint256 constant LOG2_INPUTS = 24;
    uint256 constant LOG2_WINDOW = LOG2_UCYCLES + LOG2_BIG_CYCLES;
    uint256 constant LOG2_EPOCH = LOG2_WINDOW + LOG2_INPUTS;
    uint256 constant UCYCLE_MASK = (uint256(1) << LOG2_UCYCLES) - 1;
    uint256 constant BIG_CYCLE_MASK = (uint256(1) << LOG2_BIG_CYCLES) - 1;
    uint256 constant LAST_COUNTER = (uint256(1) << LOG2_EPOCH) - 1;
    uint256 constant LAST_INPUT_INDEX = (uint256(1) << LOG2_INPUTS) - 1;
    uint256 constant LAST_OPENING = LAST_INPUT_INDEX << LOG2_WINDOW;

    bytes32 constant BACKGROUND = keccak256("audit.background");
    bytes32 constant JUNK = keccak256("audit.junk");
    bytes32 constant HONEST_FINAL = keccak256("audit.honest-final");
    bytes32 constant DISHONEST_FINAL = keccak256("audit.dishonest-final");
    Time.Duration constant ALLOWANCE = Time.Duration.wrap(1 << 20);

    struct Geometry {
        string name;
        MultiLevelTournamentFactory factory;
        CartesiStateTransition adapter;
        uint64 leafLevel;
        uint64 height;
    }

    /// One proven leaf: the real states around it and its epoch's inputs.
    struct Vector {
        string name;
        uint256 startCycle;
        uint256 position;
        bytes32 initialHash;
        bytes32 agree;
        bytes32 next;
        bytes proof;
        Branch branch;
        bool inputPresent;
        uint256 inputIndex;
        bytes32 inputWord;
    }

    function testDocLayoutMatchesStepConstants() public pure {
        assertEq(
            LOG2_UCYCLES,
            EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
        );
        assertEq(
            LOG2_BIG_CYCLES,
            EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
        );
        assertEq(
            LOG2_INPUTS,
            EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
        );
    }

    //
    // (a) The epoch's last counter, 2^92 - 1: closing step plus reset.
    //

    function testEpochLastCounterCanonical() public {
        _epochLastCounter(_canonical());
    }

    function testEpochLastCounterHistorical() public {
        _epochLastCounter(_historical());
    }

    function _epochLastCounter(Geometry memory g) private {
        Vector memory v;
        v.name = "epoch last counter";
        v.position = (uint256(1) << g.height) - 1;
        v.startCycle = (uint256(1) << LOG2_EPOCH) - (uint256(1) << g.height);
        assertEq(v.startCycle + v.position, LAST_COUNTER);
        (v.initialHash,,) = _proofsLua(v.startCycle, 0);
        (v.agree, v.next, v.proof) = _proofsLua(LAST_COUNTER, 0);
        // The agree leaf is the post-state of transition 2^92 - 2.
        _requirePostStateOf(LAST_COUNTER - 1, 0, v.agree);
        v.branch = Branch.CLOSING;
        _runBothOrders(g, v);
    }

    //
    // (b) The last input slot's opening, (2^24 - 1) << 68. Every leaf tile
    // divides 2^68, so an opening is always a child's position zero.
    //

    function testLastInputOpeningWithoutInputCanonical() public {
        _lastInputOpeningWithoutInput(_canonical());
    }

    function testLastInputOpeningWithoutInputHistorical() public {
        _lastInputOpeningWithoutInput(_historical());
    }

    function _lastInputOpeningWithoutInput(Geometry memory g) private {
        Vector memory v;
        v.name = "last opening, no input";
        v.startCycle = LAST_OPENING;
        (v.agree, v.next, v.proof) = _proofsLua(LAST_OPENING, 0);
        v.initialHash = v.agree;
        _requirePostStateOf(LAST_OPENING - 1, 0, v.initialHash);
        // Absent input: the DA prefix is a zero length and nothing else.
        for (uint256 i; i < 8; ++i) {
            assertEq(uint8(v.proof[i]), 0);
        }
        v.branch = Branch.OPENING;
        _runBothOrders(g, v);
    }

    function testLastInputOpeningWithInputCanonical() public {
        _lastInputOpeningWithInput(_canonical());
    }

    function testLastInputOpeningWithInputHistorical() public {
        _lastInputOpeningWithInput(_historical());
    }

    /// The agree state is the template's, not the state after 2^24 - 1 real
    /// inputs: the adapter and Tournament see only the agree state, the
    /// counter, the proof and the provider, so a sparse epoch drives the same
    /// path.
    function _lastInputOpeningWithInput(Geometry memory g) private {
        Vector memory v;
        v.name = "last opening, with input";
        v.startCycle = LAST_OPENING;
        v.inputPresent = true;
        v.inputIndex = LAST_INPUT_INDEX;
        v.inputWord = bytes32(LAST_INPUT_INDEX);
        (v.agree, v.next, v.proof) =
            _sparseInputLua(LAST_OPENING, LAST_INPUT_INDEX);
        v.initialHash = v.agree;
        // The DA prefix carries the 32-byte input.
        assertEq(_readUint(v.proof, 0, 8), 32);
        assertEq(bytes32(_readUint(v.proof, 8, 32)), v.inputWord);
        (, bytes32 idle,) = _proofsLua(LAST_OPENING, 0);
        assertNotEq(v.next, idle, "delivery must change the post-state");
        v.branch = Branch.OPENING;
        _runBothOrders(g, v);
    }

    //
    // (c) Position zero at a nonzero start that is not an opening: the plain
    // step, with initialHash as the agree state. The yield image spends
    // 702302 big cycles on input 0, so the second tile of window 0 is mid-run
    // in both geometries.
    //

    function testPositionZeroPlainStepCanonical() public {
        _positionZeroPlainStep(_canonical());
    }

    function testPositionZeroPlainStepHistorical() public {
        _positionZeroPlainStep(_historical());
    }

    function _positionZeroPlainStep(Geometry memory g) private {
        Vector memory v;
        v.name = "position zero, plain";
        v.startCycle = uint256(1) << g.height;
        v.inputPresent = true;
        (v.agree, v.next, v.proof) = _proofsLua(v.startCycle, 1);
        v.initialHash = v.agree;
        _requirePostStateOf(v.startCycle - 1, 1, v.initialHash);
        assertNotEq(v.agree, v.next, "the machine is mid-input");
        v.branch = Branch.PLAIN;
        _runBothOrders(g, v);
    }

    //
    // (d) The last position of a child: the agree leaf is the child's own
    // second-to-last leaf and the proven leaf is its final state.
    //

    function testChildLastPositionCanonical() public {
        _childLastPosition(_canonical());
    }

    function testChildLastPositionHistorical() public {
        _childLastPosition(_historical());
    }

    function _childLastPosition(Geometry memory g) private {
        Vector memory v;
        v.name = "child last position";
        v.startCycle = uint256(1) << g.height;
        v.position = (uint256(1) << g.height) - 1;
        v.inputPresent = true;
        uint256 counter = v.startCycle + v.position;
        (v.initialHash,,) = _proofsLua(v.startCycle, 1);
        (v.agree, v.next, v.proof) = _proofsLua(counter, 1);
        _requirePostStateOf(counter - 1, 1, v.agree);
        v.branch = Branch.CLOSING;
        _runBothOrders(g, v);
    }

    //
    // Extra: the rejected input's closing, which substitutes the revert root,
    // at an interior position of its tile.
    //

    function testRejectionClosingInteriorCanonical() public {
        _rejectionClosingInterior(_canonical());
    }

    function testRejectionClosingInteriorHistorical() public {
        _rejectionClosingInterior(_historical());
    }

    function _rejectionClosingInterior(Geometry memory g) private {
        Vector memory v;
        v.name = "rejection closing";
        v.inputPresent = true;
        uint256 counter;
        (counter, v.agree, v.next, v.proof) =
            _vectorLua("first-input-rejection-closing");
        v.startCycle = counter & ~((uint256(1) << g.height) - 1);
        v.position = counter - v.startCycle;
        assertLt(v.position, (uint256(1) << g.height) - 1, "interior");
        (v.initialHash,,) = _proofsLua(v.startCycle, 1);
        _requirePostStateOf(counter - 1, 1, v.agree);
        // The revert root is the template's: input 0 is rejected.
        (bytes32 template,,) = _proofsLua(0, 0);
        assertEq(v.next, template);
        v.branch = Branch.CLOSING;
        _runBothOrders(g, v);
    }

    //
    // Runner
    //

    function _runBothOrders(Geometry memory g, Vector memory v) private {
        _run(g, v, true);
        _run(g, v, false);
    }

    /// Per-run state, kept in memory to stay clear of via-IR stack limits.
    struct Run {
        uint256 counter;
        bool honestFirst;
        bytes32 honestFinal;
        SparseTree.T honest;
        SparseTree.T one;
        SparseTree.T two;
        IDataProvider provider;
        ITournament t;
        Match.Id id;
        uint256 closesAt;
    }

    function _run(Geometry memory g, Vector memory v, bool honestFirst)
        private
    {
        Run memory r = _start(g, v, honestFirst);
        assertEq(_bisectAndSeal(r.t, r.id, r.one, r.two, v.agree), v.position);
        _checkSealed(r, v);
        _win(g, r, v);
        _requireOnlyBranchAccepts(v, r.counter);
        _checkResolved(r);
        _log(g, v, r);
    }

    function _start(Geometry memory g, Vector memory v, bool honestFirst)
        private
        returns (Run memory r)
    {
        // toCycle at stride zero, computed here independently.
        r.counter = v.startCycle + v.position;
        r.honestFirst = honestFirst;
        uint256 last = (uint256(1) << g.height) - 1;
        assertLe(v.position, last);
        assertEq(uint8(_branchOf(r.counter)), uint8(v.branch), "doc branch");

        r.honestFinal = v.position == last ? v.next : HONEST_FINAL;
        bytes32 dishonestFinal = v.position == last ? JUNK : DISHONEST_FINAL;
        r.honest = _tree(g.height, v, v.next, r.honestFinal);
        SparseTree.T memory dishonest = _tree(g.height, v, JUNK, dishonestFinal);

        // Fresh per run, so call expectations cannot match another run.
        r.provider =
            new OneInputProvider(v.inputPresent, v.inputIndex, v.inputWord);

        ITournament.TournamentDescriptor memory d;
        (r.t, d) = g.factory
            .instantiateInner(
                Machine.Hash.wrap(v.initialHash),
                r.honest.root(),
                Machine.Hash.wrap(r.honestFinal),
                dishonest.root(),
                Machine.Hash.wrap(dishonestFinal),
                ALLOWANCE,
                v.startCycle,
                g.leafLevel,
                r.provider
            );
        assertEq(d.baseCycle, v.startCycle);
        assertEq(d.log2Stride, 0);
        assertEq(d.height, g.height);
        assertEq(uint8(d.kind), uint8(ITournament.TournamentKind.LEAF));
        r.closesAt = uint256(Time.Instant.unwrap(d.startInstant))
            + Time.Duration.unwrap(d.allowance);

        r.one = honestFirst ? r.honest : dishonest;
        r.two = honestFirst ? dishonest : r.honest;
        _join(r.t, r.one, honestFirst ? r.honestFinal : dishonestFinal);
        _join(r.t, r.two, honestFirst ? dishonestFinal : r.honestFinal);
        r.id = Match.Id(r.one.root(), r.two.root());
    }

    function _checkSealed(Run memory r, Vector memory v) private view {
        (Match.Phase phase, ITournament.SealedMatchView memory s) =
            r.t.sealedMatch(r.id.hashFromId());
        assertEq(uint8(phase), uint8(Match.Phase.SEALED));
        assertEq(s.divergencePosition, v.position);
        assertEq(s.divergenceCycle, r.counter);
        assertEq(Machine.Hash.unwrap(s.agreeState), v.agree);
        assertEq(
            Machine.Hash.unwrap(s.finalStateOne), r.honestFirst ? v.next : JUNK
        );
        assertEq(
            Machine.Hash.unwrap(s.finalStateTwo), r.honestFirst ? JUNK : v.next
        );
    }

    function _win(Geometry memory g, Run memory r, Vector memory v) private {
        // What Tournament hands the adapter, byte for byte.
        vm.expectCall(
            address(g.adapter),
            abi.encodeCall(
                IStateTransition.transitionState,
                (v.agree, r.counter, v.proof, r.provider)
            ),
            1
        );
        // Only the opening branch consults the provider.
        if (v.branch == Branch.OPENING) {
            vm.expectCall(
                address(r.provider),
                abi.encodeCall(
                    IDataProvider.provideMerkleRootOfInput,
                    (r.counter >> LOG2_WINDOW, _expectedInput(v, r.counter))
                ),
                1
            );
        } else {
            vm.expectCall(
                address(r.provider),
                abi.encodeWithSelector(
                    IDataProvider.provideMerkleRootOfInput.selector
                ),
                0
            );
        }
        r.t.winLeafMatch(r.id, r.honest.child(0), r.honest.child(1), v.proof);

        ITournament.TournamentStandingView memory standing =
            r.t.tournamentStanding();
        assertEq(
            uint8(standing.standing),
            uint8(ITournament.TournamentStanding.AWAITING_CLOSURE)
        );
        assertTrue(standing.candidate.eq(r.honest.root()));
    }

    /// Past closure the orphan resolves to the honest final state and
    /// attributes it to the honest contested commitment.
    function _checkResolved(Run memory r) private {
        vm.roll(r.closesAt);
        ITournament.TournamentStandingView memory standing =
            r.t.tournamentStanding();
        assertEq(
            uint8(standing.standing),
            uint8(ITournament.TournamentStanding.INNER_WINNER)
        );
        assertTrue(standing.candidate.eq(r.honest.root()));
        assertEq(Machine.Hash.unwrap(standing.finalState), r.honestFinal);
        assertTrue(standing.parentCommitment.eq(r.honest.root()));
    }

    function _log(Geometry memory g, Vector memory v, Run memory r)
        private
        pure
    {
        console.log(
            string.concat(
                g.name,
                " / ",
                v.name,
                r.honestFirst ? " / honest=one" : " / honest=two"
            )
        );
        console.log("  startCycle  ", v.startCycle);
        console.log("  position    ", v.position);
        console.log("  counter     ", r.counter);
        console.log("  branch      ", _branchName(v.branch));
        console.log("  proof bytes ", v.proof.length);
    }

    /// The adapter picks its body from the counter alone. Representatives of
    /// the three classes in the counter's own input window show that only
    /// the expected body consumes this proof, so the body that ran inside
    /// winLeafMatch was that one. A separate adapter and provider keep these
    /// probes out of the call expectations above.
    function _requireOnlyBranchAccepts(Vector memory v, uint256 counter)
        private
    {
        CartesiStateTransition probe = new CartesiStateTransition();
        IDataProvider provider =
            new OneInputProvider(v.inputPresent, v.inputIndex, v.inputWord);
        uint256 plain = v.branch == Branch.PLAIN
            ? counter
            : (v.branch == Branch.OPENING ? counter + 1 : counter - 1);
        _probe(
            probe,
            provider,
            v,
            counter & ~((uint256(1) << LOG2_WINDOW) - 1),
            Branch.OPENING
        );
        _probe(probe, provider, v, counter | UCYCLE_MASK, Branch.CLOSING);
        _probe(probe, provider, v, plain, Branch.PLAIN);
    }

    /// `rep` is a counter of class `b`; for the expected class it is the
    /// counter itself, by construction of the representatives.
    function _probe(
        CartesiStateTransition probe,
        IDataProvider provider,
        Vector memory v,
        uint256 rep,
        Branch b
    ) private {
        assertEq(uint8(_branchOf(rep)), uint8(b));
        if (b == v.branch) {
            assertEq(rep, v.startCycle + v.position);
            assertEq(
                probe.transitionState(v.agree, rep, v.proof, provider), v.next
            );
        } else {
            vm.expectRevert();
            probe.transitionState(v.agree, rep, v.proof, provider);
        }
    }

    function _bisectAndSeal(
        ITournament t,
        Match.Id memory id,
        SparseTree.T memory one,
        SparseTree.T memory two,
        bytes32 agree
    ) private returns (uint256) {
        uint256 pos;
        bool oneReveals = true;
        for (uint64 h = one.height; h > 1; --h) {
            pos = oneReveals
                ? _advance(t, id, one, two, h, pos)
                : _advance(t, id, two, one, h, pos);
            oneReveals = !oneReveals;
        }
        // Height parity decides the final revealer, as in Match.sealDivergence.
        return oneReveals
            ? _seal(t, id, one, two, pos, agree)
            : _seal(t, id, two, one, pos, agree);
    }

    /// The revealer `r` opens its frontier parent at height `h` and then its
    /// first child that differs from the waiting side `w`.
    function _advance(
        ITournament t,
        Match.Id memory id,
        SparseTree.T memory r,
        SparseTree.T memory w,
        uint64 h,
        uint256 pos
    ) private returns (uint256) {
        uint256 parent = pos >> h;
        uint256 chosen = 2 * parent;
        bytes32 left = r.node(h - 1, chosen);
        if (left == w.node(h - 1, chosen)) {
            chosen++;
            pos += uint256(1) << (h - 1);
        }
        t.advanceMatch(
            id,
            Tree.Node.wrap(left),
            Tree.Node.wrap(r.node(h - 1, 2 * parent + 1)),
            Tree.Node.wrap(r.node(h - 2, 2 * chosen)),
            Tree.Node.wrap(r.node(h - 2, 2 * chosen + 1))
        );
        return pos;
    }

    function _seal(
        ITournament t,
        Match.Id memory id,
        SparseTree.T memory sealer,
        SparseTree.T memory waiter,
        uint256 pos,
        bytes32 agree
    ) private returns (uint256 divergence) {
        bytes32 leftLeaf = sealer.node(0, pos);
        divergence = leftLeaf != waiter.node(0, pos) ? pos : pos + 1;
        bytes32[] memory agreeProof =
            divergence == 0 ? new bytes32[](0) : sealer.proof(divergence - 1);
        t.sealLeafMatch(
            id,
            Tree.Node.wrap(leftLeaf),
            Tree.Node.wrap(sealer.node(0, pos + 1)),
            Machine.Hash.wrap(agree),
            agreeProof
        );
    }

    function _join(ITournament t, SparseTree.T memory tree, bytes32 finalState)
        private
    {
        uint256 last = (uint256(1) << tree.height) - 1;
        t.joinTournament{value: t.bondValue()}(
            Machine.Hash.wrap(finalState),
            tree.proof(last),
            tree.child(0),
            tree.child(1)
        );
    }

    /// Leaves: p - 1 is the real agree state, p the side's divergent leaf,
    /// and the last leaf the side's final state.
    function _tree(
        uint64 height,
        Vector memory v,
        bytes32 divergent,
        bytes32 finalLeaf
    ) private pure returns (SparseTree.T memory) {
        uint256 last = (uint256(1) << height) - 1;
        uint256 n = 1 + (v.position > 0 ? 1 : 0) + (v.position < last ? 1 : 0);
        uint256[] memory positions = new uint256[](n);
        bytes32[] memory values = new bytes32[](n);
        uint256 k;
        positions[k] = v.position;
        values[k++] = divergent;
        if (v.position > 0) {
            positions[k] = v.position - 1;
            values[k++] = v.agree;
        }
        if (v.position < last) {
            positions[k] = last;
            values[k++] = finalLeaf;
        }
        return SparseTree.create(height, BACKGROUND, positions, values);
    }

    //
    // Expectations from the doc, not from the adapter
    //

    /// docs/computation-hash.md, "The leaf sequence": an input boundary has
    /// ucycle and big cycle zero; a big-step boundary has (m + 1) a multiple
    /// of 2^20; anything else is a single uarch step.
    function _branchOf(uint256 counter) private pure returns (Branch) {
        uint256 ucycle = counter & UCYCLE_MASK;
        uint256 bigCycle = (counter >> LOG2_UCYCLES) & BIG_CYCLE_MASK;
        if (ucycle == 0 && bigCycle == 0) return Branch.OPENING;
        if (((counter + 1) & UCYCLE_MASK) == 0) return Branch.CLOSING;
        return Branch.PLAIN;
    }

    function _expectedInput(Vector memory v, uint256 counter)
        private
        pure
        returns (bytes memory)
    {
        if (v.inputPresent && v.inputIndex == counter >> LOG2_WINDOW) {
            return abi.encodePacked(v.inputWord);
        }
        return "";
    }

    function _branchName(Branch b) private pure returns (string memory) {
        if (b == Branch.OPENING) return "input opening";
        if (b == Branch.CLOSING) return "closing (step + reset)";
        return "plain step";
    }

    //
    // Geometries
    //

    function _canonical() private returns (Geometry memory g) {
        g.name = "canonical [38,0]/[54,38]";
        (g.factory, g.adapter) = Util.instantiateCanonicalTournamentFactory();
        g.leafLevel = 1;
        _readLeafLevel(g);
        assertEq(g.height, 38);
    }

    function _historical() private returns (Geometry memory g) {
        g.name = "historical [44,27,0]/[48,17,27]";
        (g.factory, g.adapter) =
            Util.instantiateHistoricalThreeLevelTournamentFactory();
        g.leafLevel = 2;
        _readLeafLevel(g);
        assertEq(g.height, 27);
    }

    function _readLeafLevel(Geometry memory g) private view {
        TournamentParameters memory p =
            g.factory.tournamentParameters(g.leafLevel);
        assertEq(p.levels, g.leafLevel + 1);
        assertEq(p.log2step, 0);
        assertEq(address(g.factory.stateTransition()), address(g.adapter));
        g.height = p.height;
    }

    //
    // Lua
    //

    /// The post-state of transition `counter` must be `state`.
    function _requirePostStateOf(uint256 counter, uint256 inputs, bytes32 state)
        private
    {
        (, bytes32 next,) = _proofsLua(counter, inputs);
        assertEq(next, state, "post-state of the previous transition");
    }

    function _proofsLua(uint256 counter, uint256 inputs)
        private
        returns (bytes32, bytes32, bytes memory)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "lua";
        cmd[1] = "test/step/proofs.lua";
        cmd[2] = vm.toString(counter);
        cmd[3] = vm.toString(inputs);
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        return abi.decode(vm.ffi(cmd), (bytes32, bytes32, bytes));
    }

    function _sparseInputLua(uint256 counter, uint256 index)
        private
        returns (bytes32, bytes32, bytes memory)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "lua";
        cmd[1] = "test/step/extreme_proofs.lua";
        cmd[2] = vm.toString(counter);
        cmd[3] = vm.toString(index);
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        return abi.decode(vm.ffi(cmd), (bytes32, bytes32, bytes));
    }

    function _vectorLua(string memory mode)
        private
        returns (uint256, bytes32, bytes32, bytes memory)
    {
        string[] memory cmd = new string[](3);
        cmd[0] = "lua";
        cmd[1] = "test/step/proofs.lua";
        cmd[2] = mode;
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        return abi.decode(vm.ffi(cmd), (uint256, bytes32, bytes32, bytes));
    }

    function _readUint(bytes memory data, uint256 offset, uint256 size)
        private
        pure
        returns (uint256 value)
    {
        for (uint256 i; i < size; ++i) {
            value = (value << 8) | uint8(data[offset + i]);
        }
    }
}
