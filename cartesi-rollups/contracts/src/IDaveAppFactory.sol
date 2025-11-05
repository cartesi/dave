// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IApplication} from "cartesi-rollups-contracts-2.1.0/src/dapp/IApplication.sol";

import {IDaveConsensus} from "./IDaveConsensus.sol";

/// @title Dave-App Pair Factory
/// @notice Allows anyone to reliably deploy an application
/// validated a newly-deployed `IDaveConsensus` contract.
interface IDaveAppFactory {
    /// @notice A Dave-App pair was created.
    /// @param appContract The application contract
    /// @param daveConsensus The Dave consensus contract
    event DaveAppCreated(IApplication appContract, IDaveConsensus daveConsensus);

    /// @notice Deploy a new Dave-App pair deterministically.
    /// @param templateHash The application template hash
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContract The application contract
    /// @return daveConsensus The Dave consensus contract
    function newDaveApp(bytes32 templateHash, bytes32 salt)
        external
        returns (IApplication appContract, IDaveConsensus daveConsensus);

    /// @notice Calculate the address of a Dave-App pair.
    /// @param templateHash The application template hash
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContractAddress The application contract address
    /// @return daveConsensusAddress The Dave consensus contract address
    function calculateDaveAppAddress(bytes32 templateHash, bytes32 salt)
        external
        view
        returns (address appContractAddress, address daveConsensusAddress);
}
