// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {Create2} from "@openzeppelin-contracts-5.2.0/utils/Create2.sol";

import {IInputBox} from "cartesi-rollups-contracts-2.0.0/inputs/IInputBox.sol";

import {DaveConsensus} from "./DaveConsensus.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @title Dave Consensus Factory
/// @notice Allows anyone to reliably deploy a new `DaveConsensus` contract.
contract DaveConsensusFactory {
    IInputBox inputBox;
    ITournamentFactory tournamentFactory;

    event DaveConsensusCreated(DaveConsensus daveConsensus);

    constructor(IInputBox _inputBox, ITournamentFactory _tournament) {
        inputBox = _inputBox;
        tournamentFactory = _tournament;
    }

    function newDaveConsensus(address appContract, Machine.Hash initialMachineStateHash)
        external
        returns (DaveConsensus)
    {
        DaveConsensus daveConsensus =
            new DaveConsensus(inputBox, appContract, tournamentFactory, initialMachineStateHash);

        emit DaveConsensusCreated(daveConsensus);

        return daveConsensus;
    }

    function newDaveConsensus(address appContract, Machine.Hash initialMachineStateHash, bytes32 salt)
        external
        returns (DaveConsensus)
    {
        DaveConsensus daveConsensus =
            new DaveConsensus{salt: salt}(inputBox, appContract, tournamentFactory, initialMachineStateHash);

        emit DaveConsensusCreated(daveConsensus);

        return daveConsensus;
    }

    function calculateDaveConsensusAddress(address appContract, Machine.Hash initialMachineStateHash, bytes32 salt)
        external
        view
        returns (address)
    {
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
