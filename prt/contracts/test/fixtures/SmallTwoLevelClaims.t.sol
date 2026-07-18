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
        for (uint8 claim; claim < SmallTwoLevelClaims.CLAIM_COUNT; ++claim) {
            SmallFullTree.Data memory fine = SmallTwoLevelClaims.fineTree(claim);
            SmallFullTree.Data memory root = SmallTwoLevelClaims.rootTree(claim);

            assertEq(fine.height(), 4);
            assertEq(root.height(), 2);
            for (
                uint256 segment;
                segment < SmallTwoLevelClaims.SEGMENT_COUNT;
                ++segment
            ) {
                assertTrue(
                    root.leaf(segment)
                        .eq(
                            fine.leaf(
                                SmallTwoLevelClaims.SEGMENT_SIZE * (segment + 1)
                                    - 1
                            )
                        )
                );
            }
        }
    }

    function testPairedRootAndChildSeamsAreCoherent() public pure {
        _assertCoherentPair(
            SmallTwoLevelClaims.CLAIM_ONE, SmallTwoLevelClaims.CLAIM_TWO
        );
        _assertCoherentPair(
            SmallTwoLevelClaims.CLAIM_THREE, SmallTwoLevelClaims.CLAIM_FOUR
        );
    }

    function testAllRootCommitmentsAreDistinct() public pure {
        Tree.Node[] memory roots =
            new Tree.Node[](SmallTwoLevelClaims.CLAIM_COUNT);
        for (uint8 claim; claim < SmallTwoLevelClaims.CLAIM_COUNT; ++claim) {
            SmallFullTree.Data memory root = SmallTwoLevelClaims.rootTree(claim);
            _requireNewRoot(roots, claim, root.root());
            roots[claim] = root.root();
        }
    }

    function testChildVariantsPreserveShapeFinalStateAndUniqueness()
        public
        pure
    {
        for (uint8 claim; claim < SmallTwoLevelClaims.CLAIM_COUNT; ++claim) {
            SmallFullTree.Data memory root = SmallTwoLevelClaims.rootTree(claim);
            for (
                uint256 segment;
                segment < SmallTwoLevelClaims.SEGMENT_COUNT;
                ++segment
            ) {
                Machine.Hash expectedFinal = root.leaf(segment).toMachineHash();
                Tree.Node[] memory variantRoots =
                    new Tree.Node[](SmallTwoLevelClaims.CHILD_VARIANT_COUNT);
                for (
                    uint8 variant;
                    variant < SmallTwoLevelClaims.CHILD_VARIANT_COUNT;
                    ++variant
                ) {
                    SmallFullTree.Data memory child =
                        SmallTwoLevelClaims.childTreeVariant(
                            claim, segment, variant
                        );
                    assertEq(child.height(), SmallTwoLevelClaims.CHILD_HEIGHT);
                    assertEq(
                        child.leafCount(), SmallTwoLevelClaims.SEGMENT_SIZE
                    );
                    assertTrue(child.finalState().eq(expectedFinal));
                    if (variant == 0) {
                        assertTrue(
                            child.root()
                                .eq(
                                    SmallTwoLevelClaims.childTree(
                                            claim, segment
                                        ).root()
                                )
                        );
                    }

                    _requireNewRoot(variantRoots, variant, child.root());
                    variantRoots[variant] = child.root();
                }
            }
        }
    }

    function testPairedChildPopulationsHaveDistinctRoots() public pure {
        _assertDistinctChildPopulation(
            SmallTwoLevelClaims.CLAIM_ONE, SmallTwoLevelClaims.CLAIM_TWO
        );
        _assertDistinctChildPopulation(
            SmallTwoLevelClaims.CLAIM_THREE, SmallTwoLevelClaims.CLAIM_FOUR
        );
    }

    function testDanglingClaimRemainsTheThirdClaim() public pure {
        assertEq(
            SmallTwoLevelClaims.DANGLING_CLAIM, SmallTwoLevelClaims.CLAIM_THREE
        );
    }

    function _assertCoherentPair(uint8 claimOne, uint8 claimTwo) private pure {
        SmallFullTree.Data memory rootOne =
            SmallTwoLevelClaims.rootTree(claimOne);
        SmallFullTree.Data memory rootTwo =
            SmallTwoLevelClaims.rootTree(claimTwo);
        (bool parentDiffers, uint256 parentPosition) =
            rootOne.firstDivergence(rootTwo);
        assertTrue(parentDiffers);
        assertEq(parentPosition, 2);
        for (uint256 segment; segment < parentPosition; ++segment) {
            assertTrue(
                SmallTwoLevelClaims.childTree(claimOne, segment).root()
                    .eq(SmallTwoLevelClaims.childTree(claimTwo, segment).root())
            );
        }

        Machine.Hash childInitialOne =
            SmallTwoLevelClaims.childInitialState(claimOne, parentPosition);
        Machine.Hash childInitialTwo =
            SmallTwoLevelClaims.childInitialState(claimTwo, parentPosition);
        assertEq(
            Machine.Hash.unwrap(childInitialOne),
            Machine.Hash.unwrap(childInitialTwo)
        );
        assertTrue(
            Tree.Node.wrap(Machine.Hash.unwrap(childInitialOne))
                .eq(rootOne.leaf(parentPosition - 1))
        );
        assertEq(SmallTwoLevelClaims.childStartCycle(parentPosition), 8);

        SmallFullTree.Data memory childOne =
            SmallTwoLevelClaims.childTree(claimOne, parentPosition);
        SmallFullTree.Data memory childTwo =
            SmallTwoLevelClaims.childTree(claimTwo, parentPosition);
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

    function _assertDistinctChildPopulation(uint8 claimOne, uint8 claimTwo)
        private
        pure
    {
        Tree.Node[] memory roots =
            new Tree.Node[](2 * SmallTwoLevelClaims.CHILD_VARIANT_COUNT);
        uint256 count;
        for (
            uint8 variant;
            variant < SmallTwoLevelClaims.CHILD_VARIANT_COUNT;
            ++variant
        ) {
            Tree.Node root =
                SmallTwoLevelClaims.childTreeVariant(claimOne, 2, variant)
                    .root();
            _requireNewRoot(roots, count, root);
            roots[count++] = root;
        }
        for (
            uint8 variant;
            variant < SmallTwoLevelClaims.CHILD_VARIANT_COUNT;
            ++variant
        ) {
            Tree.Node root =
                SmallTwoLevelClaims.childTreeVariant(claimTwo, 2, variant)
                    .root();
            _requireNewRoot(roots, count, root);
            roots[count++] = root;
        }
        assertEq(count, roots.length);
    }

    function _requireNewRoot(
        Tree.Node[] memory roots,
        uint256 count,
        Tree.Node candidate
    ) private pure {
        for (uint256 i; i < count; ++i) {
            assertFalse(candidate.eq(roots[i]));
        }
    }
}
