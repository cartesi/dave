pragma solidity ^0.8.30;

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
import {IApplicationFactoryErrors} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactoryErrors.sol";
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
import {DaveConsensus} from "src/DaveConsensus.sol";
import {IDaveAppFactory} from "src/IDaveAppFactory.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";
import {ISentryErrors} from "src/ISentryErrors.sol";

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

contract SettlementApplication {
    function isForeclosed() external pure returns (bool) {
        return false;
    }
}

contract SettlementCallbackReceiver {
    bool public exhaustsGas = true;

    function acceptPayments() external {
        exhaustsGas = false;
    }

    receive() external payable {
        if (exhaustsGas) {
            assembly ("memory-safe") {
                for {} 1 {} { pop(keccak256(0, 0)) }
            }
        }
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

    Time.Duration constant RESPONSE_BUDGET = Time.Duration.wrap(5);
    Time.Duration constant MAX_ALLOWANCE = Time.Duration.wrap(120);
    uint256 constant STAGING_GAS_CEILING = 500_000;

    function setUp() external {
        _inputBox = new InputBox();
        _appFactory = new ApplicationFactory();
        _stateTransition = new CartesiStateTransition(new RiscVStateTransition(), new CmioStateTransition());
        _tournamentFactory = new MultiLevelTournamentFactory(
            new Tournament(),
            new CanonicalTournamentParametersProvider(RESPONSE_BUDGET, MAX_ALLOWANCE),
            _stateTransition
        );
        _daveAppFactory = new DaveAppFactory(_inputBox, _appFactory, _tournamentFactory);
    }

    function testNewDaveApp(
        bytes32 templateHash,
        uint64 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) external {
        _randomizeBlockNumber(claimStagingPeriod);

        (address precalculatedAppContractAddress, address precalculatedDaveConsensusAddress) = _daveAppFactory.calculateDaveAppAddress(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        );

        vm.recordLogs();

        try _daveAppFactory.newDaveApp(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        ) returns (
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

            _testNewDaveAppSuccess(
                templateHash,
                claimStagingPeriod,
                sentryManager,
                sentries,
                withdrawalConfig,
                appContract,
                daveConsensus,
                logs
            );

            (precalculatedAppContractAddress, precalculatedDaveConsensusAddress) =
                _daveAppFactory.calculateDaveAppAddress(
                    templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
                );

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
            _testNewDaveAppFailure(sentries, withdrawalConfig, errorData);
            return;
        }

        // Cannot deploy an application with the same salt twice
        try _daveAppFactory.newDaveApp(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        ) {
            revert("second deterministic deployment did not revert");
        } catch (bytes memory errorData) {
            assertEq(
                errorData, new bytes(0), "second deterministic deployment did not revert with empty errorData data"
            );
        }
    }

    function testStageAndAcceptTournamentResult(
        bytes32 templateHash,
        uint64 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt,
        bytes32 outputsMerkleRoot,
        bytes[] calldata inputPayloads,
        bool recoverBeforeStaging
    ) external {
        _randomizeBlockNumber(claimStagingPeriod);

        IApplication appContract;
        IDaveConsensus daveConsensus;

        vm.assumeNoRevert();
        (appContract, daveConsensus) = _daveAppFactory.newDaveApp(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        );

        bytes[] memory inputs = new bytes[](inputPayloads.length);

        for (uint256 i; i < inputPayloads.length; ++i) {
            inputs[i] = _addInput(address(appContract), inputPayloads[i]);
        }

        (,,, ITournament tournament,,,,) = daveConsensus.getCurrentSealedEpoch();

        bytes32[] memory outputsMerkleRootProof = _randomProof(Memory.LOG2_MAX_SIZE);
        bytes32 machineMerkleRoot = outputsMerkleRootProof.merkleRootAfterReplacement(
            EmulatorConstants.AR_CMIO_TX_BUFFER_START >> EmulatorConstants.HASH_TREE_LOG2_WORD_SIZE,
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
            bool val5;

            (val1, val2, val3, val4, val5,,,) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            assertEq(address(val4), address(tournament));
            assertFalse(val5); // isTournamentResultStaged
        }

        // Check epoch staging readiness
        {
            bool val1;
            bool val2;
            uint256 val3;

            (val1, val2, val3,,) = daveConsensus.canStageTournamentResult();

            assertFalse(val1); // isFinished
            assertFalse(val2); // isTournamentResultStaged
            assertEq(val3, 0); // epochNumber
        }

        // Check epoch acceptance readiness
        {
            bool val1;
            uint256 val2;

            (val1,,, val2,,) = daveConsensus.canAcceptStagedTournamentResult();

            assertFalse(val1); // isTournamentResultStaged
            assertEq(val2, 0); // epochNumber
        }

        vm.expectRevert(IDaveConsensus.TournamentNotFinishedYet.selector);
        vm.prank(vm.randomAddress());
        daveConsensus.stageTournamentResult(0, outputsMerkleRoot, outputsMerkleRootProof);

        uint64 maxBlockNumber = type(uint64).max - claimStagingPeriod;
        vm.roll(vm.randomUint(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE), maxBlockNumber));

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
            bool val5;

            (val1, val2, val3, val4, val5,,,) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            assertEq(address(val4), address(tournament));
            assertFalse(val5); // isTournamentResultStaged
        }

        // Check epoch staging readiness
        {
            bool val1;
            bool val2;
            uint256 val3;
            Tree.Node val4;
            Machine.Hash val5;

            (val1, val2, val3, val4, val5) = daveConsensus.canStageTournamentResult();

            assertTrue(val1); //  isFinished
            assertFalse(val2); // isTournamentResultStaged
            assertEq(val3, 0); // epochNumber
            assertEq(Tree.Node.unwrap(val4), commitment);
            assertEq(Machine.Hash.unwrap(val5), machineMerkleRoot);
        }

        // Check epoch acceptance readiness
        {
            bool val1;
            uint256 val2;

            (val1,,, val2,,) = daveConsensus.canAcceptStagedTournamentResult();

            assertFalse(val1); // isTournamentResultStaged
            assertEq(val2, 0); // epochNumber
        }

        // Try staging tournament result with an invalid epoch number
        {
            uint256 incorrectEpochNumber = vm.randomUint(1, type(uint256).max);
            vm.expectRevert(_encodeIncorrectEpochNumber(incorrectEpochNumber, 0));
            vm.prank(vm.randomAddress());
            daveConsensus.stageTournamentResult(incorrectEpochNumber, outputsMerkleRoot, outputsMerkleRootProof);
        }

        // Try staging tournament result with invalid outputs Merkle root proof size
        while (true) {
            uint256 invalidProofSize = vm.randomUint(0, 2 * outputsMerkleRootProof.length + 1);
            if (invalidProofSize != outputsMerkleRootProof.length) {
                bytes32[] memory invalidOutputsMerkleRootProof = _randomProof(invalidProofSize);
                vm.expectRevert(_encodeInvalidOutputsMerkleRootProofSize(invalidProofSize));
                vm.prank(vm.randomAddress());
                daveConsensus.stageTournamentResult(0, outputsMerkleRoot, invalidOutputsMerkleRootProof);
                break;
            }
        }

        // Try staging tournament result with invalid outputs Merkle root
        while (true) {
            bytes32 invalidOutputsMerkleRoot = bytes32(vm.randomUint());
            if (invalidOutputsMerkleRoot != outputsMerkleRoot) {
                vm.expectRevert(_encodeInvalidOutputsMerkleRootProof(machineMerkleRoot));
                vm.prank(vm.randomAddress());
                daveConsensus.stageTournamentResult(0, invalidOutputsMerkleRoot, outputsMerkleRootProof);
                break;
            }
        }

        vm.expectRevert(_encodeApplicationForeclosed(address(appContract)));
        this.simulateForeclosureAndStaging(appContract, daveConsensus, 0, outputsMerkleRoot, outputsMerkleRootProof);

        uint256 burnedBalanceBefore = address(0).balance;

        if (recoverBeforeStaging) {
            assertTrue(tournament.tryRecoveringBond());
        }

        uint256 stagingBlockNumber = vm.getBlockNumber();

        vm.recordLogs();

        vm.prank(vm.randomAddress());
        daveConsensus.stageTournamentResult(0, outputsMerkleRoot, outputsMerkleRootProof);

        assertEq(address(tournament).balance, 0);
        assertEq(submitter.balance, balanceBefore - callValue + bondValue);
        assertEq(address(0).balance, burnedBalanceBefore + callValue - bondValue);

        logs = vm.getRecordedLogs();

        uint256 numOfEpochStagedEvents;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(daveConsensus)) {
                if (log.topics[0] == IDaveConsensus.EpochStaged.selector) {
                    ++numOfEpochStagedEvents;

                    assertEq(log.topics[1], bytes32(0)); // epochNumber

                    bytes32 arg1;
                    bytes32 arg2;

                    (arg1, arg2) = abi.decode(log.data, (bytes32, bytes32));

                    assertEq(arg1, machineMerkleRoot); // stagedPostEpochMachineStateHash
                    assertEq(arg2, outputsMerkleRoot); // stagedPostEpochOutputsMerkleRoot
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else {
                revert UnexpectedLogEmitter(log);
            }
        }

        assertEq(numOfEpochStagedEvents, 1);

        // Check current sealed epoch
        {
            uint256 val1;
            uint256 val2;
            uint256 val3;
            ITournament val4;
            bool val5;
            uint256 val6;
            Machine.Hash val7;
            bytes32 val8;

            (val1, val2, val3, val4, val5, val6, val7, val8) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            assertEq(address(val4), address(tournament));
            assertTrue(val5); // isTournamentResultStaged
            assertEq(val6, stagingBlockNumber);
            assertEq(Machine.Hash.unwrap(val7), machineMerkleRoot);
            assertEq(val8, outputsMerkleRoot);
        }

        // Check epoch staging readiness
        {
            bool val1;
            bool val2;
            uint256 val3;
            Tree.Node val4;
            Machine.Hash val5;

            (val1, val2, val3, val4, val5) = daveConsensus.canStageTournamentResult();

            assertTrue(val1); //  isFinished
            assertTrue(val2); // isTournamentResultStaged
            assertEq(val3, 0); // epochNumber
            assertEq(Tree.Node.unwrap(val4), commitment);
            assertEq(Machine.Hash.unwrap(val5), machineMerkleRoot);
        }

        // Check epoch acceptance readiness
        {
            bool val1;
            bool val2;
            bool val3;
            uint256 val4;
            Machine.Hash val5;
            bytes32 val6;

            (val1, val2, val3, val4, val5, val6) = daveConsensus.canAcceptStagedTournamentResult();

            assertTrue(val1); // isTournamentResultStaged
            assertFalse(val2); // doAllSentriesAgreeWithStagedTournamentResult
            assertEq(val3, claimStagingPeriod == 0); // isClaimStagingPeriodOver
            assertEq(val4, 0); // epochNumber
            assertEq(Machine.Hash.unwrap(val5), machineMerkleRoot);
            assertEq(val6, outputsMerkleRoot);
        }

        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), bytes32(0));
        assertFalse(daveConsensus.isOutputsMerkleRootValid(address(appContract), outputsMerkleRoot));

        // Try re-staging tournament result
        vm.expectRevert(IDaveConsensus.TournamentResultAlreadyStaged.selector);
        vm.prank(vm.randomAddress());
        daveConsensus.stageTournamentResult(0, outputsMerkleRoot, outputsMerkleRootProof);

        // Try accepting tournament result before claim staging period is over
        if (claimStagingPeriod >= 1) {
            uint256 numberOfBlocksAfterStaging = vm.randomUint(0, claimStagingPeriod - 1);
            vm.roll(stagingBlockNumber + numberOfBlocksAfterStaging);
            vm.expectRevert(_encodeClaimStagingPeriodNotOverYet(numberOfBlocksAfterStaging, claimStagingPeriod));
            vm.prank(vm.randomAddress());
            daveConsensus.acceptStagedTournamentResult(0);
        }

        // If there is at least one sentry, at random decide to submit sentry claims
        // corroborating with the staged tournament result
        uint256 numOfSentries = daveConsensus.getNumberOfSentries();
        uint256[] memory sentryIds = _getShuffledSentryIds(numOfSentries);
        uint256 numOfClaims = vm.randomUint(0, numOfSentries);
        bool doAllSentriesAgreeWithStagedTournamentResult = (numOfSentries > 0) && (numOfClaims == numOfSentries);
        for (uint256 i; i < numOfClaims; ++i) {
            _submitSentryClaim(appContract, daveConsensus, 0, sentryIds[i], Machine.Hash.wrap(machineMerkleRoot));
            _attemptSentryClaimResubmission(daveConsensus, 0, sentryIds[vm.randomUint(0, i)]);
        }

        vm.roll(vm.randomUint(stagingBlockNumber + claimStagingPeriod, type(uint64).max));

        // Check current sealed epoch
        {
            uint256 val1;
            uint256 val2;
            uint256 val3;
            ITournament val4;
            bool val5;
            uint256 val6;
            Machine.Hash val7;
            bytes32 val8;

            (val1, val2, val3, val4, val5, val6, val7, val8) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            assertEq(address(val4), address(tournament));
            assertTrue(val5); // isTournamentResultStaged
            assertEq(val6, stagingBlockNumber);
            assertEq(Machine.Hash.unwrap(val7), machineMerkleRoot);
            assertEq(val8, outputsMerkleRoot);
        }

        // Check epoch staging readiness
        {
            bool val1;
            bool val2;
            uint256 val3;
            Tree.Node val4;
            Machine.Hash val5;

            (val1, val2, val3, val4, val5) = daveConsensus.canStageTournamentResult();

            assertTrue(val1); //  isFinished
            assertTrue(val2); // isTournamentResultStaged
            assertEq(val3, 0); // epochNumber
            assertEq(Tree.Node.unwrap(val4), commitment);
            assertEq(Machine.Hash.unwrap(val5), machineMerkleRoot);
        }

        // Check epoch acceptance readiness
        {
            bool val1;
            bool val2;
            bool val3;
            uint256 val4;
            Machine.Hash val5;
            bytes32 val6;

            (val1, val2, val3, val4, val5, val6) = daveConsensus.canAcceptStagedTournamentResult();

            assertTrue(val1); // isTournamentResultStaged
            assertEq(val2, doAllSentriesAgreeWithStagedTournamentResult);
            assertTrue(val3); // isClaimStagingPeriodOver
            assertEq(val4, 0); // epochNumber
            assertEq(Machine.Hash.unwrap(val5), machineMerkleRoot);
            assertEq(val6, outputsMerkleRoot);
        }

        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), bytes32(0));
        assertFalse(daveConsensus.isOutputsMerkleRootValid(address(appContract), outputsMerkleRoot));

        vm.expectRevert(_encodeApplicationForeclosed(address(appContract)));
        this.simulateForeclosureAndAcceptance(appContract, daveConsensus, 0);

        vm.recordLogs();

        vm.prank(vm.randomAddress());
        daveConsensus.acceptStagedTournamentResult(0);

        logs = vm.getRecordedLogs();

        // Check current sealed epoch
        {
            uint256 val1;
            uint256 val2;
            uint256 val3;
            ITournament val4;
            bool val5;

            (val1, val2, val3, val4, val5,,,) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 1); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, inputs.length); // inputIndexUpperBound
            tournament = val4;
            assertFalse(val5); // isTournamentResultStaged
        }

        // Arbitration result
        {
            (bool isFinished,,) = tournament.arbitrationResult();
            assertFalse(isFinished);
        }

        // Check epoch staging readiness
        {
            bool val1;
            bool val2;
            uint256 val3;

            (val1, val2, val3,,) = daveConsensus.canStageTournamentResult();

            assertFalse(val1); // isFinished
            assertFalse(val2); // isTournamentResultStaged
            assertEq(val3, 1); // epochNumber
        }

        // Check epoch acceptance readiness
        {
            bool val1;
            uint256 val2;

            (val1,,, val2,,) = daveConsensus.canAcceptStagedTournamentResult();

            assertFalse(val1); // isTournamentResultStaged
            assertEq(val2, 1); // epochNumber
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

                    assertEq(log.topics[1], bytes32(uint256(1))); // epochNumber

                    uint256 arg1;
                    uint256 arg2;
                    bytes32 arg3;
                    bytes32 arg4;
                    address arg5;

                    (arg1, arg2, arg3, arg4, arg5) = abi.decode(log.data, (uint256, uint256, bytes32, bytes32, address));

                    assertEq(arg1, 0); // inputIndexLowerBound
                    assertEq(arg2, inputs.length); // inputIndexUpperBound
                    assertEq(arg3, machineMerkleRoot); // initialMachineStateHash
                    assertEq(arg4, outputsMerkleRoot);
                    assertEq(arg5, address(tournament));
                } else {
                    revert UnexpectedLogTopic0(log);
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
            uint256 inputIndexOutOfBounds = vm.randomUint(inputs.length, type(uint256).max);
            uint256 inputLength = vm.randomUint(0, 100);
            bytes memory input = vm.randomBytes(inputLength);
            assertEq(daveConsensus.provideMerkleRootOfInput(inputIndexOutOfBounds, input), bytes32(0));
        }
    }

    function testRotateSentry(
        bytes32 templateHash,
        uint64 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) external {
        IApplication appContract;
        IDaveConsensus daveConsensus;

        vm.assumeNoRevert();
        (appContract, daveConsensus) = _daveAppFactory.newDaveApp(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        );

        uint256 numOfSentries = daveConsensus.getNumberOfSentries();
        uint256 numOfRounds = 16;

        for (uint256 round; round < numOfRounds; ++round) {
            address nonSentryManager = _randomAddressNotEq(sentryManager);

            vm.prank(nonSentryManager);
            vm.expectRevert(_encodeCallerIsNotSentryManager(nonSentryManager));
            daveConsensus.rotateSentry(vm.randomAddress(), vm.randomAddress());

            vm.expectRevert(_encodeApplicationForeclosed(address(appContract)));
            this.simulateForeclosureAndRotation(appContract, daveConsensus, vm.randomAddress(), vm.randomAddress());

            address nonSentry = _randomNonSentry(daveConsensus);

            vm.prank(sentryManager);
            vm.expectRevert(_encodeCannotRotateNonSentry(nonSentry));
            daveConsensus.rotateSentry(nonSentry, vm.randomAddress());

            if (numOfSentries >= 1) {
                uint256 sentryId = vm.randomUint(1, numOfSentries);
                address sentry = daveConsensus.getSentryById(sentryId);
                assertEq(daveConsensus.getSentryId(sentry), sentryId);

                uint256 anotherSentryId = vm.randomUint(1, numOfSentries);
                address anotherSentry = daveConsensus.getSentryById(anotherSentryId);
                assertEq(daveConsensus.getSentryId(anotherSentry), anotherSentryId);

                vm.prank(sentryManager);
                vm.expectRevert(_encodeDuplicatedSentryAddress(anotherSentryId, anotherSentry));
                daveConsensus.rotateSentry(sentry, anotherSentry);

                vm.prank(sentryManager);
                vm.expectRevert(ISentryErrors.ZeroSentryAddress.selector);
                daveConsensus.rotateSentry(sentry, address(0));

                address[] memory sentriesBefore = _getSentries(daveConsensus);
                assertEq(sentriesBefore.length, numOfSentries);

                address newSentry = _randomValidNonSentry(daveConsensus);

                vm.recordLogs();

                vm.prank(sentryManager);
                daveConsensus.rotateSentry(sentry, newSentry);

                Vm.Log[] memory logs = vm.getRecordedLogs();
                uint256 numOfSentryRotationEvents;
                for (uint256 i; i < logs.length; ++i) {
                    Vm.Log memory log = logs[i];
                    if (log.emitter == address(daveConsensus)) {
                        assertGe(log.topics.length, 1);
                        bytes32 topic0 = log.topics[0];
                        if (topic0 == IDaveConsensus.SentryRotation.selector) {
                            assertEq(log.topics.length, 4);
                            assertEq(log.topics[1], bytes32(sentryId));
                            assertEq(log.topics[2], bytes32(uint256(uint160(sentry))));
                            assertEq(log.topics[3], bytes32(uint256(uint160(newSentry))));
                            assertEq(log.data, abi.encode());
                            ++numOfSentryRotationEvents;
                        } else {
                            revert UnexpectedLogTopic0(log);
                        }
                    } else {
                        revert UnexpectedLogEmitter(log);
                    }
                }
                assertEq(numOfSentryRotationEvents, 1);

                assertEq(daveConsensus.getSentryId(sentry), 0);
                assertEq(daveConsensus.getSentryId(newSentry), sentryId);
                assertEq(daveConsensus.getSentryById(sentryId), newSentry);

                address[] memory sentriesAfter = _getSentries(daveConsensus);
                assertEq(sentriesBefore.length, sentriesAfter.length);

                for (uint256 i; i < sentriesAfter.length; ++i) {
                    if (sentryId == (i + 1)) {
                        assertEq(sentriesBefore[i], sentry);
                        assertEq(sentriesAfter[i], newSentry);
                    } else {
                        assertEq(sentriesBefore[i], sentriesAfter[i]);
                    }
                }
            }
        }
    }

    /// @notice This function is used to simulate a foreclosure and a tournament-result staging.
    /// If the staging succeeds, then the function reverts with error message "Successful staging".
    /// If the staging fails, then the function propagates the error from the DaveConsensus contract.
    function simulateForeclosureAndStaging(
        IApplication appContract,
        IDaveConsensus daveConsensus,
        uint256 epochNumber,
        bytes32 outputsMerkleRoot,
        bytes32[] calldata proof
    ) external {
        vm.prank(appContract.getGuardian());
        appContract.foreclose();
        vm.prank(vm.randomAddress());
        daveConsensus.stageTournamentResult(epochNumber, outputsMerkleRoot, proof);
        revert("Successful staging");
    }

    /// @notice This function is used to simulate a foreclosure and a sentry claim.
    /// If the claim succeeds, then the function reverts with error message "Successful claim".
    /// If the claim fails, then the function propagates the error from the DaveConsensus contract.
    function simulateForeclosureAndSentryClaim(
        IApplication appContract,
        IDaveConsensus daveConsensus,
        uint256 epochNumber,
        address sentry,
        Machine.Hash postEpochMachineStateHash
    ) external {
        vm.prank(appContract.getGuardian());
        appContract.foreclose();
        vm.prank(sentry);
        daveConsensus.submitSentryClaim(epochNumber, postEpochMachineStateHash);
        revert("Successful claim");
    }

    /// @notice This function is used to simulate a foreclosure and a sentry rotation.
    /// If the rotation succeeds, then the function reverts with error message "Successful rotation".
    /// If the rotation fails, then the function propagates the error from the DaveConsensus contract.
    function simulateForeclosureAndRotation(
        IApplication appContract,
        IDaveConsensus daveConsensus,
        address currentSentry,
        address newSentry
    ) external {
        vm.prank(appContract.getGuardian());
        appContract.foreclose();
        vm.prank(daveConsensus.getSentryManager());
        daveConsensus.rotateSentry(currentSentry, newSentry);
        revert("Successful rotation");
    }

    /// @notice This function is used to simulate a foreclosure and a tournament-result acceptance.
    /// If the acceptance succeeds, then the function reverts with error message "Successful acceptance".
    /// If the acceptance fails, then the function propagates the error from the DaveConsensus contract.
    function simulateForeclosureAndAcceptance(
        IApplication appContract,
        IDaveConsensus daveConsensus,
        uint256 epochNumber
    ) external {
        vm.prank(appContract.getGuardian());
        appContract.foreclose();
        vm.prank(vm.randomAddress());
        daveConsensus.acceptStagedTournamentResult(epochNumber);
        revert("Successful acceptance");
    }

    function testStageAndAcceptAdvanceWhenWinnerExhaustsPaymentCallback() external {
        _randomizeBlockNumber(0);

        SettlementApplication appContract = new SettlementApplication();
        address[] memory sentries = new address[](0);
        IDaveConsensus daveConsensus = new DaveConsensus(
            _inputBox,
            address(appContract),
            _tournamentFactory,
            Machine.Hash.wrap(bytes32(uint256(1))),
            0,
            address(0),
            sentries
        );
        (,,, ITournament tournament,,,,) = daveConsensus.getCurrentSealedEpoch();

        bytes32 outputsMerkleRoot = bytes32(uint256(2));
        bytes32[] memory outputsMerkleRootProof = _randomProof(Memory.LOG2_MAX_SIZE);
        bytes32 machineMerkleRoot = outputsMerkleRootProof.merkleRootAfterReplacement(
            EmulatorConstants.AR_CMIO_TX_BUFFER_START >> EmulatorConstants.HASH_TREE_LOG2_WORD_SIZE,
            keccak256(abi.encode(outputsMerkleRoot))
        );

        bytes32[] memory finalStateProof = _randomProof(tournament.tournamentArguments().commitmentArgs.height);
        (bytes32 leftChild, bytes32 rightChild) = _getCommitmentChildren(machineMerkleRoot, finalStateProof);
        SettlementCallbackReceiver receiver = new SettlementCallbackReceiver();
        uint256 bond = tournament.bondValue();
        vm.deal(address(receiver), bond);
        vm.prank(address(receiver));
        tournament.joinTournament{value: bond}(
            Machine.Hash.wrap(machineMerkleRoot), finalStateProof, Tree.Node.wrap(leftChild), Tree.Node.wrap(rightChild)
        );

        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));
        assertTrue(tournament.isFinished());

        uint256 gasBefore = gasleft();
        daveConsensus.stageTournamentResult(0, outputsMerkleRoot, outputsMerkleRootProof);
        uint256 stagingGasUsed = gasBefore - gasleft();
        assertLt(stagingGasUsed, STAGING_GAS_CEILING);

        (
            uint256 stagedEpochNumber,,,
            ITournament stagedTournament,
            bool isTournamentResultStaged,,
            Machine.Hash stagedMachineStateHash,
            bytes32 stagedOutputsMerkleRoot
        ) = daveConsensus.getCurrentSealedEpoch();
        assertEq(stagedEpochNumber, 0);
        assertEq(address(stagedTournament), address(tournament));
        assertTrue(isTournamentResultStaged);
        assertEq(Machine.Hash.unwrap(stagedMachineStateHash), machineMerkleRoot);
        assertEq(stagedOutputsMerkleRoot, outputsMerkleRoot);
        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), bytes32(0));
        assertFalse(daveConsensus.isOutputsMerkleRootValid(address(appContract), outputsMerkleRoot));
        assertEq(address(receiver).balance, 0);
        assertEq(address(tournament).balance, bond);

        daveConsensus.acceptStagedTournamentResult(0);

        (uint256 nextEpochNumber,,, ITournament nextTournament,,,,) = daveConsensus.getCurrentSealedEpoch();
        assertEq(nextEpochNumber, 1);
        assertNotEq(address(nextTournament), address(tournament));
        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), machineMerkleRoot);
        assertTrue(daveConsensus.isOutputsMerkleRootValid(address(appContract), outputsMerkleRoot));

        receiver.acceptPayments();
        assertTrue(tournament.tryRecoveringBond());
        assertEq(address(receiver).balance, bond);
        assertEq(address(tournament).balance, 0);
    }

    function _testNewDaveAppSuccess(
        bytes32 templateHash,
        uint64 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
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
            ITournament val4;
            bool val5;
            uint256 val6;
            Machine.Hash val7;
            bytes32 val8;

            (val1, val2, val3, val4, val5, val6, val7, val8) = daveConsensus.getCurrentSealedEpoch();

            assertEq(val1, 0); // epochNumber
            assertEq(val2, 0); // inputIndexLowerBound
            assertEq(val3, 0); // inputIndexUpperBound
            tournament = val4;
            assertFalse(val5); // isTournamentResultStaged
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

                    assertEq(log.topics[1], bytes32(0)); // epochNumber

                    uint256 arg1;
                    uint256 arg2;
                    bytes32 arg3;
                    bytes32 arg4;
                    address arg5;

                    (arg1, arg2, arg3, arg4, arg5) = abi.decode(log.data, (uint256, uint256, bytes32, bytes32, address));

                    assertEq(arg1, 0); // inputIndexLowerBound
                    assertEq(arg2, 0); // inputIndexUpperBound
                    assertEq(arg3, templateHash); // initialMachineStateHash
                    assertEq(arg4, bytes32(0)); // outputsMerkleRoot
                    assertEq(arg5, address(tournament)); // tournament
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
            assertEq(Time.Duration.unwrap(tournamentArgs.responseBudget), Time.Duration.unwrap(RESPONSE_BUDGET));
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
            bool val2;
            uint256 val3;

            (val1, val2, val3,,) = daveConsensus.canStageTournamentResult();

            assertFalse(val1); // isFinished
            assertFalse(val2); // isTournamentResultStaged
            assertEq(val3, 0); // epochNumber
        }

        assertEq(address(daveConsensus.getInputBox()), address(_inputBox));
        assertEq(address(daveConsensus.getApplicationContract()), address(appContract));
        assertEq(address(daveConsensus.getTournamentFactory()), address(_tournamentFactory));
        assertEq(daveConsensus.getClaimStagingPeriod(), claimStagingPeriod);
        assertEq(daveConsensus.getSentryManager(), sentryManager);
        assertEq(_getSentries(daveConsensus), sentries);
        assertEq(daveConsensus.getDeploymentBlockNumber(), vm.getBlockNumber());
        assertTrue(daveConsensus.supportsInterface(type(IERC165).interfaceId));
        assertTrue(daveConsensus.supportsInterface(type(IDaveConsensus).interfaceId));
        assertTrue(daveConsensus.supportsInterface(type(IOutputsMerkleRootValidator).interfaceId));
        assertTrue(daveConsensus.supportsInterface(type(IDataProvider).interfaceId));
        assertFalse(daveConsensus.supportsInterface(0xffffffff));
        assertEq(daveConsensus.getLastFinalizedMachineMerkleRoot(address(appContract)), bytes32(0));
        assertFalse(daveConsensus.isOutputsMerkleRootValid(address(appContract), bytes32(vm.randomUint())));

        address notAppContract = _randomAddressNotEq(address(appContract));

        vm.expectRevert(_encodeApplicationMismatch(address(appContract), notAppContract));
        daveConsensus.getLastFinalizedMachineMerkleRoot(notAppContract);

        vm.expectRevert(_encodeApplicationMismatch(address(appContract), notAppContract));
        daveConsensus.isOutputsMerkleRootValid(notAppContract, bytes32(vm.randomUint()));

        bytes4 unsupportedInterfaceId;

        while (true) {
            unsupportedInterfaceId = vm.randomBytes4();
            if (
                unsupportedInterfaceId != type(IERC165).interfaceId
                    && unsupportedInterfaceId != type(IDaveConsensus).interfaceId
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

        assertEq(daveConsensus.getSentryId(address(0)), 0);
        assertEq(daveConsensus.getSentryId(_randomAddressNotIn(sentries)), 0);
        assertEq(daveConsensus.getSentryById(0), address(0));
        assertEq(daveConsensus.getSentryById(vm.randomUint(sentries.length + 1, type(uint256).max)), address(0));
        assertFalse(daveConsensus.hasSentryClaimedInEpoch(vm.randomUint(), vm.randomUint()));
        assertEq(daveConsensus.getSentryClaimCount(vm.randomUint(), Machine.Hash.wrap(bytes32(vm.randomUint()))), 0);
    }

    function _testNewDaveAppFailure(
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes memory errorData
    ) internal pure {
        (bool isValidError, bytes32 errorSelector, bytes memory errorArgs) = errorData.consumeBytes4();
        assertTrue(isValidError, "Expected error to contain a 4-byte selector");
        if (errorSelector == IApplicationFactoryErrors.InvalidWithdrawalConfig.selector) {
            assertEq(errorArgs, abi.encode(withdrawalConfig), "Expected withdrawal configs to match");
            assertFalse(withdrawalConfig.isValid(), "Expected withdrawal config to be invalid");
        } else if (errorSelector == ISentryErrors.ZeroSentryAddress.selector) {
            assertEq(errorArgs, abi.encode());
            assertTrue(_contains(sentries, address(0)), "Expected sentries array to have the zero address");
        } else if (errorSelector == ISentryErrors.DuplicatedSentryAddress.selector) {
            (uint256 sentryId, address sentry) = abi.decode(errorArgs, (uint256, address));
            assertGe(sentryId, 1, "Expected sentry ID >= 1");
            assertLe(sentryId, sentries.length, "Expected sentry ID <= N");
            assertEq(sentries[sentryId - 1], sentry, "Expected array to have sentry at given index");
            assertTrue(_contains(sentries[sentryId:], sentry), "Expected array to have duplicated address");
        } else {
            revert("Unexpected error");
        }
    }

    function _randomizeBlockNumber(uint64 claimStagingPeriod) internal {
        // We limit the block number by type(uint64).max because the PRT contracts
        // use block numbers for time-keeping, and stores them as uint64 values.
        // We assume there is some slack so we can fast-forward to a block in which
        // the tournament is closed, and we can stage the tournament result, and a
        // block in which the staged tournament result can be accepted.
        // We type the claim staging period as uint64 because otherwise the fuzzer
        // would often pick values too high for these assumptions.
        uint256 blockNumber = vm.getBlockNumber();
        uint64 maxAllowance = Time.Duration.unwrap(MAX_ALLOWANCE);
        vm.assume(blockNumber <= type(uint256).max - maxAllowance);
        vm.assume(blockNumber + maxAllowance <= type(uint256).max - claimStagingPeriod);
        vm.assume(blockNumber + maxAllowance + claimStagingPeriod <= type(uint64).max);
        vm.roll(blockNumber + vm.randomUint(0, type(uint64).max - maxAllowance - claimStagingPeriod));
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

    function _submitSentryClaim(
        IApplication appContract,
        IDaveConsensus daveConsensus,
        uint256 epochNumber,
        uint256 sentryId,
        Machine.Hash postEpochMachineStateHash
    ) internal {
        address sentry = daveConsensus.getSentryById(sentryId);

        // Pick a random hash for testing error cases
        Machine.Hash randomHash = Machine.Hash.wrap(bytes32(vm.randomUint()));

        // Attempt to claim a random hash for the wrong epoch number
        uint256 randomEpochNumber = _randomUintNotEq(epochNumber);
        vm.prank(sentry);
        vm.expectRevert(_encodeIncorrectEpochNumber(randomEpochNumber, epochNumber));
        daveConsensus.submitSentryClaim(randomEpochNumber, randomHash);

        // Make a non-sentry attempt to claim a random hash
        address nonSentry = _randomNonSentry(daveConsensus);
        vm.prank(nonSentry);
        vm.expectRevert(_encodeCallerIsNotSentry(nonSentry));
        daveConsensus.submitSentryClaim(epochNumber, randomHash);

        // Simulate foreclosure and attempt to claim a random hash
        vm.expectRevert(_encodeApplicationForeclosed(address(appContract)));
        this.simulateForeclosureAndSentryClaim(appContract, daveConsensus, epochNumber, sentry, randomHash);

        // Ensure the sentry has not submitted a claim yet
        assertFalse(daveConsensus.hasSentryClaimedInEpoch(epochNumber, sentryId));

        // Get the current number of claims before the submission for later comparison
        uint256 claimCountBefore = daveConsensus.getSentryClaimCount(epochNumber, postEpochMachineStateHash);
        assertLe(claimCountBefore, daveConsensus.getNumberOfSentries());

        // Make the sentry submit the claim while recording logs
        vm.recordLogs();
        vm.prank(sentry);
        daveConsensus.submitSentryClaim(epochNumber, postEpochMachineStateHash);

        // Check the logs for a SentryClaim event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 numOfSentryClaimEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(daveConsensus)) {
                assertGe(log.topics.length, 1);
                bytes32 topic0 = log.topics[0];
                if (topic0 == IDaveConsensus.SentryClaim.selector) {
                    assertEq(log.topics.length, 4);
                    assertEq(log.topics[1], bytes32(epochNumber));
                    assertEq(log.topics[2], bytes32(sentryId));
                    assertEq(log.topics[3], bytes32(uint256(uint160(sentry))));
                    assertEq(log.data, abi.encode(postEpochMachineStateHash));
                    ++numOfSentryClaimEvents;
                } else {
                    revert UnexpectedLogTopic0(log);
                }
            } else {
                revert UnexpectedLogEmitter(log);
            }
        }
        assertEq(numOfSentryClaimEvents, 1);

        // Ensure the sentry has claimed in epoch according to the contract and that
        // the number of claims in the epoch increased by 1
        assertTrue(daveConsensus.hasSentryClaimedInEpoch(epochNumber, sentryId));
        assertEq(daveConsensus.getSentryClaimCount(epochNumber, postEpochMachineStateHash), claimCountBefore + 1);
    }

    function _attemptSentryClaimResubmission(IDaveConsensus daveConsensus, uint256 epochNumber, uint256 sentryId)
        internal
    {
        address randomSentry = daveConsensus.getSentryById(sentryId);
        vm.expectRevert(_encodeSentryAlreadyClaimed(epochNumber, sentryId));
        vm.prank(randomSentry);
        daveConsensus.submitSentryClaim(epochNumber, Machine.Hash.wrap(bytes32(vm.randomUint())));
    }

    function _encodeDuplicatedSentryAddress(uint256 sentryId, address sentry)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(ISentryErrors.DuplicatedSentryAddress.selector, sentryId, sentry);
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

    function _encodeInvalidOutputsMerkleRootProofSize(uint256 suppliedProofSize)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(IDaveConsensus.InvalidOutputsMerkleRootProofSize.selector, suppliedProofSize);
    }

    function _encodeInvalidOutputsMerkleRootProof(bytes32 machineMerkleRoot)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(IDaveConsensus.InvalidOutputsMerkleRootProof.selector, machineMerkleRoot);
    }

    function _encodeClaimStagingPeriodNotOverYet(uint256 numberOfBlocksAfterStaging, uint256 claimStagingPeriod)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(
            IDaveConsensus.ClaimStagingPeriodNotOverYet.selector, numberOfBlocksAfterStaging, claimStagingPeriod
        );
    }

    function _encodeApplicationForeclosed(address appContract) internal pure returns (bytes memory encodedError) {
        return abi.encodeWithSelector(IApplicationChecker.ApplicationForeclosed.selector, appContract);
    }

    function _encodeSentryAlreadyClaimed(uint256 epochNumber, uint256 sentryId)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(IDaveConsensus.SentryAlreadyClaimed.selector, epochNumber, sentryId);
    }

    function _encodeCallerIsNotSentry(address caller) internal pure returns (bytes memory encodedError) {
        return abi.encodeWithSelector(IDaveConsensus.CallerIsNotSentry.selector, caller);
    }

    function _encodeCallerIsNotSentryManager(address caller) internal pure returns (bytes memory encodedError) {
        return abi.encodeWithSelector(IDaveConsensus.CallerIsNotSentryManager.selector, caller);
    }

    function _encodeCannotRotateNonSentry(address nonSentry) internal pure returns (bytes memory encodedError) {
        return abi.encodeWithSelector(IDaveConsensus.CannotRotateNonSentry.selector, nonSentry);
    }

    function _randomUintNotEq(uint256 n) internal returns (uint256 m) {
        while (true) {
            m = vm.randomUint();
            if (n != m) {
                break;
            }
        }
    }

    function _contains(address[] memory array, address value) internal pure returns (bool) {
        for (uint256 i; i < array.length; ++i) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }

    function _randomAddressNotIn(address[] memory disallowList) internal returns (address addr) {
        while (true) {
            addr = vm.randomAddress();
            if (!_contains(disallowList, addr)) {
                break;
            }
        }
    }

    function _randomAddressNotEq(address n) internal returns (address m) {
        while (true) {
            m = vm.randomAddress();
            if (n != m) {
                break;
            }
        }
    }

    function _randomNonSentry(IDaveConsensus daveConsensus) internal returns (address nonSentry) {
        while (true) {
            nonSentry = vm.randomAddress();
            if (daveConsensus.getSentryId(nonSentry) == 0) {
                break;
            }
        }
    }

    function _randomValidNonSentry(IDaveConsensus daveConsensus) internal returns (address nonSentry) {
        while (true) {
            nonSentry = _randomNonSentry(daveConsensus);
            if (nonSentry != address(0)) {
                break;
            }
        }
    }

    function _getSentries(IDaveConsensus daveConsensus) internal view returns (address[] memory sentries) {
        sentries = new address[](daveConsensus.getNumberOfSentries());
        for (uint256 i; i < sentries.length; ++i) {
            uint256 sentryId = i + 1;
            sentries[i] = daveConsensus.getSentryById(sentryId);
            assertEq(daveConsensus.getSentryId(sentries[i]), sentryId);
            assertNotEq(sentries[i], address(0));
        }
    }

    function _getShuffledSentryIds(uint256 numOfSentries) internal returns (uint256[] memory sentryIds) {
        sentryIds = new uint256[](numOfSentries);
        for (uint256 i; i < numOfSentries; ++i) {
            sentryIds[i] = i + 1;
        }
        _shuffleInPlace(sentryIds);
    }

    function _shuffleInPlace(uint256[] memory array) internal {
        // Nothing to be done.
        if (array.length == 0) {
            return;
        }

        // Fisher-Yates shuffle
        for (uint256 i = array.length - 1; i > 0; --i) {
            uint256 j = vm.randomUint(0, i);
            (array[i], array[j]) = (array[j], array[i]);
        }
    }
}
