// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Errors} from "@openzeppelin-contracts-5.5.0/utils/Errors.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {IStateTransition} from "src/IStateTransition.sol";
import {ITournament} from "src/ITournament.sol";
import {
    ITournamentParametersProvider
} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

contract FactoryDependencyParametersProvider is ITournamentParametersProvider {
    function tournamentParameters(uint64 level)
        external
        pure
        override
        returns (TournamentParameters memory)
    {
        require(level == 0);
        return TournamentParameters({
            levels: 1,
            log2step: 0,
            height: 1,
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

    function testValidDependenciesProduceCallableRootClone() public {
        vm.roll(100);
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            implementation, parametersProvider, stateTransition
        );

        ITournament root =
            factory.instantiate(Machine.ZERO_STATE, IDataProvider(address(0)));
        assertGt(address(root).code.length, 0);

        ITournament.TournamentArguments memory args = root.tournamentArguments();
        assertEq(args.level, 0);
        assertEq(args.levels, 1);
        assertEq(args.commitmentArgs.log2step, 0);
        assertEq(args.commitmentArgs.height, 1);
        assertEq(args.tournamentFactory, address(factory));
        assertEq(address(args.stateTransition), address(stateTransition));
        assertFalse(root.isClosed());
        assertGt(root.bondValue(), 0);
    }
}
