// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Errors} from "@openzeppelin-contracts-5.5.0/utils/Errors.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

contract FactoryDependencyParametersProvider is ITournamentParametersProvider {
    error InvalidLevel(uint64 level);

    function tournamentParameters(uint64 level)
        external
        pure
        override
        returns (TournamentParameters memory)
    {
        if (level > 1) {
            revert InvalidLevel(level);
        }

        return TournamentParameters({
            levels: 2,
            log2step: level == 0 ? 2 : 0,
            height: level == 0 ? 3 : 2,
            responseBudget: Time.Duration.wrap(1),
            maxAllowance: Time.Duration.wrap(100)
        });
    }
}

contract FactoryDependencyStateTransition is IStateTransition {
    function transitionState(
        bytes32 machineState,
        uint256,
        bytes calldata,
        IDataProvider
    ) external pure override returns (bytes32) {
        return machineState;
    }
}

contract MultiLevelTournamentFactoryDependenciesTest is Test {
    Tournament internal implementation;
    ITournamentParametersProvider internal parametersProvider;
    IStateTransition internal stateTransition;

    function setUp() public {
        implementation = new Tournament();
        parametersProvider = new FactoryDependencyParametersProvider();
        stateTransition = new FactoryDependencyStateTransition();
    }

    function testRejectsZeroImplementation() public {
        vm.expectRevert(Errors.FailedDeployment.selector);
        new MultiLevelTournamentFactory(
            Tournament(address(0)), parametersProvider, stateTransition
        );
    }

    function testRejectsNoCodeImplementation() public {
        address noCode = address(0xbeef);
        assertEq(noCode.code.length, 0);

        vm.expectRevert(Errors.FailedDeployment.selector);
        new MultiLevelTournamentFactory(
            Tournament(noCode), parametersProvider, stateTransition
        );
    }

    function testRejectsZeroParametersProvider() public {
        vm.expectRevert(Errors.FailedDeployment.selector);
        new MultiLevelTournamentFactory(
            implementation,
            ITournamentParametersProvider(address(0)),
            stateTransition
        );
    }

    function testRejectsNoCodeParametersProvider() public {
        address noCode = address(0xbeef);
        assertEq(noCode.code.length, 0);

        vm.expectRevert(Errors.FailedDeployment.selector);
        new MultiLevelTournamentFactory(
            implementation,
            ITournamentParametersProvider(noCode),
            stateTransition
        );
    }

    function testRejectsZeroStateTransition() public {
        vm.expectRevert(Errors.FailedDeployment.selector);
        new MultiLevelTournamentFactory(
            implementation, parametersProvider, IStateTransition(address(0))
        );
    }

    function testRejectsNoCodeStateTransition() public {
        address noCode = address(0xbeef);
        assertEq(noCode.code.length, 0);

        vm.expectRevert(Errors.FailedDeployment.selector);
        new MultiLevelTournamentFactory(
            implementation, parametersProvider, IStateTransition(noCode)
        );
    }

    function testForwardsParametersAndProjectsLevelCount() public {
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            implementation, parametersProvider, stateTransition
        );

        uint64 levelCount = factory.tournamentLevelCount();
        assertEq(levelCount, parametersProvider.tournamentParameters(0).levels);

        for (uint64 level; level < levelCount; ++level) {
            TournamentParameters memory expected =
                parametersProvider.tournamentParameters(level);
            TournamentParameters memory actual =
                factory.tournamentParameters(level);

            assertEq(
                keccak256(abi.encode(actual)), keccak256(abi.encode(expected))
            );
            assertEq(actual.levels, levelCount);
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                FactoryDependencyParametersProvider.InvalidLevel.selector, 2
            )
        );
        factory.tournamentParameters(2);
    }

    function testReportsConfiguredStateTransition() public {
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            implementation, parametersProvider, stateTransition
        );

        assertEq(address(factory.stateTransition()), address(stateTransition));
    }

    function testValidDependenciesProduceClonesFromAdvertisedRows() public {
        vm.roll(100);
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            implementation, parametersProvider, stateTransition
        );

        ITournament root =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));
        assertGt(address(root).code.length, 0);

        TournamentParameters memory parameters = factory.tournamentParameters(0);
        ITournament.TournamentArguments memory args = root.tournamentArguments();
        assertEq(args.level, 0);
        assertEq(uint8(args.kind), uint8(ITournament.TournamentKind.NON_LEAF));
        assertEq(args.commitmentArgs.log2step, parameters.log2step);
        assertEq(args.commitmentArgs.height, parameters.height);
        assertEq(
            Time.Duration.unwrap(args.responseBudget),
            Time.Duration.unwrap(parameters.responseBudget)
        );
        assertEq(
            Time.Duration.unwrap(args.allowance),
            Time.Duration.unwrap(parameters.maxAllowance)
        );
        assertEq(args.tournamentFactory, address(factory));
        assertEq(address(args.stateTransition), address(stateTransition));
        assertFalse(root.isClosed());
        assertGt(root.bondValue(), 0);

        ITournament inner = factory.instantiateInner(
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            Tree.ZERO_NODE,
            Machine.ZERO_STATE,
            Time.Duration.wrap(80),
            4,
            1,
            IDataProvider(address(0))
        );
        assertGt(address(inner).code.length, 0);

        parameters = factory.tournamentParameters(1);
        args = inner.tournamentArguments();
        assertEq(args.level, 1);
        assertEq(uint8(args.kind), uint8(ITournament.TournamentKind.LEAF));
        assertEq(args.commitmentArgs.log2step, parameters.log2step);
        assertEq(args.commitmentArgs.height, parameters.height);
        assertEq(args.commitmentArgs.startCycle, 4);
        assertEq(
            Time.Duration.unwrap(args.responseBudget),
            Time.Duration.unwrap(parameters.responseBudget)
        );
        assertEq(Time.Duration.unwrap(args.allowance), 80);
        assertEq(args.tournamentFactory, address(factory));
        assertEq(address(args.stateTransition), address(stateTransition));
    }
}
