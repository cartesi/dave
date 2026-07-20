// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ITournament} from "src/ITournament.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

contract MatchViewsHarness {
    using Match for Match.State;

    Match.State private stored;

    function store(Match.State calldata state) external {
        stored = state;
    }

    function requireCanBeAdvanced() external view {
        stored.requireCanBeAdvanced();
    }

    function requireCanBeSealed() external view {
        stored.requireCanBeSealed();
    }

    function requireSealed() external view {
        stored.requireSealed();
    }

    function sealedView(Match.State calldata state, uint64 totalHeight)
        external
        pure
        returns (Match.SealedView memory)
    {
        return Match.sealedView(state, totalHeight);
    }
}

contract MatchViewsTest is Test {
    using Match for Match.State;

    MatchViewsHarness internal immutable HARNESS;

    constructor() {
        HARNESS = new MatchViewsHarness();
    }

    function testFuzzPhaseAndPredicatesFormOnePartition(
        bool isInit,
        uint64 height
    ) public pure {
        Match.State memory state = _state(height, 7, isInit);
        Match.Phase expected = !isInit
            ? Match.Phase.UNINITIALIZED
            : height > 1
                ? Match.Phase.BISECTING
                : height == 1 ? Match.Phase.READY_TO_SEAL : Match.Phase.SEALED;

        assertEq(uint256(state.phase()), uint256(expected));
        assertEq(state.exists(), isInit);
        assertEq(state.canBeAdvanced(), expected == Match.Phase.BISECTING);
        assertEq(state.canBeSealed(), expected == Match.Phase.READY_TO_SEAL);
        assertEq(state.isSealed(), expected == Match.Phase.SEALED);
    }

    function testStorageGuardsRejectAbsenceBeforePhase() public {
        Match.State memory absent;
        HARNESS.store(absent);

        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        HARNESS.requireCanBeAdvanced();
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        HARNESS.requireCanBeSealed();
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        HARNESS.requireSealed();
    }

    function testStorageGuardsPreserveWrongPhaseErrors() public {
        HARNESS.store(_state(1, 0, true));
        vm.expectRevert(ITournament.MatchCannotBeAdvanced.selector);
        HARNESS.requireCanBeAdvanced();
        HARNESS.store(_state(0, 0, true));
        vm.expectRevert(ITournament.MatchCannotBeAdvanced.selector);
        HARNESS.requireCanBeAdvanced();

        HARNESS.store(_state(2, 0, true));
        vm.expectRevert(ITournament.MatchCannotBeSealed.selector);
        HARNESS.requireCanBeSealed();
        HARNESS.store(_state(0, 0, true));
        vm.expectRevert(ITournament.MatchCannotBeSealed.selector);
        HARNESS.requireCanBeSealed();

        HARNESS.store(_state(2, 0, true));
        vm.expectRevert(ITournament.MatchIsNotSealed.selector);
        HARNESS.requireSealed();
        HARNESS.store(_state(1, 0, true));
        vm.expectRevert(ITournament.MatchIsNotSealed.selector);
        HARNESS.requireSealed();
    }

    function testStorageGuardsAcceptTheirExactPhase() public {
        HARNESS.store(_state(2, 0, true));
        HARNESS.requireCanBeAdvanced();

        HARNESS.store(_state(1, 0, true));
        HARNESS.requireCanBeSealed();

        HARNESS.store(_state(0, 0, true));
        HARNESS.requireSealed();
    }

    function testSealedViewDecodesEveryHeightAndPositionParity() public pure {
        for (uint64 totalHeight = 2; totalHeight <= 3; ++totalHeight) {
            _assertSealedView(totalHeight, 0);
            _assertSealedView(totalHeight, 1);
        }
    }

    function testSealedViewRejectsAbsentAndUnsealedStates() public {
        Match.State memory state;
        vm.expectRevert(ITournament.MatchDoesNotExist.selector);
        HARNESS.sealedView(state, 2);

        state = _state(1, 0, true);
        vm.expectRevert(ITournament.MatchIsNotSealed.selector);
        HARNESS.sealedView(state, 2);
    }

    function _assertSealedView(uint64 totalHeight, uint256 position)
        internal
        pure
    {
        Machine.Hash agreeState = _hash(0xa0);
        Machine.Hash finalStateOne = _hash(0xb1);
        Machine.Hash finalStateTwo = _hash(0xb2);
        bool leftStoresOne = uint256(totalHeight % 2) == position % 2;
        Machine.Hash storedLeft = leftStoresOne ? finalStateOne : finalStateTwo;
        Machine.Hash storedRight = leftStoresOne ? finalStateTwo : finalStateOne;

        Match.State memory state = Match.State({
            otherParent: Tree.Node.wrap(Machine.Hash.unwrap(agreeState)),
            leftNode: Tree.Node.wrap(Machine.Hash.unwrap(storedLeft)),
            rightNode: Tree.Node.wrap(Machine.Hash.unwrap(storedRight)),
            runningLeafPosition: position,
            currentHeight: 0,
            isInit: true
        });
        Match.SealedView memory view_ = state.sealedView(totalHeight);

        assertEq(
            Machine.Hash.unwrap(view_.agreeState),
            Machine.Hash.unwrap(agreeState)
        );
        assertEq(view_.divergencePosition, position);
        assertEq(
            Machine.Hash.unwrap(view_.finalStateOne),
            Machine.Hash.unwrap(finalStateOne)
        );
        assertEq(
            Machine.Hash.unwrap(view_.finalStateTwo),
            Machine.Hash.unwrap(finalStateTwo)
        );
    }

    function _state(uint64 height, uint256 position, bool isInit)
        internal
        pure
        returns (Match.State memory)
    {
        return Match.State({
            otherParent: _node(0x11),
            leftNode: _node(0x12),
            rightNode: _node(0x13),
            runningLeafPosition: position,
            currentHeight: height,
            isInit: isInit
        });
    }

    function _node(uint256 value) internal pure returns (Tree.Node) {
        return Tree.Node.wrap(bytes32(value));
    }

    function _hash(uint256 value) internal pure returns (Machine.Hash) {
        return Machine.Hash.wrap(bytes32(value));
    }
}
