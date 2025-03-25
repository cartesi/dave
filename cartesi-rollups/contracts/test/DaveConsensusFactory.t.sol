pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

import {DaveConsensusFactory} from "src/DaveConsensusFactory.sol";
import {DaveConsensus} from "src/DaveConsensus.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {IInputBox} from "rollups-contracts/inputs/IInputBox.sol";
import {Machine} from "prt-contracts/Machine.sol";

contract DaveConsensusFactoryTest is Test {
    DaveConsensusFactory _factory;

    function setUp() public {
        _factory = new DaveConsensusFactory();
    }


    function testNewDaveConsensus(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash
    ) public {
        
        vm.recordLogs();

        IDataProvider daveConsensus = _factory.newDaveConsensus(
            inputBox, appContract, tournamentFactory, initialMachineStateHash
        );

        _testNewDaveConsensusAux(daveConsensus);
    }

    function testNewDaveConsensusDeterministic(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash,
        bytes32 salt
    ) public {
        
        address precalculatedAddress = _factory.calculateDaveConsensusAddress(
            inputBox, appContract, tournamentFactory, initialMachineStateHash, salt
        );

        vm.recordLogs();

        IDataProvider daveConsensus = _factory.newDaveConsensus(
            inputBox, appContract, tournamentFactory, initialMachineStateHash, salt
        );

        _testNewDaveConsensusAux(daveConsensus);

        assertEq(precalculatedAddress, address(daveConsensus));

        // Ensure the address remains the same when recalculated
        precalculatedAddress = _factory.calculateDaveConsensusAddress(
            inputBox, appContract, tournamentFactory, initialMachineStateHash, salt
        );
        assertEq(precalculatedAddress, address(daveConsensus));

        // Cannot deploy the same contract twice with the same salt
        vm.expectRevert();
        _factory.newDaveConsensus(inputBox, appContract, tournamentFactory, initialMachineStateHash, salt);
    }

    function _testNewDaveConsensusAux(IDataProvider daveConsensus) internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 numOfConsensusCreated;

        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];

            if (entry.topics[0] == keccak256("DaveConsensusCreation(IDataProvider)")) {
                ++numOfConsensusCreated;
                address emittedAddress = abi.decode(entry.data, (address));
                assertEq(emittedAddress, address(daveConsensus));
            }
        }

        assertEq(numOfConsensusCreated, 1);
    }
}

