// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {
    IOutputsMerkleRootValidator
} from "cartesi-rollups-contracts-2.2.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {IInputBox} from "cartesi-rollups-contracts-2.2.0/src/inputs/IInputBox.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";

import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";

import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

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
interface IDaveConsensus is IDataProvider, IOutputsMerkleRootValidator {
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

    /// @notice Get the number of base-layer block in which the contract was deployed.
    function getDeploymentBlockNumber() external view returns (uint256);

    /// @notice Get the input box contract used as data availability by the application.
    function getInputBox() external view returns (IInputBox);

    /// @notice Get the address of the application contract.
    function getApplicationContract() external view returns (address);

    /// @notice Get the tournament factory contract used to instantiate root tournaments.
    function getTournamentFactory() external view returns (ITournamentFactory);

    /// @notice Get the current sealed epoch number, boundaries, and tournament.
    /// @param epochNumber The epoch number
    /// @param inputIndexLowerBound The epoch input index (inclusive) lower bound
    /// @param inputIndexUpperBound The epoch input index (exclusive) upper bound
    /// @param tournament The tournament that will decide the post-epoch state
    function getCurrentSealedEpoch()
        external
        view
        returns (
            uint256 epochNumber,
            uint256 inputIndexLowerBound,
            uint256 inputIndexUpperBound,
            ITournament tournament
        );

    /// @notice Check whether the current sealed epoch can be settled.
    /// @return isFinished Whether the current sealed epoch tournament has finished yet
    /// @return epochNumber The current sealed epoch number
    /// @return winnerCommitment If the tournament has finished, the winning commitment
    function canSettle() external view returns (bool isFinished, uint256 epochNumber, Tree.Node winnerCommitment);

    /// @notice Settle the current sealed epoch.
    /// @param epochNumber The current sealed epoch number (used to avoid race conditions)
    /// @param outputsMerkleRoot The post-epoch outputs Merkle root (used to validate outputs)
    /// @param proof The bottom-up Merkle proof of the outputs Merkle root in the final machine state
    /// @dev On success, emits an `EpochSealed` event.
    function settle(uint256 epochNumber, bytes32 outputsMerkleRoot, bytes32[] calldata proof) external;
}
