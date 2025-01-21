// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

import {IInputBox} from "rollups-contracts/inputs/IInputBox.sol";
import {InputBox} from "rollups-contracts/inputs/InputBox.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/Machine.sol";
import {Tree} from "prt-contracts/Tree.sol";

import {DaveConsensus} from "src/DaveConsensus.sol";
import {Merkle} from "src/Merkle.sol";

contract MerkleProxy {
    using Merkle for bytes;

    function getSmallestMerkleRootFromBytes(bytes calldata data) external pure returns (bytes32) {
        return data.getSmallestMerkleRootFromBytes();
    }
}

contract MockTournament is ITournament {
    Machine.Hash immutable _initialState;
    IDataProvider immutable _provider;
    bool _finished;
    Tree.Node _winnerCommitment;
    Machine.Hash _finalState;

    constructor(Machine.Hash initialState, IDataProvider provider) {
        _initialState = initialState;
        _provider = provider;
    }

    function finish(Tree.Node winnerCommitment, Machine.Hash finalState) external {
        _finished = true;
        _winnerCommitment = winnerCommitment;
        _finalState = finalState;
    }

    function getInitialState() external view returns (Machine.Hash) {
        return _initialState;
    }

    function getProvider() external view returns (IDataProvider) {
        return _provider;
    }

    function arbitrationResult()
        external
        view
        returns (bool finished, Tree.Node winnerCommitment, Machine.Hash finalState)
    {
        finished = _finished;
        winnerCommitment = _winnerCommitment;
        finalState = _finalState;
    }
}

contract MockTournamentFactory is ITournamentFactory {
    MockTournament[] _mockTournaments;
    bytes32 _salt;

    error IndexOutOfBounds();

    function instantiate(Machine.Hash initialState, IDataProvider provider) external returns (ITournament) {
        MockTournament mockTournament = new MockTournament{salt: _salt}(initialState, provider);
        _mockTournaments.push(mockTournament);
        return mockTournament;
    }

    function calculateTournamentAddress(Machine.Hash initialState, IDataProvider provider)
        external
        view
        returns (address)
    {
        return Create2.computeAddress(
            _salt, keccak256(abi.encodePacked(type(MockTournament).creationCode, abi.encode(initialState, provider)))
        );
    }

    function setSalt(bytes32 salt) external {
        _salt = salt;
    }

    function getNumberOfMockTournaments() external view returns (uint256) {
        return _mockTournaments.length;
    }

    function getMockTournament(uint256 index) external view returns (MockTournament) {
        if (index < _mockTournaments.length) {
            return _mockTournaments[index];
        } else {
            revert IndexOutOfBounds();
        }
    }
}

contract DaveConsensusTest is Test {
    IInputBox _inputBox;
    MockTournamentFactory _mockTournamentFactory;
    MerkleProxy _merkleProxy;

    function setUp() external {
        _inputBox = new InputBox();
        _mockTournamentFactory = new MockTournamentFactory();
        _merkleProxy = new MerkleProxy();
    }

    function testMockTournamentFactory() external view {
        assertEq(_mockTournamentFactory.getNumberOfMockTournaments(), 0);
    }

    function testMockTournamentFactory(uint256 index) external {
        vm.expectRevert(MockTournamentFactory.IndexOutOfBounds.selector);
        _mockTournamentFactory.getMockTournament(index);
    }

    function testConstructorAndSettle(
        address appContract,
        Machine.Hash[3] calldata states,
        uint256[2] memory inputCounts,
        bytes32[3] calldata salts,
        Tree.Node[2] calldata winnerCommitments
    ) external {
        for (uint256 i; i < 2; ++i) {
            inputCounts[i] = bound(inputCounts[i], 0, 5);
        }

        _addInputs(appContract, inputCounts[0]);

        address daveConsensusAddress = _calculateNewDaveConsensus(appContract, states[0], salts[0]);

        _mockTournamentFactory.setSalt(salts[1]);
        address mockTournamentAddress =
            _mockTournamentFactory.calculateTournamentAddress(states[0], IDataProvider(daveConsensusAddress));

        vm.expectEmit(daveConsensusAddress);
        emit DaveConsensus.ConsensusCreation(_inputBox, appContract, _mockTournamentFactory);

        vm.expectEmit(daveConsensusAddress);
        emit DaveConsensus.EpochSealed(0, 0, inputCounts[0], states[0], ITournament(mockTournamentAddress));

        DaveConsensus daveConsensus = _newDaveConsensus(appContract, states[0], salts[0]);

        assertEq(address(daveConsensus), daveConsensusAddress);
        assertEq(address(daveConsensus.getInputBox()), address(_inputBox));
        assertEq(daveConsensus.getApplicationContract(), appContract);
        assertEq(address(daveConsensus.getTournamentFactory()), address(_mockTournamentFactory));

        {
            bool isFinished;
            uint256 epochNumber;

            (isFinished, epochNumber) = daveConsensus.canSettle();

            assertFalse(isFinished);
            assertEq(epochNumber, 0);
        }

        {
            uint256 epochNumber;
            uint256 inputIndexLowerBound;
            uint256 inputIndexUpperBound;
            ITournament tournament;

            (epochNumber, inputIndexLowerBound, inputIndexUpperBound, tournament) =
                daveConsensus.getCurrentSealedEpoch();

            assertEq(epochNumber, 0);
            assertEq(inputIndexLowerBound, 0);
            assertEq(inputIndexUpperBound, inputCounts[0]);
            assertEq(address(tournament), mockTournamentAddress);
        }

        assertEq(_mockTournamentFactory.getNumberOfMockTournaments(), 1);
        assertEq(address(_mockTournamentFactory.getMockTournament(0)), mockTournamentAddress);

        MockTournament mockTournament = MockTournament(mockTournamentAddress);

        assertEq(Machine.Hash.unwrap(mockTournament.getInitialState()), Machine.Hash.unwrap(states[0]));
        assertEq(address(mockTournament.getProvider()), address(daveConsensus));

        {
            (bool isFinished,,) = mockTournament.arbitrationResult();

            assertFalse(isFinished);
        }

        mockTournament.finish(winnerCommitments[0], states[1]);

        {
            bool isFinished;
            Tree.Node winnerCommitmentTmp;
            Machine.Hash finalStateTmp;

            (isFinished, winnerCommitmentTmp, finalStateTmp) = mockTournament.arbitrationResult();

            assertTrue(isFinished);
            assertEq(Tree.Node.unwrap(winnerCommitmentTmp), Tree.Node.unwrap(winnerCommitments[0]));
            assertEq(Machine.Hash.unwrap(finalStateTmp), Machine.Hash.unwrap(states[1]));
        }

        {
            bool isFinished;
            uint256 epochNumber;

            (isFinished, epochNumber) = daveConsensus.canSettle();

            assertTrue(isFinished);
            assertEq(epochNumber, 0);
        }

        _addInputs(appContract, inputCounts[1]);

        address previousMockTournamentAddress = mockTournamentAddress;

        _mockTournamentFactory.setSalt(salts[2]);
        mockTournamentAddress =
            _mockTournamentFactory.calculateTournamentAddress(states[1], IDataProvider(daveConsensusAddress));

        vm.expectEmit(daveConsensusAddress);
        emit DaveConsensus.EpochSealed(
            1, inputCounts[0], inputCounts[0] + inputCounts[1], states[1], ITournament(mockTournamentAddress)
        );

        daveConsensus.settle(0);

        {
            bool isFinished;
            uint256 epochNumber;

            (isFinished, epochNumber) = daveConsensus.canSettle();

            assertFalse(isFinished);
            assertEq(epochNumber, 1);
        }

        {
            uint256 epochNumber;
            uint256 inputIndexLowerBound;
            uint256 inputIndexUpperBound;
            ITournament tournament;

            (epochNumber, inputIndexLowerBound, inputIndexUpperBound, tournament) =
                daveConsensus.getCurrentSealedEpoch();

            assertEq(epochNumber, 1);
            assertEq(inputIndexLowerBound, inputCounts[0]);
            assertEq(inputIndexUpperBound, inputCounts[0] + inputCounts[1]);
            assertEq(address(tournament), mockTournamentAddress);
        }

        assertEq(_mockTournamentFactory.getNumberOfMockTournaments(), 2);
        assertEq(address(_mockTournamentFactory.getMockTournament(0)), previousMockTournamentAddress);
        assertEq(address(_mockTournamentFactory.getMockTournament(1)), mockTournamentAddress);

        mockTournament = MockTournament(mockTournamentAddress);

        assertEq(Machine.Hash.unwrap(mockTournament.getInitialState()), Machine.Hash.unwrap(states[1]));
        assertEq(address(mockTournament.getProvider()), address(daveConsensus));

        {
            (bool isFinished,,) = mockTournament.arbitrationResult();

            assertFalse(isFinished);
        }

        mockTournament.finish(winnerCommitments[1], states[2]);

        {
            bool isFinished;
            Tree.Node winnerCommitmentTmp;
            Machine.Hash finalStateTmp;

            (isFinished, winnerCommitmentTmp, finalStateTmp) = mockTournament.arbitrationResult();

            assertTrue(isFinished);
            assertEq(Tree.Node.unwrap(winnerCommitmentTmp), Tree.Node.unwrap(winnerCommitments[1]));
            assertEq(Machine.Hash.unwrap(finalStateTmp), Machine.Hash.unwrap(states[2]));
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

        _mockTournamentFactory.setSalt(salts[0]);

        DaveConsensus daveConsensus = _newDaveConsensus(appContract, states[0], salts[1]);

        _addInputs(appContract, inputCounts[1]);

        vm.expectRevert(abi.encodeWithSelector(DaveConsensus.IncorrectEpochNumber.selector, wrongEpochNumber, 0));
        daveConsensus.settle(wrongEpochNumber);

        vm.expectRevert(DaveConsensus.TournamentNotFinishedYet.selector);
        daveConsensus.settle(0);
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

        _mockTournamentFactory.setSalt(salts[0]);

        DaveConsensus daveConsensus = _newDaveConsensus(appContract, initialState, salts[1]);

        if (inputs.length > 0) {
            inputIndexWithinBounds = bound(inputIndexWithinBounds, 0, inputs.length - 1);
            bytes memory input = inputs[inputIndexWithinBounds];
            bytes32 root = daveConsensus.provideMerkleRootOfInput(inputIndexWithinBounds, input);
            assertEq(root, _merkleProxy.getSmallestMerkleRootFromBytes(input));
        }

        {
            inputIndexOutsideBounds = bound(inputIndexOutsideBounds, inputs.length, type(uint256).max);
            bytes32 root = daveConsensus.provideMerkleRootOfInput(inputIndexOutsideBounds, new bytes(0));
            assertEq(root, bytes32(0));
        }
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
                    abi.encode(_inputBox, appContract, _mockTournamentFactory, initialState)
                )
            )
        );
    }

    function _newDaveConsensus(address appContract, Machine.Hash initialState, bytes32 salt)
        internal
        returns (DaveConsensus)
    {
        return new DaveConsensus{salt: salt}(_inputBox, appContract, _mockTournamentFactory, initialState);
    }
}
