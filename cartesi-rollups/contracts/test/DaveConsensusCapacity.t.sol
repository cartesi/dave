// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {Test} from "forge-std-1.9.6/src/Test.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {DaveConsensus} from "src/DaveConsensus.sol";
import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

contract CapacityConsensus is DaveConsensus {
    constructor(IInputBox inputBox, address app, ITournamentFactory factory)
        DaveConsensus(inputBox, app, factory, Machine.Hash.wrap(bytes32(0)), 0, address(0), new address[](0))
    {}

    // Isolate sealing from validity proofs and tournament resolution, covered
    // by DaveAppFactoryTest. Acceptance still runs through the public entry point.
    function stageForTest() external {
        _isTournamentResultStaged = true;
    }
}

contract DaveConsensusCapacityTest is Test {
    uint256 constant CAPACITY = 1 << EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH;
    IInputBox constant INPUT_BOX = IInputBox(address(0x100));
    address constant APP = address(0x200);
    ITournamentFactory constant FACTORY = ITournamentFactory(address(0x300));
    ITournament constant TOURNAMENT = ITournament(address(0x400));

    function setUp() external {
        vm.mockCall(
            address(FACTORY), abi.encodeWithSelector(ITournamentFactory.instantiate.selector), abi.encode(TOURNAMENT)
        );
        vm.mockCall(APP, abi.encodeCall(IApplication.isForeclosed, ()), abi.encode(false));
    }

    function _count(uint256 count) internal {
        vm.mockCall(address(INPUT_BOX), abi.encodeCall(IInputBox.getNumberOfInputs, (APP)), abi.encode(count));
    }

    function _deploy(uint256 count) internal returns (CapacityConsensus) {
        _count(count);
        return new CapacityConsensus(INPUT_BOX, APP, FACTORY);
    }

    function _bounds(CapacityConsensus consensus, uint256 epoch, uint256 lower, uint256 upper) internal view {
        (uint256 actualEpoch, uint256 actualLower, uint256 actualUpper,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(actualEpoch, epoch);
        assertEq(actualLower, lower);
        assertEq(actualUpper, upper);
    }

    function testBacklogRollsAcrossEpochsWithoutFinalizingUnprocessedInputs() external {
        CapacityConsensus consensus = _deploy(CAPACITY + 1);
        _bounds(consensus, 0, 0, CAPACITY);
        consensus.stageForTest();
        consensus.acceptStagedTournamentResult(0);
        _bounds(consensus, 1, CAPACITY, CAPACITY + 1);
        assertTrue(consensus.wasInputFinalized(APP, CAPACITY - 1, 0));
        assertFalse(consensus.wasInputFinalized(APP, CAPACITY, 0));

        _count(3 * CAPACITY + 1);
        consensus.stageForTest();
        consensus.acceptStagedTournamentResult(1);
        _bounds(consensus, 2, CAPACITY + 1, 2 * CAPACITY + 1);
        assertTrue(consensus.wasInputFinalized(APP, CAPACITY, 0));
        assertFalse(consensus.wasInputFinalized(APP, CAPACITY + 1, 0));
    }

    function testCapacityBoundaryAndEmptyEpochs() external {
        uint256[4] memory counts = [uint256(0), CAPACITY - 1, CAPACITY, CAPACITY + 1];
        for (uint256 i; i < counts.length; ++i) {
            CapacityConsensus consensus = _deploy(counts[i]);
            uint256 first = counts[i] < CAPACITY ? counts[i] : CAPACITY;
            _bounds(consensus, 0, 0, first);
            consensus.stageForTest();
            consensus.acceptStagedTournamentResult(0);
            _bounds(consensus, 1, first, counts[i]);
        }
    }
}
