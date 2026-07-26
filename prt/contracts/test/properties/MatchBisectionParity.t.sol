// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ITournament} from "src/ITournament.sol";
import {Commitment} from "src/tournament/libs/Commitment.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

library MatchBisectionMutation {
    function advance(
        Match.State storage state,
        Tree.Node leftNode,
        Tree.Node rightNode,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) external {
        Match.advanceBisection(
            state, leftNode, rightNode, newLeftNode, newRightNode
        );
    }

    function seal(
        Match.State storage state,
        Commitment.Arguments memory args,
        Match.Id calldata id,
        Tree.Node leftLeaf,
        Tree.Node rightLeaf,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    )
        external
        returns (Machine.Hash divergentStateOne, Machine.Hash divergentStateTwo)
    {
        return Match.sealDivergence(
            state, args, id, leftLeaf, rightLeaf, agreeState, agreeStateProof
        );
    }
}

/// @dev Checks Match against a test-owned sparse Merkle model. The general
/// model differs from a uniform tree at one selected leaf, so arbitrary heights
/// and positions require only linear space. Focused two-difference traces also
/// check leftmost-divergence precedence between subtrees and terminal leaves.
contract MatchBisectionParityTest is Test {
    using Commitment for Commitment.Arguments;
    using Match for Match.State;
    using Tree for Tree.Node;

    uint64 internal constant MAX_REVIEWED_HEIGHT = 55;
    uint64 internal constant LOG2_STEP = 3;
    uint256 internal constant START_CYCLE = 17;

    Machine.Hash internal constant INITIAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0x11)));
    Machine.Hash internal constant COMMON_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xaa)));
    Machine.Hash internal constant DIVERGENT_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xbb)));
    Machine.Hash internal constant LATER_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xcc)));

    struct Trace {
        uint64 height;
        uint64 remainingHeight;
        uint256 position;
        uint256 relativePosition;
        uint256 runningPosition;
        bool commitmentOneDiffers;
        bool responderIsOne;
        Tree.Node[] uniform;
        Commitment.Arguments args;
        Match.Id id;
    }

    struct AdvanceInput {
        Tree.Node left;
        Tree.Node right;
        Tree.Node newLeft;
        Tree.Node newRight;
        uint256 half;
        uint256 childPosition;
        bool descendRight;
    }

    struct SealInput {
        Tree.Node leftLeaf;
        Tree.Node rightLeaf;
        Machine.Hash agreeState;
        bytes32[] agreeProof;
    }

    struct MultipleDifferenceTrace {
        bool commitmentOneDiffers;
        Tree.Node commonLeaf;
        Tree.Node divergentLeaf;
        Tree.Node firstSubtree;
        Tree.Node laterSubtree;
        Tree.Node uniformSubtree;
        Commitment.Arguments args;
        Match.Id id;
    }

    Match.State private _state;

    function testExhaustiveEveryPositionThroughHeightEight() public {
        for (uint64 height = 1; height <= 8; ++height) {
            uint256 leafCount = uint256(1) << height;
            for (uint256 position; position < leafCount; ++position) {
                _assertTrace(height, position, false, false);
                _assertTrace(height, position, true, false);
            }
        }
    }

    function testEveryHeightIncludesBothBoundaryPathsAndOrders() public {
        for (uint64 height = 1; height <= MAX_REVIEWED_HEIGHT; ++height) {
            uint256 last = (uint256(1) << height) - 1;
            _assertTrace(height, 0, false, false);
            _assertTrace(height, 0, true, false);
            _assertTrace(height, last, false, false);
            _assertTrace(height, last, true, false);
        }
    }

    function testHeight55BoundaryAndAlternatingPathsBothOrders() public {
        uint256 last = (uint256(1) << MAX_REVIEWED_HEIGHT) - 1;
        uint256 midpoint = uint256(1) << (MAX_REVIEWED_HEIGHT - 1);
        uint256 alternatingBits = type(uint256).max / 3;
        uint256[8] memory positions = [
            uint256(0),
            uint256(1),
            midpoint - 1,
            midpoint,
            last - 1,
            last,
            alternatingBits & last,
            (~alternatingBits) & last
        ];

        for (uint256 i; i < positions.length; ++i) {
            _assertTrace(MAX_REVIEWED_HEIGHT, positions[i], false, false);
            _assertTrace(MAX_REVIEWED_HEIGHT, positions[i], true, false);
        }
    }

    function testAgreeProofBelongsToFinalResponderAtEveryHeight() public {
        for (uint64 height = 1; height <= MAX_REVIEWED_HEIGHT; ++height) {
            uint256 position = uint256(1) << (height - 1);
            _assertTrace(height, position, height % 2 == 0, true);
        }
    }

    function testBothChildSubtreesDifferChoosesEarliestDivergence() public {
        _assertMultipleDifferenceTrace(false);
        _assertMultipleDifferenceTrace(true);
    }

    function testBothFinalLeavesDifferChoosesLeftmost() public {
        _assertHeightOneLeftmost(false);
        _assertHeightOneLeftmost(true);
    }

    function testZeroHashesRemainValidMatchData() public {
        Tree.Node zero = Tree.ZERO_NODE;
        Tree.Node other = Tree.Node.wrap(bytes32(uint256(0x99)));
        Match.Id memory id = Match.Id({
            commitmentOne: zero.join(zero), commitmentTwo: zero.join(other)
        });
        Commitment.Arguments memory args = Commitment.Arguments({
            initialHash: INITIAL_STATE,
            startCycle: START_CYCLE,
            log2step: LOG2_STEP,
            height: 1
        });
        (, Match.State memory initialState) = Match.create(
            args.height, id.commitmentOne, id.commitmentTwo, zero, other
        );
        _state = initialState;

        bytes32[] memory agreeProof = new bytes32[](1);
        agreeProof[0] = Tree.Node.unwrap(zero);
        (Machine.Hash finalStateOne, Machine.Hash finalStateTwo) = MatchBisectionMutation.seal(
            _state,
            args,
            id,
            zero,
            zero,
            Machine.Hash.wrap(bytes32(0)),
            agreeProof
        );

        Match.SealedView memory view_ = _state.sealedView();
        _assertHash(view_.agreeState, Machine.Hash.wrap(bytes32(0)));
        assertEq(view_.divergencePosition, 1);
        _assertHash(finalStateOne, Machine.Hash.wrap(bytes32(0)));
        _assertHash(finalStateTwo, other.toMachineHash());
        _assertHash(view_.finalStateOne, finalStateOne);
        _assertHash(view_.finalStateTwo, finalStateTwo);
    }

    function testFuzzParityAcrossReviewedGeometry(
        uint8 rawHeight,
        uint256 rawPosition,
        bool commitmentOneDiffers
    ) public {
        uint64 height = uint64(bound(rawHeight, 1, MAX_REVIEWED_HEIGHT));
        uint256 last = (uint256(1) << height) - 1;
        uint256 position = bound(rawPosition, 0, last);

        _assertTrace(height, position, commitmentOneDiffers, false);
    }

    function _assertTrace(
        uint64 height,
        uint256 position,
        bool commitmentOneDiffers,
        bool rejectOtherProof
    ) internal {
        Trace memory trace = _initializeTrace(
            height, position, commitmentOneDiffers
        );
        while (trace.remainingHeight > 1) {
            _advanceTrace(trace);
        }
        _sealTrace(trace, rejectOtherProof);
    }

    function _assertMultipleDifferenceTrace(bool commitmentOneDiffers)
        internal
    {
        MultipleDifferenceTrace memory trace =
            _initializeMultipleDifferenceTrace(commitmentOneDiffers);
        _advanceMultipleDifferenceTrace(trace);
        _sealMultipleDifferenceTrace(trace);
    }

    function _assertHeightOneLeftmost(bool commitmentOneDiffers) internal {
        Tree.Node commonLeaf = Tree.Node.wrap(Machine.Hash.unwrap(COMMON_STATE));
        Tree.Node divergentLeaf =
            Tree.Node.wrap(Machine.Hash.unwrap(DIVERGENT_STATE));
        Tree.Node laterLeaf = Tree.Node.wrap(Machine.Hash.unwrap(LATER_STATE));
        Tree.Node commonRoot = commonLeaf.join(commonLeaf);
        Tree.Node bothDifferRoot = divergentLeaf.join(laterLeaf);

        Trace memory trace;
        trace.height = 1;
        trace.remainingHeight = 1;
        trace.commitmentOneDiffers = commitmentOneDiffers;
        trace.responderIsOne = true;
        trace.args = Commitment.Arguments({
            initialHash: INITIAL_STATE,
            startCycle: START_CYCLE,
            log2step: LOG2_STEP,
            height: 1
        });
        trace.id = commitmentOneDiffers
            ? Match.Id(bothDifferRoot, commonRoot)
            : Match.Id(commonRoot, bothDifferRoot);

        Tree.Node oneLeft = commitmentOneDiffers ? divergentLeaf : commonLeaf;
        Tree.Node oneRight = commitmentOneDiffers ? laterLeaf : commonLeaf;
        Tree.Node twoLeft = commitmentOneDiffers ? commonLeaf : divergentLeaf;
        Tree.Node twoRight = commitmentOneDiffers ? commonLeaf : laterLeaf;
        assertFalse(oneLeft.eq(twoLeft));
        assertFalse(oneRight.eq(twoRight));

        (Match.IdHash idHash, Match.State memory initialState) = Match.create(
            trace.args.height,
            trace.id.commitmentOne,
            trace.id.commitmentTwo,
            twoLeft,
            twoRight
        );
        _state = initialState;
        _assertInitialState(trace, idHash, twoLeft, twoRight);

        (Machine.Hash sealedOne, Machine.Hash sealedTwo) = MatchBisectionMutation.seal(
            _state,
            trace.args,
            trace.id,
            oneLeft,
            oneRight,
            INITIAL_STATE,
            new bytes32[](0)
        );
        _assertSealedState(trace, INITIAL_STATE, sealedOne, sealedTwo);
    }

    function _initializeMultipleDifferenceTrace(bool commitmentOneDiffers)
        internal
        returns (MultipleDifferenceTrace memory trace)
    {
        trace.commitmentOneDiffers = commitmentOneDiffers;
        trace.commonLeaf = Tree.Node.wrap(Machine.Hash.unwrap(COMMON_STATE));
        trace.divergentLeaf =
            Tree.Node.wrap(Machine.Hash.unwrap(DIVERGENT_STATE));
        Tree.Node laterLeaf = Tree.Node.wrap(Machine.Hash.unwrap(LATER_STATE));
        trace.uniformSubtree = trace.commonLeaf.join(trace.commonLeaf);
        trace.firstSubtree = trace.commonLeaf.join(trace.divergentLeaf);
        trace.laterSubtree = laterLeaf.join(trace.commonLeaf);

        Tree.Node uniformRoot = trace.uniformSubtree.join(trace.uniformSubtree);
        Tree.Node multipleRoot = trace.firstSubtree.join(trace.laterSubtree);
        trace.id = commitmentOneDiffers
            ? Match.Id(multipleRoot, uniformRoot)
            : Match.Id(uniformRoot, multipleRoot);
        trace.args = Commitment.Arguments({
            initialHash: INITIAL_STATE,
            startCycle: START_CYCLE,
            log2step: LOG2_STEP,
            height: 2
        });

        Tree.Node twoLeft =
            commitmentOneDiffers ? trace.uniformSubtree : trace.firstSubtree;
        Tree.Node twoRight =
            commitmentOneDiffers ? trace.uniformSubtree : trace.laterSubtree;
        (, Match.State memory initialState) = Match.create(
            trace.args.height,
            trace.id.commitmentOne,
            trace.id.commitmentTwo,
            twoLeft,
            twoRight
        );
        _state = initialState;
    }

    function _advanceMultipleDifferenceTrace(MultipleDifferenceTrace memory trace)
        internal
    {
        Tree.Node left = trace.commitmentOneDiffers
            ? trace.firstSubtree
            : trace.uniformSubtree;
        Tree.Node right = trace.commitmentOneDiffers
            ? trace.laterSubtree
            : trace.uniformSubtree;
        Tree.Node waitingLeft = trace.commitmentOneDiffers
            ? trace.uniformSubtree
            : trace.firstSubtree;
        Tree.Node waitingRight = trace.commitmentOneDiffers
            ? trace.uniformSubtree
            : trace.laterSubtree;
        assertFalse(left.eq(waitingLeft));
        assertFalse(right.eq(waitingRight));

        Tree.Node newRight =
            trace.commitmentOneDiffers ? trace.divergentLeaf : trace.commonLeaf;
        MatchBisectionMutation.advance(
            _state, left, right, trace.commonLeaf, newRight
        );

        assertEq(_state.currentHeight, 1);
        assertEq(_state.runningLeafPosition, 0);
        _assertNode(_state.otherParent, waitingLeft);
        _assertNode(_state.leftNode, trace.commonLeaf);
        _assertNode(_state.rightNode, newRight);
    }

    function _sealMultipleDifferenceTrace(MultipleDifferenceTrace memory trace)
        internal
    {
        Tree.Node rightLeaf =
            trace.commitmentOneDiffers ? trace.commonLeaf : trace.divergentLeaf;
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = Tree.Node.unwrap(rightLeaf);
        proof[1] = Tree.Node
            .unwrap(
                trace.commitmentOneDiffers
                    ? trace.uniformSubtree
                    : trace.laterSubtree
            );

        (Machine.Hash sealedOne, Machine.Hash sealedTwo) = MatchBisectionMutation.seal(
            _state,
            trace.args,
            trace.id,
            trace.commonLeaf,
            rightLeaf,
            COMMON_STATE,
            proof
        );

        Trace memory expected;
        expected.position = 1;
        expected.commitmentOneDiffers = trace.commitmentOneDiffers;
        expected.args = trace.args;
        _assertSealedState(expected, COMMON_STATE, sealedOne, sealedTwo);
    }

    function _initializeTrace(
        uint64 height,
        uint256 position,
        bool commitmentOneDiffers
    ) internal returns (Trace memory trace) {
        trace.height = height;
        trace.remainingHeight = height;
        trace.position = position;
        trace.relativePosition = position;
        trace.commitmentOneDiffers = commitmentOneDiffers;
        trace.responderIsOne = true;
        trace.uniform = _uniformNodes(height);
        trace.args = Commitment.Arguments({
            initialHash: INITIAL_STATE,
            startCycle: START_CYCLE,
            log2step: LOG2_STEP,
            height: height
        });
        trace.id.commitmentOne =
            _node(commitmentOneDiffers, height, position, trace.uniform);
        trace.id.commitmentTwo =
            _node(!commitmentOneDiffers, height, position, trace.uniform);
        _storeInitialState(trace);
    }

    function _storeInitialState(Trace memory trace) internal {
        (Tree.Node twoLeft, Tree.Node twoRight) = _children(
            !trace.commitmentOneDiffers,
            trace.height,
            trace.position,
            trace.uniform
        );
        (Match.IdHash idHash, Match.State memory initialState) = Match.create(
            trace.args.height,
            trace.id.commitmentOne,
            trace.id.commitmentTwo,
            twoLeft,
            twoRight
        );
        _state = initialState;
        _assertInitialState(trace, idHash, twoLeft, twoRight);
    }

    function _assertInitialState(
        Trace memory trace,
        Match.IdHash idHash,
        Tree.Node twoLeft,
        Tree.Node twoRight
    ) internal view {
        assertEq(Match.IdHash.unwrap(idHash), keccak256(abi.encode(trace.id)));
        assertTrue(_state.isInit);
        assertEq(_state.currentHeight, trace.args.height);
        assertEq(_state.runningLeafPosition, 0);
        _assertNode(_state.otherParent, trace.id.commitmentOne);
        _assertNode(_state.leftNode, twoLeft);
        _assertNode(_state.rightNode, twoRight);
    }

    function _advanceTrace(Trace memory trace) internal {
        bool responderDiffers =
            trace.responderIsOne == trace.commitmentOneDiffers;
        AdvanceInput memory input;
        (input.left, input.right) = _children(
            responderDiffers,
            trace.remainingHeight,
            trace.relativePosition,
            trace.uniform
        );
        input.half = uint256(1) << (trace.remainingHeight - 1);
        input.descendRight = trace.relativePosition >= input.half;
        input.childPosition = input.descendRight
            ? trace.relativePosition - input.half
            : trace.relativePosition;
        (input.newLeft, input.newRight) = _children(
            responderDiffers,
            trace.remainingHeight - 1,
            input.childPosition,
            trace.uniform
        );

        MatchBisectionMutation.advance(
            _state, input.left, input.right, input.newLeft, input.newRight
        );
        if (input.descendRight) trace.runningPosition += input.half;
        --trace.remainingHeight;
        trace.relativePosition = input.childPosition;
        trace.responderIsOne = !trace.responderIsOne;
        _assertActiveState(trace);
    }

    function _assertActiveState(Trace memory trace) internal view {
        assertTrue(_state.isInit);
        assertEq(_state.currentHeight, trace.remainingHeight);
        assertEq(_state.runningLeafPosition, trace.runningPosition);
        assertEq(
            trace.runningPosition,
            (trace.position >> trace.remainingHeight) << trace.remainingHeight
        );
        assertEq(trace.runningPosition % 2, 0);
        _assertNode(
            _state.otherParent,
            _node(
                trace.responderIsOne == trace.commitmentOneDiffers,
                trace.remainingHeight,
                trace.relativePosition,
                trace.uniform
            )
        );

        {
            (Tree.Node expectedLeft, Tree.Node expectedRight) = _children(
                trace.responderIsOne != trace.commitmentOneDiffers,
                trace.remainingHeight,
                trace.relativePosition,
                trace.uniform
            );
            _assertNode(_state.leftNode, expectedLeft);
            _assertNode(_state.rightNode, expectedRight);
        }
    }

    function _sealTrace(Trace memory trace, bool rejectOtherProof) internal {
        bool responderDiffers =
            trace.responderIsOne == trace.commitmentOneDiffers;
        SealInput memory input;
        (input.leftLeaf, input.rightLeaf) = _children(
            responderDiffers, 1, trace.relativePosition, trace.uniform
        );
        input.agreeState = trace.position == 0 ? INITIAL_STATE : COMMON_STATE;

        if (rejectOtherProof && trace.position != 0) {
            _assertOtherProofRejected(trace, input, responderDiffers);
        }
        if (trace.position != 0) {
            input.agreeProof = _agreeProof(
                responderDiffers,
                trace.height,
                trace.position - 1,
                trace.position,
                trace.uniform
            );
        }

        (Machine.Hash sealedOne, Machine.Hash sealedTwo) = MatchBisectionMutation.seal(
            _state,
            trace.args,
            trace.id,
            input.leftLeaf,
            input.rightLeaf,
            input.agreeState,
            input.agreeProof
        );
        _assertSealedState(trace, input.agreeState, sealedOne, sealedTwo);
    }

    function _assertOtherProofRejected(
        Trace memory trace,
        SealInput memory input,
        bool responderDiffers
    ) internal {
        bytes32[] memory otherProof = _agreeProof(
            !responderDiffers,
            trace.height,
            trace.position - 1,
            trace.position,
            trace.uniform
        );
        vm.expectPartialRevert(ITournament.CommitmentStateMismatch.selector);
        MatchBisectionMutation.seal(
            _state,
            trace.args,
            trace.id,
            input.leftLeaf,
            input.rightLeaf,
            input.agreeState,
            otherProof
        );
        assertEq(_state.currentHeight, 1);
        assertEq(_state.runningLeafPosition, trace.runningPosition);
    }

    function _assertSealedState(
        Trace memory trace,
        Machine.Hash agreeState,
        Machine.Hash sealedOne,
        Machine.Hash sealedTwo
    ) internal view {
        Machine.Hash expectedOne = trace.commitmentOneDiffers
            ? DIVERGENT_STATE
            : COMMON_STATE;
        Machine.Hash expectedTwo =
            trace.commitmentOneDiffers ? COMMON_STATE : DIVERGENT_STATE;
        _assertHash(sealedOne, expectedOne);
        _assertHash(sealedTwo, expectedTwo);
        _assertRawSealedState(trace, agreeState, expectedOne, expectedTwo);
        _assertSealedView(trace, agreeState, expectedOne, expectedTwo);
    }

    function _assertRawSealedState(
        Trace memory trace,
        Machine.Hash agreeState,
        Machine.Hash expectedOne,
        Machine.Hash expectedTwo
    ) internal view {
        assertTrue(_state.isInit);
        assertEq(_state.currentHeight, 0);
        assertEq(_state.runningLeafPosition, trace.position);
        _assertNode(
            _state.otherParent, Tree.Node.wrap(Machine.Hash.unwrap(agreeState))
        );

        _assertNode(
            _state.leftNode, Tree.Node.wrap(Machine.Hash.unwrap(expectedOne))
        );
        _assertNode(
            _state.rightNode, Tree.Node.wrap(Machine.Hash.unwrap(expectedTwo))
        );
    }

    function _assertSealedView(
        Trace memory trace,
        Machine.Hash agreeState,
        Machine.Hash expectedOne,
        Machine.Hash expectedTwo
    ) internal view {
        Match.SealedView memory view_ = _state.sealedView();
        uint256 agreeCycle = trace.args.toCycle(view_.divergencePosition);
        _assertHash(view_.agreeState, agreeState);
        assertEq(
            agreeCycle,
            START_CYCLE + (trace.position * (uint256(1) << LOG2_STEP))
        );
        _assertHash(view_.finalStateOne, expectedOne);
        _assertHash(view_.finalStateTwo, expectedTwo);
    }

    function _uniformNodes(uint64 height)
        internal
        pure
        returns (Tree.Node[] memory nodes)
    {
        nodes = new Tree.Node[](height + 1);
        nodes[0] = Tree.Node.wrap(Machine.Hash.unwrap(COMMON_STATE));
        for (uint64 level = 1; level <= height; ++level) {
            nodes[level] = nodes[level - 1].join(nodes[level - 1]);
        }
    }

    function _node(
        bool differs,
        uint64 height,
        uint256 position,
        Tree.Node[] memory uniform
    ) internal pure returns (Tree.Node) {
        if (!differs) return uniform[height];

        Tree.Node node = Tree.Node.wrap(Machine.Hash.unwrap(DIVERGENT_STATE));
        for (uint64 level; level < height; ++level) {
            if (((position >> level) & 1) == 0) {
                node = node.join(uniform[level]);
            } else {
                node = uniform[level].join(node);
            }
        }
        return node;
    }

    function _children(
        bool differs,
        uint64 height,
        uint256 position,
        Tree.Node[] memory uniform
    ) internal pure returns (Tree.Node left, Tree.Node right) {
        assert(height > 0);
        uint64 childHeight = height - 1;
        left = uniform[childHeight];
        right = uniform[childHeight];
        if (!differs) return (left, right);

        uint256 half = uint256(1) << childHeight;
        if (position < half) {
            left = _node(true, childHeight, position, uniform);
        } else {
            right = _node(true, childHeight, position - half, uniform);
        }
    }

    function _agreeProof(
        bool differs,
        uint64 height,
        uint256 agreePosition,
        uint256 divergencePosition,
        Tree.Node[] memory uniform
    ) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](height);
        for (uint64 level; level < height; ++level) {
            Tree.Node sibling = uniform[level];
            uint256 siblingIndex = (agreePosition >> level) ^ 1;
            if (differs && (divergencePosition >> level) == siblingIndex) {
                uint256 relativePosition =
                    divergencePosition & ((uint256(1) << level) - 1);
                sibling = _node(true, level, relativePosition, uniform);
            }
            proof[level] = Tree.Node.unwrap(sibling);
        }
    }

    function _assertNode(Tree.Node actual, Tree.Node expected) internal pure {
        assertEq(Tree.Node.unwrap(actual), Tree.Node.unwrap(expected));
    }

    function _assertHash(Machine.Hash actual, Machine.Hash expected)
        internal
        pure
    {
        assertEq(Machine.Hash.unwrap(actual), Machine.Hash.unwrap(expected));
    }
}
