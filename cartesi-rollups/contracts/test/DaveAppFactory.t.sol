pragma solidity ^0.8.22;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {Ownable} from "@openzeppelin-contracts-5.2.0/access/Ownable.sol";
import {IERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/IERC165.sol";

import {DataAvailability} from "cartesi-rollups-contracts-3.0.0/src/common/DataAvailability.sol";
import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {ApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/ApplicationFactory.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationChecker.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactory.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {InputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/InputBox.sol";
import {LibBinaryMerkleTree} from "cartesi-rollups-contracts-3.0.0/src/library/LibBinaryMerkleTree.sol";
import {LibBytes} from "cartesi-rollups-contracts-3.0.0/src/library/LibBytes.sol";
import {LibKeccak256} from "cartesi-rollups-contracts-3.0.0/src/library/LibKeccak256.sol";
import {LibWithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/library/LibWithdrawalConfig.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {
    CanonicalTournamentParametersProvider
} from "prt-contracts/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {CartesiStateTransition} from "prt-contracts/state-transition/CartesiStateTransition.sol";
import {CmioStateTransition} from "prt-contracts/state-transition/CmioStateTransition.sol";
import {RiscVStateTransition} from "prt-contracts/state-transition/RiscVStateTransition.sol";
import {Tournament} from "prt-contracts/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {IDaveAppFactory} from "src/IDaveAppFactory.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";

library LibExternalBinaryKeccak256MerkleTree {
    using LibBinaryMerkleTree for bytes32[];

    function merkleRootAfterReplacement(bytes32[] calldata sibs, uint256 nodeIndex, bytes32 node)
        external
        pure
        returns (bytes32)
    {
        return sibs.merkleRootAfterReplacement(nodeIndex, node, LibKeccak256.hashPair);
    }
}

contract DaveAppFactoryTest is Test {
    using LibExternalBinaryKeccak256MerkleTree for bytes32[];
    using LibWithdrawalConfig for WithdrawalConfig;
    using LibBytes for bytes;

    error UnexpectedLogEmitter(Vm.Log log);
    error UnexpectedLogTopic0(Vm.Log log);

    IInputBox _inputBox;
    IApplicationFactory _appFactory;
    IStateTransition _stateTransition;
    ITournamentFactory _tournamentFactory;
    IDaveAppFactory _daveAppFactory;

    Time.Duration constant MATCH_EFFORT = Time.Duration.wrap(5);
    Time.Duration constant MAX_ALLOWANCE = Time.Duration.wrap(120);

    function setUp() external {
        _inputBox = new InputBox();
        _appFactory = new ApplicationFactory();
        _stateTransition = new CartesiStateTransition(new RiscVStateTransition(), new CmioStateTransition());
        _tournamentFactory = new MultiLevelTournamentFactory(
            new Tournament(), new CanonicalTournamentParametersProvider(MATCH_EFFORT, MAX_ALLOWANCE), _stateTransition
        );
        _daveAppFactory = new DaveAppFactory(_inputBox, _appFactory, _tournamentFactory);
    }

    function testNewDaveApp(bytes32 templateHash, WithdrawalConfig calldata withdrawalConfig, bytes32 salt) external {
        _randomizeBlockNumber();

        (address precalculatedAppContractAddress, address precalculatedDaveConsensusAddress) =
            _daveAppFactory.calculateDaveAppAddress(templateHash, withdrawalConfig, salt);

        vm.recordLogs();

        try _daveAppFactory.newDaveApp(templateHash, withdrawalConfig, salt) returns (
            IApplication appContract, IDaveConsensus daveConsensus
        ) {
            Vm.Log[] memory logs = vm.getRecordedLogs();

            assertEq(
                precalculatedAppContractAddress,
                address(appContract),
                "calculateDaveAppAddress(...)[0] != newDaveApp(...)[0]"
            );

            assertEq(
                precalculatedDaveConsensusAddress,
                address(daveConsensus),
                "calculateDaveAppAddress(...)[1] != newDaveApp(...)[1]"
            );

            _testNewDaveAppSuccess(templateHash, withdrawalConfig, appContract, daveConsensus, logs);

            (precalculatedAppContractAddress, precalculatedDaveConsensusAddress) =
                _daveAppFactory.calculateDaveAppAddress(templateHash, withdrawalConfig, salt);

            assertEq(
                precalculatedAppContractAddress,
                address(appContract),
                "calculateDaveAppAddress(...)[0] != newDaveApp(...)[0]"
            );

            assertEq(
                precalculatedDaveConsensusAddress,
                address(daveConsensus),
                "calculateDaveAppAddress(...)[1] != newDaveApp(...)[1]"
            );
        } catch (bytes memory errorData) {
            _testNewDaveAppFailure(withdrawalConfig, errorData);
            return;
        }

        // Cannot deploy an application with the same salt twice
        try _daveAppFactory.newDaveApp(templateHash, withdrawalConfig, salt) {
            revert("second deterministic deployment did not revert");
        } catch (bytes memory errorData) {
            assertEq(
                errorData, new bytes(0), "second deterministic deployment did not revert with empty errorData data"
            );
        }
    }

    function testSettle(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt,
        bytes32 outputsMerkleRoot,
        bytes[] calldata inputPayloads,
        bool foreclose
    ) external {
        _randomizeBlockNumber();

        IApplication appContract;
        IDaveConsensus daveConsensus;

        vm.assumeNoRevert();
        (appContract, daveConsensus) = _daveAppFactory.newDaveApp(templateHash, withdrawalConfig, salt);

        bytes[] memory inputs = new bytes[](inputPayloads.length);

        for (uint256 i; i < inputPayloads.length; ++i) {
            inputs[i] = _addInput(address(appContract), inputPayloads[i]);
        }

        (,,, ITournament tournament) = daveConsensus.getCurrentSealedEpoch();

        bytes32[] memory outputsMerkleRootProof = _randomProof(Memory.LOG2_MAX_SIZE);
        bytes32 machineMerkleRoot = outputsMerkleRootProof.merkleRootAfterReplacement(
            EmulatorConstants.PMA_CMIO_TX_BUFFER_START >> EmulatorConstants.TREE_LOG2_WORD_SIZE,
            keccak256(abi.encode(outputsMerkleRoot))
        );

        bytes32[] memory finalStateProof = _randomProof(tournament.tournamentArguments().commitmentArgs.height);
        (bytes32 leftChild, bytes32 rightChild) = _getCommitmentChildren(machineMerkleRoot, finalStateProof);
        bytes32 commitment = LibKeccak256.hashPair(leftChild, rightChild);

        address submitter = vm.randomAddress();
        uint256 bondValue = tournament.bondValue();
        uint256 callValue = vm.randomUint(bondValue, type(uint256).max);

        vm.deal(submitter, vm.randomUint(callValue, type(uint256).max));

        uint256 balanceBefore = submitter.balance;

        vm.recordLogs();

        vm.startPrank(submitter);
        tournament.joinTournament{value: callValue}(
            Machine.Hash.wrap(machineMerkleRoot), finalStateProof, Tree.Node.wrap(leftChild), Tree.Node.wrap(rightChild)
        );
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 numOfCommitmentJoinedEvents;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(tournament)) {
                if (log.topics[0] == ITournament.CommitmentJoined.selector) {
                    ++numOfCommitmentJoinedEvents;
                    assertEq(log.topics[1], bytes32(uint256(uint160(submitter))));
                    bytes32 arg1;
                    bytes32 arg2;
                    (arg1, arg2) = abi.decode(log.data, (bytes32, bytes32));
                    assertEq(arg1, commitment);
                    assertEq(arg2, machineMerkleRoot);
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else {
                revert UnexpectedLogEmitter(log);
            }
        }

        assertEq(numOfCommitmentJoinedEvents, 1);

        assertFalse(tournament.isFinished());
        assertFalse(tournament.isClosed());

        assertEq(tournament.getNewInnerTournamentCount(), 0);
        assertEq(tournament.getMatchDeletedCount(), 0);
        assertEq(tournament.getMatchAdvancedCount(), 0);
        assertEq(tournament.getMatchCreatedCount(), 0);
        assertEq(tournament.getCommitmentJoinedCount(), 1);

        assertEq(submitter.balance + callValue, balanceBefore, "joinTournament() keeps all Wei");

        // Commitment clock and final state
        {
            Clock.State memory arg1;
            Machine.Hash arg2;
            (arg1, arg2) = tournament.getCommitment(Tree.Node.wrap(commitment));
            assertEq(Time.Duration.unwrap(arg1.allowance), Time.Duration.unwrap(MAX_ALLOWANCE));
            assertEq(Time.Instant.unwrap(arg1.startInstant), 0); // paused clock
            assertEq(Machine.Hash.unwrap(arg2), machineMerkleRoot);
        }

        // Arbitration result
        {
            (bool isFinished,,) = tournament.arbitrationResult();
            assertFalse(isFinished);
        }

        // Check current sealed epoch
        {
            uint256 val1;
            uint256 val2;
            uint256 val3;
            ITournament val4;

            (val1, val2, val3, val4) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            assertEq(address(val4), address(tournament));
        }

        // Check epoch settlement readiness
        {
            bool val1;
            uint256 val2;

            (val1, val2,) = daveConsensus.canSettle();

            assertFalse(val1); // isFinished
            assertEq(val2, 0); // epochNumber
        }

        address settler = vm.randomAddress();

        vm.startPrank(settler);
        vm.expectRevert(IDaveConsensus.TournamentNotFinishedYet.selector);
        daveConsensus.settle(0, outputsMerkleRoot, outputsMerkleRootProof);
        vm.stopPrank();

        vm.roll(vm.randomUint(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE), type(uint64).max));

        assertTrue(tournament.isClosed());
        assertTrue(tournament.isFinished());

        // Arbitration result
        {
            bool val1;
            Tree.Node val2;
            Machine.Hash val3;

            (val1, val2, val3) = tournament.arbitrationResult();
            assertTrue(val1); // isFinished
            assertEq(Tree.Node.unwrap(val2), commitment);
            assertEq(Machine.Hash.unwrap(val3), machineMerkleRoot);
        }

        // Check current sealed epoch
        {
            uint256 val1;
            uint256 val2;
            uint256 val3;
            ITournament val4;

            (val1, val2, val3, val4) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            assertEq(address(val4), address(tournament));
        }

        // Check epoch settlement readiness
        {
            bool val1;
            uint256 val2;
            Tree.Node val3;

            (val1, val2, val3) = daveConsensus.canSettle();

            assertTrue(val1); //  isFinished
            assertEq(val2, 0); // epochNumber
            assertEq(Tree.Node.unwrap(val3), commitment);
        }

        vm.startPrank(settler);
        {
            uint256 incorrectEpochNumber = vm.randomUint(1, type(uint256).max);
            vm.expectRevert(_encodeIncorrectEpochNumber(incorrectEpochNumber, 0));
            daveConsensus.settle(incorrectEpochNumber, outputsMerkleRoot, outputsMerkleRootProof);
        }
        vm.stopPrank();

        if (foreclose) {
            vm.startPrank(appContract.getGuardian());
            appContract.foreclose();
            vm.stopPrank();
        }

        vm.recordLogs();

        vm.startPrank(settler);
        try daveConsensus.settle(0, outputsMerkleRoot, outputsMerkleRootProof) {
            assertFalse(foreclose);
        } catch (bytes memory errorData) {
            (bool isValidError, bytes32 errorSelector,) = errorData.consumeBytes4();
            assertTrue(isValidError, "Expected error to contain a 4-byte selector");
            if (errorSelector == IApplicationChecker.ApplicationForeclosed.selector) {
                assertTrue(foreclose, "Application was foreclosed prior to settlement attempt");
                assertTrue(appContract.isForeclosed(), "Application is indeed foreclosed");
                return; // do not continue test case
            } else {
                revert("Unexpected error");
            }
        }
        vm.stopPrank();

        logs = vm.getRecordedLogs();

        {
            uint256 val1;
            uint256 val2;
            uint256 val3;

            (val1, val2, val3, tournament) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 1); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, inputs.length); // inputIndexUpperBound
        }

        uint256 numOfTournamentCreatedEvents;
        uint256 numOfEpochSealedEvents;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(_tournamentFactory)) {
                if (log.topics[0] == ITournamentFactory.TournamentCreated.selector) {
                    ++numOfTournamentCreatedEvents;
                    address arg1;
                    arg1 = abi.decode(log.data, (address));
                    assertEq(arg1, address(tournament));
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else if (log.emitter == address(daveConsensus)) {
                if (log.topics[0] == IDaveConsensus.EpochSealed.selector) {
                    ++numOfEpochSealedEvents;

                    uint256 arg1;
                    uint256 arg2;
                    uint256 arg3;
                    bytes32 arg4;
                    bytes32 arg5;
                    address arg6;

                    (arg1, arg2, arg3, arg4, arg5, arg6) =
                        abi.decode(log.data, (uint256, uint256, uint256, bytes32, bytes32, address));

                    assertEq(arg1, 1); // epochNumber
                    assertEq(arg2, 0); // inputIndexLowerBound
                    assertEq(arg3, inputs.length); // inputIndexUpperBound
                    assertEq(arg4, machineMerkleRoot); // initialMachineStateHash
                    assertEq(arg5, outputsMerkleRoot);
                    assertEq(arg6, address(tournament));
                }
            } else {
                revert UnexpectedLogEmitter(log);
            }
        }

        assertEq(numOfTournamentCreatedEvents, 1);
        assertEq(numOfEpochSealedEvents, 1);

        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), machineMerkleRoot);
        assertTrue(daveConsensus.isOutputsMerkleRootValid(address(appContract), outputsMerkleRoot));

        for (uint256 i; i < inputs.length; ++i) {
            bytes memory input = inputs[i];
            assertNotEq(daveConsensus.provideMerkleRootOfInput(i, input), bytes32(0));
        }

        {
            uint256 inputIndexWithinBounds = vm.randomUint(inputs.length, type(uint256).max);
            uint256 inputLength = vm.randomUint(0, 100);
            bytes memory input = vm.randomBytes(inputLength);
            assertEq(daveConsensus.provideMerkleRootOfInput(inputIndexWithinBounds, input), bytes32(0));
        }
    }

    function _testNewDaveAppSuccess(
        bytes32 templateHash,
        WithdrawalConfig calldata withdrawalConfig,
        IApplication appContract,
        IDaveConsensus daveConsensus,
        Vm.Log[] memory logs
    ) internal {
        uint256 numOfOwnershipTransferredEvents;
        uint256 numOfApplicationCreatedEvents;
        uint256 numOfConsensusCreationEvents;
        uint256 numOfTournamentCreatedEvents;
        uint256 numOfEpochSealedEvents;
        uint256 numOfOutputsMerkleRootValidatorChangedEvents;
        uint256 numOfDaveAppCreatedEvents;

        ITournament tournament;

        // Check current sealed epoch
        {
            uint256 val1;
            uint256 val2;
            uint256 val3;

            (val1, val2, val3, tournament) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
        }

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(appContract)) {
                if (log.topics[0] == Ownable.OwnershipTransferred.selector) {
                    ++numOfOwnershipTransferredEvents;
                    if (numOfOwnershipTransferredEvents == 1) {
                        assertEq(log.topics[1], bytes32(0)); // previousOwner
                        assertEq(log.topics[2], bytes32(uint256(uint160(address(_daveAppFactory))))); // newOwner
                    } else {
                        assertEq(log.topics[1], bytes32(uint256(uint160(address(_daveAppFactory))))); // previousOwner
                        assertEq(log.topics[2], bytes32(0)); // newOwner
                    }
                } else if (log.topics[0] == IApplication.OutputsMerkleRootValidatorChanged.selector) {
                    ++numOfOutputsMerkleRootValidatorChangedEvents;
                    address arg1 = abi.decode(log.data, (address));
                    assertEq(arg1, address(daveConsensus)); // newOutputsMerkleRootValidator
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else if (log.emitter == address(_appFactory)) {
                if (log.topics[0] == IApplicationFactory.ApplicationCreated.selector) {
                    ++numOfApplicationCreatedEvents;
                    assertEq(log.topics[1], bytes32(0)); // outputsMerkleRootValidator
                    address arg1;
                    bytes32 arg2;
                    bytes memory arg3;
                    WithdrawalConfig memory arg4;
                    address arg5;
                    (arg1, arg2, arg3, arg4, arg5) =
                        abi.decode(log.data, (address, bytes32, bytes, WithdrawalConfig, address));
                    assertEq(arg1, address(_daveAppFactory)); // appOwner
                    assertEq(arg2, templateHash);
                    {
                        (bool isValid, bytes32 selector, bytes memory args) = arg3.consumeBytes4();
                        assertTrue(isValid, "Expected data availability to be valid");
                        assertEq(selector, DataAvailability.InputBox.selector);
                        address inputBoxAddress = abi.decode(args, (address));
                        assertEq(inputBoxAddress, address(_inputBox));
                    }
                    assertEq(abi.encode(arg4), abi.encode(withdrawalConfig));
                    assertEq(arg5, address(appContract));
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else if (log.emitter == address(daveConsensus)) {
                if (log.topics[0] == IDaveConsensus.ConsensusCreation.selector) {
                    ++numOfConsensusCreationEvents;

                    address arg1;
                    address arg2;
                    address arg3;

                    (arg1, arg2, arg3) = abi.decode(log.data, (address, address, address));

                    assertEq(arg1, address(_inputBox));
                    assertEq(arg2, address(appContract));
                    assertEq(arg3, address(_tournamentFactory));
                } else if (log.topics[0] == IDaveConsensus.EpochSealed.selector) {
                    ++numOfEpochSealedEvents;

                    uint256 arg1;
                    uint256 arg2;
                    uint256 arg3;
                    bytes32 arg4;
                    bytes32 arg5;
                    address arg6;

                    (arg1, arg2, arg3, arg4, arg5, arg6) =
                        abi.decode(log.data, (uint256, uint256, uint256, bytes32, bytes32, address));

                    assertEq(arg1, 0); // epochNumber
                    assertEq(arg2, 0); // inputIndexLowerBound
                    assertEq(arg3, 0); // inputIndexUpperBound
                    assertEq(arg4, templateHash); // initialMachineStateHash
                    assertEq(arg5, bytes32(0)); // outputsMerkleRoot
                    assertEq(arg6, address(tournament)); // tournament
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else if (log.emitter == address(_daveAppFactory)) {
                if (log.topics[0] == IDaveAppFactory.DaveAppCreated.selector) {
                    ++numOfDaveAppCreatedEvents;
                    address arg1;
                    address arg2;
                    (arg1, arg2) = abi.decode(log.data, (address, address));
                    assertEq(arg1, address(appContract));
                    assertEq(arg2, address(daveConsensus));
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else if (log.emitter == address(_tournamentFactory)) {
                if (log.topics[0] == ITournamentFactory.TournamentCreated.selector) {
                    ++numOfTournamentCreatedEvents;
                    address arg1;
                    arg1 = abi.decode(log.data, (address));
                    assertEq(arg1, address(tournament));
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else {
                revert UnexpectedLogEmitter(log);
            }
        }

        assertEq(numOfOwnershipTransferredEvents, 2);
        assertEq(numOfApplicationCreatedEvents, 1);
        assertEq(numOfConsensusCreationEvents, 1);
        assertEq(numOfTournamentCreatedEvents, 1);
        assertEq(numOfEpochSealedEvents, 1);
        assertEq(numOfOutputsMerkleRootValidatorChangedEvents, 1);
        assertEq(numOfDaveAppCreatedEvents, 1);

        assertFalse(tournament.isFinished());
        assertFalse(tournament.isClosed());
        assertEq(tournament.getNewInnerTournamentCount(), 0);
        assertEq(tournament.getMatchDeletedCount(), 0);
        assertEq(tournament.getMatchAdvancedCount(), 0);
        assertEq(tournament.getMatchCreatedCount(), 0);
        assertEq(tournament.getCommitmentJoinedCount(), 0);

        // Tournament-level constants
        {
            uint64 levels;
            uint64 level;
            (levels, level,,) = tournament.tournamentLevelConstants();
            assertGe(levels, 1);
            assertEq(level, 0);
        }

        // Tournament-specific arguments
        {
            ITournament.TournamentArguments memory tournamentArgs;
            tournamentArgs = tournament.tournamentArguments();
            assertEq(Machine.Hash.unwrap(tournamentArgs.commitmentArgs.initialHash), templateHash);
            assertEq(tournamentArgs.commitmentArgs.startCycle, 0);
            assertGe(tournamentArgs.levels, 1);
            assertEq(tournamentArgs.level, 0);
            assertEq(Time.Instant.unwrap(tournamentArgs.startInstant), vm.getBlockNumber());
            assertEq(Time.Duration.unwrap(tournamentArgs.allowance), Time.Duration.unwrap(MAX_ALLOWANCE));
            assertEq(Time.Duration.unwrap(tournamentArgs.maxAllowance), Time.Duration.unwrap(MAX_ALLOWANCE));
            assertEq(Time.Duration.unwrap(tournamentArgs.matchEffort), Time.Duration.unwrap(MATCH_EFFORT));
            assertEq(address(tournamentArgs.provider), address(daveConsensus));
            assertEq(address(tournamentArgs.stateTransition), address(_stateTransition));
            assertEq(tournamentArgs.tournamentFactory, address(_tournamentFactory));
        }

        // Arbitration result
        {
            (bool isFinished,,) = tournament.arbitrationResult();
            assertFalse(isFinished);
        }

        // Check epoch settlement readiness
        {
            bool val1;
            uint256 val2;

            (val1, val2,) = daveConsensus.canSettle();

            assertFalse(val1); // isFinished
            assertEq(val2, 0); // epochNumber
        }

        assertEq(address(daveConsensus.getInputBox()), address(_inputBox));
        assertEq(address(daveConsensus.getApplicationContract()), address(appContract));
        assertEq(address(daveConsensus.getTournamentFactory()), address(_tournamentFactory));
        assertEq(daveConsensus.getDeploymentBlockNumber(), vm.getBlockNumber());
        assertTrue(daveConsensus.supportsInterface(type(IERC165).interfaceId));
        assertTrue(daveConsensus.supportsInterface(type(IOutputsMerkleRootValidator).interfaceId));
        assertTrue(daveConsensus.supportsInterface(type(IDataProvider).interfaceId));
        assertFalse(daveConsensus.supportsInterface(0xffffffff));
        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), bytes32(0));
        assertFalse(daveConsensus.isOutputsMerkleRootValid(address(appContract), bytes32(vm.randomUint())));

        address notAppContract;

        while (true) {
            notAppContract = vm.randomAddress();
            if (notAppContract != address(appContract)) {
                break;
            }
        }

        vm.expectRevert(_encodeApplicationMismatch(address(appContract), notAppContract));
        daveConsensus.getLastFinalizedMachineMerkleRoot(notAppContract);

        vm.expectRevert(_encodeApplicationMismatch(address(appContract), notAppContract));
        daveConsensus.isOutputsMerkleRootValid(notAppContract, bytes32(vm.randomUint()));

        bytes4 unsupportedInterfaceId;

        while (true) {
            unsupportedInterfaceId = vm.randomBytes4();
            if (
                unsupportedInterfaceId != type(IERC165).interfaceId
                    && unsupportedInterfaceId != type(IOutputsMerkleRootValidator).interfaceId
                    && unsupportedInterfaceId != type(IDataProvider).interfaceId
            ) {
                break;
            }
        }

        assertFalse(daveConsensus.supportsInterface(unsupportedInterfaceId));

        {
            uint256 inputIndexWithinBounds = vm.randomUint();
            uint256 inputLength = vm.randomUint(0, 100);
            bytes memory input = vm.randomBytes(inputLength);
            assertEq(daveConsensus.provideMerkleRootOfInput(inputIndexWithinBounds, input), bytes32(0));
        }
    }

    function _testNewDaveAppFailure(WithdrawalConfig calldata withdrawalConfig, bytes memory errorData) internal pure {
        (bool isValidError, bytes32 errorSelector, bytes memory errorArgs) = errorData.consumeBytes4();
        assertTrue(isValidError, "Expected error to contain a 4-byte selector");
        if (errorSelector == bytes4(keccak256("Error(string)"))) {
            string memory errorMsg = abi.decode(errorArgs, (string));
            bytes32 errorMsgHash = keccak256(bytes(errorMsg));
            if (errorMsgHash == keccak256("Invalid withdrawal config")) {
                assertFalse(withdrawalConfig.isValid(), "Expected withdrawal config to be invalid");
            } else {
                revert("Unexpected error message");
            }
        } else {
            revert("Unexpected error");
        }
    }

    function _randomizeBlockNumber() internal {
        // We limit the block number by type(uint64).max because the PRT contracts
        // use block numbers for time-keeping, and stores them as uint64 values.
        // We also give some slack (the maximum tournament allowance) so we can
        // fast-forward to a block in which the tournament is closed.
        vm.roll(vm.randomUint(vm.getBlockNumber(), type(uint64).max - Time.Duration.unwrap(MAX_ALLOWANCE)));
    }

    function _randomProof(uint256 n) internal returns (bytes32[] memory proof) {
        proof = new bytes32[](n);
        for (uint256 i; i < proof.length; ++i) {
            proof[i] = bytes32(vm.randomUint());
        }
    }

    function _getCommitmentChildren(bytes32 machineMerkleRoot, bytes32[] memory proof)
        internal
        pure
        returns (bytes32 leftChild, bytes32 rightChild)
    {
        leftChild = proof[proof.length - 1];

        rightChild = machineMerkleRoot;
        for (uint256 i; i < proof.length - 1; ++i) {
            rightChild = LibKeccak256.hashPair(proof[i], rightChild);
        }
    }

    function _addInput(address appContract, bytes memory payload) internal returns (bytes memory input) {
        uint256 index = _inputBox.getNumberOfInputs(appContract);

        vm.recordLogs();

        _inputBox.addInput(appContract, payload);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(logs.length, 1, "No logs emitted on addInput()");

        Vm.Log memory log = logs[0];

        if (log.emitter == address(_inputBox)) {
            if (log.topics[0] == IInputBox.InputAdded.selector) {
                assertEq(log.topics[1], bytes32(uint256(uint160(appContract))));
                assertEq(log.topics[2], bytes32(index));
                return abi.decode(log.data, (bytes));
            } else {
                revert UnexpectedLogTopic0(log);
            }
        } else {
            revert UnexpectedLogEmitter(log);
        }
    }

    function _encodeApplicationMismatch(address expected, address obtained)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(IDaveConsensus.ApplicationMismatch.selector, expected, obtained);
    }

    function _encodeIncorrectEpochNumber(uint256 received, uint256 actual)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, received, actual);
    }
}
