// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std/console.sol";
import "forge-std/Test.sol";

import "src/tournament/libs/Match.sol";
import "src/CanonicalConstants.sol";

pragma solidity ^0.8.0;

library ExternalMatch {
    function requireEq(Match.IdHash left, Match.IdHash right) external {
        Match.requireEq(left, right);
    }
}

contract MatchTest is Test {
    using Tree for Tree.Node;
    using Machine for Machine.Hash;
    using Match for Match.Id;
    using Match for Match.IdHash;
    using Match for Match.State;

    Tree.Node constant ONE_NODE = Tree.Node.wrap(bytes32(uint256(1)));

    Match.State leftDivergenceMatch;
    Match.State rightDivergenceMatch;
    Match.IdHash leftDivergenceMatchId;
    Match.IdHash rightDivergenceMatchId;

    function setUp() public {
        Tree.Node leftDivergenceCommitment1 =
            Tree.ZERO_NODE.join(Tree.ZERO_NODE);
        Tree.Node rightDivergenceCommitment1 =
            Tree.ZERO_NODE.join(Tree.ZERO_NODE);

        Tree.Node leftDivergenceCommitment2 = ONE_NODE.join(Tree.ZERO_NODE);
        Tree.Node rightDivergenceCommitment2 = Tree.ZERO_NODE.join(ONE_NODE);

        (leftDivergenceMatchId, leftDivergenceMatch) = Match.createMatch(
            leftDivergenceCommitment1,
            leftDivergenceCommitment2,
            ONE_NODE,
            Tree.ZERO_NODE,
            0,
            1
        );

        (rightDivergenceMatchId, rightDivergenceMatch) = Match.createMatch(
            rightDivergenceCommitment1,
            rightDivergenceCommitment2,
            Tree.ZERO_NODE,
            ONE_NODE,
            0,
            1
        );
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
        assertTrue(leftDivergenceMatchId.eq(leftDivergenceMatchId));
        assertTrue(rightDivergenceMatchId.eq(rightDivergenceMatchId));
        assertTrue(!leftDivergenceMatchId.eq(rightDivergenceMatchId));
        assertTrue(!rightDivergenceMatchId.eq(leftDivergenceMatchId));

        vm.expectRevert("matches are not equal");
        ExternalMatch.requireEq(leftDivergenceMatchId, rightDivergenceMatchId);
    }
}
