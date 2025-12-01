// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {Create2} from "@openzeppelin-contracts-5.5.0/utils/Create2.sol";

import {DataAvailability} from "cartesi-rollups-contracts-2.1.1/src/common/DataAvailability.sol";
import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-2.1.1/src/consensus/IOutputsMerkleRootValidator.sol";
import {IApplication} from "cartesi-rollups-contracts-2.1.1/src/dapp/IApplication.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-2.1.1/src/dapp/IApplicationFactory.sol";
import {IInputBox} from "cartesi-rollups-contracts-2.1.1/src/inputs/IInputBox.sol";

import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

import {DaveConsensus} from "./DaveConsensus.sol";
import {IDaveAppFactory} from "./IDaveAppFactory.sol";
import {IDaveConsensus} from "./IDaveConsensus.sol";

contract DaveAppFactory is IDaveAppFactory {
    IInputBox immutable INPUT_BOX;
    IApplicationFactory immutable APP_FACTORY;
    ITournamentFactory immutable TOURNAMENT_FACTORY;

    IOutputsMerkleRootValidator constant NO_VALIDATOR = IOutputsMerkleRootValidator(address(0));

    constructor(IInputBox inputBox, IApplicationFactory appFactory, ITournamentFactory tournamentFactory) {
        INPUT_BOX = inputBox;
        APP_FACTORY = appFactory;
        TOURNAMENT_FACTORY = tournamentFactory;
    }

    function newDaveApp(bytes32 templateHash, bytes32 salt)
        external
        override
        returns (IApplication appContract, IDaveConsensus daveConsensus)
    {
        appContract = _newApplication(templateHash, salt);
        daveConsensus = _newDaveConsensus(address(appContract), templateHash, salt);
        appContract.migrateToOutputsMerkleRootValidator(daveConsensus);
        appContract.renounceOwnership();
        emit DaveAppCreated(appContract, daveConsensus);
    }

    function calculateDaveAppAddress(bytes32 templateHash, bytes32 salt)
        external
        view
        override
        returns (address appContractAddress, address daveConsensusAddress)
    {
        appContractAddress = _calculateApplicationAddress(templateHash, salt);
        daveConsensusAddress = _calculateDaveConsensusAddress(appContractAddress, templateHash, salt);
    }

    /// @notice Encode the data availability blob for applications that only use the input box as DA.
    function _encodeInputBoxDataAvailability() internal view returns (bytes memory) {
        return abi.encodeCall(DataAvailability.InputBox, (INPUT_BOX));
    }

    /// @notice Instantiate a new application contract owned by the current contract,
    /// with no outputs Merkle root validator (the zero address), and with the input box
    /// as the only data availability source.
    function _newApplication(bytes32 templateHash, bytes32 salt) internal returns (IApplication) {
        bytes memory dataAvailability = _encodeInputBoxDataAvailability();
        return APP_FACTORY.newApplication(NO_VALIDATOR, address(this), templateHash, dataAvailability, salt);
    }

    /// @notice Instantiate a new `DaveConsensus` contract.
    function _newDaveConsensus(address appContract, bytes32 templateHash, bytes32 salt)
        internal
        returns (DaveConsensus)
    {
        Machine.Hash initialMachineStateHash = Machine.Hash.wrap(templateHash);
        return new DaveConsensus{salt: salt}(INPUT_BOX, appContract, TOURNAMENT_FACTORY, initialMachineStateHash);
    }

    /// @notice Calculates the address of an application contract.
    function _calculateApplicationAddress(bytes32 templateHash, bytes32 salt) internal view returns (address) {
        bytes memory dataAvailability = _encodeInputBoxDataAvailability();
        return
            APP_FACTORY.calculateApplicationAddress(NO_VALIDATOR, address(this), templateHash, dataAvailability, salt);
    }

    /// @notice Calculates the address of a `DaveConsensus` contract.
    function _calculateDaveConsensusAddress(address appContract, bytes32 templateHash, bytes32 salt)
        internal
        view
        returns (address)
    {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DaveConsensus).creationCode,
                    abi.encode(INPUT_BOX, appContract, TOURNAMENT_FACTORY, templateHash)
                )
            )
        );
    }
}
