// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {AccessLogs} from "step/src/AccessLogs.sol";
import {Buffer} from "step/src/Buffer.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {CanonicalTournamentParametersProvider} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFourLevelParametersProvider} from "test/fixtures/SmallFourLevelTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {SmallTwoLevelParametersProvider} from "test/fixtures/SmallTwoLevelTournament.sol";
import {TableTournamentParametersProvider} from "test/fixtures/TableTournamentParametersProvider.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Leaf-proof stub that checks what Tournament hands the adapter. A
/// view function cannot write, so in probe mode the revert payload is the
/// record; armed, it returns `post` only for the expected pair.
contract RecordingStateTransition is IStateTransition {
    error Observed(
        bytes32 machineState,
        uint256 counter,
        uint256 proofLength,
        address provider
    );
    error UnexpectedPair(
        bytes32 machineState,
        uint256 counter,
        bytes32 expectedState,
        uint256 expectedCounter
    );

    bool internal _probing;
    bytes32 internal _expectedState;
    uint256 internal _expectedCounter;
    bytes32 internal _post;

    function probe() external {
        _probing = true;
    }

    function arm(bytes32 expectedState, uint256 expectedCounter, bytes32 post)
        external
    {
        _probing = false;
        _expectedState = expectedState;
        _expectedCounter = expectedCounter;
        _post = post;
    }

    function transitionState(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs,
        IDataProvider provider
    ) external view override returns (bytes32) {
        if (_probing) {
            revert Observed(
                machineState, counter, proofs.length, address(provider)
            );
        }
        if (machineState != _expectedState || counter != _expectedCounter) {
            revert UnexpectedPair(
                machineState, counter, _expectedState, _expectedCounter
            );
        }
        return _post;
    }
}

/// @dev No input at `EXPECTED`; any other index reverts, so the adapter's
/// input-index derivation is observed through a full Tournament descent.
contract ExpectedIndexProvider is IDataProvider {
    error UnexpectedInputIndex(uint256 index, uint256 expected);

    uint256 internal immutable EXPECTED;

    constructor(uint256 expected) {
        EXPECTED = expected;
    }

    function provideMerkleRootOfInput(uint256 index, bytes calldata)
        external
        view
        override
        returns (bytes32)
    {
        if (index != EXPECTED) {
            revert UnexpectedInputIndex(index, EXPECTED);
        }
        return bytes32(0);
    }
}

/// @dev Exposes the adapter's internal coordinate constants.
contract CartesiStateTransitionExposer is CartesiStateTransition {
    function log2InputWindowSpan() external pure returns (uint64) {
        return LOG2_INPUT_WINDOW_SPAN;
    }

    function log2EpochRulerSpan() external pure returns (uint64) {
        return LOG2_EPOCH_RULER_SPAN;
    }

    function inputMask() external pure returns (uint256) {
        return INPUT_MASK;
    }

    function uarchCycleMask() external pure returns (uint256) {
        return UARCH_CYCLE_MASK;
    }

    function epochRulerSpan() external pure returns (uint256) {
        return EPOCH_RULER_SPAN;
    }
}

/// @dev Complete Merkle trees with piecewise-constant leaves, so the
/// canonical 54/38 geometry can be driven without materializing 2^54 leaves.
/// Piece k covers [starts[k], starts[k + 1]); starts[0] is zero.
library SparseTree {
    using Tree for Tree.Node;

    struct Data {
        uint64 height;
        uint256[] starts;
        bytes32[] values;
        // uniform[k][h]: root of 2^h copies of values[k]
        bytes32[][] uniform;
    }

    function build(
        uint64 height,
        uint256[] memory starts,
        bytes32[] memory values
    ) internal pure returns (Data memory t) {
        require(starts.length == values.length && starts[0] == 0, "sparse");
        t.height = height;
        t.starts = starts;
        t.values = values;
        t.uniform = new bytes32[][](values.length);
        for (uint256 k; k < values.length; ++k) {
            bytes32[] memory u = new bytes32[](height + 1);
            u[0] = values[k];
            for (uint64 h = 1; h <= height; ++h) {
                u[h] = Tree.Node
                    .unwrap(
                        Tree.Node.wrap(u[h - 1]).join(Tree.Node.wrap(u[h - 1]))
                    );
            }
            t.uniform[k] = u;
        }
    }

    function node(Data memory t, uint64 h, uint256 index)
        internal
        pure
        returns (Tree.Node)
    {
        uint256 lo = index << h;
        uint256 hi = lo + (uint256(1) << h);
        uint256 k = _pieceOf(t, lo);
        if (k + 1 == t.starts.length || t.starts[k + 1] >= hi) {
            return Tree.Node.wrap(t.uniform[k][h]);
        }
        return node(t, h - 1, 2 * index).join(node(t, h - 1, 2 * index + 1));
    }

    function root(Data memory t) internal pure returns (Tree.Node) {
        return node(t, t.height, 0);
    }

    function leaf(Data memory t, uint256 position)
        internal
        pure
        returns (Tree.Node)
    {
        return node(t, 0, position);
    }

    function children(Data memory t, uint64 h, uint256 index)
        internal
        pure
        returns (Tree.Node, Tree.Node)
    {
        return (node(t, h - 1, 2 * index), node(t, h - 1, 2 * index + 1));
    }

    function proof(Data memory t, uint256 position)
        internal
        pure
        returns (bytes32[] memory siblings)
    {
        siblings = new bytes32[](t.height);
        for (uint64 h; h < t.height; ++h) {
            siblings[h] = Tree.Node.unwrap(node(t, h, (position >> h) ^ 1));
        }
    }

    function lastPosition(Data memory t) internal pure returns (uint256) {
        return (uint256(1) << t.height) - 1;
    }

    function _pieceOf(Data memory t, uint256 position)
        private
        pure
        returns (uint256 k)
    {
        for (uint256 i = 1; i < t.starts.length; ++i) {
            if (t.starts[i] > position) break;
            k = i;
        }
    }
}

/// @dev Adapter composition (campaign dimension 12). Every other audit
/// reproduction proves leaves with ProofSelectedStateTransition, which ignores
/// (machineState, counter). This file checks the pair Tournament hands the
/// adapter in multi-level descents against a model taken from
/// docs/computation-hash.md, not from Commitment.toCycle:
///
/// - a fine computation has an implicit initial state s_-1 and leaves
///   s_0 .. s_{N-1}; transition m maps s_{m-1} to s_m;
/// - a level of stride 2^k samples the end of each stride: its leaf q, in a
///   tree starting at fine index S, is s_{S + (q + 1) 2^k - 1};
/// - a child refines one parent stride: it starts at the stride's first fine
///   index, its implicit state is the state before that index, and its last
///   leaf is the parent's divergent leaf.
///
/// A Sybil table agrees with the honest one before fine index m and differs
/// from m on. The leaf proof must receive machineState = s_{m-1} (the root's
/// initial hash at m = 0) and counter = m. Every test here is a refutation of
/// "Tournament hands the adapter a wrong pair": it passes on the current tree.
contract AdapterCompositionTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using SparseTree for SparseTree.Data;
    using TournamentInspector for ITournament;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;
    using Buffer for Buffer.Context;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 1000;

    uint256 constant LOG2_INPUT_WINDOW = 68;
    uint256 constant LOG2_UARCH_SPAN = 20;
    uint256 constant EPOCH_LOG2 = 92;

    // Piecewise values for the canonical drive. P is the agreed predecessor.
    bytes32 constant VA = bytes32(uint256(0xa1));
    bytes32 constant VP = bytes32(uint256(0xb2));
    bytes32 constant VQ = bytes32(uint256(0xc3));
    bytes32 constant VY = bytes32(uint256(0xd4));

    // Nonzero, so a provider the adapter sees is plumbed, not defaulted.
    IDataProvider constant DATA = IDataProvider(address(0xda7a));

    struct Case {
        bytes32[] honest;
        bytes32[] sybil;
        uint256 m;
        uint256 orient;
    }

    struct Fine {
        uint256[] starts;
        bytes32[] values;
    }

    struct SparseCase {
        Fine honest;
        Fine sybil;
        bytes32 initial;
        uint256 m;
        uint256 orient;
        // 0 stub, 1 real adapter proves, 2 real adapter reset probe
        uint8 mode;
        bytes proofs;
    }

    MultiLevelTournamentFactory internal _factory;
    RecordingStateTransition internal _stub;
    uint64[] internal _ls;
    uint64[] internal _hs;

    //
    // Small geometries: every fine leaf, both orientations per level
    //

    function testRefutedAdapterPairHarnessTwoLevel() public {
        _useProvider(new SmallTwoLevelParametersProvider(_g(), _t(), _a()));
        _sweep(_orients2());
    }

    function testRefutedAdapterPairOddChildHeight() public {
        _useTable2(1, 3);
        _sweep(_orients2());
        _useTable2(3, 1);
        _sweep(_orients2());
        _useTable2(1, 1);
        _sweep(_orients2());
    }

    function testRefutedAdapterPairMixedParityTwoLevel() public {
        _useTable2(2, 3);
        _sweep(_orients2());
        _useTable2(3, 2);
        _sweep(_orients2());
    }

    function testRefutedAdapterPairFourLevelFixture() public {
        _useProvider(new SmallFourLevelParametersProvider(_g(), _t(), _a()));
        _sweep(_orients4());
    }

    /// @dev Heights 2, 1, 2, 1 over strides 16, 8, 2, 1: both parities at
    /// every depth and a height-two leaf level.
    function testRefutedAdapterPairFourLevelMixedParity() public {
        uint64[] memory ls = new uint64[](4);
        uint64[] memory hs = new uint64[](4);
        (ls[0], hs[0]) = (4, 2);
        (ls[1], hs[1]) = (3, 1);
        (ls[2], hs[2]) = (1, 2);
        (ls[3], hs[3]) = (0, 1);
        _useProvider(_table(ls, hs));
        _sweep(_orients4());
    }

    function testRefutedAdapterPairSingleLevel() public {
        uint256[] memory orients = new uint256[](2);
        orients[1] = 1;
        for (uint64 h = 2; h <= 3; ++h) {
            uint64[] memory ls = new uint64[](1);
            uint64[] memory hs = new uint64[](1);
            hs[0] = h;
            _useProvider(_table(ls, hs));
            _sweep(orients);
        }
    }

    /// @dev Negative control: the stub rejects a pair one counter off, so a
    /// passing sweep is evidence, not a stub that accepts anything.
    function testStubRejectsShiftedCounter() public {
        _useProvider(new SmallTwoLevelParametersProvider(_g(), _t(), _a()));
        uint256 m = 6;
        bytes32[] memory honest = _honestFine(16);
        bytes32[] memory sybil = _sybilFine(honest, m);
        InspectableTournament root = newRoot(_factory);
        SmallFullTree.Data memory hR = _levelTree(honest, 0, 2, 2);
        SmallFullTree.Data memory sR = _levelTree(sybil, 0, 2, 2);
        join(root, hR, HONEST);
        join(root, sR, SYBIL);
        advanceToSeal(root, hR, sR);
        (InspectableTournament child,) = sealInner(root, hR, sR);
        SmallFullTree.Data memory hC = _levelTree(honest, 4, 0, 2);
        SmallFullTree.Data memory sC = _levelTree(sybil, 4, 0, 2);
        join(child, hC, HONEST);
        join(child, sC, SYBIL);
        advanceToSeal(child, hC, sC);
        sealLeaf(child, hC, sC);

        (Tree.Node l, Tree.Node r) = hC.children(2, 0);
        _stub.arm(honest[m - 1], m + 1, honest[m]);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecordingStateTransition.UnexpectedPair.selector,
                honest[m - 1],
                m,
                honest[m - 1],
                m + 1
            )
        );
        child.winLeafMatch(matchId(hC, sC), l, r, hex"00");
    }

    //
    // Canonical geometry [38, 0] / [54, 38]
    //

    /// @dev The canonical table through Tournament, at the boundary counters
    /// the adapter's shape predicates distinguish.
    function testRefutedAdapterPairCanonicalBoundaries() public {
        _factory = new MultiLevelTournamentFactory(
            new InspectableTournament(), _canonicalProvider(), _newStub()
        );
        uint256[] memory ms = _canonicalCounters();
        for (uint256 i; i < ms.length; ++i) {
            for (uint256 orient; orient < 4; ++orient) {
                this.runSparseCase(_stubCase(ms[i], orient));
            }
        }
    }

    /// @dev The real adapter composed with the canonical table, with the
    /// identity uarch step (uarch cycle at its maximum) as the honest proof.
    /// Input boundaries see the epoch-local index through the provider.
    function testRefutedRealAdapterCanonicalComposition() public {
        (bytes32 x, bytes memory stepProof) = _cycleOverflowProof();
        uint256 lastInput = ((uint256(1) << 24) - 1) << LOG2_INPUT_WINDOW;
        uint256[3] memory ms =
            [uint256(0), lastInput, (uint256(1) << EPOCH_LOG2) - 2];
        for (uint256 i; i < ms.length; ++i) {
            bool inputBoundary = i < 2;
            _factory = new MultiLevelTournamentFactory(
                new InspectableTournament(),
                _canonicalProvider(),
                new CartesiStateTransition()
            );
            bytes memory proofs = inputBoundary
                ? abi.encodePacked(uint64(0), stepProof)
                : stepProof;
            for (uint256 orient; orient < 4; orient += 3) {
                SparseCase memory c = _realCase(ms[i], orient, x, proofs, 1);
                this.runSparseCase(c);
            }
        }
    }

    /// @dev The epoch's last counter reaches the adapter's reset shape through
    /// Tournament: the step part of the proof is consumed, then the reset
    /// rejects a zero reset proof. No honest reset proof exists here, so this
    /// shows shape selection, not a win.
    function testRefutedRealAdapterLastCounterSelectsReset() public {
        (bytes32 x, bytes memory stepProof) = _cycleOverflowProof();
        _factory = new MultiLevelTournamentFactory(
            new InspectableTournament(),
            _canonicalProvider(),
            new CartesiStateTransition()
        );
        bytes memory proofs = bytes.concat(stepProof, new bytes(43 * 32));
        SparseCase memory c =
            _realCase((uint256(1) << EPOCH_LOG2) - 1, 1, x, proofs, 2);
        this.runSparseCase(c);
    }

    //
    // Static coupling: adapter span and predicates against table and docs
    //

    function testRefutedEpochSpanCoupling() public {
        CartesiStateTransitionExposer x = new CartesiStateTransitionExposer();
        // docs/computation-hash.md: 24 input bits, 48 big-cycle bits, 20
        // uarch bits.
        assertEq(EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH, 24);
        assertEq(
            EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE, 48
        );
        assertEq(EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE, 20);
        assertEq(x.log2InputWindowSpan(), LOG2_INPUT_WINDOW);
        assertEq(x.log2EpochRulerSpan(), EPOCH_LOG2);
        assertEq(x.epochRulerSpan(), uint256(1) << EPOCH_LOG2);
        assertEq(x.inputMask(), (uint256(1) << LOG2_INPUT_WINDOW) - 1);
        assertEq(x.uarchCycleMask(), (uint256(1) << LOG2_UARCH_SPAN) - 1);

        // The deployed table spans exactly the adapter's epoch and tiles to
        // stride zero.
        assertEq(
            uint256(ArbitrationConstants.height(0))
                + ArbitrationConstants.log2step(0),
            x.log2EpochRulerSpan()
        );
        for (uint64 level = 1; level < ArbitrationConstants.LEVELS; ++level) {
            assertEq(
                ArbitrationConstants.log2step(level - 1),
                ArbitrationConstants.height(level)
                    + ArbitrationConstants.log2step(level)
            );
        }
        assertEq(
            ArbitrationConstants.log2step(ArbitrationConstants.LEVELS - 1), 0
        );

        // The largest counter the canonical table can hand the adapter is the
        // last counter the adapter accepts.
        uint256 lastRootStart =
            ((uint256(1) << ArbitrationConstants.height(0)) - 1)
                << ArbitrationConstants.log2step(0);
        uint256 lastCounter =
            lastRootStart + (uint256(1) << ArbitrationConstants.height(1)) - 1;
        assertEq(lastCounter, x.epochRulerSpan() - 1);
    }

    function testRefutedShapePredicatesAtBoundaries() public {
        CartesiStateTransitionExposer x = new CartesiStateTransitionExposer();
        uint256[] memory ms = _canonicalCounters();
        for (uint256 i; i < ms.length; ++i) {
            _assertShapeAgrees(x, ms[i]);
        }
        // The three named in the brief, with their expected shapes.
        (bool input0, bool big0) = _docShape(0);
        assertTrue(input0 && !big0, "m = 0 opens input 0");
        (bool inputL, bool bigL) = _docShape((uint256(1) << EPOCH_LOG2) - 1);
        assertTrue(!inputL && bigL, "the last counter closes a big cycle");
        uint256 lastInput = ((uint256(1) << 24) - 1) << LOG2_INPUT_WINDOW;
        (bool inputI, bool bigI) = _docShape(lastInput);
        assertTrue(inputI && !bigI, "the last input's first counter opens it");
        assertEq(lastInput >> x.log2InputWindowSpan(), (uint256(1) << 24) - 1);
    }

    function testRefutedFuzzShapePredicates(uint256 m) public {
        CartesiStateTransitionExposer x = new CartesiStateTransitionExposer();
        _assertShapeAgrees(x, bound(m, 0, (uint256(1) << EPOCH_LOG2) - 1));
    }

    /// @dev Behavioral twin of the static check on the real adapter: the
    /// input shape consults the provider with the doc's index; the last
    /// counter enters the reset.
    function testRefutedRealAdapterShapesAtNamedCounters() public {
        CartesiStateTransition adapter = new CartesiStateTransition();
        (bytes32 x, bytes memory stepProof) = _cycleOverflowProof();
        uint256 lastInput = ((uint256(1) << 24) - 1) << LOG2_INPUT_WINDOW;

        assertEq(
            adapter.transitionState(
                x,
                0,
                abi.encodePacked(uint64(0), stepProof),
                new ExpectedIndexProvider(0)
            ),
            x
        );
        assertEq(
            adapter.transitionState(
                x,
                lastInput,
                abi.encodePacked(uint64(0), stepProof),
                new ExpectedIndexProvider((uint256(1) << 24) - 1)
            ),
            x
        );
        // One counter before the last input is the previous window's closing
        // big-step boundary, not an input opening.
        vm.expectRevert("Write region root doesn't match");
        adapter.transitionState(
            x,
            lastInput - 1,
            bytes.concat(stepProof, new bytes(43 * 32)),
            IDataProvider(address(0))
        );
        vm.expectRevert("Write region root doesn't match");
        adapter.transitionState(
            x,
            (uint256(1) << EPOCH_LOG2) - 1,
            bytes.concat(stepProof, new bytes(43 * 32)),
            IDataProvider(address(0))
        );
        // The counter before the last is a plain step.
        assertEq(
            adapter.transitionState(
                x,
                (uint256(1) << EPOCH_LOG2) - 2,
                stepProof,
                IDataProvider(address(0))
            ),
            x
        );
    }

    //
    // Small-geometry driver
    //

    function runSmallCase(uint256 m, uint256 orient) external {
        Case memory c;
        c.honest = _honestFine(uint256(1) << (_ls[0] + _hs[0]));
        c.sybil = _sybilFine(c.honest, m);
        c.m = m;
        c.orient = orient;

        uint256 levels = _ls.length;
        InspectableTournament[] memory chain =
            new InspectableTournament[](levels);
        SmallFullTree.Data[] memory honestTrees =
            new SmallFullTree.Data[](levels);
        InspectableTournament t = InspectableTournament(
            address(_factory.instantiate(INITIAL_STATE, DATA))
        );
        uint256 start;
        for (uint256 lvl; lvl < levels; ++lvl) {
            chain[lvl] = t;
            _assertDescriptor(t, lvl, start, _predecessor(c.honest, start));
            SmallFullTree.Data memory hT =
                _levelTree(c.honest, start, _ls[lvl], _hs[lvl]);
            SmallFullTree.Data memory sT =
                _levelTree(c.sybil, start, _ls[lvl], _hs[lvl]);
            honestTrees[lvl] = hT;
            bool honestOne = ((orient >> lvl) & 1) == 1;
            SmallFullTree.Data memory one = honestOne ? hT : sT;
            SmallFullTree.Data memory two = honestOne ? sT : hT;
            join(t, one, honestOne ? HONEST : SYBIL);
            join(t, two, honestOne ? SYBIL : HONEST);
            advanceToSeal(t, one, two);

            // The first level leaf whose end-of-stride sample is at or past m.
            uint256 expected = (m - start) >> _ls[lvl];
            if (lvl + 1 < levels) {
                (InspectableTournament child, uint256 d) =
                    sealInner(t, one, two);
                assertEq(d, expected, "inner divergence position");
                _assertSealedSmall(
                    t, matchId(one, two), d, _ls[lvl], honestOne, c
                );
                start = _assertSmallChild(child, one, two, d, _ls[lvl], c);
                t = child;
            } else {
                uint256 d = sealLeaf(t, one, two);
                assertEq(d, expected, "leaf divergence position");
                _assertSealedSmall(t, matchId(one, two), d, 0, honestOne, c);
                _proveSmallLeaf(t, one, two, honestOne, c);
            }
        }
        _propagateSmall(chain, honestTrees);
    }

    /// @dev The parent's sealed view against the model: the agree state is
    /// the state before the divergent stride, and the final states are each
    /// claim's sample at the stride's end.
    function _assertSealedSmall(
        InspectableTournament t,
        Match.Id memory id,
        uint256 d,
        uint64 log2step,
        bool honestOne,
        Case memory c
    ) internal view {
        uint256 strideStart = (c.m >> log2step) << log2step;
        uint256 lastFine = strideStart + (uint256(1) << log2step) - 1;
        bytes32[] memory oneFine = honestOne ? c.honest : c.sybil;
        bytes32[] memory twoFine = honestOne ? c.sybil : c.honest;
        _assertSealedView(
            t,
            id,
            d,
            _predecessor(c.honest, strideStart),
            oneFine[lastFine],
            twoFine[lastFine]
        );
    }

    function _assertSealedSparse(
        InspectableTournament t,
        SparseTree.Data memory one,
        SparseTree.Data memory two,
        uint256 d,
        uint64 log2step,
        bool honestOne,
        SparseCase memory c
    ) internal view {
        uint256 strideStart = (c.m >> log2step) << log2step;
        uint256 lastFine = strideStart + (uint256(1) << log2step) - 1;
        Fine memory oneFine = honestOne ? c.honest : c.sybil;
        Fine memory twoFine = honestOne ? c.sybil : c.honest;
        _assertSealedView(
            t,
            Match.Id(one.root(), two.root()),
            d,
            _sparsePredecessor(c.honest, strideStart, c.initial),
            _fineAt(oneFine, lastFine),
            _fineAt(twoFine, lastFine)
        );
    }

    function _assertSealedView(
        InspectableTournament t,
        Match.Id memory id,
        uint256 d,
        bytes32 agree,
        bytes32 finalOne,
        bytes32 finalTwo
    ) internal view {
        (Match.Phase phase, ITournament.SealedMatchView memory v) =
            t.sealedMatch(id.hashFromId());
        assertEq(uint8(phase), uint8(Match.Phase.SEALED), "sealed phase");
        assertEq(Machine.Hash.unwrap(v.agreeState), agree, "sealed agree");
        assertEq(v.divergencePosition, d, "sealed position");
        assertEq(Machine.Hash.unwrap(v.finalStateOne), finalOne, "sealed one");
        assertEq(Machine.Hash.unwrap(v.finalStateTwo), finalTwo, "sealed two");
    }

    function _assertSmallChild(
        InspectableTournament child,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two,
        uint256 d,
        uint64 parentLog2step,
        Case memory c
    ) internal view returns (uint256 childStart) {
        bool honestOne =
            ((c.orient >> (child.tournamentArguments().level - 1)) & 1) == 1;
        bytes32[] memory oneFine = honestOne ? c.honest : c.sybil;
        bytes32[] memory twoFine = honestOne ? c.sybil : c.honest;

        childStart = (c.m >> parentLog2step) << parentLog2step;
        uint256 lastFine = childStart + (uint256(1) << parentLog2step) - 1;
        ITournament.TournamentArguments memory a = child.tournamentArguments();
        assertEq(a.commitmentArgs.startCycle, childStart, "child start");
        assertEq(
            Machine.Hash.unwrap(a.commitmentArgs.initialHash),
            _predecessor(c.honest, childStart),
            "child initial hash is the agreed predecessor"
        );
        assertEq(
            _predecessor(c.sybil, childStart),
            _predecessor(c.honest, childStart),
            "both claims agree before the child"
        );
        assertEq(
            Machine.Hash.unwrap(a.nestedDispute.contestedFinalStateOne),
            oneFine[lastFine],
            "contested state one"
        );
        assertEq(
            Machine.Hash.unwrap(a.nestedDispute.contestedFinalStateTwo),
            twoFine[lastFine],
            "contested state two"
        );
        assertTrue(a.nestedDispute.contestedCommitmentOne.eq(one.root()));
        assertTrue(a.nestedDispute.contestedCommitmentTwo.eq(two.root()));
        // The contested states are the parent's divergent leaves.
        assertEq(Tree.Node.unwrap(one.leaf(d)), oneFine[lastFine]);
        assertEq(Tree.Node.unwrap(two.leaf(d)), twoFine[lastFine]);
    }

    function _proveSmallLeaf(
        InspectableTournament t,
        SmallFullTree.Data memory one,
        SmallFullTree.Data memory two,
        bool honestOne,
        Case memory c
    ) internal {
        Match.Id memory id = matchId(one, two);
        SmallFullTree.Data memory hT = honestOne ? one : two;
        SmallFullTree.Data memory sT = honestOne ? two : one;
        uint64 h = hT.height();
        bytes32 pred = _predecessor(c.honest, c.m);
        bytes memory proofs = abi.encode(c.m);

        (Tree.Node hl, Tree.Node hr) = hT.children(h, 0);
        (bytes32 seenState, uint256 seenCounter,, address seenProvider) =
            _observe(t, id, hl, hr, proofs);
        assertEq(seenState, pred, "adapter machineState");
        assertEq(seenCounter, c.m, "adapter counter");
        assertEq(seenProvider, address(DATA), "adapter provider");

        _stub.arm(pred, c.m, c.honest[c.m]);
        (Tree.Node sl, Tree.Node sr) = sT.children(h, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.WrongFinalState.selector,
                honestOne ? 2 : 1,
                c.honest[c.m],
                c.sybil[c.m]
            )
        );
        t.winLeafMatch(id, sl, sr, proofs);

        vm.expectCall(
            address(_stub),
            abi.encodeCall(
                IStateTransition.transitionState, (pred, c.m, proofs, DATA)
            )
        );
        t.winLeafMatch(id, hl, hr, proofs);
        assertTrue(dangling(t).eq(hT.root()), "honest leaf winner");
    }

    function _propagateSmall(
        InspectableTournament[] memory chain,
        SmallFullTree.Data[] memory trees
    ) internal {
        for (uint256 k = chain.length; k > 1; --k) {
            uint64 closure = closureOf(chain[k - 1]);
            if (closure > block.number) rollTo(closure);
            propagate(chain[k - 2], chain[k - 1], trees[k - 2]);
        }
        assertTrue(dangling(chain[0]).eq(trees[0].root()), "honest root");
    }

    //
    // Sparse (canonical) driver
    //

    function runSparseCase(SparseCase memory c) external {
        uint256 levels = _factory.tournamentLevelCount();
        InspectableTournament[] memory chain =
            new InspectableTournament[](levels);
        SparseTree.Data[] memory honestTrees = new SparseTree.Data[](levels);
        IDataProvider provider = DATA;
        if (c.mode == 1 && _isInputOpening(c.m)) {
            provider = new ExpectedIndexProvider(c.m >> LOG2_INPUT_WINDOW);
        }
        InspectableTournament t = InspectableTournament(
            address(
                _factory.instantiate(Machine.Hash.wrap(c.initial), provider)
            )
        );
        uint256 start;
        for (uint256 lvl; lvl < levels; ++lvl) {
            TournamentParameters memory p =
                _factory.tournamentParameters(uint64(lvl));
            chain[lvl] = t;
            _assertDescriptor(
                t, lvl, start, _sparsePredecessor(c.honest, start, c.initial)
            );
            SparseTree.Data memory hT =
                _levelSparse(c.honest, start, p.log2step, p.height);
            SparseTree.Data memory sT =
                _levelSparse(c.sybil, start, p.log2step, p.height);
            honestTrees[lvl] = hT;
            bool honestOne = ((c.orient >> lvl) & 1) == 1;
            SparseTree.Data memory one = honestOne ? hT : sT;
            SparseTree.Data memory two = honestOne ? sT : hT;
            _joinSparse(t, one, honestOne ? HONEST : SYBIL);
            _joinSparse(t, two, honestOne ? SYBIL : HONEST);
            _advanceSparseToSeal(t, one, two);

            uint256 expected = (c.m - start) >> p.log2step;
            if (lvl + 1 < levels) {
                (InspectableTournament child, uint256 d) =
                    _sealSparse(t, one, two, false);
                assertEq(d, expected, "inner divergence position");
                _assertSealedSparse(t, one, two, d, p.log2step, honestOne, c);
                start = _assertSparseChild(child, one, two, d, p.log2step, c);
                t = child;
            } else {
                (, uint256 d) = _sealSparse(t, one, two, true);
                assertEq(d, expected, "leaf divergence position");
                _assertSealedSparse(t, one, two, d, 0, honestOne, c);
                if (!_proveSparseLeaf(t, one, two, honestOne, c)) return;
            }
        }
        for (uint256 k = levels; k > 1; --k) {
            uint64 closure = closureOf(chain[k - 1]);
            if (closure > block.number) rollTo(closure);
            (Tree.Node l, Tree.Node r) =
                honestTrees[k - 2].children(honestTrees[k - 2].height, 0);
            chain[k - 2].winInnerTournament(chain[k - 1], l, r);
        }
        assertTrue(dangling(chain[0]).eq(honestTrees[0].root()), "honest root");
    }

    function _assertSparseChild(
        InspectableTournament child,
        SparseTree.Data memory one,
        SparseTree.Data memory two,
        uint256 d,
        uint64 parentLog2step,
        SparseCase memory c
    ) internal view returns (uint256 childStart) {
        bool honestOne =
            ((c.orient >> (child.tournamentArguments().level - 1)) & 1) == 1;
        Fine memory oneFine = honestOne ? c.honest : c.sybil;
        Fine memory twoFine = honestOne ? c.sybil : c.honest;

        childStart = (c.m >> parentLog2step) << parentLog2step;
        uint256 lastFine = childStart + (uint256(1) << parentLog2step) - 1;
        ITournament.TournamentArguments memory a = child.tournamentArguments();
        assertEq(a.commitmentArgs.startCycle, childStart, "child start");
        assertEq(
            Machine.Hash.unwrap(a.commitmentArgs.initialHash),
            _sparsePredecessor(c.honest, childStart, c.initial),
            "child initial hash is the agreed predecessor"
        );
        assertEq(
            Machine.Hash.unwrap(a.nestedDispute.contestedFinalStateOne),
            _fineAt(oneFine, lastFine)
        );
        assertEq(
            Machine.Hash.unwrap(a.nestedDispute.contestedFinalStateTwo),
            _fineAt(twoFine, lastFine)
        );
        assertTrue(a.nestedDispute.contestedCommitmentOne.eq(one.root()));
        assertTrue(a.nestedDispute.contestedCommitmentTwo.eq(two.root()));
        assertEq(Tree.Node.unwrap(one.leaf(d)), _fineAt(oneFine, lastFine));
        assertEq(Tree.Node.unwrap(two.leaf(d)), _fineAt(twoFine, lastFine));
    }

    /// @return proven false when the case stops at the leaf (reset probe)
    function _proveSparseLeaf(
        InspectableTournament t,
        SparseTree.Data memory one,
        SparseTree.Data memory two,
        bool honestOne,
        SparseCase memory c
    ) internal returns (bool proven) {
        Match.Id memory id = Match.Id(one.root(), two.root());
        SparseTree.Data memory hT = honestOne ? one : two;
        SparseTree.Data memory sT = honestOne ? two : one;
        (Tree.Node hl, Tree.Node hr) = hT.children(hT.height, 0);
        (Tree.Node sl, Tree.Node sr) = sT.children(sT.height, 0);
        bytes32 pred = _sparsePredecessor(c.honest, c.m, c.initial);
        bytes32 honestPost = _fineAt(c.honest, c.m);
        bytes32 sybilPost = _fineAt(c.sybil, c.m);

        if (c.mode == 0) {
            (bytes32 seenState, uint256 seenCounter,, address seenProvider) =
                _observe(t, id, hl, hr, c.proofs);
            assertEq(seenState, pred, "adapter machineState");
            assertEq(seenCounter, c.m, "adapter counter");
            assertEq(seenProvider, address(DATA), "adapter provider");
            _stub.arm(pred, c.m, honestPost);
        } else if (c.mode == 2) {
            vm.expectRevert("Write region root doesn't match");
            t.winLeafMatch(id, hl, hr, c.proofs);
            return false;
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.WrongFinalState.selector,
                honestOne ? 2 : 1,
                honestPost,
                sybilPost
            )
        );
        t.winLeafMatch(id, sl, sr, c.proofs);
        t.winLeafMatch(id, hl, hr, c.proofs);
        assertTrue(dangling(t).eq(hT.root()), "honest leaf winner");
        return true;
    }

    function _joinSparse(
        InspectableTournament t,
        SparseTree.Data memory tree,
        address claimer
    ) internal {
        (Tree.Node left, Tree.Node right) = tree.children(tree.height, 0);
        uint256 bond = t.bondValue();
        vm.prank(claimer);
        t.joinTournament{value: bond}(
            tree.leaf(tree.lastPosition()).toMachineHash(),
            tree.proof(tree.lastPosition()),
            left,
            right
        );
    }

    function _advanceSparseToSeal(
        InspectableTournament t,
        SparseTree.Data memory one,
        SparseTree.Data memory two
    ) internal {
        Match.Id memory id = Match.Id(one.root(), two.root());
        while (true) {
            Match.State memory s = t.getMatch(id.hashFromId());
            uint64 h = s.currentHeight;
            if (h <= 1) break;
            (SparseTree.Data memory r, SparseTree.Data memory w) =
                _sparseRoles(t, h, one, two);
            uint256 idx = s.runningLeafPosition >> h;
            (Tree.Node left, Tree.Node right) = r.children(h, idx);
            uint256 selected = 2 * idx;
            if (left.eq(w.node(h - 1, selected))) selected += 1;
            (Tree.Node nextLeft, Tree.Node nextRight) =
                r.children(h - 1, selected);
            t.advanceMatch(id, left, right, nextLeft, nextRight);
        }
    }

    function _sealSparse(
        InspectableTournament t,
        SparseTree.Data memory one,
        SparseTree.Data memory two,
        bool leaf
    ) internal returns (InspectableTournament child, uint256 divergence) {
        Match.Id memory id = Match.Id(one.root(), two.root());
        Match.State memory s = t.getMatch(id.hashFromId());
        (SparseTree.Data memory r, SparseTree.Data memory w) =
            _sparseRoles(t, 1, one, two);
        uint256 idx = s.runningLeafPosition >> 1;
        (Tree.Node left, Tree.Node right) = r.children(1, idx);
        divergence = 2 * idx;
        if (left.eq(w.leaf(divergence))) divergence += 1;
        Machine.Hash agree;
        bytes32[] memory proof;
        if (divergence == 0) {
            agree = t.tournamentArguments().commitmentArgs.initialHash;
            proof = new bytes32[](0);
        } else {
            agree = r.leaf(divergence - 1).toMachineHash();
            proof = r.proof(divergence - 1);
        }
        if (leaf) {
            t.sealLeafMatch(id, left, right, agree, proof);
        } else {
            vm.recordLogs();
            t.sealInnerMatchAndCreateInnerTournament(
                id, left, right, agree, proof
            );
            child = recordedChild(t, id, vm.getRecordedLogs());
        }
    }

    function _sparseRoles(
        InspectableTournament t,
        uint64 currentHeight,
        SparseTree.Data memory one,
        SparseTree.Data memory two
    )
        internal
        view
        returns (SparseTree.Data memory r, SparseTree.Data memory w)
    {
        (,,, uint64 total) = t.tournamentLevelConstants();
        bool oneReveals = Match.responder(total, currentHeight)
            == ITournament.CommitmentSide.ONE;
        r = oneReveals ? one : two;
        w = oneReveals ? two : one;
    }

    //
    // Model
    //

    function _honestFine(uint256 n)
        internal
        pure
        returns (bytes32[] memory fine)
    {
        fine = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            fine[i] = bytes32(uint256(0x100000000) + i);
        }
    }

    function _sybilFine(bytes32[] memory honest, uint256 m)
        internal
        pure
        returns (bytes32[] memory fine)
    {
        fine = new bytes32[](honest.length);
        for (uint256 i; i < honest.length; ++i) {
            fine[i] = i < m ? honest[i] : bytes32(uint256(0x200000000) + i);
        }
    }

    /// @dev The state before fine index x: s_{x-1}, or the implicit s_-1.
    function _predecessor(bytes32[] memory fine, uint256 x)
        internal
        pure
        returns (bytes32)
    {
        return x == 0 ? Machine.Hash.unwrap(INITIAL_STATE) : fine[x - 1];
    }

    /// @dev Leaf q samples the end of stride q: s_{start + (q + 1) 2^ls - 1}.
    function _levelTree(
        bytes32[] memory fine,
        uint256 start,
        uint64 ls,
        uint64 h
    ) internal pure returns (SmallFullTree.Data memory) {
        Tree.Node[] memory leaves = new Tree.Node[](uint256(1) << h);
        for (uint256 q; q < leaves.length; ++q) {
            leaves[q] = Tree.Node.wrap(fine[start + ((q + 1) << ls) - 1]);
        }
        return SmallFullTree.buildFromLeaves(leaves);
    }

    /// @dev Pieces [0, m - 1) -> a, [m - 1, m) -> p, [m, 2^92) -> tail,
    /// empty pieces omitted.
    function _fine3(uint256 m, bytes32 a, bytes32 p, bytes32 tail)
        internal
        pure
        returns (Fine memory f)
    {
        uint256 n = 1 + (m >= 1 ? 1 : 0) + (m >= 2 ? 1 : 0);
        f.starts = new uint256[](n);
        f.values = new bytes32[](n);
        uint256 k;
        if (m >= 2) {
            f.starts[k] = 0;
            f.values[k] = a;
            ++k;
        }
        if (m >= 1) {
            f.starts[k] = m - 1;
            f.values[k] = p;
            ++k;
        }
        f.starts[k] = m;
        f.values[k] = tail;
    }

    function _fineAt(Fine memory f, uint256 i)
        internal
        pure
        returns (bytes32 v)
    {
        for (uint256 k; k < f.starts.length; ++k) {
            if (f.starts[k] > i) break;
            v = f.values[k];
        }
    }

    function _sparsePredecessor(Fine memory f, uint256 x, bytes32 initial)
        internal
        pure
        returns (bytes32)
    {
        return x == 0 ? initial : _fineAt(f, x - 1);
    }

    /// @dev The level tree over a piecewise fine table. Leaf q samples fine
    /// index start + (q + 1) 2^ls - 1, so a fine piece starting at b >= start
    /// first shows at leaf floor((b - start) / 2^ls).
    function _levelSparse(Fine memory f, uint256 start, uint64 ls, uint64 h)
        internal
        pure
        returns (SparseTree.Data memory)
    {
        uint256 count = uint256(1) << h;
        uint256[] memory qs = new uint256[](f.starts.length);
        bytes32[] memory vs = new bytes32[](f.starts.length);
        uint256 n = 1;
        vs[0] = _fineAt(f, start + (uint256(1) << ls) - 1);
        for (uint256 k = 1; k < f.starts.length; ++k) {
            uint256 b = f.starts[k];
            if (b < start) continue;
            uint256 q = (b - start) >> ls;
            if (q == 0 || q >= count) continue;
            bytes32 v = _fineAt(f, start + ((q + 1) << ls) - 1);
            if (q == qs[n - 1]) {
                vs[n - 1] = v;
            } else {
                (qs[n], vs[n]) = (q, v);
                ++n;
            }
        }
        uint256[] memory starts = new uint256[](n);
        bytes32[] memory values = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (starts[i], values[i]) = (qs[i], vs[i]);
        }
        return SparseTree.build(h, starts, values);
    }

    function _docShape(uint256 m)
        internal
        pure
        returns (bool inputBoundary, bool bigStepBoundary)
    {
        // Structure::decompose, as docs/computation-hash.md states it.
        uint256 ucycle = m & ((uint256(1) << 20) - 1);
        uint256 bigCycle = (m >> 20) & ((uint256(1) << 48) - 1);
        inputBoundary = ucycle == 0 && bigCycle == 0;
        bigStepBoundary = (m + 1) % (uint256(1) << 20) == 0;
    }

    function _assertShapeAgrees(CartesiStateTransitionExposer x, uint256 m)
        internal
        view
    {
        (bool docInput, bool docBig) = _docShape(m);
        bool adapterInput = (m & x.inputMask()) == 0;
        bool adapterBig =
            !adapterInput && (m & x.uarchCycleMask()) == x.uarchCycleMask();
        assertEq(adapterInput, docInput, "input predicate");
        assertEq(adapterBig, docBig, "big-step predicate");
        assertFalse(docInput && docBig, "doc shapes overlap");
        assertEq(m >> x.log2InputWindowSpan(), m >> 68, "input index");
        assertLt(m, x.epochRulerSpan());
    }

    function _isInputOpening(uint256 m) internal pure returns (bool) {
        (bool input,) = _docShape(m);
        return input;
    }

    //
    // Setup helpers
    //

    function _sweep(uint256[] memory orients) internal {
        uint256 n = uint256(1) << (_ls[0] + _hs[0]);
        for (uint256 m; m < n; ++m) {
            for (uint256 i; i < orients.length; ++i) {
                this.runSmallCase(m, orients[i]);
            }
        }
    }

    function _useProvider(ITournamentParametersProvider provider) internal {
        _stub = new RecordingStateTransition();
        _factory = new MultiLevelTournamentFactory(
            new InspectableTournament(), provider, _stub
        );
        uint64 levels = _factory.tournamentLevelCount();
        delete _ls;
        delete _hs;
        for (uint64 lvl; lvl < levels; ++lvl) {
            TournamentParameters memory p = _factory.tournamentParameters(lvl);
            _ls.push(p.log2step);
            _hs.push(p.height);
        }
    }

    function _useTable2(uint64 rootHeight, uint64 leafHeight) internal {
        uint64[] memory ls = new uint64[](2);
        uint64[] memory hs = new uint64[](2);
        (ls[0], hs[0]) = (leafHeight, rootHeight);
        (ls[1], hs[1]) = (0, leafHeight);
        _useProvider(_table(ls, hs));
    }

    function _table(uint64[] memory ls, uint64[] memory hs)
        internal
        returns (ITournamentParametersProvider)
    {
        return new TableTournamentParametersProvider(
            ls, hs, _g(), _t(), _a(), ls[0] + hs[0]
        );
    }

    function _canonicalProvider()
        internal
        returns (ITournamentParametersProvider)
    {
        return new CanonicalTournamentParametersProvider(
            12_000, 8 hours, 5 minutes
        );
    }

    function _newStub() internal returns (RecordingStateTransition) {
        _stub = new RecordingStateTransition();
        return _stub;
    }

    function _assertDescriptor(
        InspectableTournament t,
        uint256 lvl,
        uint256 start,
        bytes32 initial
    ) internal view {
        ITournament.TournamentArguments memory a = t.tournamentArguments();
        TournamentParameters memory p =
            _factory.tournamentParameters(uint64(lvl));
        assertEq(a.level, lvl, "level");
        assertEq(a.commitmentArgs.startCycle, start, "start cycle");
        assertEq(a.commitmentArgs.log2step, p.log2step, "log2step");
        assertEq(a.commitmentArgs.height, p.height, "height");
        assertEq(
            Machine.Hash.unwrap(a.commitmentArgs.initialHash),
            initial,
            "initial"
        );
        assertEq(
            uint8(a.kind),
            uint8(
                lvl + 1 == p.levels
                    ? ITournament.TournamentKind.LEAF
                    : ITournament.TournamentKind.NON_LEAF
            ),
            "kind"
        );
    }

    function _observe(
        InspectableTournament t,
        Match.Id memory id,
        Tree.Node left,
        Tree.Node right,
        bytes memory proofs
    )
        internal
        returns (
            bytes32 state,
            uint256 counter,
            uint256 proofLength,
            address provider
        )
    {
        _stub.probe();
        try t.winLeafMatch(id, left, right, proofs) {
            revert("probe: the proof did not consult the adapter");
        } catch (bytes memory reason) {
            require(
                reason.length == 4 + 128
                    && bytes4(reason)
                        == RecordingStateTransition.Observed.selector,
                "probe: unexpected revert"
            );
            bytes memory payload = new bytes(128);
            for (uint256 i; i < 128; ++i) {
                payload[i] = reason[i + 4];
            }
            (state, counter, proofLength, provider) =
                abi.decode(payload, (bytes32, uint256, uint256, address));
        }
        assertEq(proofLength, proofs.length, "proof bytes forwarded");
    }

    function _stubCase(uint256 m, uint256 orient)
        internal
        pure
        returns (SparseCase memory c)
    {
        c.honest = _fine3(m, VA, VP, VQ);
        c.sybil = _fine3(m, VA, VP, VY);
        c.initial = Machine.Hash.unwrap(INITIAL_STATE);
        c.m = m;
        c.orient = orient;
        c.mode = 0;
        c.proofs = hex"c0ffee";
    }

    function _realCase(
        uint256 m,
        uint256 orient,
        bytes32 x,
        bytes memory proofs,
        uint8 mode
    ) internal pure returns (SparseCase memory c) {
        // Honest: s_{m-1} = s_m = x under the identity step; the Sybil
        // diverges at m.
        c.honest = _fine3(m, VA, x, x);
        c.sybil = _fine3(m, VA, x, VY);
        c.initial = m == 0 ? x : Machine.Hash.unwrap(INITIAL_STATE);
        c.m = m;
        c.orient = orient;
        c.mode = mode;
        c.proofs = proofs;
    }

    function _canonicalCounters() internal pure returns (uint256[] memory ms) {
        uint256 epoch = uint256(1) << EPOCH_LOG2;
        uint256 stride = uint256(1) << 38;
        uint256 lastInput = ((uint256(1) << 24) - 1) << LOG2_INPUT_WINDOW;
        ms = new uint256[](10);
        ms[0] = 0;
        ms[1] = 1;
        ms[2] = stride - 1;
        ms[3] = stride;
        ms[4] = (uint256(1) << LOG2_UARCH_SPAN) - 1;
        ms[5] = lastInput - 1;
        ms[6] = lastInput;
        ms[7] = epoch - stride;
        ms[8] = epoch - 2;
        ms[9] = epoch - 1;
    }

    function _orients2() internal pure returns (uint256[] memory o) {
        o = new uint256[](4);
        (o[0], o[1], o[2], o[3]) = (0, 1, 2, 3);
    }

    function _orients4() internal pure returns (uint256[] memory o) {
        o = new uint256[](4);
        (o[0], o[1], o[2], o[3]) = (0, 15, 5, 10);
    }

    function _g() internal pure returns (Time.Duration) {
        return Time.Duration.wrap(G);
    }

    function _t() internal pure returns (Time.Duration) {
        return Time.Duration.wrap(T);
    }

    function _a() internal pure returns (Time.Duration) {
        return Time.Duration.wrap(ALLOWANCE);
    }

    /// @dev The identity uarch step: a uarch cycle already at its maximum
    /// reports overflow and leaves the state unchanged.
    function _cycleOverflowProof()
        internal
        pure
        returns (bytes32 machineState, bytes memory proof)
    {
        Memory.PhysicalAddress cycleAddress =
            Memory.toPhysicalAddress(EmulatorConstants.UARCH_CYCLE_ADDRESS);
        (Memory.PhysicalAddress leafAddress, uint64 wordOffset) =
            Memory.truncateToLeaf(cycleAddress);
        bytes32 leafWord = AccessLogs.setBytes8ToBytes32AtOffset(
            AccessLogs.solidityUint64ToMachineWord(
                EmulatorConstants.UARCH_CYCLE_MAX
            ),
            bytes32(0),
            wordOffset
        );
        proof = abi.encodePacked(
            leafWord, new bytes(uint256(Memory.LOG2_MAX_SIZE) * 32)
        );
        Buffer.Context memory siblings = Buffer.Context(proof, 32);
        machineState = siblings.getRoot(
            Memory.regionFromLeafAddress(leafAddress),
            keccak256(abi.encodePacked(leafWord))
        );
    }
}
