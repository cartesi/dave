pragma solidity ^0.8.22;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {ApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/ApplicationFactory.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationFactory} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationFactory.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {InputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/InputBox.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    CanonicalTournamentParametersProvider
} from "prt-contracts/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {ISafetyGateTask} from "prt-contracts/safety-gate-task/ISafetyGateTask.sol";
import {SafetyGateTask} from "prt-contracts/safety-gate-task/SafetyGateTask.sol";
import {SafetyGateTaskSpawner} from "prt-contracts/safety-gate-task/SafetyGateTaskSpawner.sol";
import {CartesiStateTransition} from "prt-contracts/state-transition/CartesiStateTransition.sol";
import {CmioStateTransition} from "prt-contracts/state-transition/CmioStateTransition.sol";
import {RiscVStateTransition} from "prt-contracts/state-transition/RiscVStateTransition.sol";
import {Tournament} from "prt-contracts/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {IDaveAppFactory} from "src/IDaveAppFactory.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";

import {LibExternalBinaryKeccak256MerkleTree, getCommitmentChildren} from "./DaveTestLib.sol";

/// @notice End-to-end test of a gated Dave app deployed via
/// `DaveAppFactory.newGatedDaveApp`, settling through a SafetyGateTask that
/// wraps a real root tournament.
contract DaveSafetyGateTest is Test {
    using LibExternalBinaryKeccak256MerkleTree for bytes32[];
    using Machine for Machine.Hash;

    IInputBox _inputBox;
    IApplicationFactory _appFactory;
    IStateTransition _stateTransition;
    MultiLevelTournamentFactory _tournamentFactory;
    IDaveAppFactory _daveAppFactory;

    Time.Duration constant MATCH_EFFORT = Time.Duration.wrap(5);
    Time.Duration constant MAX_ALLOWANCE = Time.Duration.wrap(120);
    Time.Duration constant WINDOW = Time.Duration.wrap(10);

    address constant SENTRY_ONE = address(0x1001);
    address constant SENTRY_TWO = address(0x1002);
    address constant SENTRY_MANAGER = address(0x3001);

    bytes32 constant TEMPLATE_HASH = bytes32(uint256(0xdead));

    function setUp() external {
        _inputBox = new InputBox();
        _appFactory = new ApplicationFactory();
        _stateTransition = new CartesiStateTransition(new RiscVStateTransition(), new CmioStateTransition());
        _tournamentFactory = new MultiLevelTournamentFactory(
            new Tournament(), new CanonicalTournamentParametersProvider(MATCH_EFFORT, MAX_ALLOWANCE), _stateTransition
        );

        _daveAppFactory = new DaveAppFactory(_inputBox, _appFactory, _tournamentFactory);
    }

    function _sentries() internal pure returns (address[] memory sentries) {
        sentries = new address[](2);
        sentries[0] = SENTRY_ONE;
        sentries[1] = SENTRY_TWO;
    }

    struct Fixture {
        IApplication appContract;
        IDaveConsensus daveConsensus;
        SafetyGateTaskSpawner gateSpawner;
        SafetyGateTask gate;
        ITournament tournament;
        address submitter;
        uint256 bondValue;
        bytes32 machineMerkleRoot;
        bytes32 outputsMerkleRoot;
        bytes32[] outputsMerkleRootProof;
    }

    /// @notice Deploy a gated Dave app through the factory and join its
    /// inner tournament with a fabricated commitment, so the tournament can
    /// finish by timeout.
    function _newJoinedFixture() internal returns (Fixture memory f) {
        WithdrawalConfig memory zeroConfig;

        (address precalcApp, address precalcConsensus, address precalcGateSpawner) = _daveAppFactory.calculateGatedDaveAppAddress(
            TEMPLATE_HASH, zeroConfig, SENTRY_MANAGER, WINDOW, _sentries(), bytes32(0)
        );

        vm.expectEmit(true, true, false, true, address(_daveAppFactory));
        emit IDaveAppFactory.GatedDaveAppCreated(
            IApplication(precalcApp), IDaveConsensus(precalcConsensus), SafetyGateTaskSpawner(precalcGateSpawner)
        );
        (f.appContract, f.daveConsensus, f.gateSpawner) =
            _daveAppFactory.newGatedDaveApp(TEMPLATE_HASH, zeroConfig, SENTRY_MANAGER, WINDOW, _sentries(), bytes32(0));

        assertEq(precalcApp, address(f.appContract), "app address precalc mismatch");
        assertEq(precalcConsensus, address(f.daveConsensus), "consensus address precalc mismatch");
        assertEq(precalcGateSpawner, address(f.gateSpawner), "gate spawner address precalc mismatch");

        // the gate spawner carries the app-declared governance parameters
        // and wraps the factory's bound proof system
        assertEq(f.gateSpawner.SENTRY_MANAGER(), SENTRY_MANAGER);
        assertEq(address(f.gateSpawner.INNER_SPAWNER()), address(_tournamentFactory));
        assertEq(Time.Duration.unwrap(f.gateSpawner.DISAGREEMENT_WINDOW()), Time.Duration.unwrap(WINDOW));
        assertEq(f.gateSpawner.getSentries(), _sentries());
        assertEq(address(f.daveConsensus.getTaskSpawner()), address(f.gateSpawner));

        (,,, ITask task) = f.daveConsensus.getCurrentSealedEpoch();
        assertTrue(task.supportsInterface(type(ISafetyGateTask).interfaceId), "task should be a safety gate");
        f.gate = SafetyGateTask(address(task));

        ITask innerTask = f.gate.INNER_TASK();
        assertTrue(innerTask.supportsInterface(type(ITournament).interfaceId), "inner task should be a tournament");
        f.tournament = ITournament(address(innerTask));

        f.outputsMerkleRoot = bytes32(uint256(0xbeef));
        f.outputsMerkleRootProof = _zeroProof(Memory.LOG2_MAX_SIZE);
        f.machineMerkleRoot = f.outputsMerkleRootProof
            .merkleRootAfterReplacement(
                EmulatorConstants.AR_CMIO_TX_BUFFER_START >> EmulatorConstants.HASH_TREE_LOG2_WORD_SIZE,
                keccak256(abi.encode(f.outputsMerkleRoot))
            );

        bytes32[] memory finalStateProof = _zeroProof(f.tournament.tournamentArguments().commitmentArgs.height);
        (bytes32 leftChild, bytes32 rightChild) = getCommitmentChildren(f.machineMerkleRoot, finalStateProof);

        f.submitter = vm.addr(0xb0b);
        f.bondValue = f.tournament.bondValue();
        vm.deal(f.submitter, f.bondValue);

        vm.prank(f.submitter);
        f.tournament.joinTournament{value: f.bondValue}(
            Machine.Hash.wrap(f.machineMerkleRoot),
            finalStateProof,
            Tree.Node.wrap(leftChild),
            Tree.Node.wrap(rightChild)
        );
    }

    function _rollUntilInnerFinished(Fixture memory f) internal {
        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(MAX_ALLOWANCE));
        assertTrue(f.tournament.isFinished(), "inner tournament should be finished");
    }

    function _assertCannotSettle(Fixture memory f) internal {
        (bool isFinished,,) = f.daveConsensus.canSettle();
        assertFalse(isFinished, "epoch should not be settleable");

        vm.expectRevert(IDaveConsensus.TournamentNotFinishedYet.selector);
        f.daveConsensus.settle(0, f.outputsMerkleRoot, f.outputsMerkleRootProof);
    }

    function _settleAndCheck(Fixture memory f) internal {
        (bool isFinished, uint256 epochNumber, Machine.Hash finalState) = f.daveConsensus.canSettle();
        assertTrue(isFinished, "epoch should be settleable");
        assertEq(epochNumber, 0);
        assertEq(Machine.Hash.unwrap(finalState), f.machineMerkleRoot, "gate must expose the inner result");

        f.daveConsensus.settle(0, f.outputsMerkleRoot, f.outputsMerkleRootProof);

        (uint256 newEpochNumber,,, ITask newTask) = f.daveConsensus.getCurrentSealedEpoch();
        assertEq(newEpochNumber, 1);
        assertTrue(
            newTask.supportsInterface(type(ISafetyGateTask).interfaceId), "next epoch task should be a safety gate"
        );
        assertTrue(newTask != ITask(address(f.gate)), "next epoch should have a fresh gate");

        // cleanup cascaded through the gate and recovered the inner bond
        assertEq(f.submitter.balance, f.bondValue, "submitter should have the bond back");
    }

    function testSettleWithSentryAgreement() external {
        Fixture memory f = _newJoinedFixture();

        _assertCannotSettle(f);

        _rollUntilInnerFinished(f);

        // inner task is finished, but the gate still holds settlement
        _assertCannotSettle(f);

        vm.prank(SENTRY_ONE);
        f.gate.sentryVote(Machine.Hash.wrap(f.machineMerkleRoot));

        // one vote is not enough
        _assertCannotSettle(f);

        vm.prank(SENTRY_TWO);
        f.gate.sentryVote(Machine.Hash.wrap(f.machineMerkleRoot));

        _settleAndCheck(f);
    }

    function testSettleWithMissingVotesAfterFallback() external {
        Fixture memory f = _newJoinedFixture();

        _rollUntilInnerFinished(f);

        vm.prank(SENTRY_ONE);
        f.gate.sentryVote(Machine.Hash.wrap(f.machineMerkleRoot));

        assertTrue(f.gate.canStartFallbackTimer());
        assertTrue(f.gate.startFallbackTimer());

        // window has not elapsed yet
        _assertCannotSettle(f);

        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(WINDOW));

        _settleAndCheck(f);
    }

    function testSentriesCannotChangeResultOnlyDelay() external {
        Fixture memory f = _newJoinedFixture();

        _rollUntilInnerFinished(f);

        // unanimous sentry agreement on a *wrong* state must not settle,
        // and after the fallback window the *inner* result wins
        bytes32 wrongState = bytes32(uint256(0xbad));
        vm.prank(SENTRY_ONE);
        f.gate.sentryVote(Machine.Hash.wrap(wrongState));
        vm.prank(SENTRY_TWO);
        f.gate.sentryVote(Machine.Hash.wrap(wrongState));

        _assertCannotSettle(f);

        assertTrue(f.gate.canStartFallbackTimer());
        assertTrue(f.gate.startFallbackTimer());

        vm.roll(vm.getBlockNumber() + Time.Duration.unwrap(WINDOW));

        _settleAndCheck(f);
    }

    function testGatedAndBareShareAppAddressSpace() external {
        WithdrawalConfig memory zeroConfig;
        _daveAppFactory.newDaveApp(TEMPLATE_HASH, zeroConfig, bytes32(0));

        // same (templateHash, config, salt) collides on the application
        // address, whichever deployment flavor came first
        vm.expectRevert();
        _daveAppFactory.newGatedDaveApp(TEMPLATE_HASH, zeroConfig, SENTRY_MANAGER, WINDOW, _sentries(), bytes32(0));
    }

    function _zeroProof(uint256 n) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](n);
    }
}
