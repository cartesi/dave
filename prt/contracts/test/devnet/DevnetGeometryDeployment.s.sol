// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

import {DeploymentScript, Seconds} from "../../script/Deployment.s.sol";
import {TableTournamentParametersProvider} from "../fixtures/TableTournamentParametersProvider.sol";

import {ClockBudgets} from "src/arbitration-config/ClockBudgets.sol";
import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";

/// @notice Devnet-only PRT deployment serving the three-level test table CI
/// and local tests run (docs/test-harness.md). Everything but the parameters
/// provider matches `DeploymentScript.run`, and each contract is stored under
/// the same name, so downstream deployments wire themselves to this factory
/// unchanged.
contract DevnetGeometryDeploymentScript is DeploymentScript {
    error NotADevnet(uint256 chainId);

    uint64 constant EPOCH_LOG2_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
            + EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;

    /// @notice The canonical three-level table's rows and 30-minute
    /// commitment budget, kept as the test shape once production moves to
    /// two levels.
    function runThreeLevel() external {
        _registerChains();
        _registerChainKinds();
        _deployWithTable(_threeLevelProviderArguments());
    }

    /// @notice The three-level table provider's constructor arguments.
    /// @dev Should be called after `_registerChains` and `_registerChainKinds`.
    function _threeLevelProviderArguments()
        internal
        view
        returns (bytes memory)
    {
        uint64[] memory log2steps = new uint64[](3);
        uint64[] memory heights = new uint64[](3);
        (log2steps[0], heights[0]) = (44, 48);
        (log2steps[1], heights[1]) = (27, 17);
        (log2steps[2], heights[2]) = (0, 27);
        return
            _tableProviderArguments(
                log2steps, heights, Seconds.wrap(30 minutes)
            );
    }

    function _tableProviderArguments(
        uint64[] memory log2steps,
        uint64[] memory heights,
        Seconds commitmentBudget
    ) internal view returns (bytes memory) {
        ClockBudgets.Model memory clocks = _getClockModel(commitmentBudget);
        return abi.encode(
            log2steps,
            heights,
            ClockBudgets.responseBudget(clocks),
            ClockBudgets.commitmentBudget(clocks),
            ClockBudgets.maxAllowance(clocks, uint64(log2steps.length)),
            EPOCH_LOG2_SPAN
        );
    }

    function _deployWithTable(bytes memory providerArguments) internal {
        require(
            _getCurrentChainInfo().kind == ChainKind.DEVNET,
            NotADevnet(block.chainid)
        );

        vmSafe.startBroadcast();

        address cartesiStateTransition = _storeDeployment(
            type(CartesiStateTransition).name,
            _create2(type(CartesiStateTransition).creationCode, abi.encode())
        );

        address tournamentImpl = _storeDeployment(
            type(Tournament).name,
            _create2(type(Tournament).creationCode, abi.encode())
        );

        address tableTournamentParametersProvider = _storeDeployment(
            type(TableTournamentParametersProvider).name,
            _create2(
                type(TableTournamentParametersProvider).creationCode,
                providerArguments
            )
        );

        _storeDeployment(
            type(MultiLevelTournamentFactory).name,
            _create2(
                type(MultiLevelTournamentFactory).creationCode,
                abi.encode(
                    tournamentImpl,
                    tableTournamentParametersProvider,
                    cartesiStateTransition
                )
            )
        );

        vmSafe.stopBroadcast();
    }
}
