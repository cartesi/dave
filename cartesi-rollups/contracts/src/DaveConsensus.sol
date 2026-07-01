// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {ERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/IERC165.sol";

import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {ApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/ApplicationChecker.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {LibBinaryMerkleTree} from "cartesi-rollups-contracts-3.0.0/src/library/LibBinaryMerkleTree.sol";
import {LibKeccak256} from "cartesi-rollups-contracts-3.0.0/src/library/LibKeccak256.sol";
import {LibMath} from "cartesi-rollups-contracts-3.0.0/src/library/LibMath.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";
import {Memory} from "step/src/Memory.sol";

import {IDaveConsensus} from "./IDaveConsensus.sol";

contract DaveConsensus is IDaveConsensus, ERC165, ApplicationChecker {
    using LibMath for uint256;
    using LibBinaryMerkleTree for bytes;
    using LibBinaryMerkleTree for bytes32[];

    /// @notice The input box contract
    IInputBox immutable _INPUT_BOX;

    /// @notice The application contract
    address immutable _APP_CONTRACT;

    /// @notice The contract used to instantiate tournaments
    ITournamentFactory immutable _TOURNAMENT_FACTORY;

    /// @notice The claim staging period
    uint256 immutable _CLAIM_STAGING_PERIOD;

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

    /// @notice Whether the result of the current sealed epoch tournament is staged
    bool _isTournamentResultStaged;

    /// @notice The number of the block in which the tournament result was staged
    /// @dev Only meaningful if _isTournamentResultStaged is true.
    uint256 _stagingBlockNumber;

    /// @notice The staged post-epoch machine state hash
    /// @dev Only meaningful if _isTournamentResultStaged is true.
    Machine.Hash _stagedPostEpochMachineStateHash;

    /// @notice The staged post-epoch outputs Merkle root
    /// @dev Only meaningful if _isTournamentResultStaged is true.
    bytes32 _stagedPostEpochOutputsMerkleRoot;

    /// @notice Settled output trees' merkle root hash
    mapping(bytes32 => bool) _outputsMerkleRoots;

    /// @notice Last-finalized machine state hash
    Machine.Hash _lastFinalizedMachineStateHash;

    constructor(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash,
        uint256 claimStagingPeriod
    ) {
        // Initialize immutable variables
        _INPUT_BOX = inputBox;
        _APP_CONTRACT = appContract;
        _TOURNAMENT_FACTORY = tournamentFactory;
        _CLAIM_STAGING_PERIOD = claimStagingPeriod;
        emit ConsensusCreation(inputBox, appContract, tournamentFactory);

        // Initialize first sealed epoch
        uint256 inputIndexUpperBound = inputBox.getNumberOfInputs(appContract);
        _inputIndexUpperBound = inputIndexUpperBound;
        ITournament tournament = tournamentFactory.instantiate(initialMachineStateHash, this);
        _tournament = tournament;
        emit EpochSealed(0, 0, inputIndexUpperBound, initialMachineStateHash, bytes32(0), tournament);
    }

    function canStageTournamentResult()
        external
        view
        override
        returns (
            bool isFinished,
            bool isTournamentResultStaged,
            uint256 epochNumber,
            Tree.Node winnerCommitment,
            Machine.Hash winnerPostEpochMachineStateHash
        )
    {
        epochNumber = _epochNumber;
        isTournamentResultStaged = _isTournamentResultStaged;
        (isFinished, winnerCommitment, winnerPostEpochMachineStateHash) = _tournament.arbitrationResult();
    }

    function stageTournamentResult(uint256 epochNumber, bytes32 outputsMerkleRoot, bytes32[] calldata proof)
        external
        override
        notForeclosed(_APP_CONTRACT)
    {
        // Check tournament settlement
        require(epochNumber == _epochNumber, IncorrectEpochNumber(epochNumber, _epochNumber));

        // Check whether the tournament result is staged
        require(!_isTournamentResultStaged, TournamentResultAlreadyStaged());

        // Check tournament finished
        (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournament.arbitrationResult();
        require(isFinished, TournamentNotFinishedYet());

        // Check outputs Merkle root
        _validateOutputTree(finalMachineStateHash, outputsMerkleRoot, proof);

        // Stage tournament result, and store the current block number for
        // later checking whether the claim staging period has elapsed
        _stagingBlockNumber = block.number;
        _stagedPostEpochMachineStateHash = finalMachineStateHash;
        _stagedPostEpochOutputsMerkleRoot = outputsMerkleRoot;
        _isTournamentResultStaged = true;

        // Try recovering bond for tournament winner
        try _tournament.tryRecoveringBond() {} catch {}

        emit EpochStaged(epochNumber, finalMachineStateHash, outputsMerkleRoot);
    }

    function canAcceptStagedTournamentResult()
        external
        view
        override
        returns (
            bool isTournamentResultStaged,
            bool isClaimStagingPeriodOver,
            uint256 epochNumber,
            Machine.Hash stagedPostEpochMachineStateHash,
            bytes32 stagedPostEpochOutputsMerkleRoot
        )
    {
        epochNumber = _epochNumber;
        isTournamentResultStaged = _isTournamentResultStaged;
        if (_isTournamentResultStaged) {
            isClaimStagingPeriodOver = ((block.number - _stagingBlockNumber) >= _CLAIM_STAGING_PERIOD);
            stagedPostEpochMachineStateHash = _stagedPostEpochMachineStateHash;
            stagedPostEpochOutputsMerkleRoot = _stagedPostEpochOutputsMerkleRoot;
        }
    }

    function acceptStagedTournamentResult(uint256 epochNumber) external override notForeclosed(_APP_CONTRACT) {
        // Check tournament settlement
        require(epochNumber == _epochNumber, IncorrectEpochNumber(epochNumber, _epochNumber));

        // Check whether the tournament result is staged
        require(_isTournamentResultStaged, TournamentResultNotStaged());

        // Check whether the claim staging period has elapsed
        {
            uint256 numberOfBlocksAfterStaging = block.number - _stagingBlockNumber;
            require(
                numberOfBlocksAfterStaging >= _CLAIM_STAGING_PERIOD,
                ClaimStagingPeriodNotOverYet(numberOfBlocksAfterStaging, _CLAIM_STAGING_PERIOD)
            );
        }

        // Get staged tournament result
        Machine.Hash finalMachineStateHash = _stagedPostEpochMachineStateHash;
        bytes32 outputsMerkleRoot = _stagedPostEpochOutputsMerkleRoot;

        // Seal current accumulating epoch, save settled output tree and machine state hash
        _epochNumber++;
        _inputIndexLowerBound = _inputIndexUpperBound;
        _inputIndexUpperBound = _INPUT_BOX.getNumberOfInputs(_APP_CONTRACT);
        _outputsMerkleRoots[outputsMerkleRoot] = true;
        _lastFinalizedMachineStateHash = finalMachineStateHash;
        _isTournamentResultStaged = false;

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
    }

    function getCurrentSealedEpoch()
        external
        view
        override
        returns (
            uint256 epochNumber,
            uint256 inputIndexLowerBound,
            uint256 inputIndexUpperBound,
            ITournament tournament,
            bool isTournamentResultStaged,
            uint256 stagingBlockNumber,
            Machine.Hash stagedPostEpochMachineStateHash,
            bytes32 stagedPostEpochOutputsMerkleRoot
        )
    {
        epochNumber = _epochNumber;
        inputIndexLowerBound = _inputIndexLowerBound;
        inputIndexUpperBound = _inputIndexUpperBound;
        tournament = _tournament;
        isTournamentResultStaged = _isTournamentResultStaged;
        if (_isTournamentResultStaged) {
            stagingBlockNumber = _stagingBlockNumber;
            stagedPostEpochMachineStateHash = _stagedPostEpochMachineStateHash;
            stagedPostEpochOutputsMerkleRoot = _stagedPostEpochOutputsMerkleRoot;
        }
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

    function getClaimStagingPeriod() external view override returns (uint256) {
        return _CLAIM_STAGING_PERIOD;
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

        bytes32 calculatedInputHash = LibKeccak256.hashBytes(input);
        bytes32 realInputHash = _INPUT_BOX.getInputHash(_APP_CONTRACT, inputIndex);
        require(calculatedInputHash == realInputHash, InputHashMismatch(calculatedInputHash, realInputHash));

        uint256 log2DataBlockSize = Memory.LOG2_LEAF;
        uint256 log2DriveSize = input.length.ceilLog2().max(log2DataBlockSize);
        return input.merkleRoot(log2DriveSize, log2DataBlockSize, LibKeccak256.hashBlock, LibKeccak256.hashPair);
    }

    function isOutputsMerkleRootValid(address appContract, bytes32 outputsMerkleRoot)
        public
        view
        override
        onlyValidAppContract(appContract)
        returns (bool)
    {
        return _outputsMerkleRoots[outputsMerkleRoot];
    }

    function getLastFinalizedMachineMerkleRoot(address appContract)
        external
        view
        override
        onlyValidAppContract(appContract)
        returns (bytes32)
    {
        return Machine.Hash.unwrap(_lastFinalizedMachineStateHash);
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
            EmulatorConstants.AR_CMIO_TX_BUFFER_START >> EmulatorConstants.HASH_TREE_LOG2_WORD_SIZE,
            keccak256(abi.encode(outputsMerkleRoot)),
            LibKeccak256.hashPair
        );

        require(machineStateHash == allegedStateHash, InvalidOutputsMerkleRootProof(finalMachineStateHash));
    }

    modifier onlyValidAppContract(address appContract) {
        _ensureAppContractIsValid(appContract);
        _;
    }

    function _ensureAppContractIsValid(address appContract) internal view {
        require(_APP_CONTRACT == appContract, ApplicationMismatch(_APP_CONTRACT, appContract));
    }
}
