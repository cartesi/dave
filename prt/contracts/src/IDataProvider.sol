// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

interface IDataProvider {
    function merkleizedData(
        bytes32 namespace,
        bytes calldata id,
        bytes calldata proof
    ) external returns (bytes32);
}
