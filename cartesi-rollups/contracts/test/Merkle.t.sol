// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {MerkleConstants} from "src/MerkleConstants.sol";
import {PristineMerkleTree} from "src/PristineMerkleTree.sol";
import {Merkle} from "src/Merkle.sol";

contract MerkleTest is Test {
    using Merkle for bytes;

    function testJoinEquivalence(bytes32 a, bytes32 b) external pure {
        assertEq(Merkle.join(a, b), keccak256(abi.encodePacked(a, b)));
    }
}
