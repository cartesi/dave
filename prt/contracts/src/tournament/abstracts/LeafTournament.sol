// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Tournament} from "./Tournament.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Gas} from "prt-contracts/tournament/libs/Gas.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @notice Leaf tournament is the one that seals leaf match
abstract contract LeafTournament is Tournament {
    using Machine for Machine.Hash;
    using Commitment for Tree.Node;
    using Tree for Tree.Node;
    using Clock for Clock.State;
    using Match for Match.Id;
    using Match for Match.State;

    function sealLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external override refundable(Gas.SEAL_LEAF_MATCH) tournamentNotFinished {
        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireCanBeFinalized();

        // At the final step (leaf sealing), both sides may know how to prove
        // the state transition. We intentionally run BOTH clocks to incentivize
        // rapid completion by either party. This departs from the single-active
        // clock used during bisection steps.
        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            _clock1.setPaused();
            _clock1.advanceClock();
            _clock2.setPaused();
            _clock2.advanceClock();
        }

        _matchState.sealMatch(
            tournamentArguments().commitmentArgs,
            _matchId,
            _leftLeaf,
            _rightLeaf,
            _agreeHash,
            _agreeHashProof
        );
    }

    function winLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        bytes calldata proofs
    ) external override refundable(Gas.WIN_LEAF_MATCH) tournamentNotFinished {
        Clock.State storage _clockOne = clocks[_matchId.commitmentOne];
        Clock.State storage _clockTwo = clocks[_matchId.commitmentTwo];
        _clockOne.requireInitialized();
        _clockTwo.requireInitialized();

        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        TournamentArguments memory args = tournamentArguments();

        (
            Machine.Hash _agreeHash,
            uint256 _agreeCycle,
            Machine.Hash _finalStateOne,
            Machine.Hash _finalStateTwo
        ) = _matchState.getDivergence(args.commitmentArgs);

        IStateTransition stateTransition = _stateTransition();
        Machine.Hash _finalState = Machine.Hash
            .wrap(
                stateTransition.transitionState(
                    Machine.Hash.unwrap(_agreeHash),
                    _agreeCycle,
                    proofs,
                    args.provider
                )
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

            deleteMatch(
                _matchId, MatchDeletionReason.STEP, WinnerCommitment.ONE
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

            deleteMatch(
                _matchId, MatchDeletionReason.STEP, WinnerCommitment.TWO
            );
        } else {
            revert WrongNodesForStep();
        }
    }

    function eliminateInnerTournament(ITournament) external pure override {
        revert NotImplemented();
    }

    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata,
        Tree.Node,
        Tree.Node,
        Machine.Hash,
        bytes32[] calldata
    ) external pure override {
        revert NotImplemented();
    }

    function winInnerTournament(ITournament, Tree.Node, Tree.Node)
        external
        pure
        override
    {
        revert NotImplemented();
    }

    function _totalGasEstimate() internal view override returns (uint256) {
        return Gas.ADVANCE_MATCH * tournamentArguments().commitmentArgs.height
            + Gas.SEAL_LEAF_MATCH + Gas.WIN_LEAF_MATCH;
    }

    function _stateTransition() internal view virtual returns (IStateTransition);
}
