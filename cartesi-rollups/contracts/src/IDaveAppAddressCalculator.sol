// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

/// @notice This contract serves solely for the development Cannon package to have
/// accesss to the pre-calculated application address in order to send it an input
/// before the deployment of the `DaveConsensus` contract.
interface IDaveAppAddressCalculator {
    /// @notice The addresses of the application and `DaveConsensus` contracts were calculated.
    /// @param templateHash The template hash of the application
    /// @param salt The salt used to add entropy to the generated addresses
    /// @param appContractAddress The address of the application contract
    /// @param daveConsensusAddress The address of the `DaveConsensus` contract
    event AddressCalculation(
        bytes32 templateHash, bytes32 salt, address appContractAddress, address daveConsensusAddress
    );

    /// @notice Calculate the address of the application and `DaveConsensus`
    /// contracts given the provided constructor arguments.
    /// @param templateHash The template hash of the application
    /// @param salt The salt used to add entropy to the generated addresses
    function calculateDaveAppAddress(bytes32 templateHash, bytes32 salt) external;
}
