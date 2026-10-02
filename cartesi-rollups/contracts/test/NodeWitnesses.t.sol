// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {LibBinaryMerkleTree} from "cartesi-rollups-contracts-3.0.0/src/library/LibBinaryMerkleTree.sol";
import {LibKeccak256} from "cartesi-rollups-contracts-3.0.0/src/library/LibKeccak256.sol";
import {LibMath} from "cartesi-rollups-contracts-3.0.0/src/library/LibMath.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {CartesiStateTransition} from "prt-contracts/state-transition/CartesiStateTransition.sol";

import {Memory} from "step/src/Memory.sol";

/// One epoch's inputs, rooted the way DaveConsensus.provideMerkleRootOfInput
/// roots them.
contract EpochInputs is IDataProvider {
    using LibBinaryMerkleTree for bytes;
    using LibMath for uint256;

    bytes[] private _inputs;

    error UnexpectedInput(uint256 index);

    constructor(bytes[] memory inputs) {
        for (uint256 i; i < inputs.length; ++i) {
            _inputs.push(inputs[i]);
        }
    }

    function provideMerkleRootOfInput(uint256 index, bytes calldata input) external view returns (bytes32) {
        if (index >= _inputs.length) {
            return bytes32(0);
        }
        require(keccak256(input) == keccak256(_inputs[index]), UnexpectedInput(index));

        uint256 log2DataBlockSize = Memory.LOG2_LEAF;
        uint256 log2DriveSize = input.length.ceilLog2().max(log2DataBlockSize);
        return input.merkleRoot(log2DriveSize, log2DataBlockSize, LibKeccak256.hashBlock, LibKeccak256.hashPair);
    }
}

/// The step must accept the witness bytes the Rust node sends. The vectors
/// are pinned on the node side, which regenerates them: node_witnesses.json by
/// node_witness_vectors_hold (cartesi-rollups/node/tests/engine_machine.rs),
/// and node_seam_witnesses.json, the input budget's seams, by
/// seam_witness_vectors_hold (cartesi-rollups/node/src/engine/machine_stf.rs).
contract NodeWitnessesTest is Test {
    string constant VECTORS = "../node/tests/fixtures/node_witnesses.json";
    string constant SEAM_VECTORS = "../node/tests/fixtures/node_seam_witnesses.json";

    function testNodeWitnessesReachTheirPostStates() public {
        _replay(VECTORS);
    }

    function testNodeSeamWitnessesReachTheirPostStates() public {
        _replay(SEAM_VECTORS);
    }

    function _replay(string memory path) private {
        string memory json = vm.readFile(path);
        CartesiStateTransition stateTransition = new CartesiStateTransition();

        string[] memory names = vm.parseJsonKeys(json, ".vectors");
        assertGt(names.length, 0, "no vectors");
        for (uint256 i; i < names.length; ++i) {
            string memory vector = string.concat(".vectors.", names[i]);
            string memory program = vm.parseJsonString(json, string.concat(vector, ".program"));
            EpochInputs inputs = new EpochInputs(vm.parseJsonBytesArray(json, string.concat(".inputs.", program)));

            bytes32 postState = stateTransition.transitionState(
                vm.parseJsonBytes32(json, string.concat(vector, ".pre_state")),
                vm.parseJsonUint(json, string.concat(vector, ".meta_cycle")),
                vm.parseJsonBytes(json, string.concat(vector, ".proof")),
                inputs
            );
            assertEq(postState, vm.parseJsonBytes32(json, string.concat(vector, ".post_state")), names[i]);
        }
    }
}
