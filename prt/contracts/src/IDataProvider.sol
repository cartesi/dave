// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

interface IDataProvider {
    /// @notice Provides the Merkle root of an input
    /// @param inputIndexWithinEpoch The index of the input within the epoch
    /// @param input The input blob (to hash and check against the input box)
    /// @return The root of smallest Merkle tree that fits the input
    function provideMerkleRootOfInput(
        uint256 inputIndexWithinEpoch,
        bytes calldata input
    ) external view returns (bytes32);
}
