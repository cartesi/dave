// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/ERC165.sol";
import {SafeCast} from "@openzeppelin-contracts-5.2.0/utils/math/SafeCast.sol";

import {IOutputsMerkleRootValidator} from "cartesi-rollups-contracts-2.0.0/consensus/IOutputsMerkleRootValidator.sol";
import {IInputBox} from "cartesi-rollups-contracts-2.0.0/inputs/IInputBox.sol";
import {LibMerkle32} from "cartesi-rollups-contracts-2.0.0/library/LibMerkle32.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournament.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

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
contract DaveConsensus is IDataProvider, IOutputsMerkleRootValidator, ERC165 {
    using Merkle for bytes;
    using Merkle for uint256;
    using LibMerkle32 for bytes32[];
    using SafeCast for uint256;

    struct SealedEpoch {
        uint64 number;
        uint64 inputIndexLowerBound;
        uint64 inputIndexUpperBound;
        ITournament tournament;
    }

    /// @notice The input box contract
    IInputBox immutable _inputBox;

    /// @notice The application contract
    address immutable _appContract;

    /// @notice The contract used to instantiate tournaments
    ITournamentFactory immutable _tournamentFactory;

    /// @notice The current sealed epoch
    SealedEpoch _epoch;

    /// @notice Settled output trees' merkle root hash
    mapping(bytes32 => bool) _outputsMerkleRoots;

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
    /// @param outputsMerkleRoot the Merkle root hash of the outputs tree
    /// @param tournament the sealed epoch tournament contract
    event EpochSealed(
        uint256 epochNumber,
        uint256 inputIndexLowerBound,
        uint256 inputIndexUpperBound,
        Machine.Hash initialMachineStateHash,
        bytes32 outputsMerkleRoot,
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

    /// @notice Supplied output tree proof not consistent with settled machine hash
    /// @param settledState Settled machine state hash
    error InvalidOutputsMerkleRootProof(Machine.Hash settledState);

    /// @notice Supplied output tree proof size is incorrect
    /// @param suppliedProofSize Supplied proof size
    error InvalidOutputsMerkleRootProofSize(uint256 suppliedProofSize);

    /// @notice Application address does not match
    /// @param expected Expected application address
    /// @param received Received application address
    error ApplicationMismatch(address expected, address received);

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

        // Seal first epoch
        _sealEpoch(0, 0, initialMachineStateHash, bytes32(0));
    }

    function canSettle() external view returns (bool isFinished, uint256 epochNumber, Tree.Node winnerCommitment) {
        (isFinished, winnerCommitment,) = _epoch.tournament.arbitrationResult();
        epochNumber = _epoch.number;
    }

    function settle(uint256 epochNumber, bytes32 outputsMerkleRoot, bytes32[] calldata proof) external {
        // Get current sealed epoch
        SealedEpoch memory epoch = _epoch;

        // Check epoch number
        require(epochNumber == epoch.number, IncorrectEpochNumber(epochNumber, epoch.number));

        // Check tournament finished
        (bool isFinished,, Machine.Hash finalMachineStateHash) = epoch.tournament.arbitrationResult();
        require(isFinished, TournamentNotFinishedYet());
        _epoch.tournament = ITournament(address(0));

        // Check outputs Merkle root
        _validateOutputTree(finalMachineStateHash, outputsMerkleRoot, proof);

        // Seal current accumulating epoch
        _sealEpoch(epoch.number + 1, epoch.inputIndexUpperBound, finalMachineStateHash, outputsMerkleRoot);

        // Save settled output tree
        _outputsMerkleRoots[outputsMerkleRoot] = true;
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
        epochNumber = _epoch.number;
        inputIndexLowerBound = _epoch.inputIndexLowerBound;
        inputIndexUpperBound = _epoch.inputIndexUpperBound;
        tournament = _epoch.tournament;
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
        uint256 inputIndex = uint256(_epoch.inputIndexLowerBound) + inputIndexWithinEpoch;

        if (inputIndex >= _epoch.inputIndexUpperBound) {
            // out-of-bounds index: repeat the state (as a fixpoint function)
            return bytes32(0);
        }

        bytes32 calculatedInputHash = keccak256(input);
        bytes32 realInputHash = _inputBox.getInputHash(_appContract, inputIndex);
        require(calculatedInputHash == realInputHash, InputHashMismatch(calculatedInputHash, realInputHash));

        uint256 log2SizeOfDrive = input.length.getMinLog2SizeOfDriveLength();
        return input.getMerkleRootFromBytes(log2SizeOfDrive);
    }

    /// @inheritdoc IOutputsMerkleRootValidator
    function isOutputsMerkleRootValid(address appContract, bytes32 outputsMerkleRoot)
        public
        view
        override
        returns (bool)
    {
        require(_appContract == appContract, ApplicationMismatch(_appContract, appContract));
        return _outputsMerkleRoots[outputsMerkleRoot];
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IDataProvider).interfaceId
            || interfaceId == type(IOutputsMerkleRootValidator).interfaceId || super.supportsInterface(interfaceId);
    }

    function _validateOutputTree(
        Machine.Hash finalMachineStateHash,
        bytes32 outputsMerkleRoot,
        bytes32[] calldata proof
    ) internal pure {
        bytes32 machineStateHash = Machine.Hash.unwrap(finalMachineStateHash);

        require(proof.length == Memory.LOG2_MAX_SIZE, InvalidOutputsMerkleRootProofSize(proof.length));
        bytes32 allegedStateHash = proof.merkleRootAfterReplacement(
            EmulatorConstants.PMA_CMIO_TX_BUFFER_START >> EmulatorConstants.TREE_LOG2_WORD_SIZE,
            keccak256(abi.encode(outputsMerkleRoot))
        );

        require(machineStateHash == allegedStateHash, InvalidOutputsMerkleRootProof(finalMachineStateHash));
    }

    function _sealEpoch(
        uint64 number,
        uint64 inputIndexLowerBound,
        Machine.Hash initialMachineStateHash,
        bytes32 outputsMerkleRoot
    ) internal {
        uint256 inputIndexUpperBound = _inputBox.getNumberOfInputs(_appContract);
        ITournament tournament = _tournamentFactory.instantiate(initialMachineStateHash, this);

        _epoch = SealedEpoch({
            number: number,
            inputIndexLowerBound: inputIndexLowerBound,
            inputIndexUpperBound: inputIndexUpperBound.toUint64(),
            tournament: tournament
        });

        emit EpochSealed(
            number, inputIndexLowerBound, inputIndexUpperBound, initialMachineStateHash, outputsMerkleRoot, tournament
        );
    }
}
