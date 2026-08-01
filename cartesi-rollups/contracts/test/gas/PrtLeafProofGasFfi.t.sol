// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.22;

import {Gas} from "prt-contracts/tournament/libs/Gas.sol";

import {LeafTournamentGasFixture} from "./LeafTournamentGasFixture.sol";

contract OrdinaryLeafWinOneFfiTest is LeafTournamentGasFixture {
    function setUp() public {
        _initializeLeafGasFixture(1, new uint256[](0), WinnerSide.ONE);
    }

    function testMeasureOrdinaryStepWithOneWinning() public {
        _measureLeafWin("ordinary step one wins");
    }
}

contract OrdinaryLeafWinTwoFfiTest is LeafTournamentGasFixture {
    function setUp() public {
        _initializeLeafGasFixture(1, new uint256[](0), WinnerSide.TWO);
    }

    function testMeasureOrdinaryStepWithTwoWinning() public {
        _measureLeafWin("ordinary step two wins");
    }
}

contract ResetLeafWinOneFfiTest is LeafTournamentGasFixture {
    function setUp() public {
        _initializeLeafGasFixture((1 << 20) - 1, new uint256[](0), WinnerSide.ONE);
    }

    function testMeasureResetWithOneWinning() public {
        _measureLeafWin("reset one wins");
    }
}

contract ResetLeafWinTwoFfiTest is LeafTournamentGasFixture {
    function setUp() public {
        _initializeLeafGasFixture((1 << 20) - 1, new uint256[](0), WinnerSide.TWO);
    }

    function testMeasureResetWithTwoWinning() public {
        _measureLeafWin("reset two wins");
    }
}

contract RevertLeafWinOneFfiTest is LeafTournamentGasFixture {
    function setUp() public {
        _initializeRevertLeafGasFixture(0, WinnerSide.ONE);
    }

    function testMeasureRevertWithOneWinning() public {
        _measureLeafWin("revert one wins");
    }
}

contract RevertLeafWinTwoFfiTest is LeafTournamentGasFixture {
    function setUp() public {
        _initializeRevertLeafGasFixture(0, WinnerSide.TWO);
    }

    function testMeasureRevertWithTwoWinning() public {
        _measureLeafWin("revert two wins");
    }
}

abstract contract InputLeafWinFfiTest is LeafTournamentGasFixture {
    uint256 internal constant SECOND_INPUT_COUNTER = 1 << 68;

    function _payloads(uint256 targetPayloadSize) internal pure returns (uint256[] memory sizes) {
        sizes = new uint256[](2);
        sizes[0] = 0;
        sizes[1] = targetPayloadSize;
    }
}

contract SmallInputLeafWinOneFfiTest is InputLeafWinFfiTest {
    function setUp() public {
        _initializeLeafGasFixture(SECOND_INPUT_COUNTER, _payloads(0), WinnerSide.ONE);
    }

    function testMeasureSmallInputWithOneWinning() public {
        _measureLeafWin("small input one wins");
    }
}

contract SmallInputLeafWinTwoFfiTest is InputLeafWinFfiTest {
    function setUp() public {
        _initializeLeafGasFixture(SECOND_INPUT_COUNTER, _payloads(0), WinnerSide.TWO);
    }

    function testMeasureSmallInputWithTwoWinning() public {
        _measureLeafWin("small input two wins");
    }
}

contract RepresentativeInputLeafWinOneFfiTest is InputLeafWinFfiTest {
    function setUp() public {
        _initializeLeafGasFixture(SECOND_INPUT_COUNTER, _payloads(REPRESENTATIVE_PAYLOAD_SIZE), WinnerSide.ONE);
    }

    function testMeasureRepresentativeInputWithOneWinning() public {
        _measureLeafWin("representative input one wins");
    }
}

contract MaximumInputLeafWinOneFfiTest is InputLeafWinFfiTest {
    function setUp() public {
        _initializeLeafGasFixture(SECOND_INPUT_COUNTER, _payloads(MAX_PAYLOAD_SIZE), WinnerSide.ONE);
        assertEq(proofInputSize, MAX_ENCODED_INPUT_SIZE);
        _assertPayloadAboveMaximumRejected();
    }

    function testMeasureMaximumInputWithOneWinning() public {
        Measurement memory result = _measureLeafWin("maximum input one wins");
        assertEq(_roundUpToThousand(_minimumReviewedAllocation(result)) + 1_000, Gas.WIN_LEAF_MATCH);
    }
}

contract MaximumInputLeafWinTwoFfiTest is InputLeafWinFfiTest {
    function setUp() public {
        _initializeLeafGasFixture(SECOND_INPUT_COUNTER, _payloads(MAX_PAYLOAD_SIZE), WinnerSide.TWO);
        assertEq(proofInputSize, MAX_ENCODED_INPUT_SIZE);
        _assertPayloadAboveMaximumRejected();
    }

    function testMeasureMaximumInputWithTwoWinning() public {
        Measurement memory result = _measureLeafWin("maximum input two wins");
        assertEq(_roundUpToThousand(_minimumReviewedAllocation(result)) + 1_000, Gas.WIN_LEAF_MATCH);
    }
}

contract OutOfRangeInputLeafWinOneFfiTest is InputLeafWinFfiTest {
    function setUp() public {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 0;
        _initializeLeafGasFixture(SECOND_INPUT_COUNTER, sizes, WinnerSide.ONE);
    }

    function testMeasureOutOfRangeInputWithOneWinning() public {
        _measureLeafWin("out of range input one wins");
    }
}
