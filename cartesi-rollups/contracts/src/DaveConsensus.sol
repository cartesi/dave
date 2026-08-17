// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {ERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin-contracts-5.2.0/utils/introspection/IERC165.sol";
import {BitMaps} from "@openzeppelin-contracts-5.2.0/utils/structs/BitMaps.sol";

import {IOutputsMerkleRootValidator} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
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
    using BitMaps for BitMaps.BitMap;
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

    /// @notice The account that is authorized to manage sentry rotations.
    /// @notice See the `getSentryManager` function.
    address immutable _SENTRY_MANAGER;

    /// @notice The total number of sentries.
    /// @notice See the `getNumberOfSentries` function.
    uint256 immutable _NUM_OF_SENTRIES;

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

    /// @notice Sentry IDs indexed by address.
    /// @notice See the `getSentryId` function.
    /// @dev Non-sentries are assigned to ID zero.
    /// @dev Sentries have IDs greater than zero.
    mapping(address => uint256) private _sentryId;

    /// @notice Sentry addresses indexed by ID.
    /// @notice See the `getSentryById` function.
    /// @dev Invalid IDs map to address zero.
    mapping(uint256 => address) private _sentryById;

    /// @notice A mapping that keeps track of which sentries have claimed in any given epoch.
    /// @notice See the `hasSentryClaimedInEpoch` function.
    mapping(uint256 => BitMaps.BitMap) private _epochClaimBitMap;

    /// @notice A mapping that keeps track of post-epoch machine state hash claim counts per epoch.
    /// @notice See the `getSentryClaimCount` function.
    mapping(uint256 => mapping(Machine.Hash => uint256)) private _claimCount;

    constructor(
        IInputBox inputBox,
        address appContract,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash,
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] memory sentries
    ) {
        // Initialize immutable variables
        _INPUT_BOX = inputBox;
        _APP_CONTRACT = appContract;
        _TOURNAMENT_FACTORY = tournamentFactory;
        _CLAIM_STAGING_PERIOD = claimStagingPeriod;
        _SENTRY_MANAGER = sentryManager;
        for (uint256 i; i < sentries.length; ++i) {
            address sentry = sentries[i];
            _ensureSentryAddressIsValid(sentry);
            uint256 sentryId = ++_NUM_OF_SENTRIES;
            _sentryId[sentry] = sentryId;
            _sentryById[sentryId] = sentry;
        }
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
        (isFinished, winnerCommitment, winnerPostEpochMachineStateHash) = _tournamentResult(_tournament);
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
        (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournamentResult(_tournament);
        require(isFinished, TournamentNotFinishedYet());

        // Check outputs Merkle root
        _validateOutputTree(finalMachineStateHash, outputsMerkleRoot, proof);

        // Stage tournament result, and store the current block number for
        // later checking whether the claim staging period has elapsed.
        // Staging moves no value: bond recovery is a separate, explicit,
        // permissionless call on the retired tournament.
        _stagingBlockNumber = block.number;
        _stagedPostEpochMachineStateHash = finalMachineStateHash;
        _stagedPostEpochOutputsMerkleRoot = outputsMerkleRoot;
        _isTournamentResultStaged = true;

        emit EpochStaged(epochNumber, finalMachineStateHash, outputsMerkleRoot);
    }

    function submitSentryClaim(uint256 epochNumber, Machine.Hash postEpochMachineStateHash)
        external
        override
        notForeclosed(_APP_CONTRACT)
    {
        // Check whether caller is authorized
        address caller = msg.sender;
        uint256 sentryId = getSentryId(caller);
        require(sentryId > 0, CallerIsNotSentry(caller));

        // Check epoch settlement
        require(epochNumber == _epochNumber, IncorrectEpochNumber(epochNumber, _epochNumber));

        // Check whether sentry has claimed in epoch already
        BitMaps.BitMap storage epochClaimBitMap = _epochClaimBitMap[epochNumber];
        require(!epochClaimBitMap.get(sentryId), SentryAlreadyClaimed(epochNumber, sentryId));

        // Mark epoch as claimed (for sentry) and increment claim count for post-epoch state hash
        epochClaimBitMap.set(sentryId);
        ++_claimCount[epochNumber][postEpochMachineStateHash];

        // Emit sentry claim event so that off-chain components can update their tallies
        emit SentryClaim(epochNumber, sentryId, caller, postEpochMachineStateHash);
    }

    function canAcceptStagedTournamentResult()
        external
        view
        override
        returns (
            bool isTournamentResultStaged,
            bool doAllSentriesAgreeWithStagedTournamentResult,
            bool isClaimStagingPeriodOver,
            uint256 epochNumber,
            Machine.Hash stagedPostEpochMachineStateHash,
            bytes32 stagedPostEpochOutputsMerkleRoot
        )
    {
        epochNumber = _epochNumber;
        isTournamentResultStaged = _isTournamentResultStaged;
        if (_isTournamentResultStaged) {
            doAllSentriesAgreeWithStagedTournamentResult = _doAllSentriesAgreeWithStagedTournamentResult();
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
        // if not all sentries agree with the staged tournament result
        if (!_doAllSentriesAgreeWithStagedTournamentResult()) {
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

    function rotateSentry(address currentSentry, address newSentry)
        external
        override
        onlySentryManager
        notForeclosed(_APP_CONTRACT)
    {
        uint256 sentryId = getSentryId(currentSentry);
        require(sentryId > 0, CannotRotateNonSentry(currentSentry));
        _ensureSentryAddressIsValid(newSentry);
        _sentryId[currentSentry] = 0;
        _sentryId[newSentry] = sentryId;
        _sentryById[sentryId] = newSentry;
        emit SentryRotation(sentryId, currentSentry, newSentry);
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

    function getSentryManager() external view override returns (address) {
        return _SENTRY_MANAGER;
    }

    function getNumberOfSentries() external view override returns (uint256) {
        return _NUM_OF_SENTRIES;
    }

    function getSentryId(address sentry) public view override returns (uint256) {
        return _sentryId[sentry];
    }

    function getSentryById(uint256 sentryId) external view override returns (address) {
        return _sentryById[sentryId];
    }

    function hasSentryClaimedInEpoch(uint256 epochNumber, uint256 sentryId) external view override returns (bool) {
        return _epochClaimBitMap[epochNumber].get(sentryId);
    }

    function getSentryClaimCount(uint256 epochNumber, Machine.Hash postEpochMachineStateHash)
        external
        view
        override
        returns (uint256)
    {
        return _claimCount[epochNumber][postEpochMachineStateHash];
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
        return interfaceId == type(IDaveConsensus).interfaceId || interfaceId == type(IDataProvider).interfaceId
            || interfaceId == type(IOutputsMerkleRootValidator).interfaceId || super.supportsInterface(interfaceId);
    }

    function getDeploymentBlockNumber() external view override returns (uint256) {
        return _DEPLOYMENT_BLOCK_NUMBER;
    }

    /// @notice Read the root tournament's result through its typed standing.
    /// @dev A failed root (finished without a winner) reverts, preserving the
    /// staging posture: such an epoch cannot be settled from this tournament.
    function _tournamentResult(ITournament tournament)
        internal
        view
        returns (bool finished, Tree.Node winnerCommitment, Machine.Hash finalMachineStateHash)
    {
        ITournament.TournamentStandingView memory standing = tournament.tournamentStanding();
        if (standing.standing == ITournament.TournamentStanding.ROOT_WINNER) {
            return (true, standing.candidate, standing.finalState);
        } else if (standing.standing == ITournament.TournamentStanding.ROOT_FAILED) {
            revert ITournament.TournamentFailedNoWinner();
        } else {
            return (false, Tree.ZERO_NODE, Machine.ZERO_STATE);
        }
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

    function _doAllSentriesAgreeWithStagedTournamentResult() internal view returns (bool) {
        return _NUM_OF_SENTRIES > 0 && _claimCount[_epochNumber][_stagedPostEpochMachineStateHash] == _NUM_OF_SENTRIES;
    }

    modifier onlyValidAppContract(address appContract) {
        _ensureAppContractIsValid(appContract);
        _;
    }

    modifier onlySentryManager() {
        _ensureCallerIsSentryManager();
        _;
    }

    function _ensureAppContractIsValid(address appContract) internal view {
        require(_APP_CONTRACT == appContract, ApplicationMismatch(_APP_CONTRACT, appContract));
    }

    function _ensureSentryAddressIsValid(address sentry) internal view {
        require(sentry != address(0), ZeroSentryAddress());
        uint256 sentryId = getSentryId(sentry);
        require(sentryId == 0, DuplicatedSentryAddress(sentryId, sentry));
    }

    function _ensureCallerIsSentryManager() internal view {
        address caller = msg.sender;
        require(caller == _SENTRY_MANAGER, CallerIsNotSentryManager(caller));
    }
}
