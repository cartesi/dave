// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";

/// @notice Test-only validation for an injected tournament parameter table.
/// @dev Production keeps geometry static. This helper makes the generation
/// invariants executable without adding deployment-time validation or copying
/// any Match transition logic into tests.
library TournamentParameterTableValidator {
    uint256 internal constant MAX_LOG2_EXTENT = 256;

    error EmptyTable();
    error LevelsCannotBeZero(uint64 row);
    error LevelsMismatch(uint64 row, uint64 declared, uint64 actual);
    error RootMaxAllowanceCannotBeZero();
    error HeightCannotBeZero(uint64 row);
    error HeightExceedsCoordinateSpace(uint64 row, uint64 height);
    error Log2StepOutsideCoordinateSpace(uint64 row, uint64 log2step);
    error RowExtentExceedsCoordinateSpace(
        uint64 row, uint64 height, uint64 log2step
    );
    error RootExtentMismatch(uint256 actual, uint64 expected);
    error RowsDoNotTile(
        uint64 parentRow, uint64 parentLog2step, uint256 childExtent
    );
    error LeafLog2StepMustBeZero(uint64 log2step);

    /// @return levels Number of validated rows.
    /// @return totalLog2Span Validated root height plus root stride.
    function validate(
        TournamentParameters[] memory table,
        uint64 expectedTotalLog2Span
    ) internal pure returns (uint64 levels, uint64 totalLog2Span) {
        if (table.length == 0) revert EmptyTable();

        levels = uint64(table.length);
        for (uint64 row; row < levels; ++row) {
            uint64 declared = table[row].levels;
            if (declared == 0) revert LevelsCannotBeZero(row);
            if (declared != levels) {
                revert LevelsMismatch(row, declared, levels);
            }
        }

        if (Time.Duration.unwrap(table[0].maxAllowance) == 0) {
            revert RootMaxAllowanceCannotBeZero();
        }

        uint256[] memory extents = new uint256[](levels);
        for (uint64 row; row < levels; ++row) {
            uint64 height = table[row].height;
            uint64 log2step = table[row].log2step;

            if (height == 0) revert HeightCannotBeZero(row);
            if (height > MAX_LOG2_EXTENT) {
                revert HeightExceedsCoordinateSpace(row, height);
            }
            if (log2step >= MAX_LOG2_EXTENT) {
                revert Log2StepOutsideCoordinateSpace(row, log2step);
            }

            uint256 extent = uint256(height) + log2step;
            if (extent > MAX_LOG2_EXTENT) {
                revert RowExtentExceedsCoordinateSpace(row, height, log2step);
            }
            extents[row] = extent;
        }

        totalLog2Span = uint64(extents[0]);
        if (totalLog2Span != expectedTotalLog2Span) {
            revert RootExtentMismatch(totalLog2Span, expectedTotalLog2Span);
        }

        for (uint64 row = 1; row < levels; ++row) {
            uint64 parentLog2step = table[row - 1].log2step;
            if (parentLog2step != extents[row]) {
                revert RowsDoNotTile(row - 1, parentLog2step, extents[row]);
            }
        }

        uint64 leafLog2step = table[levels - 1].log2step;
        if (leafLog2step != 0) {
            revert LeafLog2StepMustBeZero(leafLog2step);
        }
    }
}

/// @notice External boundary used to assert exact validator errors.
contract TournamentParameterTableValidatorHarness {
    function validate(
        TournamentParameters[] calldata table,
        uint64 expectedTotalLog2Span
    ) external pure returns (uint64 levels, uint64 totalLog2Span) {
        return TournamentParameterTableValidator.validate(
            table, expectedTotalLog2Span
        );
    }
}
