// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/types/Machine.sol";

library Tree {
    using Tree for Node;

    type Node is bytes32;

    // The `bytes32` cast here can be dispensed,
    // or the `0x0` byte literal can be changed
    // into the `0` integer literal.
    Node constant ZERO_NODE = Node.wrap(bytes32(0x0));

    // Contracts that use this function could use the following syntax
    // introduced in Solidity 0.8.19:
    //
    // using {Tree.eq as ==} for Tree.Node;
    function eq(Node left, Node right) internal pure returns (bool) {
        bytes32 l = Node.unwrap(left);
        bytes32 r = Node.unwrap(right);
        return l == r;
    }

    // See cartesi-rollups/contracts/src/Merkle.sol:Merkle.join
    // for a more gas-efficient low-level implementation.
    // There are unit tests certifying its correctness.
    // I see prt/contracts/src/tournament/libs/Commitment.sol:Commitment
    // using the same naive implementation on bytes32,
    // so maybe we could implement a fast join implementation
    // somewhere that works on bytes32 values and this function
    // that operates on Node user-defined value types could use
    // it underneath.
    function join(Node left, Node right) internal pure returns (Node) {
        bytes32 l = Node.unwrap(left);
        bytes32 r = Node.unwrap(right);
        bytes32 p = keccak256(abi.encode(l, r));
        return Node.wrap(p);
    }

    function verify(Node parent, Node left, Node right)
        internal
        pure
        returns (bool)
    {
        return parent.eq(left.join(right));
    }

    function requireChildren(Node parent, Node left, Node right)
        internal
        pure
    {
        require(parent.verify(left, right), "child nodes don't match parent");
    }

    function isZero(Node node) internal pure returns (bool) {
        // It could use the `eq` function defined in this library
        // to compare `hash` with the ZERO_NODE constant.
        bytes32 n = Node.unwrap(node);
        return n == 0x0;
    }

    // Rename as requireIsNonZero?
    function requireExist(Node node) internal pure {
        require(!node.isZero(), "tree node doesn't exist");
    }

    // Why did we define a separate type for machine hash
    // if it is a Merkle tree node?
    function toMachineHash(Node node) internal pure returns (Machine.Hash) {
        return Machine.Hash.wrap(Node.unwrap(node));
    }
}
