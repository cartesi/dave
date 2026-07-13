// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationFactoryErrors} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactoryErrors.sol";

import {IDaveConsensus} from "./IDaveConsensus.sol";
import {ISentryErrors} from "./ISentryErrors.sol";

/// @title Dave-App Pair Factory
/// @notice Allows anyone to reliably deploy an application
/// validated by a newly-deployed `IDaveConsensus` contract.
interface IDaveAppFactory is IApplicationFactoryErrors, ISentryErrors {
    /// @notice A Dave-App pair was created.
    /// @param appContract The application contract
    /// @param daveConsensus The Dave consensus contract
    event DaveAppCreated(IApplication appContract, IDaveConsensus daveConsensus);

    /// @notice Deploy a new Dave-App pair deterministically.
    /// @param templateHash The application template hash
    /// @param claimStagingPeriod The claim staging period
    /// @param sentryManager The sentry manager address
    /// @param sentries The array of sentries
    /// @param withdrawalConfig The withdrawal configuration
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContract The application contract
    /// @return daveConsensus The Dave consensus contract
    /// @dev May raise `ZeroSentryAddress` and `DuplicatedSentryAddress` errors,
    /// if the sentry array contains a zero or duplicated address, respectively.
    /// If an empty sentries array is provided, then epochs only settle
    /// after tournament results are staged for `claimStagingPeriod` blocks.
    /// If a non-empty sentries array is provided, then the claim staging period
    /// serves as a fallback if not all sentries agree with the tournament result,
    /// which should give the guardian enough time to foreclose the application
    /// if the disagreement stems from a bug on PRT.
    function newDaveApp(
        bytes32 templateHash,
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) external returns (IApplication appContract, IDaveConsensus daveConsensus);

    /// @notice Calculate the address of a Dave-App pair.
    /// @param templateHash The application template hash
    /// @param claimStagingPeriod The claim staging period
    /// @param sentryManager The sentry manager address
    /// @param sentries The array of sentries
    /// @param withdrawalConfig The withdrawal configuration
    /// @param salt A 32-byte value used to add entropy to the addresses
    /// @return appContractAddress The application contract address
    /// @return daveConsensusAddress The Dave consensus contract address
    function calculateDaveAppAddress(
        bytes32 templateHash,
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) external view returns (address appContractAddress, address daveConsensusAddress);
}
