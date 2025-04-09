pragma solidity ^0.8.22;

import {Vm} from "forge-std-1.9.6/src/Vm.sol";
import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Create2} from "@openzeppelin-contracts-5.2.0/utils/Create2.sol";

import {IInputBox} from "cartesi-rollups-contracts-2.0.0/inputs/IInputBox.sol";
import {InputBox} from "cartesi-rollups-contracts-2.0.0/inputs/InputBox.sol";

import {DaveConsensusFactory} from "src/DaveConsensusFactory.sol";
import {DaveConsensus} from "src/DaveConsensus.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournamentFactory.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract MockTournamentFactory is ITournamentFactory {
    address tournamentAddress;

    function setAddress(address _addr) external {
        tournamentAddress = _addr;
    }

    function instantiate(Machine.Hash, IDataProvider) external view returns (ITournament) {
        return ITournament(tournamentAddress);
    }
}

contract DaveConsensusFactoryTest is Test {
    DaveConsensusFactory _factory;
    InputBox _inputBox;
    MockTournamentFactory _tournamentFactory;
    Machine.Hash _initialMachineStateHash;

    function setUp() public {
        _inputBox = new InputBox();
        _tournamentFactory = new MockTournamentFactory();
        _factory = new DaveConsensusFactory(_inputBox, _tournamentFactory);
        _initialMachineStateHash = Machine.Hash.wrap(0x0);
    }

    function testNewDaveConsensus(address appContract, address _tournamentAddress, uint256 numberOfInputs) public {
        numberOfInputs = bound(numberOfInputs, 0, 10);
        vm.recordLogs();
        _tournamentFactory.setAddress(_tournamentAddress);
        for (uint256 i = 0; i < numberOfInputs; ++i) {
            _inputBox.addInput(appContract, new bytes(i));
        }
        DaveConsensus daveConsensus = _factory.newDaveConsensus(appContract, _initialMachineStateHash);
        _testNewDaveConsensusAux(daveConsensus, _tournamentAddress, numberOfInputs);
    }

    function testNewDaveConsensusDeterministic(
        address appContract,
        address _tournamentAddress,
        uint256 numberOfInputs,
        bytes32 salt
    ) public {
        address precalculatedAddress =
            _factory.calculateDaveConsensusAddress(appContract, _initialMachineStateHash, salt);

        vm.recordLogs();

        _tournamentFactory.setAddress(_tournamentAddress);
        numberOfInputs = bound(numberOfInputs, 0, 10);
        for (uint256 i = 0; i < numberOfInputs; ++i) {
            _inputBox.addInput(appContract, new bytes(i));
        }
        DaveConsensus daveConsensus = _factory.newDaveConsensus(appContract, _initialMachineStateHash, salt);

        _testNewDaveConsensusAux(daveConsensus, _tournamentAddress, numberOfInputs);

        assertEq(precalculatedAddress, address(daveConsensus));

        // Ensure the address remains the same when recalculated
        precalculatedAddress = _factory.calculateDaveConsensusAddress(appContract, _initialMachineStateHash, salt);
        assertEq(precalculatedAddress, address(daveConsensus));

        // Cannot deploy the same contract twice with the same salt
        vm.expectRevert();
        _factory.newDaveConsensus(appContract, _initialMachineStateHash, salt);
    }

    function _testNewDaveConsensusAux(DaveConsensus daveConsensus, address fuzzAddress, uint256 nInputs) internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 numOfConsensusCreated;

        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];

            if (entry.topics[0] == DaveConsensusFactory.DaveConsensusCreated.selector) {
                ++numOfConsensusCreated;
                address emittedAddress = abi.decode(entry.data, (address));
                assertEq(emittedAddress, address(daveConsensus));
            }
            if (entry.topics[0] == DaveConsensus.EpochSealed.selector) {
                (
                    ,
                    uint256 inputIndexLowerBound,
                    uint256 inputIndexUpperBound,
                    Machine.Hash initialMachineStateHash,
                    bytes32 outputTreeHash,
                    ITournament tournamentAddress
                ) = abi.decode(entry.data, (uint256, uint256, uint256, Machine.Hash, bytes32, ITournament));

                assertEq(address(tournamentAddress), fuzzAddress);
                assertEq(inputIndexLowerBound, 0);
                assertEq(inputIndexUpperBound, nInputs);
                assertEq(Machine.Hash.unwrap(initialMachineStateHash), Machine.Hash.unwrap(_initialMachineStateHash));
                assertEq(outputTreeHash, bytes32(0));
            }
        }

        assertEq(numOfConsensusCreated, 1);
    }
}
