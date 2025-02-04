// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IInputBox} from "rollups-contracts/inputs/IInputBox.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/Machine.sol";

import {Merkle} from "./Merkle.sol";

/// @notice Consensus contract with Dave tournaments.
///
/// @notice This contract validates only one application,
/// which read inputs from the InputBox contract.
///
/// @notice This contract also manages epoch boundaries, which
/// are defined in terms of block numbers. We represent them
/// as intervals of the form [a,b). They are also identified by
/// incremental numbers that start from 0.
///
/// @notice Off-chain nodes can listen to `EpochSealed` events
/// to know where epochs start and end, and which epochs have been
/// settled already and which one is open for challenges still.
/// Anyone can settle an epoch by calling `settle`.
/// One can also check if it can be settled by calling `canSettle`.
///
/// @notice At any given time, there is always one sealed epoch.
/// Prior to it, every epoch has been settled.
/// After it, the next epoch is accumulating inputs. Once this epoch is settled,
/// the accumlating epoch will be sealed, and a new
/// accumulating epoch will be created.
///
contract DaveConsensus is IDataProvider {
    using Merkle for bytes;

    /// @notice The input box contract
    IInputBox immutable _inputBox;

    /// @notice The application contract
    address immutable _appContract;

    /// @notice The contract used to instantiate tournaments
    ITournamentFactory immutable _tournamentFactory;

    /// @notice Current sealed epoch number
    uint256 _epochNumber;

    /// @notice Input index (inclusive) lower bound of the current sealed epoch
    uint256 _inputIndexLowerBound;

    /// @notice Input index (exclusive) upper bound of the current sealed epoch
    uint256 _inputIndexUpperBound;

    /// @notice Current sealed epoch tournament
    ITournament _tournament;

    /// @notice Consensus contract was created
    /// @param inputBox the input box contract
    /// @param appContract the application contract
    /// @param tournamentFactory the tournament factory contract
    event ConsensusCreation(IInputBox inputBox, address appContract, ITournamentFactory tournamentFactory);

    /// @notice An epoch was sealed
    /// @param epochNumber the sealed epoch number
    /// @param inputIndexLowerBound the input index (inclusive) lower bound in the sealed epoch
    /// @param inputIndexUpperBound the input index (exclusive) upper bound in the sealed epoch
    /// @param initialMachineStateHash the initial machine state hash
    /// @param tournament the sealed epoch tournament contract
    event EpochSealed(
        uint256 epochNumber,
        uint256 inputIndexLowerBound,
        uint256 inputIndexUpperBound,
        Machine.Hash initialMachineStateHash,
        ITournament tournament
    );

    /// @notice Received epoch number is different from actual
    /// @param received The epoch number received as argument
    /// @param actual The actual epoch number in storage
    error IncorrectEpochNumber(uint256 received, uint256 actual);

    /// @notice Tournament is not finished yet
    error TournamentNotFinishedYet();

    /// @notice Hash of received input blob is different from stored on-chain
    /// @param fromReceivedInput Hash of received input blob
    /// @param fromInputBox Hash of input stored on the input box contract
    error InputHashMismatch(bytes32 fromReceivedInput, bytes32 fromInputBox);

    constructor(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash
    ) {
        // Initialize immutable variables
        _inputBox = inputBox;
        _appContract = appContract;
        _tournamentFactory = tournamentFactory;
        emit ConsensusCreation(inputBox, appContract, tournamentFactory);

        // Initialize first sealed epoch
        uint256 inputIndexUpperBound = inputBox.getNumberOfInputs(appContract);
        _inputIndexUpperBound = inputIndexUpperBound;
        ITournament tournament = tournamentFactory.instantiate(initialMachineStateHash, this);
        _tournament = tournament;
        emit EpochSealed(0, 0, inputIndexUpperBound, initialMachineStateHash, tournament);
    }

    function canSettle() external view returns (bool isFinished, uint256 epochNumber) {
        (isFinished,,) = _tournament.arbitrationResult();
        epochNumber = _epochNumber;
    }

    function settle(uint256 epochNumber) external {
        // Check tournament settlement
        uint256 actualEpochNumber = _epochNumber;
        require(epochNumber == actualEpochNumber, IncorrectEpochNumber(epochNumber, actualEpochNumber));
        (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournament.arbitrationResult();
        require(isFinished, TournamentNotFinishedYet());

        // Seal current accumulating epoch
        _epochNumber = ++epochNumber;
        uint256 inputIndexLowerBound = _inputIndexUpperBound;
        _inputIndexLowerBound = inputIndexLowerBound;
        uint256 inputIndexUpperBound = _inputBox.getNumberOfInputs(_appContract);
        _inputIndexUpperBound = inputIndexUpperBound;
        ITournament tournament = _tournamentFactory.instantiate(finalMachineStateHash, this);
        _tournament = tournament;
        emit EpochSealed(epochNumber, inputIndexLowerBound, inputIndexUpperBound, finalMachineStateHash, tournament);
    }

    function getCurrentSealedEpoch()
        external
        view
        returns (
            uint256 epochNumber,
            uint256 inputIndexLowerBound,
            uint256 inputIndexUpperBound,
            ITournament tournament
        )
    {
        epochNumber = _epochNumber;
        inputIndexLowerBound = _inputIndexLowerBound;
        inputIndexUpperBound = _inputIndexUpperBound;
        tournament = _tournament;
    }

    function getInputBox() external view returns (IInputBox) {
        return _inputBox;
    }

    function getApplicationContract() external view returns (address) {
        return _appContract;
    }

    function getTournamentFactory() external view returns (ITournamentFactory) {
        return _tournamentFactory;
    }

    /// @inheritdoc IDataProvider
    function provideMerkleRootOfInput(uint256 inputIndexWithinEpoch, bytes calldata input)
        external
        view
        override
        returns (bytes32)
    {
        uint256 inputIndex = _inputIndexLowerBound + inputIndexWithinEpoch;

        if (inputIndex >= _inputIndexUpperBound) {
            // out-of-bounds index: repeat the state (as a fixpoint function)
            return bytes32(0);
        }

        bytes32 calculatedInputHash = keccak256(input);
        bytes32 realInputHash = _inputBox.getInputHash(_appContract, inputIndex);
        require(calculatedInputHash == realInputHash, InputHashMismatch(calculatedInputHash, realInputHash));

        uint256 log2SizeOfDrive = input.getMinLog2SizeOfDrive();
        return input.getMerkleRootFromBytes(log2SizeOfDrive);
    }
}
