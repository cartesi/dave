pragma solidity ^0.8.22;

import {Vm} from "forge-std-1.9.6/src/Vm.sol";
import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Create2} from "@openzeppelin-contracts-5.2.0/utils/Create2.sol";

import {ApplicationFactory} from "cartesi-rollups-contracts-2.1.0-alpha.1/src/dapp/ApplicationFactory.sol";
import {DataAvailability} from "cartesi-rollups-contracts-2.1.0-alpha.1/src/common/DataAvailability.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-2.1.0-alpha.1/src/dapp/IApplicationFactory.sol";
import {IApplication} from "cartesi-rollups-contracts-2.1.0-alpha.1/src/dapp/IApplication.sol";
import {IInputBox} from "cartesi-rollups-contracts-2.1.0-alpha.1/src/inputs/IInputBox.sol";
import {InputBox} from "cartesi-rollups-contracts-2.1.0-alpha.1/src/inputs/InputBox.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";
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
    IApplicationFactory _appFactory;
    DaveAppFactory _daveAppFactory;
    IInputBox _inputBox;
    MockTournamentFactory _tournamentFactory;
    Machine.Hash _initialMachineStateHash;

    function setUp() external {
        _inputBox = new InputBox();
        _appFactory = new ApplicationFactory();
        _tournamentFactory = new MockTournamentFactory();
        _daveAppFactory = new DaveAppFactory(_inputBox, _appFactory, _tournamentFactory);
        _initialMachineStateHash = Machine.Hash.wrap(keccak256("foo"));
    }

    function testNewDaveApp(address randomTournamentAddress, bytes32 templateHash, bytes32 salt) external {
        address appContractAddress;
        address daveConsensusAddress;

        // Pre-calculate app and `DaveConsensus` contract addresses
        (appContractAddress, daveConsensusAddress) = _daveAppFactory.calculateDaveAppAddress(templateHash, salt);

        // Deploy app and `DaveConsensus` addresses
        vm.recordLogs();
        _tournamentFactory.setAddress(randomTournamentAddress);
        (IApplication appContract, DaveConsensus daveConsensus) = _daveAppFactory.newDaveApp(templateHash, salt);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Check if addresses match those pre-calculated ones
        assertEq(appContractAddress, address(appContract));
        assertEq(daveConsensusAddress, address(daveConsensus));

        uint256 numOfDaveAppsCreated;
        uint256 numOfAppsCreated;

        // Check logs
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];

            if (entry.emitter == address(_daveAppFactory) && entry.topics[0] == DaveAppFactory.DaveAppCreated.selector)
            {
                ++numOfDaveAppsCreated;
                address[] memory emittedAddresses = new address[](2);
                (emittedAddresses[0], emittedAddresses[1]) = abi.decode(entry.data, (address, address));
                assertEq(emittedAddresses[0], appContractAddress);
                assertEq(emittedAddresses[1], daveConsensusAddress);
            } else if (entry.emitter == daveConsensusAddress && entry.topics[0] == DaveConsensus.EpochSealed.selector) {
                (
                    uint256 epochNumber,
                    uint256 inputIndexLowerBound,
                    uint256 inputIndexUpperBound,
                    bytes32 initialMachineStateHash,
                    bytes32 outputTreeHash,
                    address tournamentAddress
                ) = abi.decode(entry.data, (uint256, uint256, uint256, bytes32, bytes32, address));

                assertEq(epochNumber, 0);
                assertEq(inputIndexLowerBound, 0);
                assertEq(inputIndexUpperBound, 0);
                assertEq(initialMachineStateHash, templateHash);
                assertEq(outputTreeHash, bytes32(0));
                assertEq(tournamentAddress, randomTournamentAddress);
            } else if (
                entry.emitter == address(_appFactory)
                    && entry.topics[0] == IApplicationFactory.ApplicationCreated.selector
            ) {
                ++numOfAppsCreated;
                assertEq(address(uint160(uint256(entry.topics[1]))), address(0));
                (
                    address appOwner,
                    bytes32 templateHashArg,
                    bytes memory dataAvailability,
                    address appContractAddressArg
                ) = abi.decode(entry.data, (address, bytes32, bytes, address));

                assertEq(appOwner, address(_daveAppFactory));
                assertEq(templateHashArg, templateHash);
                assertEq(dataAvailability, abi.encodeCall(DataAvailability.InputBox, _inputBox));
                assertEq(appContractAddressArg, appContractAddress);
            }
        }
        assertEq(numOfDaveAppsCreated, 1);
        assertEq(numOfAppsCreated, 1);

        // Check current sealed epoch
        (uint256 epochNumber, uint256 inputIndexLowerBound, uint256 inputIndexUpperBound, ITournament tournament) =
            daveConsensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 0);
        assertEq(inputIndexLowerBound, 0);
        assertEq(inputIndexUpperBound, 0);
        assertEq(address(tournament), randomTournamentAddress);

        // Check getters
        assertEq(address(daveConsensus.getInputBox()), address(_inputBox));
        assertEq(address(daveConsensus.getApplicationContract()), appContractAddress);
        assertEq(address(daveConsensus.getTournamentFactory()), address(_tournamentFactory));

        // Ensure the address remains the same when recalculated
        (appContractAddress, daveConsensusAddress) = _daveAppFactory.calculateDaveAppAddress(templateHash, salt);
        assertEq(appContractAddress, address(appContract));
        assertEq(daveConsensusAddress, address(daveConsensus));

        // Cannot deploy the same contract twice with the same salt
        vm.expectRevert();
        _daveAppFactory.newDaveApp(templateHash, salt);
    }
}
