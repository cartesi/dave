// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {IOutputsMerkleRootValidator} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactory.sol";
import {RollupsTest} from "cartesi-rollups-contracts-3.0.0/test/util/RollupsTest.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";
import {PrivateApplicationFactory} from "src/PrivateApplicationFactory.sol";

contract DaveAppFactorySquattingTest is RollupsTest {
    DaveAppFactory factory;
    ITournamentFactory constant TOURNAMENT_FACTORY = ITournamentFactory(address(0x100));
    bytes32 constant TEMPLATE = bytes32(uint256(1));

    function setUp() external {
        vm.mockCall(
            address(TOURNAMENT_FACTORY),
            abi.encodeWithSelector(ITournamentFactory.instantiate.selector),
            abi.encode(ITournament(address(0x200)))
        );
        factory = new DaveAppFactory(_contracts.core.inputBox, _contracts.core.applicationFactory, TOURNAMENT_FACTORY);
    }

    function testSharedFactorySquattingCannotCaptureThePrefundedDaveAddress() external {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        (address predicted, address consensus) =
            factory.calculateDaveAppAddress(TEMPLATE, 10, address(0), sentries, config, 0);
        vm.deal(predicted, 1 ether);
        IApplication squat = _contracts.core.applicationFactory
            .newApplication(
                IOutputsMerkleRootValidator(address(0)),
                address(factory),
                TEMPLATE,
                _contracts.core.inputBox,
                config,
                bytes32(0)
            );
        assertNotEq(address(squat), predicted);
        (IApplication app, IDaveConsensus deployedConsensus) =
            factory.newDaveApp(TEMPLATE, 10, address(0), sentries, config, 0);
        assertEq(address(app), predicted);
        assertEq(address(deployedConsensus), consensus);
        assertEq(address(app.getOutputsMerkleRootValidator()), consensus);
        assertEq(app.owner(), address(0));
        assertEq(predicted.balance, 1 ether);
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

    function testPrivateFactoryRejectsDirectDeployment() external {
        IApplicationFactory privateFactory = IApplicationFactory(vm.computeCreateAddress(address(factory), 1));
        WithdrawalConfig memory config;
        vm.expectRevert(PrivateApplicationFactory.UnauthorizedCaller.selector);
        privateFactory.newApplication(
            IOutputsMerkleRootValidator(address(0)),
            address(factory),
            TEMPLATE,
            _contracts.core.inputBox,
            config,
            bytes32(0)
        );
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

    function testFuzzAllConsensusSettingsAreBoundToTheApplicationAddress(uint64 period, address manager, bytes32 salt)
        external
        view
    {
        WithdrawalConfig memory config;
        address[] memory sentries = new address[](0);
        (address original,) = factory.calculateDaveAppAddress(TEMPLATE, period, manager, sentries, config, salt);
        (address otherPeriod,) =
            factory.calculateDaveAppAddress(TEMPLATE, uint256(period) + 1, manager, sentries, config, salt);
        assertNotEq(original, otherPeriod);
        (address otherManager,) =
            factory.calculateDaveAppAddress(TEMPLATE, period, address(uint160(manager) ^ 1), sentries, config, salt);
        assertNotEq(original, otherManager);
        sentries = new address[](1);
        sentries[0] = address(1);
        (address otherSentries,) = factory.calculateDaveAppAddress(TEMPLATE, period, manager, sentries, config, salt);
        assertNotEq(original, otherSentries);
    }
}
