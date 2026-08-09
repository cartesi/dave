// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {BinaryMerkleTreeErrors} from "cartesi-rollups-contracts-3.0.0/src/common/BinaryMerkleTreeErrors.sol";
import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {IApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationChecker.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {ISentryErrors} from "./ISentryErrors.sol";

/// @notice Consensus contract with Dave tournaments.
///
/// @notice This contract validates only one application,
/// which read inputs from the InputBox contract.
///
/// @notice This contract also manages epoch boundaries, which
/// are defined in terms of input indices. We represent them
/// as intervals of the form [a,b). They are also identified by
/// incremental numbers that start from 0.
///
/// @notice Off-chain nodes can listen to `EpochSealed` events
/// to know where epochs start and end, and which epochs have been
/// settled already and which one is open for challenges still.
/// Anyone can stage a tournament result by calling `stageTournamentResult`.
/// One can also check if it can be staged by calling `canStageTournamentResult`.
/// Sentries can submit claims for the post-epoch machine state hash
/// in order to speed up epoch settlement (by skipping the claim staging period).
/// Anyone can settle an epoch by calling `acceptStagedTournamentResult`.
/// One can also check if it can be settled by calling `canAcceptStagedTournamentResult`.
///
/// @notice At any given time, there is always one sealed epoch.
/// Prior to it, every epoch has been settled.
/// After it, the next epoch is accumulating inputs. Once this epoch is settled,
/// the accumulating epoch will be sealed, and a new
/// accumulating epoch will be created.
/// Every sealed epoch has an associated tournament.
/// Once a tournament is finished, and a winner commitment is declared,
/// it can then be staged by anyone. After the claim staging period is elapsed,
/// or all sentries (if there is any) agree with the staged tournament result,
/// anyone can settle the epoch by accepting the staged winner commitment.
///
interface IDaveConsensus is
    IDataProvider,
    IOutputsMerkleRootValidator,
    IApplicationChecker,
    BinaryMerkleTreeErrors,
    ISentryErrors
{
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
        uint256 indexed epochNumber,
        uint256 inputIndexLowerBound,
        uint256 inputIndexUpperBound,
        Machine.Hash initialMachineStateHash,
        bytes32 outputsMerkleRoot,
        ITournament tournament
    );

    /// @notice A sentry has claimed the post-epoch machine state hash.
    /// @param epochNumber The epoch number
    /// @param sentryId The sentry ID
    /// @param sentry The sentry address
    /// @param postEpochMachineStateHash The post-epoch machine state hash
    event SentryClaim(
        uint256 indexed epochNumber,
        uint256 indexed sentryId,
        address indexed sentry,
        Machine.Hash postEpochMachineStateHash
    );

    /// @notice An epoch was staged
    /// @param epochNumber the sealed epoch number
    /// @param stagedPostEpochMachineStateHash The staged post-epoch machine state hash
    /// @param stagedPostEpochOutputsMerkleRoot The staged post-epoch outputs Merkle root
    event EpochStaged(
        uint256 indexed epochNumber,
        Machine.Hash stagedPostEpochMachineStateHash,
        bytes32 stagedPostEpochOutputsMerkleRoot
    );

    /// @notice The sentry manager rotated a sentry.
    /// @param sentryId The sentry ID
    /// @param oldSentry The old sentry address
    /// @param newSentry The new sentry address
    /// @dev It is guaranteed that, in the instant right before the rotation,
    /// `getSentryId(oldSentry) == sentryId`, `getSentryId(newSentry) == 0`, and `getSentryById(sentryId) == oldSentry`.
    /// And, in the instant right after the rotation, it is also guaranteed that
    /// `getSentryId(oldSentry) == 0`, `getSentryId(newSentry) == sentryId`, and `getSentryById(sentryId) == newSentry`.
    /// Furthermore, the number of sentries is unchanged all other sentries keep their IDs and addresses.
    event SentryRotation(uint256 indexed sentryId, address indexed oldSentry, address indexed newSentry);

    /// @notice Received epoch number is different from actual
    /// @param received The epoch number received as argument
    /// @param actual The actual epoch number in storage
    error IncorrectEpochNumber(uint256 received, uint256 actual);

    /// @notice Tournament is not finished yet
    error TournamentNotFinishedYet();

    /// @notice Tournament result is not yet staged
    error TournamentResultNotStaged();

    /// @notice Tournament result was already staged
    error TournamentResultAlreadyStaged();

    /// @notice The tournament result was staged but the claim staging period is not over yet.
    /// @param numberOfBlocksAfterStaging The number of blocks since the claim was staged
    /// @param claimStagingPeriod The claim staging period, in number of blocks
    error ClaimStagingPeriodNotOverYet(uint256 numberOfBlocksAfterStaging, uint256 claimStagingPeriod);

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

    /// @notice This error is raised whenever the `submitSentryClaim`
    /// function is called by someone who is not a sentry.
    /// @param caller The caller address
    error CallerIsNotSentry(address caller);

    /// @notice This error is raised whenever a sentry attempts to call the
    /// `submitSentryClaim` function twice for the same epoch.
    /// @param epochNumber The epoch number
    /// @param sentryId The sentry ID
    error SentryAlreadyClaimed(uint256 epochNumber, uint256 sentryId);

    /// @notice This error is raised whenever the `rotateSentry`
    /// function is called by someone who is not the sentry manager.
    /// @param caller The caller address
    error CallerIsNotSentryManager(address caller);

    /// @notice This error is raised whenever the `rotateSentry`
    /// function is called with a non-sentry address as `currentSentry`.
    /// @param nonSentry The non-sentry address
    error CannotRotateNonSentry(address nonSentry);

    /// @notice Get the number of base-layer block in which the contract was deployed.
    function getDeploymentBlockNumber() external view returns (uint256);

    /// @notice Get the input box contract used as data availability by the application.
    function getInputBox() external view returns (IInputBox);

    /// @notice Get the address of the application contract.
    function getApplicationContract() external view returns (address);

    /// @notice Get the tournament factory contract used to instantiate root tournaments.
    function getTournamentFactory() external view returns (ITournamentFactory);

    /// @notice Get the number of base-layer blocks after which a staged claim can be accepted.
    /// @dev A claim, in the context of PRT, is the winner commitment of a tournament, if there is one.
    /// Once a tournament finishes, and a winner is declared, anyone can stage the tournament result.
    /// After all sentries agree with the staged claim or after the claim staging period is elapsed,
    /// anyone can accept the staged claim into finality. If there are no sentries, then acceptance
    /// can only occur after the claim staging period is elapsed.
    function getClaimStagingPeriod() external view returns (uint256);

    /// @notice Get the number of sentries.
    /// @dev This number can be zero, that is, there are no sentries.
    function getNumberOfSentries() external view returns (uint256);

    /// @notice Get the sentry manager address.
    /// @dev The sentry manager is the only one capable of rotating sentries.
    function getSentryManager() external view returns (address);

    /// @notice Get the ID of a sentry.
    /// @param sentry The sentry address
    /// @dev Sentries are assigned IDs between 1 and `N`, the total number of sentries.
    /// @dev Non-sentries are assigned to ID zero.
    function getSentryId(address sentry) external view returns (uint256);

    /// @notice Get the address of a sentry by its ID.
    /// @param sentryId The sentry ID
    /// @dev Sentry IDs range from 1 to `N`, the total number of sentries.
    /// @dev Valid IDs do not map to address zero.
    /// @dev Invalid IDs map to address zero.
    function getSentryById(uint256 sentryId) external view returns (address);

    /// @notice Check whether a sentry has claimed any post-epoch machine state in a given epoch.
    /// @param epochNumber The epoch number
    /// @param sentryId The sentry ID
    /// @dev You can obtain the ID of a sentry by its address through the `getSentryId` function
    /// or the address of a sentry by its ID through the `getSentryById` function.
    function hasSentryClaimedInEpoch(uint256 epochNumber, uint256 sentryId) external view returns (bool);

    /// @notice Get the number of sentries that have claimed a given post-epoch machine state in a given epoch.
    /// @param epochNumber The epoch number
    /// @param postEpochMachineStateHash The post-epoch machine state hash
    function getSentryClaimCount(uint256 epochNumber, Machine.Hash postEpochMachineStateHash)
        external
        view
        returns (uint256);

    /// @notice As a sentry manager, rotate a sentry.
    /// @param currentSentry The current sentry address
    /// @param newSentry The new sentry address that will inherit the current sentry's ID
    /// @dev This action can be useful whenever a sentry account is compromised.
    /// A compromised sentry may either purposefully submit false post-epoch machine state hashes
    /// or drain the funds from the sentry account. In either case, the epoch settlement is delayed
    /// by the claim staging period, which is undesired for application users and maintainers.
    /// In those cases, the sentry manager can rotate the address of the compromised sentry slot,
    /// ensuring epochs settle earlier in the happy path through sentry claims.
    /// If a sentry has already claimed in the current sealed epoch, then rotating their address
    /// will not erase their claim. Rather, rotation only updates the address that is authorized
    /// to claim for that sentry slot. So, if that sentry slot has already placed a claim, then the
    /// new sentry will only be able to submit a claim for the next epoch.
    /// On success, emits a `SentryRotation` event.
    function rotateSentry(address currentSentry, address newSentry) external;

    /// @notice Get the current sealed epoch number, boundaries, tournament, and staging info.
    /// @return epochNumber The epoch number
    /// @return inputIndexLowerBound The epoch input index (inclusive) lower bound
    /// @return inputIndexUpperBound The epoch input index (exclusive) upper bound
    /// @return tournament The tournament that will decide the post-epoch state
    /// @return isTournamentResultStaged Whether the tournament result (if there is one) is staged
    /// @return stagingBlockNumber The number of the block in which the tournament result was staged
    /// @return stagedPostEpochMachineStateHash The staged post-epoch machine state hash
    /// @return stagedPostEpochOutputsMerkleRoot The staged post-epoch outputs Merkle root
    /// @dev The values of stagingBlockNumber, stagedPostEpochMachineStateHash, and stagedPostEpochOutputsMerkleRoot
    /// only have meaning if the value of isTournamentResultStaged is true.
    function getCurrentSealedEpoch()
        external
        view
        returns (
            uint256 epochNumber,
            uint256 inputIndexLowerBound,
            uint256 inputIndexUpperBound,
            ITournament tournament,
            bool isTournamentResultStaged,
            uint256 stagingBlockNumber,
            Machine.Hash stagedPostEpochMachineStateHash,
            bytes32 stagedPostEpochOutputsMerkleRoot
        );

    /// @notice Check whether the tournament result of the current sealed epoch can be staged.
    /// @return isFinished Whether the current sealed epoch tournament is finished
    /// @return isTournamentResultStaged Whether the tournament result (if there is one) is staged
    /// @return epochNumber The current sealed epoch number
    /// @return winnerCommitment If the tournament has finished, the winner commitment
    /// @return winnerPostEpochMachineStateHash If the tournament has finished, the winner post-epoch machine state hash
    /// @dev Validators should only call `stageTournamentResult` if isFinished is true and isTournamentResultStaged is false.
    function canStageTournamentResult()
        external
        view
        returns (
            bool isFinished,
            bool isTournamentResultStaged,
            uint256 epochNumber,
            Tree.Node winnerCommitment,
            Machine.Hash winnerPostEpochMachineStateHash
        );

    /// @notice Stage the tournament result of the current sealed epoch.
    /// @param epochNumber The current sealed epoch number (used to avoid race conditions)
    /// @param outputsMerkleRoot The post-epoch outputs Merkle root (used to validate outputs)
    /// @param proof The bottom-up Merkle proof of the outputs Merkle root in the final machine state
    /// @dev On success, stores the staged result and emits an `EpochStaged`
    /// event. Bond recovery is a separate permissionless action on the
    /// tournament and cannot affect staging.
    function stageTournamentResult(uint256 epochNumber, bytes32 outputsMerkleRoot, bytes32[] calldata proof) external;

    /// @notice As a sentry, claim the post-epoch machine state hash for the current sealed epoch.
    /// If all sentries claim the same post-epoch machine state hash as the staged tournament result,
    /// then the claim staging period is skipped entirely, potentially shortening the finality delay.
    /// Note that this skipping is only possible if the consensus has at least one sentry.
    /// @param epochNumber The current sealed epoch number (used to avoid race conditions)
    /// @param postEpochMachineStateHash The post-epoch machine state hash
    /// @dev On success, emits a `SentryClaim` event.
    function submitSentryClaim(uint256 epochNumber, Machine.Hash postEpochMachineStateHash) external;

    /// @notice Check whether the staged tournament result of the current sealed epoch can be accepted.
    /// @return isTournamentResultStaged Whether the tournament result (if there is one) is staged
    /// @return doAllSentriesAgreeWithStagedTournamentResult Whether all sentries agree with staged tournament result
    /// @return isClaimStagingPeriodOver Whether the claim staging period is over
    /// @return epochNumber The current sealed epoch number
    /// @return stagedPostEpochMachineStateHash If the tournament result is staged, the staged post-epoch machine state hash
    /// @return stagedPostEpochOutputsMerkleRoot If the tournament result is staged, the staged post-epoch outputs Merkle root
    /// @dev Validators should only call `acceptStagedTournamentResult` if the Boolean expression isTournamentResultStaged
    /// AND (doAllSentriesAgreeWithStagedTournamentResult OR isClaimStagingPeriodOver) is true. Be also mindful that
    /// doAllSentriesAgreeWithStagedTournamentResult, isClaimStagingPeriodOver, stagedPostEpochMachineStateHash, and
    /// stagedPostEpochOutputsMerkleRoot only have any meaning if isTournamentResultStaged is true.
    function canAcceptStagedTournamentResult()
        external
        view
        returns (
            bool isTournamentResultStaged,
            bool doAllSentriesAgreeWithStagedTournamentResult,
            bool isClaimStagingPeriodOver,
            uint256 epochNumber,
            Machine.Hash stagedPostEpochMachineStateHash,
            bytes32 stagedPostEpochOutputsMerkleRoot
        );

    /// @notice Accept the staged tournament result of the current sealed epoch.
    /// @param epochNumber The current sealed epoch number (used to avoid race conditions)
    /// @dev On success, emits an `EpochSealed` event.
    function acceptStagedTournamentResult(uint256 epochNumber) external;
}
