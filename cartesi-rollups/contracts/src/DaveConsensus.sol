// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {ERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/IERC165.sol";

import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-2.1.0-alpha.3/src/consensus/IOutputsMerkleRootValidator.sol";
import {IInputBox} from "cartesi-rollups-contracts-2.1.0-alpha.3/src/inputs/IInputBox.sol";
import {LibMerkle32} from "cartesi-rollups-contracts-2.1.0-alpha.3/src/library/LibMerkle32.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {IDaveConsensus} from "./IDaveConsensus.sol";
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
contract DaveConsensus is IDaveConsensus, ERC165 {
    using Merkle for bytes;
    using LibMerkle32 for bytes32[];

    /// @notice The input box contract
    IInputBox immutable _INPUT_BOX;

    /// @notice The application contract
    address immutable _APP_CONTRACT;

    /// @notice The contract used to instantiate tournaments
    ITournamentFactory immutable _TOURNAMENT_FACTORY;

    /// @notice Deployment block number
    uint256 immutable _DEPLOYMENT_BLOCK_NUMBER = block.number;

    /// @notice Current sealed epoch number
    uint256 _epochNumber;

    /// @notice Input index (inclusive) lower bound of the current sealed epoch
    uint256 _inputIndexLowerBound;

    /// @notice Input index (exclusive) upper bound of the current sealed epoch
    uint256 _inputIndexUpperBound;

    /// @notice Current sealed epoch tournament
    ITournament _tournament;

    /// @notice Settled output trees' merkle root hash
    mapping(bytes32 => bool) _outputsMerkleRoots;

    constructor(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash
    ) {
        // Initialize immutable variables
        _INPUT_BOX = inputBox;
        _APP_CONTRACT = appContract;
        _TOURNAMENT_FACTORY = tournamentFactory;
        emit ConsensusCreation(inputBox, appContract, tournamentFactory);

        // Initialize first sealed epoch
        uint256 inputIndexUpperBound = inputBox.getNumberOfInputs(appContract);
        _inputIndexUpperBound = inputIndexUpperBound;
        ITournament tournament = tournamentFactory.instantiate(initialMachineStateHash, this);
        _tournament = tournament;
        emit EpochSealed(0, 0, inputIndexUpperBound, initialMachineStateHash, bytes32(0), tournament);
    }

    function canSettle()
        external
        view
        override
        returns (bool isFinished, uint256 epochNumber, Tree.Node winnerCommitment)
    {
        (isFinished, winnerCommitment,) = _tournament.arbitrationResult();
        epochNumber = _epochNumber;
    }

    function settle(uint256 epochNumber, bytes32 outputsMerkleRoot, bytes32[] calldata proof) external override {
        // Check tournament settlement
        require(epochNumber == _epochNumber, IncorrectEpochNumber(epochNumber, _epochNumber));

        // Check tournament finished
        (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournament.arbitrationResult();
        require(isFinished, TournamentNotFinishedYet());
        ITournament oldTournament = _tournament;
        _tournament = ITournament(address(0));

        // Check outputs Merkle root
        _validateOutputTree(finalMachineStateHash, outputsMerkleRoot, proof);

        // Seal current accumulating epoch, save settled output tree
        _epochNumber++;
        _inputIndexLowerBound = _inputIndexUpperBound;
        _inputIndexUpperBound = _INPUT_BOX.getNumberOfInputs(_APP_CONTRACT);
        _outputsMerkleRoots[outputsMerkleRoot] = true;

        // Start new tournament
        _tournament = _TOURNAMENT_FACTORY.instantiate(finalMachineStateHash, this);

        emit EpochSealed(
            _epochNumber,
            _inputIndexLowerBound,
            _inputIndexUpperBound,
            finalMachineStateHash,
            outputsMerkleRoot,
            _tournament
        );

        oldTournament.tryRecoveringBond();
    }

    function getCurrentSealedEpoch()
        external
        view
        override
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

    function getInputBox() external view override returns (IInputBox) {
        return _INPUT_BOX;
    }

    function getApplicationContract() external view override returns (address) {
        return _APP_CONTRACT;
    }

    function getTournamentFactory() external view override returns (ITournamentFactory) {
        return _TOURNAMENT_FACTORY;
    }

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

        /// forge-lint: disable-next-line(asm-keccak256)
        bytes32 calculatedInputHash = keccak256(input);
        bytes32 realInputHash = _INPUT_BOX.getInputHash(_APP_CONTRACT, inputIndex);
        require(calculatedInputHash == realInputHash, InputHashMismatch(calculatedInputHash, realInputHash));

        uint256 log2SizeOfDrive = input.getMinLog2SizeOfDrive();
        return input.getMerkleRootFromBytes(log2SizeOfDrive);
    }

    function isOutputsMerkleRootValid(address appContract, bytes32 outputsMerkleRoot)
        public
        view
        override
        returns (bool)
    {
        require(_APP_CONTRACT == appContract, ApplicationMismatch(_APP_CONTRACT, appContract));
        return _outputsMerkleRoots[outputsMerkleRoot];
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IDataProvider).interfaceId
            || interfaceId == type(IOutputsMerkleRootValidator).interfaceId || super.supportsInterface(interfaceId);
    }

    function getDeploymentBlockNumber() external view override returns (uint256) {
        return _DEPLOYMENT_BLOCK_NUMBER;
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
}
