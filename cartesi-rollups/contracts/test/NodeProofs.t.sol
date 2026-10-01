// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {LeafProof} from "cartesi-rollups-contracts-3.0.0/src/common/LeafProof.sol";
import {MachineValidityProof} from "cartesi-rollups-contracts-3.0.0/src/common/MachineValidityProof.sol";
import {LibMachineValidityProof} from "cartesi-rollups-contracts-3.0.0/src/library/LibMachineValidityProof.sol";

import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// External entry points for the calldata-only verifiers the contracts use.
contract Verifiers {
    function getRoot(bytes32 leaf, uint64 height, uint256 position, bytes32[] calldata siblings)
        external
        pure
        returns (bytes32)
    {
        return Tree.Node.unwrap(Commitment.getRoot(leaf, height, position, siblings));
    }

    function getRootForLastLeaf(uint64 height, bytes32 leaf, bytes32[] calldata siblings)
        external
        pure
        returns (bytes32)
    {
        return Tree.Node.unwrap(Commitment.getRootForLastLeaf(height, leaf, siblings));
    }

    function validate(MachineValidityProof calldata proof, bytes32 finalState) external pure returns (bytes32) {
        return LibMachineValidityProof.validate(proof, finalState);
    }
}

/// The contracts must accept the commitment proofs and the settlement
/// validity proof the Rust node produces. The vectors are pinned on the node
/// side by node_proof_vectors_hold (cartesi-rollups/node/tests/engine_machine.rs),
/// which regenerates them; the expected outputs Merkle root is the reference
/// CLI's.
contract NodeProofsTest is Test {
    string constant VECTORS = "../node/tests/fixtures/node_proofs.json";

    Verifiers immutable VERIFIERS = new Verifiers();

    function testCommitmentProofsOpenTheirRoots() public view {
        string memory json = vm.readFile(VECTORS);
        string[] memory names = vm.parseJsonKeys(json, ".commitments");
        assertGt(names.length, 0, "no commitment vectors");
        for (uint256 i; i < names.length; ++i) {
            string memory vector = string.concat(".commitments.", names[i]);
            bytes32 root = vm.parseJsonBytes32(json, string.concat(vector, ".root"));
            uint64 height = uint64(vm.parseJsonUint(json, string.concat(vector, ".height")));
            uint256 position = vm.parseJsonUint(json, string.concat(vector, ".position"));
            bytes32 leaf = vm.parseJsonBytes32(json, string.concat(vector, ".leaf"));
            bytes32[] memory siblings = vm.parseJsonBytes32Array(json, string.concat(vector, ".siblings"));

            assertEq(VERIFIERS.getRoot(leaf, height, position, siblings), root, names[i]);
            if (position == (uint256(1) << height) - 1) {
                assertEq(VERIFIERS.getRootForLastLeaf(height, leaf, siblings), root, names[i]);
            }
        }
    }

    function testSettlementProofsValidateTheirFinalStates() public view {
        string memory json = vm.readFile(VECTORS);
        string[] memory names = vm.parseJsonKeys(json, ".settlements");
        assertGt(names.length, 0, "no settlement vectors");
        for (uint256 i; i < names.length; ++i) {
            string memory vector = string.concat(".settlements.", names[i]);
            MachineValidityProof memory proof = MachineValidityProof({
                iflagsYProof: _leafProof(json, string.concat(vector, ".iflags_y")),
                htifTohostProof: _leafProof(json, string.concat(vector, ".htif_tohost")),
                txBufferProof: _leafProof(json, string.concat(vector, ".tx_buffer"))
            });
            bytes32 finalState = vm.parseJsonBytes32(json, string.concat(vector, ".final_state"));
            assertEq(
                VERIFIERS.validate(proof, finalState),
                vm.parseJsonBytes32(json, string.concat(vector, ".outputs_merkle_root")),
                names[i]
            );
        }
    }

    function _leafProof(string memory json, string memory key) private pure returns (LeafProof memory) {
        return LeafProof({
            dataBlock: vm.parseJsonBytes32(json, string.concat(key, ".data_block")),
            siblings: vm.parseJsonBytes32Array(json, string.concat(key, ".siblings"))
        });
    }
}
