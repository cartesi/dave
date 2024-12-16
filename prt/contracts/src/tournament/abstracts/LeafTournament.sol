// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "./Tournament.sol";
import "../libs/Commitment.sol";

import "step/src/EmulatorConstants.sol";
import "step/src/SendCmioResponse.sol";
import "step/src/UArchStep.sol";
import "step/src/UArchReset.sol";

/// @notice Leaf tournament is the one that seals leaf match
abstract contract LeafTournament is Tournament {
    using Machine for Machine.Hash;
    using Commitment for Tree.Node;
    using Tree for Tree.Node;
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;

    constructor() {}

    function sealLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external tournamentNotFinished {
        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireCanBeFinalized();
        _matchState.requireParentHasChildren(_leftLeaf, _rightLeaf);

        // Unpause clocks
        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            _clock1.setPaused();
            _clock1.advanceClock();
            _clock2.setPaused();
            _clock2.advanceClock();
        }

        _matchState.sealMatch(
            _matchId,
            initialHash,
            _leftLeaf,
            _rightLeaf,
            _agreeHash,
            _agreeHashProof
        );
    }

    error WrongFinalState(
        uint256 commitment, Machine.Hash computed, Machine.Hash claimed
    );
    error WrongNodesForStep();

    function winLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        bytes calldata proofs
    ) external tournamentNotFinished {
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];
        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        (
            Machine.Hash _agreeHash,
            uint256 _agreeCycle,
            Machine.Hash _finalStateOne,
            Machine.Hash _finalStateTwo
        ) = _matchState.getDivergence(startCycle);

        Machine.Hash _finalState = Machine.Hash.wrap(
            metaStep(Machine.Hash.unwrap(_agreeHash), _agreeCycle, proofs)
        );

        if (_leftNode.join(_rightNode).eq(_matchId.commitmentOne)) {
            require(
                _finalState.eq(_finalStateOne),
                WrongFinalState(1, _finalState, _finalStateOne)
            );

            _clockOne.setPaused();
            pairCommitment(
                _matchId.commitmentOne, _clockOne, _leftNode, _rightNode
            );
        } else if (_leftNode.join(_rightNode).eq(_matchId.commitmentTwo)) {
            require(
                _finalState.eq(_finalStateTwo),
                WrongFinalState(2, _finalState, _finalStateTwo)
            );

            _clockTwo.setPaused();
            pairCommitment(
                _matchId.commitmentTwo, _clockTwo, _leftNode, _rightNode
            );
        } else {
            revert WrongNodesForStep();
        }

        // delete storage
        deleteMatch(_matchId.hashFromId());
    }

    uint64 constant LOG2_UARCH_SPAN = 20;
    uint64 constant LOG2_EMULATOR_SPAN = 48;
    uint64 constant LOG2_INPUT_SPAN = 24;

    // TODO: move to step repo
    function metaStep(
        bytes32 machineState,
        uint256 counter,
        bytes calldata proofs
    ) internal view returns (bytes32 newMachineState) {
        // TODO: create a more convinient constructor.
        AccessLogs.Context memory accessLogs =
            AccessLogs.Context(machineState, Buffer.Context(proofs, 0));

        uint256 uarch_step_mask = (1 << LOG2_UARCH_SPAN) - 1;
        uint256 big_step_mask =
            (1 << (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN)) - 1;

        if (address(provider) == address(0)) {
            // this is a inputless version of the meta step implementation primarily used for testing
            if ((counter + 1) & uarch_step_mask == 0) {
                UArchReset.reset(accessLogs);
            } else {
                UArchStep.step(accessLogs);
            }
        } else {
            // rollups meta step handles input
            if (counter & big_step_mask == 0) {
                uint256 inputLength = uint256(bytes32(proofs[:32]));
                accessLogs = AccessLogs.Context(
                    machineState, Buffer.Context(proofs, 32 + inputLength)
                );

                if (inputLength > 0) {
                    bytes calldata input = proofs[32:32 + inputLength];
                    uint256 inputIndexWithinEpoch =
                        counter >> (LOG2_EMULATOR_SPAN + LOG2_UARCH_SPAN);

                    // TODO: maybe assert retrieved input length matches?
                    bytes32 inputMerkleRoot = provider.provideMerkleRootOfInput(
                        inputIndexWithinEpoch, input
                    );

                    require(inputMerkleRoot != bytes32(0));
                    SendCmioResponse.sendCmioResponse(
                        accessLogs,
                        EmulatorConstants.HTIF_YIELD_REASON_ADVANCE_STATE,
                        inputMerkleRoot,
                        uint32(inputLength)
                    );
                    UArchStep.step(accessLogs);
                } else {
                    UArchStep.step(accessLogs);
                }
            } else if ((counter + 1) & uarch_step_mask == 0) {
                UArchReset.reset(accessLogs);
            } else {
                UArchStep.step(accessLogs);
            }
        }
        newMachineState = accessLogs.currentRootHash;
    }
}
