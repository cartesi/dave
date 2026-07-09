// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationFactoryErrors} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactoryErrors.sol";

import {SafetyGateTaskSpawner} from "prt-contracts/safety-gate-task/SafetyGateTaskSpawner.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";

import {IDaveConsensus} from "./IDaveConsensus.sol";

/// @title Dave-App Pair Factory
/// @notice Allows anyone to reliably deploy an application
/// validated by a newly-deployed `IDaveConsensus` contract, optionally
/// gated by a safety gate (see `prt/docs/safety-gate.md`).
/// @dev Factory events are the canonical provenance check: they certify
/// that an app's settlement mechanism (consensus, proof system, and gate,
/// if any) is genuine, and distinguish gated from bare apps. App-declared
/// parameters (template hash, withdrawal config, gate governance) are not
/// certified — they are the deployer's responsibility, inspectable on-chain.
interface IDaveAppFactory is IApplicationFactoryErrors {
    /// @notice A Dave-App pair was created.
    /// @param appContract The application contract
    /// @param daveConsensus The Dave consensus contract
    event DaveAppCreated(IApplication indexed appContract, IDaveConsensus indexed daveConsensus);

    /// @notice Deploy a new Dave-App pair deterministically.
    /// @param templateHash The application template hash
    /// @param withdrawalConfig The withdrawal configuration
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContract The application contract
    /// @return daveConsensus The Dave consensus contract
    function newDaveApp(bytes32 templateHash, WithdrawalConfig calldata withdrawalConfig, bytes32 salt)
        external
        returns (IApplication appContract, IDaveConsensus daveConsensus);

    /// @notice Calculate the address of a Dave-App pair.
    /// @param templateHash The application template hash
    /// @param withdrawalConfig The withdrawal configuration
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContractAddress The application contract address
    /// @return daveConsensusAddress The Dave consensus contract address
    function calculateDaveAppAddress(bytes32 templateHash, WithdrawalConfig calldata withdrawalConfig, bytes32 salt)
        external
        view
        returns (address appContractAddress, address daveConsensusAddress);

    /// @notice A gated Dave-App pair was created.
    /// @param appContract The application contract
    /// @param daveConsensus The Dave consensus contract
    /// @param gateSpawner The app-specific safety gate spawner
    event GatedDaveAppCreated(
        IApplication indexed appContract, IDaveConsensus indexed daveConsensus, SafetyGateTaskSpawner gateSpawner
    );

    /// @notice Deploy a new Dave-App pair deterministically, with a safety
    /// gate wrapping the factory's proof system.
    /// @param templateHash The application template hash
    /// @param withdrawalConfig The withdrawal configuration
    /// @param sentryManager The address allowed to rotate the gate's sentry set
    /// @param disagreementWindow The gate's delay window before falling back
    /// to the proof system result
    /// @param sentries The gate's initial sentry list
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContract The application contract
    /// @return daveConsensus The Dave consensus contract
    /// @return gateSpawner The app-specific safety gate spawner
    /// @dev The gate governance parameters are app-declared: this factory
    /// certifies the gate mechanism, not the chosen manager/sentries/window.
    function newGatedDaveApp(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        address sentryManager,
        Time.Duration disagreementWindow,
        address[] calldata sentries,
        bytes32 salt
    ) external returns (IApplication appContract, IDaveConsensus daveConsensus, SafetyGateTaskSpawner gateSpawner);

    /// @notice Calculate the address of a gated Dave-App pair.
    /// @param templateHash The application template hash
    /// @param withdrawalConfig The withdrawal configuration
    /// @param sentryManager The address allowed to rotate the gate's sentry set
    /// @param disagreementWindow The gate's delay window before falling back
    /// to the proof system result
    /// @param sentries The gate's initial sentry list
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContractAddress The application contract address
    /// @return daveConsensusAddress The Dave consensus contract address
    /// @return gateSpawnerAddress The app-specific safety gate spawner address
    function calculateGatedDaveAppAddress(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        address sentryManager,
        Time.Duration disagreementWindow,
        address[] calldata sentries,
        bytes32 salt
    ) external view returns (address appContractAddress, address daveConsensusAddress, address gateSpawnerAddress);
}
