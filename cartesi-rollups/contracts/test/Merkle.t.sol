// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {MerkleConstants} from "src/MerkleConstants.sol";
import {PristineMerkleTree} from "src/PristineMerkleTree.sol";
import {Merkle} from "src/Merkle.sol";

library PristineMerkleTreeWrapper {
    function getNodeAtHeight(uint256 height) external pure returns (bytes32) {
        return PristineMerkleTree.getNodeAtHeight(height);
    }
}

library MerkleWrapper {
    function join(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return Merkle.join(a, b);
    }

    function getRootAfterReplacementInDrive(
        uint256 position,
        uint256 log2SizeOfReplacement,
        uint256 log2SizeOfDrive,
        bytes32 replacement,
        bytes32[] calldata siblings
    ) external pure returns (bytes32) {
        return Merkle.getRootAfterReplacementInDrive(
            position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
        );
    }

    function getMinLog2SizeOfDrive(bytes calldata data) external pure returns (uint256) {
        return Merkle.getMinLog2SizeOfDrive(data);
    }

    function getMerkleRootFromBytes(bytes calldata data, uint256 log2SizeOfDrive) external pure returns (bytes32) {
        return Merkle.getMerkleRootFromBytes(data, log2SizeOfDrive);
    }

    function getHashOfLeafAtIndex(bytes calldata data, uint256 leafIndex) external pure returns (bytes32) {
        return Merkle.getHashOfLeafAtIndex(data, leafIndex);
    }
}

contract MerkleTest is Test {
    uint256 constant LEAF_SIZE = (1 << MerkleConstants.LOG2_LEAF_SIZE);
    bytes32 constant WORD_0 = keccak256("foo");
    bytes32 constant WORD_1 = keccak256("bar");
    bytes1 constant WORD_2 = hex"ff";
    uint256 constant HEIGHT = 2;
    bytes32 constant LEAF_0 = keccak256(abi.encode(WORD_0));
    bytes32 constant LEAF_1 = keccak256(abi.encode(WORD_1));
    bytes32 constant LEAF_2 = keccak256(abi.encode(WORD_2));
    bytes32 constant LEAF_3 = keccak256(abi.encode(bytes32(0)));
    bytes32 constant NODE_01 = keccak256(abi.encode(LEAF_0, LEAF_1));
    bytes32 constant NODE_23 = keccak256(abi.encode(LEAF_2, LEAF_3));
    bytes32 constant ROOT = keccak256(abi.encode(NODE_01, NODE_23));
    uint256 constant MAX_HEIGHT = MerkleConstants.LOG2_MEMORY_SIZE - MerkleConstants.LOG2_LEAF_SIZE;

    function testJoinEquivalence(bytes32 a, bytes32 b) external pure {
        assertEq(MerkleWrapper.join(a, b), keccak256(abi.encodePacked(a, b)));
    }

    function testPristineMerkleTree() external pure {
        bytes32 node = keccak256(abi.encode(0));
        for (uint256 height; height <= MerkleConstants.TREE_HEIGHT; ++height) {
            assertEq(PristineMerkleTree.getNodeAtHeight(height), node);
            node = MerkleWrapper.join(node, node);
        }
    }

    function testPristineMerkleTreeRevert(uint256 height) external {
        height = bound(height, MerkleConstants.TREE_HEIGHT + 1, type(uint256).max);
        vm.expectRevert("Height out of bounds");
        PristineMerkleTreeWrapper.getNodeAtHeight(height);
    }

    function testGetRootAfterReplacementInDrive() external pure {
        {
            uint256 log2SizeOfReplacement = MerkleConstants.LOG2_LEAF_SIZE;
            uint256 position = 0 << log2SizeOfReplacement;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = LEAF_0;
            bytes32[] memory siblings = new bytes32[](2);
            siblings[0] = LEAF_1;
            siblings[1] = NODE_23;

            //                          +------+
            //                          | root |
            //                          +---+--+
            //                              |
            //                  +-----------+----------+
            //                  |                      |
            //              +---+--+                +--+---+
            //              |      |                | sib1 |
            //              +---+--+                +------+
            //                  |
            //      +-----------+----------+
            //      |                      |
            //  +---+--+                +--+---+
            //  | repl |                | sib0 |
            //  +------+                +------+

            assertEq(
                ROOT,
                MerkleWrapper.getRootAfterReplacementInDrive(
                    position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
                )
            );
        }
        {
            uint256 log2SizeOfReplacement = MerkleConstants.LOG2_LEAF_SIZE;
            uint256 position = 1 << log2SizeOfReplacement;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = LEAF_1;
            bytes32[] memory siblings = new bytes32[](2);
            siblings[0] = LEAF_0;
            siblings[1] = NODE_23;

            //                          +------+
            //                          | root |
            //                          +---+--+
            //                              |
            //                  +-----------+----------+
            //                  |                      |
            //              +---+--+                +--+---+
            //              |      |                | sib1 |
            //              +---+--+                +------+
            //                  |
            //      +-----------+----------+
            //      |                      |
            //  +---+--+                +--+---+
            //  | sib0 |                | repl |
            //  +------+                +------+

            assertEq(
                ROOT,
                MerkleWrapper.getRootAfterReplacementInDrive(
                    position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
                )
            );
        }
        {
            uint256 log2SizeOfReplacement = MerkleConstants.LOG2_LEAF_SIZE;
            uint256 position = 2 << log2SizeOfReplacement;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = LEAF_2;
            bytes32[] memory siblings = new bytes32[](2);
            siblings[0] = LEAF_3;
            siblings[1] = NODE_01;

            //        +------+
            //        | root |
            //        +--+---+
            //           |
            //      +----+---------+
            //      |              |
            //  +---+---+      +---+--+
            //  | sib1  |      |      |
            //  +-------+      +--+---+
            //                    |
            //          +---------+-----------+
            //          |                     |
            //      +---+---+             +---+--+
            //      | repl  |             | sib0 |
            //      +-------+             +------+

            assertEq(
                ROOT,
                MerkleWrapper.getRootAfterReplacementInDrive(
                    position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
                )
            );
        }
        {
            uint256 log2SizeOfReplacement = MerkleConstants.LOG2_LEAF_SIZE;
            uint256 position = 3 << log2SizeOfReplacement;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = LEAF_3;
            bytes32[] memory siblings = new bytes32[](2);
            siblings[0] = LEAF_2;
            siblings[1] = NODE_01;

            //        +------+
            //        | root |
            //        +--+---+
            //           |
            //      +----+---------+
            //      |              |
            //  +---+---+      +---+--+
            //  | sib1  |      |      |
            //  +-------+      +--+---+
            //                    |
            //          +---------+-----------+
            //          |                     |
            //      +---+---+             +---+--+
            //      | sib0  |             | repl |
            //      +-------+             +------+

            assertEq(
                ROOT,
                MerkleWrapper.getRootAfterReplacementInDrive(
                    position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
                )
            );
        }
        {
            uint256 log2SizeOfReplacement = 1 + MerkleConstants.LOG2_LEAF_SIZE;
            uint256 position = 0 << log2SizeOfReplacement;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = NODE_01;
            bytes32[] memory siblings = new bytes32[](1);
            siblings[0] = NODE_23;

            //        +------+
            //        | root |
            //        +--+---+
            //           |
            //      +----+---------+
            //      |              |
            //  +---+---+      +---+--+
            //  | repl  |      | sib0 |
            //  +-------+      +------+

            assertEq(
                ROOT,
                MerkleWrapper.getRootAfterReplacementInDrive(
                    position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
                )
            );
        }
        {
            uint256 log2SizeOfReplacement = 1 + MerkleConstants.LOG2_LEAF_SIZE;
            uint256 position = 1 << log2SizeOfReplacement;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = NODE_23;
            bytes32[] memory siblings = new bytes32[](1);
            siblings[0] = NODE_01;

            //        +------+
            //        | root |
            //        +--+---+
            //           |
            //      +----+---------+
            //      |              |
            //  +---+---+      +---+--+
            //  | sib0  |      | repl |
            //  +-------+      +------+

            assertEq(
                ROOT,
                MerkleWrapper.getRootAfterReplacementInDrive(
                    position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
                )
            );
        }
    }

    function testGetRootAfterReplacementInDriveRevertsPositionNotAligned(uint256 position) external {
        vm.assume(position % (1 << MerkleConstants.LOG2_LEAF_SIZE) != 0);
        {
            uint256 log2SizeOfReplacement = MerkleConstants.LOG2_LEAF_SIZE;
            uint256 log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + HEIGHT;
            bytes32 replacement = LEAF_0;
            bytes32[] memory siblings = new bytes32[](2);
            siblings[0] = LEAF_1;
            siblings[1] = NODE_23;
            vm.expectRevert("Position is not aligned");
            MerkleWrapper.getRootAfterReplacementInDrive(
                position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
            );
        }
    }

    function testGetRootAfterAnyReplacementInDriveRevertsProofLengthDoesNotMatch(
        uint256 position,
        uint256 log2SizeOfReplacement,
        uint256 log2SizeOfDrive,
        bytes32 replacement,
        bytes32[] calldata siblings
    ) external {
        log2SizeOfDrive = bound(log2SizeOfDrive, MerkleConstants.LOG2_LEAF_SIZE, MerkleConstants.LOG2_MEMORY_SIZE);
        log2SizeOfReplacement = bound(log2SizeOfReplacement, MerkleConstants.LOG2_LEAF_SIZE, log2SizeOfDrive);
        vm.assume(siblings.length != log2SizeOfDrive - log2SizeOfReplacement);
        position = (position >> log2SizeOfReplacement) << log2SizeOfReplacement;
        vm.expectRevert("Proof length does not match");
        MerkleWrapper.getRootAfterReplacementInDrive(
            position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
        );
    }

    function testGetRootAfterAnyReplacementInDrive(
        uint256 position,
        uint256 log2SizeOfReplacement,
        uint256 log2SizeOfDrive,
        bytes32 replacement
    ) external pure {
        log2SizeOfDrive = bound(log2SizeOfDrive, MerkleConstants.LOG2_LEAF_SIZE, MerkleConstants.LOG2_MEMORY_SIZE);
        log2SizeOfReplacement = bound(log2SizeOfReplacement, MerkleConstants.LOG2_LEAF_SIZE, log2SizeOfDrive);
        bytes32[] memory siblings = new bytes32[](log2SizeOfDrive - log2SizeOfReplacement);
        position = (position >> log2SizeOfReplacement) << log2SizeOfReplacement;
        MerkleWrapper.getRootAfterReplacementInDrive(
            position, log2SizeOfReplacement, log2SizeOfDrive, replacement, siblings
        );
    }

    function testGetMinLog2SizeOfDrive(bytes calldata data) external pure {
        uint256 log2SizeOfDrive = MerkleWrapper.getMinLog2SizeOfDrive(data);
        assertLe(data.length, 1 << log2SizeOfDrive);
        if (data.length <= LEAF_SIZE) {
            assertEq(log2SizeOfDrive, MerkleConstants.LOG2_LEAF_SIZE);
        } else {
            assertGt(data.length, 1 << (log2SizeOfDrive - 1));
        }
        MerkleWrapper.getMerkleRootFromBytes(data, log2SizeOfDrive);
    }

    function testGetMerkleRootFromBytes() external pure {
        bytes memory data = _getTestData();
        bytes32 root = ROOT;
        for (uint256 i; MerkleConstants.LOG2_LEAF_SIZE + HEIGHT + i <= MerkleConstants.LOG2_MEMORY_SIZE; ++i) {
            assertEq(MerkleWrapper.getMerkleRootFromBytes(data, MerkleConstants.LOG2_LEAF_SIZE + HEIGHT + i), root);
            root = MerkleWrapper.join(root, PristineMerkleTree.getNodeAtHeight(HEIGHT + i));
        }
    }

    function testGetMerkleRootFromBytesRevertDriveSmallerThanLeaf(uint256 log2SizeOfDrive) external {
        log2SizeOfDrive = bound(log2SizeOfDrive, 0, MerkleConstants.LOG2_LEAF_SIZE - 1);
        vm.expectRevert("Drive smaller than leaf");
        MerkleWrapper.getMerkleRootFromBytes(_getTestData(), log2SizeOfDrive);
    }

    function testGetMerkleRootFromBytesRevertDataLargerThanDrive(uint256 log2SizeOfDrive) external {
        log2SizeOfDrive = MerkleConstants.LOG2_LEAF_SIZE + bound(log2SizeOfDrive, 0, HEIGHT - 1);
        vm.expectRevert("Data larger than drive");
        MerkleWrapper.getMerkleRootFromBytes(_getTestData(), log2SizeOfDrive);
    }

    function testGetMerkleRootFromBytesRevertDriveLargerThanMemory(uint256 log2SizeOfDrive) external {
        log2SizeOfDrive = bound(log2SizeOfDrive, MerkleConstants.LOG2_MEMORY_SIZE + 1, type(uint256).max);
        vm.expectRevert("Drive larger than memory");
        MerkleWrapper.getMerkleRootFromBytes(_getTestData(), log2SizeOfDrive);
    }

    function testGetHashOfLeafAtIndex() external pure {
        bytes memory data = _getTestData();
        assertEq(MerkleWrapper.getHashOfLeafAtIndex(data, 0), LEAF_0);
        assertEq(MerkleWrapper.getHashOfLeafAtIndex(data, 1), LEAF_1);
        assertEq(MerkleWrapper.getHashOfLeafAtIndex(data, 2), LEAF_2);
    }

    function testGetHashOfLeafAtIndex(bytes calldata data, uint256 index) external pure {
        index = bound(index, _getNumOfLeaves(data.length), type(uint256).max);
        bytes32 leafHash = PristineMerkleTree.getNodeAtHeight(0);
        assertEq(MerkleWrapper.getHashOfLeafAtIndex(data, index), leafHash);
    }

    function _getTestData() internal pure returns (bytes memory) {
        return abi.encodePacked(WORD_0, WORD_1, WORD_2);
    }

    function _getNumOfLeaves(uint256 length) internal pure returns (uint256) {
        return (length + LEAF_SIZE - 1) / LEAF_SIZE;
    }
}
