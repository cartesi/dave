// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {
    ArbitrationConstants
} from "prt-contracts/arbitration-config/ArbitrationConstants.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";

import {
    TournamentParameterTableValidator,
    TournamentParameterTableValidatorHarness
} from "../fixtures/TournamentParameterTableValidator.sol";

contract TournamentParameterTableValidatorTest is Test {
    TournamentParameterTableValidatorHarness internal immutable VALIDATOR;

    constructor() {
        VALIDATOR = new TournamentParameterTableValidatorHarness();
    }

    function testCurrentCanonicalTableIsValid() public view {
        uint64 levels = ArbitrationConstants.LEVELS;
        TournamentParameters[] memory table = _table(levels);
        for (uint64 row; row < levels; ++row) {
            table[row] = _row(
                levels,
                ArbitrationConstants.log2step(row),
                ArbitrationConstants.height(row),
                row,
                row + 1
            );
        }

        (uint64 actualLevels, uint64 totalLog2Span) =
            VALIDATOR.validate(table, 92);

        assertEq(actualLevels, levels);
        assertEq(totalLog2Span, 92);
    }

    function testSafeFourLevelMiniatureIsValid() public view {
        TournamentParameters[] memory table = _fourLevelTable();

        (uint64 levels, uint64 totalLog2Span) = VALIDATOR.validate(table, 4);

        assertEq(levels, 4);
        assertEq(totalLog2Span, 4);
    }

    function testZeroResponseBudgetAndUnequalTimingAreValid() public view {
        TournamentParameters[] memory table = _fourLevelTable();
        for (uint64 row; row < table.length; ++row) {
            table[row].responseBudget = Time.Duration.wrap(row * 3);
            table[row].maxAllowance = Time.Duration.wrap(row + 1);
        }

        VALIDATOR.validate(table, 4);
    }

    function testRejectsEmptyTable() public {
        TournamentParameters[] memory table = _table(0);

        vm.expectRevert(TournamentParameterTableValidator.EmptyTable.selector);
        VALIDATOR.validate(table, 0);
    }

    function testRejectsZeroDeclaredLevels() public {
        TournamentParameters[] memory table = _oneLevelTable(1, 0, 1);
        table[0].levels = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.LevelsCannotBeZero.selector,
                uint64(0)
            )
        );
        VALIDATOR.validate(table, 1);
    }

    function testRejectsPerRowLevelsMismatch() public {
        TournamentParameters[] memory table = _fourLevelTable();
        table[2].levels = 3;

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.LevelsMismatch.selector,
                uint64(2),
                uint64(3),
                uint64(4)
            )
        );
        VALIDATOR.validate(table, 4);
    }

    function testRejectsZeroHeight() public {
        TournamentParameters[] memory table = _oneLevelTable(0, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.HeightCannotBeZero.selector,
                uint64(0)
            )
        );
        VALIDATOR.validate(table, 0);
    }

    function testRejectsHeightAbove256() public {
        TournamentParameters[] memory table = _oneLevelTable(257, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.HeightExceedsCoordinateSpace
                .selector,
                uint64(0),
                uint64(257)
            )
        );
        VALIDATOR.validate(table, 257);
    }

    function testAcceptsHeightExactly256() public view {
        TournamentParameters[] memory table = _oneLevelTable(256, 0, 1);

        (, uint64 totalLog2Span) = VALIDATOR.validate(table, 256);

        assertEq(totalLog2Span, 256);
    }

    function testRejectsLog2StepAt256() public {
        TournamentParameters[] memory table = _oneLevelTable(1, 256, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.Log2StepOutsideCoordinateSpace
                    .selector,
                uint64(0),
                uint64(256)
            )
        );
        VALIDATOR.validate(table, 257);
    }

    function testRejectsRowExtentAbove256() public {
        TournamentParameters[] memory table = _oneLevelTable(129, 128, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.RowExtentExceedsCoordinateSpace
                    .selector,
                uint64(0),
                uint64(129),
                uint64(128)
            )
        );
        VALIDATOR.validate(table, 257);
    }

    function testRejectsWrongRootExtent() public {
        TournamentParameters[] memory table = _fourLevelTable();

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.RootExtentMismatch.selector,
                uint256(4),
                uint64(5)
            )
        );
        VALIDATOR.validate(table, 5);
    }

    function testRejectsNonTilingRows() public {
        TournamentParameters[] memory table = _fourLevelTable();
        table[2].height = 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.RowsDoNotTile.selector,
                uint64(1),
                uint64(2),
                uint256(3)
            )
        );
        VALIDATOR.validate(table, 4);
    }

    function testRejectsNonzeroLeafLog2Step() public {
        TournamentParameters[] memory table = _oneLevelTable(1, 1, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TournamentParameterTableValidator.LeafLog2StepMustBeZero
                .selector,
                uint64(1)
            )
        );
        VALIDATOR.validate(table, 2);
    }

    function testRejectsZeroRootMaxAllowance() public {
        TournamentParameters[] memory table = _oneLevelTable(1, 0, 0);

        vm.expectRevert(
            TournamentParameterTableValidator.RootMaxAllowanceCannotBeZero
            .selector
        );
        VALIDATOR.validate(table, 1);
    }

    function testFuzzHeightBoundary(uint16 rawHeight) public {
        uint64 height = uint64(bound(rawHeight, 248, 264));
        TournamentParameters[] memory table = _oneLevelTable(height, 0, 1);

        if (height <= 256) {
            VALIDATOR.validate(table, height);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TournamentParameterTableValidator.HeightExceedsCoordinateSpace
                        .selector,
                    uint64(0),
                    height
                )
            );
            VALIDATOR.validate(table, height);
        }
    }

    function testFuzzLog2StepBoundary(uint16 rawLog2step) public {
        uint64 log2step = uint64(bound(rawLog2step, 248, 264));
        TournamentParameters[] memory table = _table(2);
        table[0] = _row(2, log2step, 1, 0, 1);
        table[1] = _row(2, 0, log2step, 0, 1);

        if (log2step < 256) {
            VALIDATOR.validate(table, log2step + 1);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TournamentParameterTableValidator.Log2StepOutsideCoordinateSpace
                        .selector,
                    uint64(0),
                    log2step
                )
            );
            VALIDATOR.validate(table, log2step + 1);
        }
    }

    function testFuzzRowExtentBoundary(uint8 rawRootHeight) public {
        uint64 rootHeight = uint64(bound(rawRootHeight, 120, 136));
        TournamentParameters[] memory table = _table(2);
        table[0] = _row(2, 128, rootHeight, 0, 1);
        table[1] = _row(2, 0, 128, 0, 1);

        if (rootHeight <= 128) {
            VALIDATOR.validate(table, rootHeight + 128);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TournamentParameterTableValidator.RowExtentExceedsCoordinateSpace
                        .selector,
                    uint64(0),
                    rootHeight,
                    uint64(128)
                )
            );
            VALIDATOR.validate(table, rootHeight + 128);
        }
    }

    function testFuzzTilingBoundary(uint8 rawChildHeight) public {
        uint64 childHeight = uint64(bound(rawChildHeight, 127, 129));
        TournamentParameters[] memory table = _table(2);
        table[0] = _row(2, 128, 1, 0, 1);
        table[1] = _row(2, 0, childHeight, 0, 1);

        if (childHeight == 128) {
            VALIDATOR.validate(table, 129);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TournamentParameterTableValidator.RowsDoNotTile.selector,
                    uint64(0),
                    uint64(128),
                    uint256(childHeight)
                )
            );
            VALIDATOR.validate(table, 129);
        }
    }

    function testFuzzLeafLog2StepBoundary(uint8 rawLeafLog2step) public {
        uint64 leafLog2step = uint64(bound(rawLeafLog2step, 0, 3));
        TournamentParameters[] memory table = _table(2);
        table[0] = _row(2, leafLog2step + 1, 1, 0, 1);
        table[1] = _row(2, leafLog2step, 1, 0, 1);

        if (leafLog2step == 0) {
            VALIDATOR.validate(table, 2);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TournamentParameterTableValidator.LeafLog2StepMustBeZero
                    .selector,
                    leafLog2step
                )
            );
            VALIDATOR.validate(table, leafLog2step + 2);
        }
    }

    function _fourLevelTable()
        private
        pure
        returns (TournamentParameters[] memory table)
    {
        table = _table(4);
        table[0] = _row(4, 3, 1, 0, 1);
        table[1] = _row(4, 2, 1, 0, 1);
        table[2] = _row(4, 1, 1, 0, 1);
        table[3] = _row(4, 0, 1, 0, 1);
    }

    function _oneLevelTable(uint64 height, uint64 log2step, uint64 maxAllowance)
        private
        pure
        returns (TournamentParameters[] memory table)
    {
        table = _table(1);
        table[0] = _row(1, log2step, height, 0, maxAllowance);
    }

    function _table(uint64 levels)
        private
        pure
        returns (TournamentParameters[] memory)
    {
        return new TournamentParameters[](levels);
    }

    function _row(
        uint64 levels,
        uint64 log2step,
        uint64 height,
        uint64 responseBudget,
        uint64 maxAllowance
    ) private pure returns (TournamentParameters memory) {
        return TournamentParameters({
            levels: levels,
            log2step: log2step,
            height: height,
            responseBudget: Time.Duration.wrap(responseBudget),
            maxAllowance: Time.Duration.wrap(maxAllowance)
        });
    }
}
