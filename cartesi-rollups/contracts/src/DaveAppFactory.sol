// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {Create2} from "@openzeppelin-contracts-5.5.0/utils/Create2.sol";

import {DataAvailability} from "cartesi-rollups-contracts-3.0.0/src/common/DataAvailability.sol";
import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactory.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";

import {ITaskSpawner} from "prt-contracts/ITaskSpawner.sol";
import {SafetyGateTaskSpawner} from "prt-contracts/safety-gate-task/SafetyGateTaskSpawner.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

import {DaveConsensus} from "./DaveConsensus.sol";
import {IDaveAppFactory} from "./IDaveAppFactory.sol";
import {IDaveConsensus} from "./IDaveConsensus.sol";

contract DaveAppFactory is IDaveAppFactory {
    IInputBox immutable INPUT_BOX;
    IApplicationFactory immutable APP_FACTORY;
    ITaskSpawner immutable TASK_SPAWNER;

    IOutputsMerkleRootValidator constant NO_VALIDATOR = IOutputsMerkleRootValidator(address(0));

    constructor(IInputBox inputBox, IApplicationFactory appFactory, ITaskSpawner taskSpawner) {
        INPUT_BOX = inputBox;
        APP_FACTORY = appFactory;
        TASK_SPAWNER = taskSpawner;
    }

    function newDaveApp(bytes32 templateHash, WithdrawalConfig calldata withdrawalConfig, bytes32 salt)
        external
        override
        returns (IApplication appContract, IDaveConsensus daveConsensus)
    {
        appContract = _newApplication(templateHash, withdrawalConfig, salt);
        daveConsensus = _newDaveConsensus(address(appContract), templateHash, TASK_SPAWNER, salt);
        _wireApp(appContract, daveConsensus);
        emit DaveAppCreated(appContract, daveConsensus);
    }

    function calculateDaveAppAddress(bytes32 templateHash, WithdrawalConfig calldata withdrawalConfig, bytes32 salt)
        external
        view
        override
        returns (address appContractAddress, address daveConsensusAddress)
    {
        appContractAddress = _calculateApplicationAddress(templateHash, withdrawalConfig, salt);
        daveConsensusAddress = _calculateDaveConsensusAddress(appContractAddress, templateHash, TASK_SPAWNER, salt);
    }

    function newGatedDaveApp(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        address sentryManager,
        Time.Duration disagreementWindow,
        address[] calldata sentries,
        bytes32 salt
    )
        external
        override
        returns (IApplication appContract, IDaveConsensus daveConsensus, SafetyGateTaskSpawner gateSpawner)
    {
        appContract = _newApplication(templateHash, withdrawalConfig, salt);
        gateSpawner = new SafetyGateTaskSpawner{salt: salt}(sentryManager, TASK_SPAWNER, disagreementWindow, sentries);
        daveConsensus = _newDaveConsensus(address(appContract), templateHash, gateSpawner, salt);
        _wireApp(appContract, daveConsensus);
        emit GatedDaveAppCreated(appContract, daveConsensus, gateSpawner);
    }

    function calculateGatedDaveAppAddress(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        address sentryManager,
        Time.Duration disagreementWindow,
        address[] calldata sentries,
        bytes32 salt
    )
        external
        view
        override
        returns (address appContractAddress, address daveConsensusAddress, address gateSpawnerAddress)
    {
        appContractAddress = _calculateApplicationAddress(templateHash, withdrawalConfig, salt);
        gateSpawnerAddress = _calculateGateSpawnerAddress(sentryManager, disagreementWindow, sentries, salt);
        daveConsensusAddress =
            _calculateDaveConsensusAddress(appContractAddress, templateHash, ITaskSpawner(gateSpawnerAddress), salt);
    }

    /// @notice Encode the data availability blob for applications that only use the input box as DA.
    function _encodeInputBoxDataAvailability() internal view returns (bytes memory) {
        return abi.encodeCall(DataAvailability.InputBox, (INPUT_BOX));
    }

    /// @notice Hand the application over to its consensus: set the outputs
    /// Merkle root validator and renounce the factory's temporary ownership.
    function _wireApp(IApplication appContract, IDaveConsensus daveConsensus) internal {
        appContract.migrateToOutputsMerkleRootValidator(daveConsensus);
        appContract.renounceOwnership();
    }

    /// @notice Instantiate a new application contract owned by the current contract,
    /// with no outputs Merkle root validator (the zero address), and with the input box
    /// as the only data availability source.
    function _newApplication(bytes32 templateHash, WithdrawalConfig calldata withdrawalConfig, bytes32 salt)
        internal
        returns (IApplication)
    {
        bytes memory dataAvailability = _encodeInputBoxDataAvailability();
        return
            APP_FACTORY.newApplication(
                NO_VALIDATOR, address(this), templateHash, dataAvailability, withdrawalConfig, salt
            );
    }

    /// @notice Instantiate a new `DaveConsensus` contract.
    function _newDaveConsensus(address appContract, bytes32 templateHash, ITaskSpawner taskSpawner, bytes32 salt)
        internal
        returns (DaveConsensus)
    {
        Machine.Hash initialMachineStateHash = Machine.Hash.wrap(templateHash);
        return new DaveConsensus{salt: salt}(INPUT_BOX, appContract, taskSpawner, initialMachineStateHash);
    }

    /// @notice Calculates the address of an application contract.
    function _calculateApplicationAddress(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) internal view returns (address) {
        bytes memory dataAvailability = _encodeInputBoxDataAvailability();
        return APP_FACTORY.calculateApplicationAddress(
            NO_VALIDATOR, address(this), templateHash, dataAvailability, withdrawalConfig, salt
        );
    }

    /// @notice Calculates the address of a `DaveConsensus` contract.
    function _calculateDaveConsensusAddress(
        address appContract,
        bytes32 templateHash,
        ITaskSpawner taskSpawner,
        bytes32 salt
    ) internal view returns (address) {
        return _calculateCreate2Address(
            type(DaveConsensus).creationCode, abi.encode(INPUT_BOX, appContract, taskSpawner, templateHash), salt
        );
    }

    /// @notice Calculates the address of a `SafetyGateTaskSpawner` contract.
    function _calculateGateSpawnerAddress(
        address sentryManager,
        Time.Duration disagreementWindow,
        address[] calldata sentries,
        bytes32 salt
    ) internal view returns (address) {
        return _calculateCreate2Address(
            type(SafetyGateTaskSpawner).creationCode,
            abi.encode(sentryManager, TASK_SPAWNER, disagreementWindow, sentries),
            salt
        );
    }

    /// @notice Address of a contract this factory would CREATE2-deploy from
    /// the given creation code and constructor arguments under `salt`.
    function _calculateCreate2Address(bytes memory creationCode, bytes memory args, bytes32 salt)
        internal
        view
        returns (address)
    {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(creationCode, args)));
    }
}
