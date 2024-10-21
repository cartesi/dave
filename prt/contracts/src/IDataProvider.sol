// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

interface IDataProvider {
    /// @notice Provides the Merkle root of the response to a Generic I/O request
    /// @param namespace The request namespace
    /// @param id The request ID
    /// @param extra Extra data (e.g. proofs)
    /// @return Merkle root of response
    /// @return Size of the response (in bytes)
    function gio(uint16 namespace, bytes calldata id, bytes calldata extra)
        external
        returns (bytes32, uint256);
}
