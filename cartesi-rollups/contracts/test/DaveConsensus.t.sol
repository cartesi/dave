// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {Create2} from "@openzeppelin-contracts-5.5.0/utils/Create2.sol";
import {IERC165} from "@openzeppelin-contracts-5.5.0/utils/introspection/IERC165.sol";

import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-2.1.1/src/consensus/IOutputsMerkleRootValidator.sol";
import {IInputBox} from "cartesi-rollups-contracts-2.1.1/src/inputs/IInputBox.sol";
import {InputBox} from "cartesi-rollups-contracts-2.1.1/src/inputs/InputBox.sol";
import {LibMerkle32} from "cartesi-rollups-contracts-2.1.1/src/library/LibMerkle32.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {ITaskSpawner} from "prt-contracts/ITaskSpawner.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {DaveConsensus} from "src/DaveConsensus.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";
import {Merkle} from "src/Merkle.sol";

contract MerkleProxy {
    using Merkle for bytes;

    function getMinLog2SizeOfDrive(bytes calldata data) external pure returns (uint256) {
        return data.getMinLog2SizeOfDrive();
    }

    function getMerkleRootFromBytes(bytes calldata data, uint256 log2SizeOfDrive) external pure returns (bytes32) {
        return data.getMerkleRootFromBytes(log2SizeOfDrive);
    }
}

contract MockTask is ITask {
    Machine.Hash immutable _INITIAL_STATE;
    IDataProvider immutable _PROVIDER;
    bool _finished;
    Machine.Hash _finalState;

    constructor(Machine.Hash initialState, IDataProvider provider) {
        _INITIAL_STATE = initialState;
        _PROVIDER = provider;
    }

    function finish(Machine.Hash finalState) external {
        _finished = true;
        _finalState = finalState;
    }

    function getInitialState() external view returns (Machine.Hash) {
        return _INITIAL_STATE;
    }

    function getProvider() external view returns (IDataProvider) {
        return _PROVIDER;
    }

    function result() external view returns (bool finished, Machine.Hash finalState) {
        finished = _finished;
        finalState = _finalState;
    }

    function cleanup() external returns (bool) {
        return _finished;
    }
}

contract MockTaskSpawner is ITaskSpawner {
    MockTask[] _mockTasks;
    bytes32 _salt;

    error IndexOutOfBounds();

    function spawn(Machine.Hash initialState, IDataProvider provider) external returns (ITask) {
        MockTask mockTask = new MockTask{salt: _salt}(initialState, provider);
        _mockTasks.push(mockTask);
        return mockTask;
    }

    function calculateTaskAddress(Machine.Hash initialState, IDataProvider provider) external view returns (address) {
        return Create2.computeAddress(
            _salt, keccak256(abi.encodePacked(type(MockTask).creationCode, abi.encode(initialState, provider)))
        );
    }

    function setSalt(bytes32 salt) external {
        _salt = salt;
    }

    function getNumberOfMockTasks() external view returns (uint256) {
        return _mockTasks.length;
    }

    function getMockTask(uint256 index) external view returns (MockTask) {
        if (index < _mockTasks.length) {
            return _mockTasks[index];
        } else {
            revert IndexOutOfBounds();
        }
    }
}

contract LibMerkle32Wrapper {
    function merkleRootAfterReplacement(bytes32[] calldata sibs, uint256 index, bytes32 leaf)
        external
        pure
        returns (bytes32)
    {
        return LibMerkle32.merkleRootAfterReplacement(sibs, index, leaf);
    }
}

contract DaveConsensusTest is Test {
    IInputBox _inputBox;
    MockTaskSpawner _mockTaskSpawner;
    MerkleProxy _merkleProxy;
    address _securityCouncil;

    function setUp() external {
        _inputBox = new InputBox();
        _mockTaskSpawner = new MockTaskSpawner();
        _merkleProxy = new MerkleProxy();
        _securityCouncil = address(0xBEEF);
    }

    function testMockTaskSpawner() external view {
        assertEq(_mockTaskSpawner.getNumberOfMockTasks(), 0);
    }

    function testMockTaskSpawner(uint256 index) external {
        vm.expectRevert(MockTaskSpawner.IndexOutOfBounds.selector);
        _mockTaskSpawner.getMockTask(index);
    }

    function testConstructorAndSettle(
        address appContract,
        bytes32[3] calldata outputsMerkleRoots,
        uint256[2] memory inputCounts,
        bytes32[3] calldata salts,
        uint256 deploymentBlockNumber
    ) external {
        vm.roll(deploymentBlockNumber);

        for (uint256 i; i < 2; ++i) {
            inputCounts[i] = bound(inputCounts[i], 0, 5);
        }

        _addInputs(appContract, inputCounts[0]);

        (Machine.Hash state0,,) = _statesAndProofs(outputsMerkleRoots[0]);

        DaveConsensus daveConsensus;
        MockTask mockTask;

        {
            address daveConsensusAddress = _calculateNewDaveConsensus(appContract, state0, salts[0]);

            _mockTaskSpawner.setSalt(salts[1]);
            address mockTaskAddress = _mockTaskSpawner.calculateTaskAddress(state0, IDataProvider(daveConsensusAddress));

            vm.expectEmit(daveConsensusAddress);
            emit IDaveConsensus.ConsensusCreation(_inputBox, appContract, _mockTaskSpawner);

            vm.expectEmit(daveConsensusAddress);
            emit IDaveConsensus.EpochSealed(0, 0, inputCounts[0], state0, bytes32(0), ITask(mockTaskAddress));

            daveConsensus = _newDaveConsensus(appContract, state0, salts[0]);

            assertEq(address(daveConsensus), daveConsensusAddress);
            assertEq(address(daveConsensus.getInputBox()), address(_inputBox));
            assertEq(daveConsensus.getApplicationContract(), appContract);
            assertEq(address(daveConsensus.getTaskSpawner()), address(_mockTaskSpawner));
            assertEq(daveConsensus.getSecurityCouncil(), _securityCouncil);
            assertEq(daveConsensus.getDeploymentBlockNumber(), deploymentBlockNumber);

            mockTask = MockTask(mockTaskAddress);
        }

        {
            bool isFinished;
            uint256 epochNumber;

            (isFinished, epochNumber,) = daveConsensus.canSettle();

            assertFalse(isFinished);
            assertEq(epochNumber, 0);
        }

        {
            uint256 epochNumber;
            uint256 inputIndexLowerBound;
            uint256 inputIndexUpperBound;
            ITask task;

            (epochNumber, inputIndexLowerBound, inputIndexUpperBound, task) = daveConsensus.getCurrentSealedEpoch();

            assertEq(epochNumber, 0);
            assertEq(inputIndexLowerBound, 0);
            assertEq(inputIndexUpperBound, inputCounts[0]);
            assertEq(address(task), address(mockTask));
        }

        assertEq(_mockTaskSpawner.getNumberOfMockTasks(), 1);
        assertEq(address(_mockTaskSpawner.getMockTask(0)), address(mockTask));

        assertEq(Machine.Hash.unwrap(mockTask.getInitialState()), Machine.Hash.unwrap(state0));
        assertEq(address(mockTask.getProvider()), address(daveConsensus));

        {
            (bool isFinished,) = mockTask.result();

            assertFalse(isFinished);
        }

        (Machine.Hash state1,,) = _statesAndProofs(outputsMerkleRoots[1]);
        mockTask.finish(state1);

        {
            bool isFinished;
            Machine.Hash finalStateTmp;

            (isFinished, finalStateTmp) = mockTask.result();

            assertTrue(isFinished);
            assertEq(Machine.Hash.unwrap(finalStateTmp), Machine.Hash.unwrap(state1));
        }

        {
            bool isFinished;
            uint256 epochNumber;

            (isFinished, epochNumber,) = daveConsensus.canSettle();

            assertTrue(isFinished);
            assertEq(epochNumber, 0);
        }

        assertFalse(daveConsensus.isOutputsMerkleRootValid(appContract, outputsMerkleRoots[1]));

        _addInputs(appContract, inputCounts[1]);

        {
            _mockTaskSpawner.setSalt(salts[2]);
            address mockTaskAddress = _mockTaskSpawner.calculateTaskAddress(state1, daveConsensus);

            (, bytes32[] memory proof1, bytes32 leaf1) = _statesAndProofs(outputsMerkleRoots[1]);

            vm.expectEmit(address(daveConsensus));
            emit IDaveConsensus.EpochSealed(
                1, inputCounts[0], inputCounts[0] + inputCounts[1], state1, leaf1, ITask(mockTaskAddress)
            );

            daveConsensus.settle(0, leaf1, proof1);

            assertEq(_mockTaskSpawner.getNumberOfMockTasks(), 2);

            mockTask = _mockTaskSpawner.getMockTask(1);

            assertEq(address(mockTask), mockTaskAddress);
        }

        {
            bool isFinished;
            uint256 epochNumber;

            (isFinished, epochNumber,) = daveConsensus.canSettle();

            assertFalse(isFinished);
            assertEq(epochNumber, 1);
        }

        {
            uint256 epochNumber;
            uint256 inputIndexLowerBound;
            uint256 inputIndexUpperBound;
            ITask task;

            (epochNumber, inputIndexLowerBound, inputIndexUpperBound, task) = daveConsensus.getCurrentSealedEpoch();

            assertEq(epochNumber, 1);
            assertEq(inputIndexLowerBound, inputCounts[0]);
            assertEq(inputIndexUpperBound, inputCounts[0] + inputCounts[1]);
            assertEq(address(task), address(mockTask));
        }

        assertEq(Machine.Hash.unwrap(mockTask.getInitialState()), Machine.Hash.unwrap(state1));
        assertEq(address(mockTask.getProvider()), address(daveConsensus));

        {
            (bool isFinished,) = mockTask.result();

            assertFalse(isFinished);
        }

        assertTrue(daveConsensus.isOutputsMerkleRootValid(appContract, outputsMerkleRoots[1]));

        (Machine.Hash state2,,) = _statesAndProofs(outputsMerkleRoots[2]);
        mockTask.finish(state2);

        {
            bool isFinished;
            Machine.Hash finalStateTmp;

            (isFinished, finalStateTmp) = mockTask.result();

            assertTrue(isFinished);
            assertEq(Machine.Hash.unwrap(finalStateTmp), Machine.Hash.unwrap(state2));
        }
    }

    function testSettleReverts(
        address appContract,
        Machine.Hash[2] calldata states,
        uint256[2] memory inputCounts,
        bytes32[2] calldata salts,
        uint256 wrongEpochNumber
    ) external {
        vm.assume(wrongEpochNumber != 0);

        for (uint256 i; i < 2; ++i) {
            inputCounts[i] = bound(inputCounts[i], 0, 5);
        }

        _addInputs(appContract, inputCounts[0]);

        _mockTaskSpawner.setSalt(salts[0]);

        DaveConsensus daveConsensus = _newDaveConsensus(appContract, states[0], salts[1]);

        _addInputs(appContract, inputCounts[1]);

        vm.expectRevert(abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, wrongEpochNumber, 0));
        daveConsensus.settle(wrongEpochNumber, bytes32(0), new bytes32[](0));

        vm.expectRevert(IDaveConsensus.TournamentNotFinishedYet.selector);
        daveConsensus.settle(0, bytes32(0), new bytes32[](0));
    }

    function testPauseBlocksSettle(
        address appContract,
        Machine.Hash initialState,
        bytes32 outputsMerkleRoot,
        bytes32 salt
    ) external {
        _mockTaskSpawner.setSalt(salt);
        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salt);

        MockTask task = _mockTaskSpawner.getMockTask(0);
        (Machine.Hash finalState, bytes32[] memory proof, bytes32 outputRoot) = _statesAndProofs(outputsMerkleRoot);
        task.finish(finalState);

        vm.prank(_securityCouncil);
        daveConsensus.pause();

        vm.expectRevert(IDaveConsensus.PausedError.selector);
        daveConsensus.settle(0, outputRoot, proof);

        vm.prank(_securityCouncil);
        daveConsensus.unpause();

        daveConsensus.settle(0, outputRoot, proof);
    }

    function testUpgradeOnlySecurityCouncil(address appContract, Machine.Hash initialState, bytes32 salt) external {
        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salt);

        MockTaskSpawner newSpawner = new MockTaskSpawner();
        vm.expectRevert(IDaveConsensus.NotSecurityCouncil.selector);
        daveConsensus.upgrade(initialState, newSpawner);
    }

    function testUpgradeSpawnsNewTask(address appContract, Machine.Hash initialState, bytes32 salt, bytes32 newSalt)
        external
    {
        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salt);

        MockTaskSpawner newSpawner = new MockTaskSpawner();
        newSpawner.setSalt(newSalt);

        Machine.Hash newState = Machine.Hash.wrap(keccak256("upgrade-state"));
        address expectedTask = newSpawner.calculateTaskAddress(newState, IDataProvider(address(daveConsensus)));

        vm.expectEmit(address(daveConsensus));
        emit IDaveConsensus.TaskUpgraded(0, newState, newSpawner, ITask(expectedTask));

        vm.prank(_securityCouncil);
        daveConsensus.upgrade(newState, newSpawner);

        assertEq(address(daveConsensus.getTaskSpawner()), address(newSpawner));

        (uint256 epochNumber,,, ITask task) = daveConsensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 0);
        assertEq(address(task), expectedTask);

        MockTask spawned = MockTask(expectedTask);
        assertEq(Machine.Hash.unwrap(spawned.getInitialState()), Machine.Hash.unwrap(newState));
        assertEq(address(spawned.getProvider()), address(daveConsensus));
    }

    function testProvideMerkleRootOfInput(
        address appContract,
        bytes[] calldata payloads,
        uint256 inputIndexWithinBounds,
        uint256 inputIndexOutsideBounds,
        Machine.Hash initialState,
        bytes32[2] calldata salts
    ) external {
        bytes[] memory inputs = _addInputs(appContract, payloads);

        _mockTaskSpawner.setSalt(salts[0]);

        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salts[1]);

        if (inputs.length > 0) {
            inputIndexWithinBounds = bound(inputIndexWithinBounds, 0, inputs.length - 1);
            bytes memory input = inputs[inputIndexWithinBounds];
            bytes32 root = daveConsensus.provideMerkleRootOfInput(inputIndexWithinBounds, input);
            uint256 log2SizeOfDrive = _merkleProxy.getMinLog2SizeOfDrive(input);
            assertEq(root, _merkleProxy.getMerkleRootFromBytes(input, log2SizeOfDrive));
        }

        {
            inputIndexOutsideBounds = bound(inputIndexOutsideBounds, inputs.length, type(uint256).max);
            bytes32 root = daveConsensus.provideMerkleRootOfInput(inputIndexOutsideBounds, new bytes(0));
            assertEq(root, bytes32(0));
        }
    }

    function testErc165(address appContract, Machine.Hash initialState, bytes32 salt, bytes4 unsupportedInterfaceId)
        external
    {
        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salt);

        // List the ID of all interfaces supported by `DaveConsensus`
        bytes4[] memory supportedInterfaces = new bytes4[](3);
        supportedInterfaces[0] = type(IERC165).interfaceId;
        supportedInterfaces[1] = type(IDataProvider).interfaceId;
        supportedInterfaces[2] = type(IOutputsMerkleRootValidator).interfaceId;

        // For each supported interface ID, ensure `supportsInterface` returns true
        // Also, make sure the fuzzy parameter `unsupportedInterfaceId` is distinct from them
        for (uint256 i; i < supportedInterfaces.length; ++i) {
            bytes4 interfaceId = supportedInterfaces[i];
            assertTrue(daveConsensus.supportsInterface(interfaceId));
            vm.assume(unsupportedInterfaceId != interfaceId);
        }

        // Finally, ensure that any other interface ID is explicitly unsupported
        assertFalse(daveConsensus.supportsInterface(unsupportedInterfaceId));
    }

    function testIsOutputsMerkleRootValid(
        address appContract,
        Machine.Hash initialState,
        bytes32 salt,
        address otherAppContract,
        bytes32 outputsMerkleRoot
    ) external {
        vm.assume(appContract != otherAppContract);

        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salt);

        vm.expectRevert(_encodeApplicationMismatch(appContract, otherAppContract));
        daveConsensus.isOutputsMerkleRootValid(otherAppContract, outputsMerkleRoot);

        assertFalse(daveConsensus.isOutputsMerkleRootValid(appContract, outputsMerkleRoot));
    }

    function _addInputs(address appContract, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _inputBox.addInput(appContract, new bytes(0));
        }
    }

    function _addInputs(address appContract, bytes[] calldata payloads) internal returns (bytes[] memory) {
        bytes32[] memory inputHashes = new bytes32[](payloads.length);

        vm.recordLogs();

        for (uint256 i; i < payloads.length; ++i) {
            inputHashes[i] = _inputBox.addInput(appContract, payloads[i]);
        }

        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes[] memory inputs = new bytes[](payloads.length);

        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            assertEq(entry.emitter, address(_inputBox));
            assertEq(entry.topics[0], IInputBox.InputAdded.selector);
            assertEq(entry.topics[1], bytes32(uint256(uint160(appContract))));
            assertEq(entry.topics[2], bytes32(i));
            bytes memory input = abi.decode(entry.data, (bytes));
            assertEq(keccak256(input), inputHashes[i]);
            inputs[i] = input;
        }

        return inputs;
    }

    function _calculateNewDaveConsensus(address appContract, Machine.Hash initialState, bytes32 salt)
        internal
        view
        returns (address)
    {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DaveConsensus).creationCode,
                    abi.encode(_inputBox, appContract, _mockTaskSpawner, _securityCouncil, initialState)
                )
            )
        );
    }

    function _newDaveConsensus(address appContract, Machine.Hash initialState, bytes32 salt)
        internal
        returns (DaveConsensus)
    {
        return new DaveConsensus{salt: salt}(_inputBox, appContract, _mockTaskSpawner, _securityCouncil, initialState);
    }

    function _statesAndProofs(bytes32 outputsMerkleRoot) private returns (Machine.Hash, bytes32[] memory, bytes32) {
        uint256 levels = Memory.LOG2_MAX_SIZE;
        bytes32[] memory siblings = new bytes32[](levels);

        bytes32 leaf = keccak256(abi.encode(outputsMerkleRoot));
        bytes32 current = leaf;
        for (uint256 i = 0; i < levels; i++) {
            siblings[i] = current;
            current = keccak256(abi.encodePacked(current, current));
        }

        bytes32 root = new LibMerkle32Wrapper()
            .merkleRootAfterReplacement(
                siblings, EmulatorConstants.PMA_CMIO_TX_BUFFER_START >> EmulatorConstants.TREE_LOG2_WORD_SIZE, leaf
            );
        assertEq(current, root);

        return (Machine.Hash.wrap(current), siblings, outputsMerkleRoot);
    }

    /// @notice Encode an `ApplicationMismatch` error.
    /// @param expected The expected application contract address (the one provided through the constructor)
    /// @param obtained The application contract address received by the function
    /// @return encodedError The ABI-encoded Solidity error
    function _encodeApplicationMismatch(address expected, address obtained)
        internal
        pure
        returns (bytes memory encodedError)
    {
        return abi.encodeWithSelector(IDaveConsensus.ApplicationMismatch.selector, expected, obtained);
    }
}
