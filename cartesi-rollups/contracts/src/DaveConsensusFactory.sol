// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

import {DaveConsensus} from "./DaveConsensus.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {IInputBox} from "rollups-contracts/inputs/IInputBox.sol";
import {Machine} from "prt-contracts/Machine.sol";

/// @title Dave Consensus Factory
/// @notice Allows anyone to reliably deploy a new `IDataProvider` contract.
contract DaveConsensusFactory {
    event DaveConsensusCreated(IDataProvider daveConsensus);

    function newDaveConsensus(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash
    ) external returns (IDataProvider) {
        IDataProvider daveConsensus =
            new DaveConsensus(inputBox, appContract, tournamentFactory, initialMachineStateHash);

        emit DaveConsensusCreated(daveConsensus);

        return daveConsensus;
    }

    function newDaveConsensus(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash,
        bytes32 salt
    ) external returns (IDataProvider) {
        IDataProvider daveConsensus =
            new DaveConsensus{salt: salt}(inputBox, appContract, tournamentFactory, initialMachineStateHash);

        emit DaveConsensusCreated(daveConsensus);

        return daveConsensus;
    }

    function calculateDaveConsensusAddress(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash,
        bytes32 salt
    ) external view returns (address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DaveConsensus).creationCode,
                    abi.encode(inputBox, appContract, tournamentFactory, initialMachineStateHash)
                )
            )
        );
    }
}
