// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../IMultiLevelTournamentFactory.sol";
import "./Tournament.sol";
import "./NonRootTournament.sol";

/// @notice Non-leaf tournament can create inner tournaments and matches
abstract contract NonLeafTournament is Tournament {
    using Clock for Clock.State;
    using Commitment for Tree.Node;
    using Machine for Machine.Hash;
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Match for Match.State;
    using Match for Match.Id;
    using Match for Match.IdHash;

    //
    // Constants
    //
    IMultiLevelTournamentFactory immutable tournamentFactory;

    //
    // Storage
    //
    mapping(NonRootTournament => Match.IdHash) matchIdFromInnerTournaments;

    //
    // Events
    //
    event newInnerTournament(Match.IdHash indexed, NonRootTournament);

    //
    // Constructor
    //
    constructor(IMultiLevelTournamentFactory _tournamentFactory) {
        tournamentFactory = _tournamentFactory;
    }

    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external tournamentNotFinished {
        Match.State storage _matchState = matches[_matchId.hashFromId()];
        _matchState.requireCanBeFinalized();
        // Pause clocks
        Time.Duration _maxDuration;
        {
            Clock.State storage _clock1 = clocks[_matchId.commitmentOne];
            Clock.State storage _clock2 = clocks[_matchId.commitmentTwo];
            _clock1.setPaused();
            _clock2.setPaused();
            _maxDuration = Clock.max(_clock1, _clock2);
        }
        (Machine.Hash _finalStateOne, Machine.Hash _finalStateTwo) = _matchState
            .sealMatch(
            _matchId,
            initialHash,
            _leftLeaf,
            _rightLeaf,
            _agreeHash,
            _agreeHashProof
        );
        NonRootTournament _inner = instantiateInner(
            _agreeHash,
            _matchId.commitmentOne,
            _finalStateOne,
            _matchId.commitmentTwo,
            _finalStateTwo,
            _maxDuration,
            _matchState.toCycle(startCycle),
            level + 1
        );
        matchIdFromInnerTournaments[_inner] = _matchId.hashFromId();

        emit newInnerTournament(_matchId.hashFromId(), _inner);
    }

    error ChildTournamentNotFinished();
    error WrongTournamentWinner(Tree.Node commitmentRoot, Tree.Node winner);

    function winInnerMatch(
        NonRootTournament _childTournament,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external tournamentNotFinished {
        Match.IdHash _matchIdHash =
            matchIdFromInnerTournaments[_childTournament];
        _matchIdHash.requireExist();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        (bool finished, Tree.Node _winner, Tree.Node _innerWinner) =
            _childTournament.innerTournamentWinner();
        require(finished, ChildTournamentNotFinished());
        _winner.requireExist();

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);
        require(
            _commitmentRoot.eq(_winner),
            WrongTournamentWinner(_commitmentRoot, _winner)
        );

        (Clock.State memory _innerClock,) =
            _childTournament.getCommitment(_innerWinner);
        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireInitialized();
        _clock.reInitialized(_innerClock);

        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode);

        // delete storage
        deleteMatch(_matchIdHash);
        matchIdFromInnerTournaments[_childTournament] = Match.ZERO_ID;
    }

    function instantiateInner(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level
    ) private returns (NonRootTournament) {
        // the inner tournament is bottom tournament at last level
        // else instantiate middle tournament
        Tournament _tournament;
        if (_level == levels - 1) {
            _tournament = tournamentFactory.instantiateBottom(
                _initialHash,
                _contestedCommitmentOne,
                _contestedFinalStateOne,
                _contestedCommitmentTwo,
                _contestedFinalStateTwo,
                _allowance,
                _startCycle,
                _level,
                provider
            );
        } else {
            _tournament = tournamentFactory.instantiateMiddle(
                _initialHash,
                _contestedCommitmentOne,
                _contestedFinalStateOne,
                _contestedCommitmentTwo,
                _contestedFinalStateTwo,
                _allowance,
                _startCycle,
                _level,
                provider
            );
        }

        return NonRootTournament(address(_tournament));
    }
}
