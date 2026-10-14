// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {ITournament} from "src/ITournament.sol";
import {Commitment} from "src/tournament/libs/Commitment.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {SmallFullTree} from "./fixtures/SmallFullTree.sol";

contract CommitmentHarness {
    function requireState(
        Tree.Node commitment,
        uint64 treeHeight,
        uint256 position,
        Machine.Hash state,
        bytes32[] calldata proof
    ) external pure {
        Commitment.requireState(commitment, treeHeight, position, state, proof);
    }

    function requireFinalState(
        Tree.Node commitment,
        uint64 treeHeight,
        Machine.Hash finalState,
        bytes32[] calldata proof
    ) external pure {
        Commitment.requireFinalState(commitment, treeHeight, finalState, proof);
    }
}

/// @dev Both proof walks require exactly `height` siblings. Without the
/// check a longer proof verifies with its excess ignored, and a shorter one
/// panics on the out-of-bounds read instead of the typed error.
contract CommitmentTest is Test {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant HEIGHT = 3;

    CommitmentHarness harness;

    function setUp() public {
        harness = new CommitmentHarness();
    }

    function testStateProofRejectsATrailingSibling() public {
        SmallFullTree.Data memory data =
            SmallFullTree.build(bytes32("commitment"), HEIGHT);
        uint256 position = 5;
        Machine.Hash state = data.leaf(position).toMachineHash();
        bytes32[] memory exact = data.proof(position);

        harness.requireState(data.root(), HEIGHT, position, state, exact);

        bytes32[] memory long = _resized(exact, exact.length + 1);
        long[exact.length] = Tree.Node.unwrap(data.root());
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.CommitmentProofWrongSize.selector,
                uint256(HEIGHT),
                long.length
            )
        );
        harness.requireState(data.root(), HEIGHT, position, state, long);
    }

    function testFinalStateProofRejectsWrongLength() public {
        SmallFullTree.Data memory data =
            SmallFullTree.build(bytes32("pin"), HEIGHT);
        bytes32[] memory exact = data.finalProof();

        harness.requireFinalState(data.root(), HEIGHT, data.finalState(), exact);

        bytes32[] memory long = _resized(exact, exact.length + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.CommitmentProofWrongSize.selector,
                uint256(HEIGHT),
                long.length
            )
        );
        harness.requireFinalState(data.root(), HEIGHT, data.finalState(), long);

        bytes32[] memory short = _resized(exact, exact.length - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITournament.CommitmentProofWrongSize.selector,
                uint256(HEIGHT),
                short.length
            )
        );
        harness.requireFinalState(data.root(), HEIGHT, data.finalState(), short);
    }

    function _resized(bytes32[] memory proof, uint256 length)
        private
        pure
        returns (bytes32[] memory resized)
    {
        resized = new bytes32[](length);
        for (uint256 i; i < length && i < proof.length; ++i) {
            resized[i] = proof[i];
        }
    }
}
