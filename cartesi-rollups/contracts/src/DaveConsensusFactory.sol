// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import {IInputBox} from "cartesi-rollups-contracts-2.0.0/inputs/IInputBox.sol";

import {DaveConsensus} from "./DaveConsensus.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @title Dave Consensus Factory
/// @notice Allows anyone to reliably deploy a new `DaveConsensus` contract.
contract DaveConsensusFactory {
    using Clones for address;

    DaveConsensus immutable _impl;
    IInputBox immutable _inputBox;
    ITournamentFactory immutable _tournamentFactory;

    event DaveConsensusCreated(DaveConsensus daveConsensus);

    constructor(DaveConsensus impl, IInputBox inputBox, ITournamentFactory tournamentFactory) {
        _impl = impl;
        _inputBox = inputBox;
        _tournamentFactory = tournamentFactory;
    }

    function getImplementation() external view returns (DaveConsensus) {
        return _impl;
    }

    function getInputBox() external view returns (IInputBox) {
        return _inputBox;
    }

    function getTournamentFactory() external view returns (ITournamentFactory) {
        return _tournamentFactory;
    }

    function newDaveConsensus(address appContract, Machine.Hash initialMachineStateHash)
        external
        returns (DaveConsensus)
    {
        bytes memory args = _encodeArgs(appContract, initialMachineStateHash);
        address clone = address(_impl).cloneWithImmutableArgs(args);
        return _init(clone);
    }

    function newDaveConsensus(address appContract, Machine.Hash initialMachineStateHash, bytes32 salt)
        external
        returns (DaveConsensus)
    {
        bytes memory args = _encodeArgs(appContract, initialMachineStateHash);
        address clone = address(_impl).cloneDeterministicWithImmutableArgs(args, salt);
        return _init(clone);
    }

    function calculateDaveConsensusAddress(address appContract, Machine.Hash initialMachineStateHash, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory args = _encodeArgs(appContract, initialMachineStateHash);
        return address(_impl).predictDeterministicAddressWithImmutableArgs(args, salt);
    }

    function _encodeArgs(address appContract, Machine.Hash initialMachineStateHash)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            DaveConsensus.Args({
                inputBox: _inputBox,
                appContract: appContract,
                initialMachineStateHash: initialMachineStateHash,
                tournamentFactory: _tournamentFactory
            })
        );
    }

    function _init(address clone) internal returns (DaveConsensus) {
        DaveConsensus daveConsensus = DaveConsensus(clone);
        daveConsensus.sealFirstEpoch();
        emit DaveConsensusCreated(daveConsensus);
        return daveConsensus;
    }
}
