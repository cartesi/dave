pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

import {DaveConsensusFactory} from "src/DaveConsensusFactory.sol";
import {DaveConsensus} from "src/DaveConsensus.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournamentFactory.sol";
import {IInputBox} from "rollups-contracts/inputs/IInputBox.sol";
import {InputBox} from "rollups-contracts/inputs/InputBox.sol";
import {Machine} from "prt-contracts/Machine.sol";
import {Tree} from "prt-contracts/Tree.sol";

contract MockTournamentFactory is ITournamentFactory {
    address tournamentAddress;

    function setAddress(address _addr) external {
        tournamentAddress = _addr;
    }

    function instantiate(Machine.Hash initialState, IDataProvider provider) external returns (ITournament) {
        return ITournament(tournamentAddress);
    }
}

contract DaveConsensusFactoryTest is Test {
    DaveConsensusFactory _factory;
    InputBox _inputBox;
    MockTournamentFactory _tournamentFactory;
    address _appContract;
    Machine.Hash _initialMachineStateHash;

    function setUp() public {
        _inputBox = new InputBox();
        _tournamentFactory = new MockTournamentFactory();
        _factory = new DaveConsensusFactory(_inputBox, _tournamentFactory);
        _initialMachineStateHash = Machine.Hash.wrap(0x0);
    }

    function testNewDaveConsensus(address appContract, address _tournamentAddress) public {
        vm.recordLogs();
        _tournamentFactory.setAddress(_tournamentAddress);
        DaveConsensus daveConsensus = _factory.newDaveConsensus(appContract, _initialMachineStateHash);
        _testNewDaveConsensusAux(daveConsensus, _tournamentAddress);
    }

    function testNewDaveConsensusDeterministic(address appContract, address _tournamentAddress, bytes32 salt) public {
        address precalculatedAddress =
            _factory.calculateDaveConsensusAddress(appContract, _initialMachineStateHash, salt);

        vm.recordLogs();

        _tournamentFactory.setAddress(_tournamentAddress);
        DaveConsensus daveConsensus = _factory.newDaveConsensus(appContract, _initialMachineStateHash, salt);

        _testNewDaveConsensusAux(daveConsensus, _tournamentAddress);

        assertEq(precalculatedAddress, address(daveConsensus));

        // Ensure the address remains the same when recalculated
        precalculatedAddress = _factory.calculateDaveConsensusAddress(appContract, _initialMachineStateHash, salt);
        assertEq(precalculatedAddress, address(daveConsensus));

        // Cannot deploy the same contract twice with the same salt
        vm.expectRevert();
        _factory.newDaveConsensus(appContract, _initialMachineStateHash, salt);
    }

    function _testNewDaveConsensusAux(DaveConsensus daveConsensus, address fuzzAddress) internal {
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
                    uint256 epochNumber,
                    uint256 inputIndexLowerBound,
                    uint256 inputIndexUpperBound,
                    Machine.Hash initialMachineStateHash,
                    ITournament tournamentAddress
                ) = abi.decode(entry.data, (uint256, uint256, uint256, Machine.Hash, ITournament));

                // Validate the tournament address
                assertEq(address(tournamentAddress), fuzzAddress);
            }
        }

        assertEq(numOfConsensusCreated, 1);
    }
}
