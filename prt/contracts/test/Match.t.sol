// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std-1.9.6/src/console.sol";
import "forge-std-1.9.6/src/Test.sol";

import "prt-contracts/tournament/libs/Match.sol";
import "prt-contracts/arbitration-config/CanonicalConstants.sol";

pragma solidity ^0.8.0;

library ExternalMatch {
    function requireEq(Match.IdHash left, Match.IdHash right) external pure {
        Match.requireEq(left, right);
    }

    function advanceMatch(
        Match.State storage state,
        Match.Id calldata id,
        Tree.Node leftNode,
        Tree.Node rightNode,
        Tree.Node newLeftNode,
        Tree.Node newRightNode
    ) external {
        Match.advanceMatch(
            state, id, leftNode, rightNode, newLeftNode, newRightNode
        );
    }

    function sealMatch(
        Match.State storage state,
        Match.Id calldata id,
        Machine.Hash initialState,
        Tree.Node leftLeaf,
        Tree.Node rightLeaf,
        Machine.Hash agreeState,
        bytes32[] calldata agreeStateProof
    )
        external
        returns (Machine.Hash divergentStateOne, Machine.Hash divergentStateTwo)
    {
        return Match.sealMatch(
            state,
            id,
            initialState,
            leftLeaf,
            rightLeaf,
            agreeState,
            agreeStateProof
        );
    }
}

contract MatchTest is Test {
    using Tree for Tree.Node;
    using Machine for Machine.Hash;
    using Match for Match.Id;
    using Match for Match.IdHash;
    using Match for Match.State;

    Tree.Node constant ONE_NODE = Tree.Node.wrap(bytes32(uint256(1)));

    Match.State advanceMatchStateLeft;
    Match.State advanceMatchStateRight;

    Match.State leftDivergenceMatch;
    Match.State rightDivergenceMatch;

    Match.IdHash leftDivergenceMatchIdHash;
    Match.IdHash rightDivergenceMatchIdHash;

    Tree.Node leftDivergenceCommitment1 = Tree.ZERO_NODE.join(Tree.ZERO_NODE);
    Tree.Node rightDivergenceCommitment1 = Tree.ZERO_NODE.join(Tree.ZERO_NODE);

    Tree.Node leftDivergenceCommitment2 = ONE_NODE.join(Tree.ZERO_NODE);
    Tree.Node rightDivergenceCommitment2 = Tree.ZERO_NODE.join(ONE_NODE);

    function setUp() public {
        (leftDivergenceMatchIdHash, leftDivergenceMatch) = Match.createMatch(
            leftDivergenceCommitment1,
            leftDivergenceCommitment2,
            ONE_NODE,
            Tree.ZERO_NODE,
            0,
            1
        );

        (rightDivergenceMatchIdHash, rightDivergenceMatch) = Match.createMatch(
            rightDivergenceCommitment1,
            rightDivergenceCommitment2,
            Tree.ZERO_NODE,
            ONE_NODE,
            0,
            1
        );
    }

    function testAdvanceMatchLeft() public {
        Tree.Node leftDivergenceCommitment3 =
            leftDivergenceCommitment1.join(Tree.ZERO_NODE);
        Tree.Node leftDivergenceCommitment4 =
            leftDivergenceCommitment2.join(Tree.ZERO_NODE);

        (, advanceMatchStateLeft) = Match.createMatch(
            leftDivergenceCommitment3,
            leftDivergenceCommitment4,
            leftDivergenceCommitment2,
            Tree.ZERO_NODE,
            0,
            2
        );
        advanceMatchStateLeft.requireExist();

        Match.Id memory id =
            Match.Id(leftDivergenceCommitment3, leftDivergenceCommitment4);

        advanceMatchStateLeft.requireCanBeAdvanced();
        ExternalMatch.advanceMatch(
            advanceMatchStateLeft,
            id,
            leftDivergenceCommitment1,
            Tree.ZERO_NODE,
            Tree.ZERO_NODE,
            Tree.ZERO_NODE
        );

        assertEq(advanceMatchStateLeft.currentHeight, 1);
        assertTrue(advanceMatchStateLeft.leftNode.eq(Tree.ZERO_NODE));
        assertTrue(advanceMatchStateLeft.rightNode.eq(Tree.ZERO_NODE));

        advanceMatchStateLeft.requireCanBeFinalized();
        ExternalMatch.sealMatch(
            advanceMatchStateLeft,
            id,
            Machine.ZERO_STATE,
            ONE_NODE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            new bytes32[](0)
        );

        advanceMatchStateLeft.requireIsFinished();
        (Machine.Hash agreeHash, uint256 agreeCycle,,) =
            advanceMatchStateLeft.getDivergence(0);

        assertEq(agreeCycle, 0);
        assertTrue(agreeHash.eq(Machine.ZERO_STATE));
    }

    function testAdvanceMatchRight() public {
        Tree.Node rightDivergenceCommitment3 =
            Tree.ZERO_NODE.join(rightDivergenceCommitment1);
        Tree.Node rightDivergenceCommitment4 =
            Tree.ZERO_NODE.join(rightDivergenceCommitment2);

        uint64 matchHeight = 2;
        (, advanceMatchStateRight) = Match.createMatch(
            rightDivergenceCommitment3,
            rightDivergenceCommitment4,
            Tree.ZERO_NODE,
            rightDivergenceCommitment2,
            0,
            matchHeight
        );
        advanceMatchStateRight.requireExist();

        Match.Id memory id =
            Match.Id(rightDivergenceCommitment3, rightDivergenceCommitment4);

        advanceMatchStateRight.requireCanBeAdvanced();
        ExternalMatch.advanceMatch(
            advanceMatchStateRight,
            id,
            Tree.ZERO_NODE,
            rightDivergenceCommitment1,
            Tree.ZERO_NODE,
            Tree.ZERO_NODE
        );

        assertEq(advanceMatchStateRight.currentHeight, matchHeight - 1);
        assertTrue(advanceMatchStateRight.leftNode.eq(Tree.ZERO_NODE));
        assertTrue(advanceMatchStateRight.rightNode.eq(Tree.ZERO_NODE));

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = Tree.Node.unwrap(ONE_NODE);
        proof[1] = Tree.Node.unwrap(Tree.ZERO_NODE);

        advanceMatchStateRight.requireCanBeFinalized();
        ExternalMatch.sealMatch(
            advanceMatchStateRight,
            id,
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            ONE_NODE,
            Machine.ZERO_STATE,
            proof
        );

        advanceMatchStateRight.requireIsFinished();
        (Machine.Hash agreeHash, uint256 agreeCycle,,) =
            advanceMatchStateRight.getDivergence(0);

        assertEq(agreeCycle, (1 << matchHeight) - 1);
        assertTrue(agreeHash.eq(Machine.ZERO_STATE));
    }

    function testAdvanceMatchRight2() public {
        Tree.Node rightDivergenceCommitment3 =
            Tree.ZERO_NODE.join(rightDivergenceCommitment1);
        Tree.Node rightDivergenceCommitment4 =
            Tree.ZERO_NODE.join(rightDivergenceCommitment2);
        Tree.Node rightDivergenceCommitment5 =
            Tree.ZERO_NODE.join(rightDivergenceCommitment3);
        Tree.Node rightDivergenceCommitment6 =
            Tree.ZERO_NODE.join(rightDivergenceCommitment4);

        uint64 matchHeight = 3;
        (, advanceMatchStateRight) = Match.createMatch(
            rightDivergenceCommitment5,
            rightDivergenceCommitment6,
            Tree.ZERO_NODE,
            rightDivergenceCommitment4,
            0,
            matchHeight
        );
        advanceMatchStateRight.requireExist();

        Match.Id memory id =
            Match.Id(rightDivergenceCommitment5, rightDivergenceCommitment6);

        advanceMatchStateRight.requireCanBeAdvanced();
        ExternalMatch.advanceMatch(
            advanceMatchStateRight,
            id,
            Tree.ZERO_NODE,
            rightDivergenceCommitment3,
            Tree.ZERO_NODE,
            rightDivergenceCommitment1
        );

        assertEq(advanceMatchStateRight.currentHeight, matchHeight - 1);
        assertTrue(advanceMatchStateRight.leftNode.eq(Tree.ZERO_NODE));
        assertTrue(
            advanceMatchStateRight.rightNode.eq(rightDivergenceCommitment1)
        );

        advanceMatchStateRight.requireCanBeAdvanced();
        ExternalMatch.advanceMatch(
            advanceMatchStateRight,
            id,
            Tree.ZERO_NODE,
            rightDivergenceCommitment2,
            Tree.ZERO_NODE,
            ONE_NODE
        );

        assertEq(advanceMatchStateRight.currentHeight, matchHeight - 2);
        assertTrue(advanceMatchStateRight.leftNode.eq(Tree.ZERO_NODE));
        assertTrue(advanceMatchStateRight.rightNode.eq(ONE_NODE));

        bytes32[] memory proof = new bytes32[](3);
        proof[0] = Tree.Node.unwrap(Tree.ZERO_NODE);
        proof[1] = Tree.Node.unwrap(Tree.ZERO_NODE);
        proof[2] = Tree.Node.unwrap(Tree.ZERO_NODE);

        advanceMatchStateRight.requireCanBeFinalized();
        ExternalMatch.sealMatch(
            advanceMatchStateRight,
            id,
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            proof
        );

        advanceMatchStateRight.requireIsFinished();
        (Machine.Hash agreeHash, uint256 agreeCycle,,) =
            advanceMatchStateRight.getDivergence(0);

        assertEq(agreeCycle, (1 << matchHeight) - 1);
        assertTrue(agreeHash.eq(Machine.ZERO_STATE));
    }

    function testDivergenceLeftWithEvenHeight() public {
        assertTrue(
            !leftDivergenceMatch.agreesOnLeftNode(Tree.ZERO_NODE),
            "left node should diverge"
        );

        leftDivergenceMatch.height = 2;
        (Machine.Hash _finalHashOne, Machine.Hash _finalHashTwo) =
            leftDivergenceMatch._setDivergenceOnLeftLeaf(Tree.ZERO_NODE);

        assertTrue(
            _finalHashOne.eq(ONE_NODE.toMachineHash()), "hash one should be 1"
        );
        assertTrue(
            _finalHashTwo.eq(Tree.ZERO_NODE.toMachineHash()),
            "hash two should be zero"
        );
    }

    function testDivergenceRightWithEvenHeight() public {
        assertTrue(
            rightDivergenceMatch.agreesOnLeftNode(Tree.ZERO_NODE),
            "left node should match"
        );

        rightDivergenceMatch.height = 2;
        (Machine.Hash _finalHashOne, Machine.Hash _finalHashTwo) =
            rightDivergenceMatch._setDivergenceOnRightLeaf(Tree.ZERO_NODE);

        assertTrue(
            _finalHashOne.eq(ONE_NODE.toMachineHash()), "hash one should be 1"
        );
        assertTrue(
            _finalHashTwo.eq(Tree.ZERO_NODE.toMachineHash()),
            "hash two should be zero"
        );
    }

    function testDivergenceLeftWithOddHeight() public {
        assertTrue(
            !leftDivergenceMatch.agreesOnLeftNode(Tree.ZERO_NODE),
            "left node should diverge"
        );

        leftDivergenceMatch.height = 3;
        (Machine.Hash _finalHashOne, Machine.Hash _finalHashTwo) =
            leftDivergenceMatch._setDivergenceOnLeftLeaf(Tree.ZERO_NODE);

        assertTrue(
            _finalHashOne.eq(Tree.ZERO_NODE.toMachineHash()),
            "hash one should be zero"
        );
        assertTrue(
            _finalHashTwo.eq(ONE_NODE.toMachineHash()), "hash two should be 1"
        );
    }

    function testDivergenceRightWithOddHeight() public {
        assertTrue(
            rightDivergenceMatch.agreesOnLeftNode(Tree.ZERO_NODE),
            "left node should match"
        );

        rightDivergenceMatch.height = 3;
        (Machine.Hash _finalHashOne, Machine.Hash _finalHashTwo) =
            rightDivergenceMatch._setDivergenceOnRightLeaf(Tree.ZERO_NODE);

        assertTrue(
            _finalHashOne.eq(Tree.ZERO_NODE.toMachineHash()),
            "hash one should be zero"
        );
        assertTrue(
            _finalHashTwo.eq(ONE_NODE.toMachineHash()), "hash two should be 1"
        );
    }

    function testEqual() public {
        assertTrue(leftDivergenceMatchIdHash.eq(leftDivergenceMatchIdHash));
        assertTrue(rightDivergenceMatchIdHash.eq(rightDivergenceMatchIdHash));
        assertTrue(!leftDivergenceMatchIdHash.eq(rightDivergenceMatchIdHash));
        assertTrue(!rightDivergenceMatchIdHash.eq(leftDivergenceMatchIdHash));

        vm.expectRevert("matches are not equal");
        ExternalMatch.requireEq(
            leftDivergenceMatchIdHash, rightDivergenceMatchIdHash
        );
    }

    function testIdHash() public pure {
        Match.Id memory id = Match.Id(Tree.ZERO_NODE, Tree.ZERO_NODE);
        Match.IdHash idHash = id.hashFromId();
        idHash.requireExist();
    }
}
