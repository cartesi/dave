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
    uint8 internal constant CLAIM_THREE = 2;
    uint8 internal constant DANGLING_CLAIM = CLAIM_THREE;
    uint8 internal constant CLAIM_FOUR = 3;
    uint8 internal constant CLAIM_COUNT = 4;
    uint8 internal constant CHILD_VARIANT_COUNT = 4;

    uint64 internal constant FINE_HEIGHT = 4;
    uint64 internal constant ROOT_HEIGHT = 2;
    uint64 internal constant CHILD_HEIGHT = 2;
    uint256 internal constant SEGMENT_SIZE = 1 << CHILD_HEIGHT;
    uint256 internal constant SEGMENT_COUNT = 1 << ROOT_HEIGHT;

    error InvalidClaim(uint8 claim);
    error InvalidSegment(uint256 segment);
    error InvalidChildVariant(uint8 variant);

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
        return childTreeVariant(claim, segment, 0);
    }

    /// @dev Variant zero is the canonical child slice. The other variants
    /// change only the first child leaf, keeping the parent-selected final
    /// state fixed while producing distinct commitment roots for population
    /// tests. They are plumbing witnesses, not execution traces.
    function childTreeVariant(uint8 claim, uint256 segment, uint8 variant)
        internal
        pure
        returns (SmallFullTree.Data memory)
    {
        if (segment >= SEGMENT_COUNT) revert InvalidSegment(segment);
        if (variant >= CHILD_VARIANT_COUNT) {
            revert InvalidChildVariant(variant);
        }
        Tree.Node[] memory fine = _fineLeaves(claim);
        Tree.Node[] memory child = new Tree.Node[](SEGMENT_SIZE);
        uint256 offset = segment * SEGMENT_SIZE;
        for (uint256 i; i < SEGMENT_SIZE; ++i) {
            child[i] = fine[offset + i];
        }
        if (variant != 0) {
            uint256 variantLeaf =
                0x80000000 + (uint256(claim) << 16) + (segment << 8) + variant;
            child[0] = Tree.Node.wrap(bytes32(variantLeaf));
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
        if (claim >= CLAIM_COUNT) revert InvalidClaim(claim);

        fine = new Tree.Node[](1 << FINE_HEIGHT);
        for (uint256 i; i < fine.length; ++i) {
            uint256 family;
            if (claim == CLAIM_ONE) {
                family = 0x1000;
            } else if (claim == CLAIM_TWO) {
                family = i < 8 ? 0x1000 : 0x2000;
            } else if (claim == CLAIM_THREE) {
                family = 0x3000;
            } else {
                family = i < 8 ? 0x3000 : 0x4000;
            }
            fine[i] = Tree.Node.wrap(bytes32(family + i));
        }
    }
}
