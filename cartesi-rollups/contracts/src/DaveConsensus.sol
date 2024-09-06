// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IInputBox} from "rollups-contracts/inputs/IInputBox.sol";
import {Inputs} from "rollups-contracts/common/Inputs.sol";
import {LibMerkle32} from "rollups-contracts/library/LibMerkle32.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/Machine.sol";

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
    using LibMerkle32 for bytes32[];

    /// @notice GIO namespace for getting advance requests from the InputBox contract
    uint16 constant INPUT_BOX_NAMESPACE = 0;

    /// @notice GIO response buffer size (2 MB)
    uint256 constant LOG2_GIO_RESPONSE_BUFFER_SIZE = 21;

    /// @notice The input box contract
    IInputBox _inputBox;

    /// @notice The application contract
    address immutable _appContract;

    /// @notice The contract used to instantiate tournaments
    ITournamentFactory immutable _tournamentFactory;

    /// @notice Current sealed epoch number
    uint256 _epochNumber;

    /// @notice Block number (inclusive) lower bound of the current sealed epoch
    uint256 _blockNumberLowerBound;

    /// @notice Block number (exclusive) upper bound of the current sealed epoch
    uint256 _blockNumberUpperBound;

    /// @notice Current sealed epoch tournament
    ITournament _tournament;

    /// @notice Consensus contract was created
    /// @param inputBox the input box contract
    /// @param appContract the application contract
    /// @param tournamentFactory the tournament factory contract
    event ConsensusCreation(IInputBox inputBox, address appContract, ITournamentFactory tournamentFactory);

    /// @notice An epoch was sealed
    /// @param epochNumber the sealed epoch number
    /// @param blockNumberLowerBound the block number (inclusive) lower bound in the sealed epoch
    /// @param blockNumberUpperBound the block number (exclusive) upper bound in the sealed epoch
    /// @param initialMachineStateHash the initial machine state hash
    /// @param tournament the sealed epoch tournament contract
    event EpochSealed(
        uint256 epochNumber,
        uint256 blockNumberLowerBound,
        uint256 blockNumberUpperBound,
        Machine.Hash initialMachineStateHash,
        ITournament tournament
    );

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
        uint256 blockNumberUpperBound = block.number;
        _blockNumberUpperBound = blockNumberUpperBound;
        ITournament tournament = tournamentFactory.instantiate(initialMachineStateHash, this);
        _tournament = tournament;
        emit EpochSealed(0, 0, blockNumberUpperBound, initialMachineStateHash, tournament);
    }

    function canSettle() external view returns (bool isFinished, uint256 epochNumber) {
        (isFinished,,) = _tournament.arbitrationResult();
        epochNumber = _epochNumber;
    }

    function settle(uint256 epochNumber) external {
        // Check tournament settlement
        require(epochNumber == _epochNumber, "Dave: incorrect epoch number");
        (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournament.arbitrationResult();
        require(isFinished, "Dave: tournament not finished");

        // Seal current accumulating epoch
        _epochNumber = ++epochNumber;
        uint256 blockNumberLowerBound = _blockNumberUpperBound;
        _blockNumberLowerBound = blockNumberLowerBound;
        uint256 blockNumberUpperBound = block.number;
        _blockNumberUpperBound = blockNumberUpperBound;
        ITournament tournament = _tournamentFactory.instantiate(finalMachineStateHash, this);
        _tournament = tournament;
        emit EpochSealed(epochNumber, blockNumberLowerBound, blockNumberUpperBound, finalMachineStateHash, tournament);
    }

    function getCurrentSealedEpoch()
        external
        view
        returns (
            uint256 epochNumber,
            uint256 blockNumberLowerBound,
            uint256 blockNumberUpperBound,
            ITournament tournament
        )
    {
        epochNumber = _epochNumber;
        blockNumberLowerBound = _blockNumberLowerBound;
        blockNumberUpperBound = _blockNumberUpperBound;
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
    function gio(uint16 namespace, bytes calldata id, bytes calldata input) external view override returns (bytes32) {
        require(namespace == INPUT_BOX_NAMESPACE, "Dave: bad namespace");
        uint256 inputIndex = abi.decode(id, (uint256));
        uint256 inputCount = _inputBox.getNumberOfInputs(_appContract);

        if (inputIndex >= inputCount) {
            // out-of-bounds index: repeat the state (as a fixpoint function)
            return bytes32(0);
        }

        bytes32 inputHash = _inputBox.getInputHash(_appContract, inputIndex);
        require(keccak256(input) == inputHash, "Dave: bad input hash");
        require(input.length >= 4, "Dave: bad input length");

        bytes4 selector = bytes4(input[:4]);
        bytes calldata args = input[4:];
        require(selector == Inputs.EvmAdvance.selector, "Dave: bad input selector");
        (,,, uint256 blockNumber,,,,) =
            abi.decode(args, (uint256, address, address, uint256, uint256, uint256, uint256, bytes));

        if (_blockNumberLowerBound <= blockNumber && blockNumber < _blockNumberUpperBound) {
            require(input.length % 32 == 4, "Dave: bad input padding");
            uint256 completeLeafCount = input.length / 32;
            bytes32[] memory leaves = new bytes32[](completeLeafCount + 1);

            // Slice input into leaves
            for (uint256 leafIndex; leafIndex < completeLeafCount; ++leafIndex) {
                leaves[leafIndex] = bytes32(input[:32]);
                input = input[32:];
            }
            leaves[completeLeafCount] = bytes32(bytes4(input[:4]));

            // Calculate Merkle root from leaves
            return leaves.merkleRoot(LOG2_GIO_RESPONSE_BUFFER_SIZE);
        } else {
            // out-of-bounds index: repeat the state (as a fixpoint function)
            return bytes32(0);
        }
    }
}
