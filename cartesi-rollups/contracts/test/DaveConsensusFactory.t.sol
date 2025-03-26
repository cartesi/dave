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
import {Machine} from "prt-contracts/Machine.sol";
import {Tree} from "prt-contracts/Tree.sol";

contract MockInputBox is IInputBox {
    mapping(address => bytes32[]) private _inputs;
    uint256 private _deploymentBlock;

    constructor() {
        _deploymentBlock = block.number;
    }

    function addInput(address appContract, bytes calldata payload) external returns (bytes32) {
        bytes32 inputHash = keccak256(payload);
        _inputs[appContract].push(inputHash);
        emit InputAdded(appContract, _inputs[appContract].length - 1, payload);
        return inputHash;
    }

    function getNumberOfInputs(address appContract) external view returns (uint256) {
        return _inputs[appContract].length;
    }

    function getInputHash(address appContract, uint256 index) external view returns (bytes32) {
        require(index < _inputs[appContract].length, "Invalid index");
        return _inputs[appContract][index];
    }

    function getDeploymentBlockNumber() external view returns (uint256) {
        return _deploymentBlock;
    }
}

contract MockTournamentFactory is ITournamentFactory {
    function instantiate(Machine.Hash initialState, IDataProvider provider) external returns (ITournament) {
        return ITournament(address(0));
    }
}

contract MockTournament is ITournament {
    bool private _finished;
    Tree.Node private _winnerCommitment;
    Machine.Hash private _finalState;

    function arbitrationResult() external view override returns (bool, Tree.Node, Machine.Hash) {
        return (_finished, _winnerCommitment, _finalState);
    }
}

contract DaveConsensusFactoryTest is Test {
    DaveConsensusFactory _factory;
    MockInputBox _inputBox;
    MockTournamentFactory _tournamentFactory;
    MockTournament _tournament;
    address _appContract;
    Machine.Hash _initialMachineStateHash;

    function setUp() public {
        _factory = new DaveConsensusFactory();
        _inputBox = new MockInputBox();
        _tournamentFactory = new MockTournamentFactory();
        _appContract = address(0x1234);
        _initialMachineStateHash = Machine.Hash.wrap(0x0);
    }

    function testNewDaveConsensus(address appContract) public {
        vm.recordLogs();

        IDataProvider daveConsensus =
            _factory.newDaveConsensus(_inputBox, appContract, _tournamentFactory, _initialMachineStateHash);

        _testNewDaveConsensusAux(daveConsensus);
    }

    function testNewDaveConsensusDeterministic(address appContract, bytes32 salt) public {
        address precalculatedAddress = _factory.calculateDaveConsensusAddress(
            _inputBox, appContract, _tournamentFactory, _initialMachineStateHash, salt
        );

        vm.recordLogs();

        IDataProvider daveConsensus =
            _factory.newDaveConsensus(_inputBox, appContract, _tournamentFactory, _initialMachineStateHash, salt);

        _testNewDaveConsensusAux(daveConsensus);

        assertEq(precalculatedAddress, address(daveConsensus));

        // Ensure the address remains the same when recalculated
        precalculatedAddress = _factory.calculateDaveConsensusAddress(
            _inputBox, appContract, _tournamentFactory, _initialMachineStateHash, salt
        );
        assertEq(precalculatedAddress, address(daveConsensus));

        // Cannot deploy the same contract twice with the same salt
        vm.expectRevert();
        _factory.newDaveConsensus(_inputBox, appContract, _tournamentFactory, _initialMachineStateHash, salt);
    }

    function _testNewDaveConsensusAux(IDataProvider daveConsensus) internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 numOfConsensusCreated;

        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];

            if (entry.topics[0] == DaveConsensusFactory.DaveConsensusCreated.selector) {
                ++numOfConsensusCreated;
                address emittedAddress = abi.decode(entry.data, (address));
                assertEq(emittedAddress, address(daveConsensus));
            }
        }

        assertEq(numOfConsensusCreated, 1);
    }
}
