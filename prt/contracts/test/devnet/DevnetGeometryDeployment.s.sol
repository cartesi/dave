// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

import {DeploymentScript} from "../../script/Deployment.s.sol";
import {TableTournamentParametersProvider} from "../fixtures/TableTournamentParametersProvider.sol";

import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";

/// @notice Devnet-only PRT deployment serving a non-canonical tournament
/// table, so clients can run against another geometry before the canonical
/// constants change. Everything but the parameters provider matches
/// `DeploymentScript.run`, and each contract is stored under the same name, so
/// downstream deployments wire themselves to this factory unchanged.
contract DevnetGeometryDeploymentScript is DeploymentScript {
    error NotADevnet(uint256 chainId);

    uint64 constant EPOCH_LOG2_SPAN =
        EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH
            + EmulatorConstants.ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
            + EmulatorConstants.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;

    /// @notice The selected two-level table (docs/dimensioning.md).
    function runTwoLevel() external {
        uint64[] memory log2steps = new uint64[](2);
        uint64[] memory heights = new uint64[](2);
        (log2steps[0], heights[0]) = (37, 55);
        (log2steps[1], heights[1]) = (0, 37);
        _deployWithTable(log2steps, heights);
    }

    function _deployWithTable(
        uint64[] memory log2steps,
        uint64[] memory heights
    ) internal {
        _registerChains();
        _registerChainKinds();
        require(
            _getCurrentChainInfo().kind == ChainKind.DEVNET,
            NotADevnet(block.chainid)
        );

        Time.Duration responseBudget = _getResponseBudget();
        Time.Duration maxAllowance = _getMaxAllowance();

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
                abi.encode(
                    log2steps,
                    heights,
                    responseBudget,
                    maxAllowance,
                    EPOCH_LOG2_SPAN
                )
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
