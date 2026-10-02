// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Time} from "src/tournament/libs/Time.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {TableTournamentParametersProvider} from "./TableTournamentParametersProvider.sol";
import {TournamentParameterTableValidator} from "./TournamentParameterTableValidator.sol";

contract TableTournamentParametersProviderTest is Test {
    uint64 internal constant EPOCH_LOG2_SPAN = 92;
    Time.Duration internal constant RESPONSE_BUDGET = Time.Duration.wrap(25);
    Time.Duration internal constant COMMITMENT_BUDGET = Time.Duration.wrap(150);
    Time.Duration internal constant MAX_ALLOWANCE = Time.Duration.wrap(300);

    function _table(uint64[2] memory log2steps, uint64[2] memory heights)
        internal
        pure
        returns (uint64[] memory steps, uint64[] memory hs)
    {
        steps = new uint64[](2);
        hs = new uint64[](2);
        for (uint256 i; i < 2; ++i) {
            steps[i] = log2steps[i];
            hs[i] = heights[i];
        }
    }

    function testServesTheTwoLevelTable() public {
        (uint64[] memory steps, uint64[] memory hs) =
            _table([uint64(37), 0], [uint64(55), 37]);
        TableTournamentParametersProvider provider = new TableTournamentParametersProvider(
            steps,
            hs,
            RESPONSE_BUDGET,
            COMMITMENT_BUDGET,
            MAX_ALLOWANCE,
            EPOCH_LOG2_SPAN
        );

        TournamentParameters memory root = provider.tournamentParameters(0);
        assertEq(root.levels, 2);
        assertEq(root.log2step, 37);
        assertEq(root.height, 55);
        assertEq(Time.Duration.unwrap(root.responseBudget), 25);
        assertEq(Time.Duration.unwrap(root.commitmentBudget), 150);
        assertEq(Time.Duration.unwrap(root.maxAllowance), 300);

        TournamentParameters memory leaf = provider.tournamentParameters(1);
        assertEq(leaf.levels, 2);
        assertEq(leaf.log2step, 0);
        assertEq(leaf.height, 37);

        vm.expectRevert(
            abi.encodeWithSelector(
                TableTournamentParametersProvider.UnknownLevel.selector, 2, 2
            )
        );
        provider.tournamentParameters(2);
    }

    function testRejectsAnInvalidTable() public {
        (uint64[] memory steps, uint64[] memory hs) =
            _table([uint64(37), 0], [uint64(55), 36]);
        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.RowsDoNotTile.selector,
                0,
                37,
                36
            )
        );
        new TableTournamentParametersProvider(
            steps,
            hs,
            RESPONSE_BUDGET,
            COMMITMENT_BUDGET,
            MAX_ALLOWANCE,
            EPOCH_LOG2_SPAN
        );
    }

    function testRejectsARaggedTable() public {
        uint64[] memory steps = new uint64[](2);
        uint64[] memory hs = new uint64[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TableTournamentParametersProvider.RaggedTable.selector, 2, 1
            )
        );
        new TableTournamentParametersProvider(
            steps,
            hs,
            RESPONSE_BUDGET,
            COMMITMENT_BUDGET,
            MAX_ALLOWANCE,
            EPOCH_LOG2_SPAN
        );
    }
}
