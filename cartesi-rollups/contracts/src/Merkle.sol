// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Math} from "./Math.sol";
import {MerkleConstants} from "./MerkleConstants.sol";
import {PristineMerkleTree} from "./PristineMerkleTree.sol";

library Merkle {
    using Math for uint256;

    /// @notice Compute the hash of the concatenation of two 32-byte values.
    /// @param a The first value
    /// @param b The second value
    /// @return c The result of `keccak256(abi.encodePacked(a, b))`
    /// @dev Uses assembly for better performance.
    function join(bytes32 a, bytes32 b) internal pure returns (bytes32 c) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            c := keccak256(0x00, 0x40)
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
        require(log2SizeOfReplacement >= MerkleConstants.LOG2_LEAF_SIZE, "Replacement smaller than leaf");
        require(log2SizeOfDrive <= MerkleConstants.LOG2_MEMORY_SIZE, "Drive larger than memory");
        require(log2SizeOfDrive >= log2SizeOfReplacement, "Replacement larger than drive");

        uint256 sizeOfReplacement = 1 << log2SizeOfReplacement;

        // check if `position` is a multiple of `sizeOfReplacement`
        require(((sizeOfReplacement - 1) & position) == 0, "Position is not aligned");

        require(siblings.length == log2SizeOfDrive - log2SizeOfReplacement, "Proof length does not match");

        for (uint256 i; i < siblings.length; ++i) {
            if ((position & (sizeOfReplacement << i)) == 0) {
                replacement = join(replacement, siblings[i]);
            } else {
                replacement = join(siblings[i], replacement);
            }
        }

        return replacement;
    }

    /// @notice Get the log2 of the smallest drive that first the provided data.
    /// @param data the byte array
    /// @dev If data is smaller than the drive, it is padded with zeros.
    /// @dev The smallest tree covers at least one leaf.
    /// @dev See `MerkleConstants` for leaf size.
    function getMinLog2SizeOfDrive(bytes calldata data) internal pure returns (uint256) {
        return data.length.log2clp().max(MerkleConstants.LOG2_LEAF_SIZE);
    }

    /// @notice Get the Merkle root of a byte array.
    /// @param data the byte array
    /// @param log2SizeOfDrive log2 of size of the drive
    /// @dev If data is smaller than the drive, it is padded with zeros.
    /// @dev See `MerkleConstants` for leaf size.
    function getMerkleRootFromBytes(bytes calldata data, uint256 log2SizeOfDrive) internal pure returns (bytes32) {
        require(log2SizeOfDrive >= MerkleConstants.LOG2_LEAF_SIZE, "Drive smaller than leaf");
        require(log2SizeOfDrive <= MerkleConstants.LOG2_MEMORY_SIZE, "Drive larger than memory");

        uint256 log2NumOfLeavesInDrive = log2SizeOfDrive - MerkleConstants.LOG2_LEAF_SIZE;

        // if data is empty, then return node from pristine Merkle tree
        if (data.length == 0) {
            return PristineMerkleTree.getNodeAtHeight(log2NumOfLeavesInDrive);
        }

        uint256 numOfLeavesInDrive = 1 << log2NumOfLeavesInDrive;

        require(data.length <= (numOfLeavesInDrive << MerkleConstants.LOG2_LEAF_SIZE), "Data larger than drive");

        // Note: This is a very generous stack depth.
        bytes32[] memory stack = new bytes32[](2 + log2NumOfLeavesInDrive);

        uint256 numOfHashes; // total number of leaves covered up until now
        uint256 stackLength; // total length of stack
        uint256 numOfJoins; // number of hashes of the same level on stack
        uint256 topStackLevel; // level of hash on top of the stack

        while (numOfHashes < numOfLeavesInDrive) {
            if ((numOfHashes << MerkleConstants.LOG2_LEAF_SIZE) < data.length) {
                // we still have leaves to hash
                stack[stackLength] = getHashOfLeafAtIndex(data, numOfHashes);
                numOfHashes++;

                numOfJoins = numOfHashes;
            } else {
                // since padding happens in getHashOfLeafAtIndex function
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

                stack[stackLength - 2] = join(h1, h2);
                stackLength = stackLength - 1; // remove hashes from stack

                numOfJoins = numOfJoins >> 1;
            }
        }

        require(stackLength == 1, "stack error");

        return stack[0];
    }

    /// @notice Get the hash of a leaf from a byte array by its index.
    /// @param data the byte array
    /// @param leafIndex the leaf index
    /// @dev The data is assumed to be followed by an infinite sequence of zeroes.
    /// @dev See `MerkleConstants` for leaf size.
    function getHashOfLeafAtIndex(bytes calldata data, uint256 leafIndex) internal pure returns (bytes32) {
        uint256 start = leafIndex << MerkleConstants.LOG2_LEAF_SIZE;
        if (start < data.length) {
            return keccak256(abi.encode(bytes32(data[start:])));
        } else {
            return PristineMerkleTree.getNodeAtHeight(0);
        }
    }
}
