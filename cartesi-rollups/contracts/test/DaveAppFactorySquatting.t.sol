// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {IOutputsMerkleRootValidator} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationChecker.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactory.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {RollupsTest} from "cartesi-rollups-contracts-3.0.0/test/util/RollupsTest.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";

contract DaveAppFactorySquattingTest is RollupsTest {
    DaveAppFactory factory;
    ITournamentFactory constant TOURNAMENT_FACTORY = ITournamentFactory(address(0x100));
    IOutputsMerkleRootValidator constant NO_VALIDATOR = IOutputsMerkleRootValidator(address(0));
    bytes32 constant TEMPLATE = bytes32(uint256(1));

    function setUp() external {
        vm.mockCall(
            address(TOURNAMENT_FACTORY),
            abi.encodeWithSelector(ITournamentFactory.instantiate.selector),
            abi.encode(ITournament(address(0x200)))
        );
        factory = new DaveAppFactory(_contracts.core.inputBox, _contracts.core.applicationFactory, TOURNAMENT_FACTORY);
    }

    function testAnotherCallerCanOnlyDeployTheExactPredictedDavePair() external {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        (address predicted, address expectedConsensus) =
            factory.calculateDaveAppAddress(TEMPLATE, 10, address(0), sentries, config, 0);
        vm.deal(predicted, 1 ether);
        vm.prank(address(0xbad));
        (IApplication app, IDaveConsensus consensus) = factory.newDaveApp(TEMPLATE, 10, address(0), sentries, config, 0);
        assertEq(address(app), predicted);
        assertEq(address(consensus), expectedConsensus);
        assertEq(address(app.getOutputsMerkleRootValidator()), expectedConsensus);
        assertEq(app.owner(), address(0));
        assertEq(consensus.getClaimStagingPeriod(), 10);
        assertEq(predicted.balance, 1 ether);
    }

    /// @notice A second deployment of the same pair reverts with empty error
    /// data, whoever sends it: the application factory's revert on an
    /// address that has code. A copy of a broadcast deployment that lands
    /// first does this to the original.
    function testTheSamePairCannotBeDeployedTwice() external {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        vm.prank(address(0xbad));
        factory.newDaveApp(TEMPLATE, 10, address(0), sentries, config, 0);
        vm.expectRevert(bytes(""));
        factory.newDaveApp(TEMPLATE, 10, address(0), sentries, config, 0);
    }

    /// @notice The salt the factory hands the application factory, which
    /// binds the consensus settings.
    function _applicationSalt(
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] memory sentries,
        bytes32 salt
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(claimStagingPeriod, sentryManager, sentries, salt));
    }

    /// @notice The predicted application address is the one the application
    /// factory reserves for the Dave factory under that salt, whatever the
    /// arguments: neither view validates them, so none is assumed valid.
    function testFuzzThePredictedApplicationIsReservedForTheFactory(
        bytes32 templateHash,
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) external view {
        (address predicted,) = factory.calculateDaveAppAddress(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        );
        assertEq(
            predicted,
            _contracts.core.applicationFactory
                .calculateReservedApplicationAddress(
                    NO_VALIDATOR,
                    address(factory),
                    templateHash,
                    _contracts.core.inputBox,
                    withdrawalConfig,
                    _applicationSalt(claimStagingPeriod, sentryManager, sentries, salt),
                    address(factory)
                )
        );
    }

    /// @notice Nobody else can occupy the predicted application address. The
    /// same application deployed through the application factory by another
    /// caller, permissionless or reserved, lands elsewhere. So does the same
    /// pair created by a second Dave factory over the same application
    /// factory. The pair is still created where it was predicted.
    function testFuzzAnotherCallerCannotOccupyThePredictedApplication(
        uint64 claimStagingPeriod,
        address sentryManager,
        address sentry,
        bytes32 salt,
        address caller
    ) external {
        vm.assume(sentry != address(0));
        vm.assume(caller != address(factory));
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](1);
        sentries[0] = sentry;
        (address predicted, address expectedConsensus) =
            factory.calculateDaveAppAddress(TEMPLATE, claimStagingPeriod, sentryManager, sentries, config, salt);
        bytes32 appSalt = _applicationSalt(claimStagingPeriod, sentryManager, sentries, salt);
        IApplicationFactory appFactory = _contracts.core.applicationFactory;
        IInputBox inputBox = _contracts.core.inputBox;

        vm.startPrank(caller);
        IApplication permissionless =
            appFactory.newApplication(NO_VALIDATOR, address(factory), TEMPLATE, inputBox, config, appSalt);
        IApplication reserved =
            appFactory.newReservedApplication(NO_VALIDATOR, address(factory), TEMPLATE, inputBox, config, appSalt);
        vm.stopPrank();
        assertNotEq(address(permissionless), predicted);
        assertNotEq(address(reserved), predicted);

        DaveAppFactory other = new DaveAppFactory(inputBox, appFactory, TOURNAMENT_FACTORY);
        vm.prank(caller);
        (IApplication otherApp,) = other.newDaveApp(TEMPLATE, claimStagingPeriod, sentryManager, sentries, config, salt);
        assertNotEq(address(otherApp), predicted);
        assertEq(predicted.code.length, 0);

        (IApplication app, IDaveConsensus consensus) =
            factory.newDaveApp(TEMPLATE, claimStagingPeriod, sentryManager, sentries, config, salt);
        assertEq(address(app), predicted);
        assertEq(address(consensus), expectedConsensus);
        assertEq(address(app.getOutputsMerkleRootValidator()), expectedConsensus);
    }

    /// @notice No input precedes the pair: the InputBox refuses an address
    /// with no code, so the consensus seals epoch 0 over no input. The node
    /// starts reading at the deployment on that ground.
    function testNoInputPrecedesThePair() external {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        (address predicted,) = factory.calculateDaveAppAddress(TEMPLATE, 10, address(0), sentries, config, 0);
        IInputBox inputBox = _contracts.core.inputBox;

        vm.expectRevert(abi.encodeWithSelector(IApplicationChecker.ApplicationNotDeployed.selector, predicted));
        inputBox.addInput(predicted, "early");
        assertEq(inputBox.getNumberOfInputs(predicted), 0);

        (IApplication app, IDaveConsensus consensus) = factory.newDaveApp(TEMPLATE, 10, address(0), sentries, config, 0);
        (uint256 epochNumber, uint256 lower, uint256 upper,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 0);
        assertEq(lower, 0);
        assertEq(upper, 0);

        inputBox.addInput(address(app), "first");
        assertEq(inputBox.getNumberOfInputs(address(app)), 1);
    }

    function testDifferentConsensusSettingsCannotSquatTheSameApplication() external {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        (address victim, address expectedConsensus) =
            factory.calculateDaveAppAddress(TEMPLATE, 10, address(0), sentries, config, 0);
        (address attacker,) = factory.calculateDaveAppAddress(TEMPLATE, 0, address(0), sentries, config, 0);
        assertNotEq(victim, attacker);
        vm.prank(address(0xbad));
        factory.newDaveApp(TEMPLATE, 0, address(0), sentries, config, 0);
        (IApplication app, IDaveConsensus consensus) = factory.newDaveApp(TEMPLATE, 10, address(0), sentries, config, 0);
        assertEq(address(app), victim);
        assertEq(address(consensus), expectedConsensus);
    }

    function testFuzzAllConsensusSettingsAreBoundToTheApplicationAddress(
        uint64 claimStagingPeriod,
        address sentryManager,
        bytes32 salt
    ) external view {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        (address original,) =
            factory.calculateDaveAppAddress(TEMPLATE, claimStagingPeriod, sentryManager, sentries, config, salt);
        (address otherClaimStagingPeriod,) = factory.calculateDaveAppAddress(
            TEMPLATE, uint256(claimStagingPeriod) + 1, sentryManager, sentries, config, salt
        );
        assertNotEq(original, otherClaimStagingPeriod);
        (address otherSentryManager,) = factory.calculateDaveAppAddress(
            TEMPLATE, claimStagingPeriod, address(uint160(sentryManager) ^ 1), sentries, config, salt
        );
        assertNotEq(original, otherSentryManager);
        sentries = new address[](1);
        sentries[0] = address(1);
        (address otherSentries,) =
            factory.calculateDaveAppAddress(TEMPLATE, claimStagingPeriod, sentryManager, sentries, config, salt);
        assertNotEq(original, otherSentries);
    }
}
