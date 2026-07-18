// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {SmallFullTree} from "./SmallFullTree.sol";

/// @dev Coordinate-coherent claims over the small two-level geometry. These
/// state tables exercise commitment plumbing; they are not an execution oracle.
library SmallTwoLevelClaims {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint8 internal constant CLAIM_ONE = 0;
    uint8 internal constant CLAIM_TWO = 1;
    uint8 internal constant DANGLING_CLAIM = 2;

    uint64 internal constant FINE_HEIGHT = 4;
    uint64 internal constant ROOT_HEIGHT = 2;
    uint64 internal constant CHILD_HEIGHT = 2;
    uint256 internal constant SEGMENT_SIZE = 1 << CHILD_HEIGHT;
    uint256 internal constant SEGMENT_COUNT = 1 << ROOT_HEIGHT;

    error InvalidClaim(uint8 claim);
    error InvalidSegment(uint256 segment);

    function initialState() internal pure returns (Machine.Hash) {
        return Machine.Hash.wrap(bytes32(uint256(0x0abc)));
    }

    function fineTree(uint8 claim)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        return SmallFullTree.buildFromLeaves(_fineLeaves(claim));
    }

    function rootTree(uint8 claim)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        Tree.Node[] memory fine = _fineLeaves(claim);
        Tree.Node[] memory coarse = new Tree.Node[](SEGMENT_COUNT);
        for (uint256 segment; segment < SEGMENT_COUNT; ++segment) {
            coarse[segment] = fine[(segment + 1) * SEGMENT_SIZE - 1];
        }
        return SmallFullTree.buildFromLeaves(coarse);
    }

    function childTree(uint8 claim, uint256 segment)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        if (segment >= SEGMENT_COUNT) revert InvalidSegment(segment);
        Tree.Node[] memory fine = _fineLeaves(claim);
        Tree.Node[] memory child = new Tree.Node[](SEGMENT_SIZE);
        uint256 offset = segment * SEGMENT_SIZE;
        for (uint256 i; i < SEGMENT_SIZE; ++i) {
            child[i] = fine[offset + i];
        }
        return SmallFullTree.buildFromLeaves(child);
    }

    function childInitialState(uint8 claim, uint256 segment)
        internal
        pure
        returns (Machine.Hash)
    {
        if (segment >= SEGMENT_COUNT) revert InvalidSegment(segment);
        if (segment == 0) return initialState();
        return _fineLeaves(claim)[segment * SEGMENT_SIZE - 1].toMachineHash();
    }

    function childStartCycle(uint256 segment) internal pure returns (uint256) {
        if (segment >= SEGMENT_COUNT) revert InvalidSegment(segment);
        return segment * SEGMENT_SIZE;
    }

    function _fineLeaves(uint8 claim)
        private
        pure
        returns (Tree.Node[] memory fine)
    {
        if (claim > DANGLING_CLAIM) revert InvalidClaim(claim);

        fine = new Tree.Node[](1 << FINE_HEIGHT);
        for (uint256 i; i < fine.length; ++i) {
            uint256 value;
            if (claim == CLAIM_ONE || (claim == CLAIM_TWO && i < 8)) {
                value = 0x1000 + i;
            } else if (claim == CLAIM_TWO) {
                value = 0x2000 + i;
            } else {
                value = 0x3000 + i;
            }
            fine[i] = Tree.Node.wrap(bytes32(value));
        }
    }
}
