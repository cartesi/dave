// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {SmallFullTree} from "./SmallFullTree.sol";
import {SmallTwoLevelClaims} from "./SmallTwoLevelClaims.sol";

contract SmallTwoLevelClaimsTest is Test {
    using Machine for Machine.Hash;
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    function testParentClaimsSelectSegmentFinalStates() public pure {
        SmallFullTree.Data memory fineOne =
            SmallTwoLevelClaims.fineTree(SmallTwoLevelClaims.CLAIM_ONE);
        SmallFullTree.Data memory rootOne =
            SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.CLAIM_ONE);

        assertEq(fineOne.height(), 4);
        assertEq(rootOne.height(), 2);
        for (uint256 segment; segment < 4; ++segment) {
            assertTrue(rootOne.leaf(segment).eq(fineOne.leaf(4 * segment + 3)));
        }
    }

    function testRootAndChildSeamIsCoherent() public pure {
        SmallFullTree.Data memory rootOne =
            SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.CLAIM_ONE);
        SmallFullTree.Data memory rootTwo =
            SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.CLAIM_TWO);
        (bool parentDiffers, uint256 parentPosition) =
            rootOne.firstDivergence(rootTwo);
        assertTrue(parentDiffers);
        assertEq(parentPosition, 2);

        Machine.Hash childInitialOne = SmallTwoLevelClaims.childInitialState(
            SmallTwoLevelClaims.CLAIM_ONE, parentPosition
        );
        Machine.Hash childInitialTwo = SmallTwoLevelClaims.childInitialState(
            SmallTwoLevelClaims.CLAIM_TWO, parentPosition
        );
        assertEq(
            Machine.Hash.unwrap(childInitialOne),
            Machine.Hash.unwrap(childInitialTwo)
        );
        assertTrue(
            Tree.Node.wrap(Machine.Hash.unwrap(childInitialOne))
                .eq(rootOne.leaf(parentPosition - 1))
        );
        assertEq(SmallTwoLevelClaims.childStartCycle(parentPosition), 8);

        SmallFullTree.Data memory childOne = SmallTwoLevelClaims.childTree(
            SmallTwoLevelClaims.CLAIM_ONE, parentPosition
        );
        SmallFullTree.Data memory childTwo = SmallTwoLevelClaims.childTree(
            SmallTwoLevelClaims.CLAIM_TWO, parentPosition
        );
        assertTrue(
            childOne.finalState()
                .eq(rootOne.leaf(parentPosition).toMachineHash())
        );
        assertTrue(
            childTwo.finalState()
                .eq(rootTwo.leaf(parentPosition).toMachineHash())
        );
        (bool childDiffers, uint256 childPosition) =
            childOne.firstDivergence(childTwo);
        assertTrue(childDiffers);
        assertEq(childPosition, 0);
    }

    function testDanglingClaimIsDistinct() public pure {
        SmallFullTree.Data memory dangling =
            SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.DANGLING_CLAIM);
        assertFalse(
            dangling.root()
                .eq(
                    SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.CLAIM_ONE)
                        .root()
                )
        );
        assertFalse(
            dangling.root()
                .eq(
                    SmallTwoLevelClaims.rootTree(SmallTwoLevelClaims.CLAIM_TWO)
                        .root()
                )
        );
    }
}
