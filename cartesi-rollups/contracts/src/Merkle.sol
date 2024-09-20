// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Math} from "./Math.sol";
import {MerkleConstants} from "./MerkleConstants.sol";
import {PristineMerkleTree} from "./PristineMerkleTree.sol";

library Merkle {
    using Math for uint256;

    /// @notice Compute the parent of two nodes.
    /// @param leftNode The left node
    /// @param rightNode The right node
    /// @return parentNode The parent node
    /// @dev Uses assembly for extra performance
    function parent(bytes32 leftNode, bytes32 rightNode) internal pure returns (bytes32 parentNode) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, leftNode)
            mstore(0x20, rightNode)
            parentNode := keccak256(0x00, 0x40)
        }
    }

    /// @notice Get the Merkle root hash of a drive with a replacement.
    /// @param position position of replacement in drive
    /// @param log2SizeOfReplacement log2 of the size of the replacement
    /// @param log2SizeOfDrive log2 of the size of the drive
    /// @param replacement the hash of the replacement
    /// @param siblings of replacement in bottom-up order
    function getRootAfterReplacementInDrive(
        uint256 position,
        uint256 log2SizeOfReplacement,
        uint256 log2SizeOfDrive,
        bytes32 replacement,
        bytes32[] calldata siblings
    ) internal pure returns (bytes32) {
        require(log2SizeOfReplacement >= MerkleConstants.LOG2_WORD_SIZE, "Replacement smaller than word");
        require(log2SizeOfDrive <= MerkleConstants.LOG2_MEMORY_SIZE, "Drive larger than memory");
        require(log2SizeOfDrive >= log2SizeOfReplacement, "Replacement larger than drive");

        uint256 sizeOfReplacement = 1 << log2SizeOfReplacement;

        // check if `position` is a multiple of `sizeOfReplacement`
        require(((sizeOfReplacement - 1) & position) == 0, "Position is not aligned");

        require(siblings.length == log2SizeOfDrive - log2SizeOfReplacement, "Proof length does not match");

        for (uint256 i; i < siblings.length; ++i) {
            if ((position & (sizeOfReplacement << i)) == 0) {
                replacement = parent(replacement, siblings[i]);
            } else {
                replacement = parent(siblings[i], replacement);
            }
        }

        return replacement;
    }

    /// @notice Get the Merkle root of a byte array.
    /// @param data the byte array
    /// @param log2SizeOfDrive log2 of size of the drive
    /// @dev If data is smaller than the drive, it is padded with zeros.
    /// @dev See `MerkleConstants` for word size.
    function getMerkleRootFromBytes(bytes calldata data, uint256 log2SizeOfDrive) internal pure returns (bytes32) {
        require(log2SizeOfDrive >= MerkleConstants.LOG2_WORD_SIZE, "Drive smaller than word");
        require(log2SizeOfDrive <= MerkleConstants.LOG2_MEMORY_SIZE, "Drive larger than memory");

        uint256 log2NumOfWordsInDrive = log2SizeOfDrive - MerkleConstants.LOG2_WORD_SIZE;

        // if data is empty, then return node from pristine Merkle tree
        if (data.length == 0) {
            return PristineMerkleTree.getNodeAtHeight(log2NumOfWordsInDrive);
        }

        uint256 numOfWordsInDrive = 1 << log2NumOfWordsInDrive;

        require(data.length <= (numOfWordsInDrive << MerkleConstants.LOG2_WORD_SIZE), "Data larger than drive");

        uint256 numOfWordsInData = data.length.ceilDivExp2(MerkleConstants.LOG2_WORD_SIZE);

        bytes32[] memory stack = new bytes32[](2 + numOfWordsInData.getLog2Floor());

        uint256 numOfHashes; // total number of leaves covered up until now
        uint256 stackLength; // total length of stack
        uint256 numOfJoins; // number of hashes of the same level on stack
        uint256 topStackLevel; // level of hash on top of the stack

        while (numOfHashes < numOfWordsInDrive) {
            if ((numOfHashes << MerkleConstants.LOG2_WORD_SIZE) < data.length) {
                // we still have words to hash
                stack[stackLength] = getHashOfWordAtIndex(data, numOfHashes);
                numOfHashes++;

                numOfJoins = numOfHashes;
            } else {
                // since padding happens in getHashOfWordAtIndex function
                // we only need to complete the stack with pre-computed
                // hash(0), hash(hash(0),hash(0)) and so on
                topStackLevel = numOfHashes.ctz();

                stack[stackLength] = PristineMerkleTree.getNodeAtHeight(topStackLevel);

                //Empty Tree Hash summarizes many hashes
                numOfHashes = numOfHashes + (1 << topStackLevel);
                numOfJoins = numOfHashes >> topStackLevel;
            }

            stackLength++;

            // while there are joins, hash top of stack together
            while (numOfJoins & 1 == 0) {
                bytes32 h2 = stack[stackLength - 1];
                bytes32 h1 = stack[stackLength - 2];

                stack[stackLength - 2] = parent(h1, h2);
                stackLength = stackLength - 1; // remove hashes from stack

                numOfJoins = numOfJoins >> 1;
            }
        }

        require(stackLength == 1, "stack error");

        return stack[0];
    }

    /// @notice Get the hash of a word from a byte array by its index.
    /// @param data the byte array
    /// @param wordIndex the word index
    /// @dev The data is assumed to be followed by an infinite sequence of zeroes.
    /// @dev See `MerkleConstants` for word size.
    function getHashOfWordAtIndex(bytes calldata data, uint256 wordIndex) internal pure returns (bytes32) {
        uint256 start = wordIndex << MerkleConstants.LOG2_WORD_SIZE;
        if (start < data.length) {
            return keccak256(abi.encode(bytes32(data[start:])));
        } else {
            return PristineMerkleTree.getNodeAtHeight(0);
        }
    }
}
