// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.28;

import "prt-contracts/tournament/abstracts/Tournament.sol";
import "prt-contracts/tournament/abstracts/NonRootTournament.sol";
import "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";
import "prt-contracts/tournament/libs/Gas.sol";

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
    // Storage
    //
    mapping(ITournament => Match.Id) matchIdFromInnerTournaments;

    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    )
        external
        refundable(Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT)
        tournamentNotFinished
    {
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
        TournamentArguments memory args = tournamentArguments();

        (Machine.Hash _finalStateOne, Machine.Hash _finalStateTwo) = _matchState
            .sealMatch(
            args.commitmentArgs,
            _matchId,
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
            _matchState.toCycle(args.commitmentArgs),
            args.level + 1
        );
        matchIdFromInnerTournaments[_inner] = _matchId;

        emit NewInnerTournament(_matchId.hashFromId(), _inner);
    }

    function winInnerTournament(
        ITournament _childTournament,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external refundable(Gas.WIN_INNER_TOURNAMENT) tournamentNotFinished {
        Match.Id memory _matchId = matchIdFromInnerTournaments[_childTournament];
        Match.IdHash _matchIdHash = _matchId.hashFromId();
        _matchIdHash.requireExist();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        require(
            !_childTournament.canBeEliminated(),
            ChildTournamentMustBeEliminated()
        );

        (bool finished, Tree.Node _winner,, Clock.State memory _innerClock) =
            _childTournament.innerTournamentWinner();
        require(finished, ChildTournamentNotFinished());
        _winner.requireExist();

        Tree.Node _commitmentRoot = _leftNode.join(_rightNode);
        require(
            _commitmentRoot.eq(_winner),
            WrongTournamentWinner(_commitmentRoot, _winner)
        );

        Clock.State storage _clock = clocks[_commitmentRoot];
        _clock.requireInitialized();
        _clock.reInitialized(_innerClock);

        pairCommitment(_commitmentRoot, _clock, _leftNode, _rightNode);

        WinnerCommitment _winnerCommitment;

        if (_winner.eq(_matchId.commitmentOne)) {
            _winnerCommitment = WinnerCommitment.ONE;
        } else if (_winner.eq(_matchId.commitmentTwo)) {
            _winnerCommitment = WinnerCommitment.TWO;
        } else {
            revert InvalidTournamentWinner(_winner);
        }

        deleteMatch(
            _matchId, MatchDeletionReason.CHILD_TOURNAMENT, _winnerCommitment
        );
        delete matchIdFromInnerTournaments[_childTournament];

        _childTournament.tryRecoveringBond();
    }

    function eliminateInnerTournament(ITournament _childTournament)
        external
        refundable(Gas.ELIMINATE_INNER_TOURNAMENT)
        tournamentNotFinished
    {
        Match.Id memory _matchId = matchIdFromInnerTournaments[_childTournament];
        Match.IdHash _matchIdHash = _matchId.hashFromId();
        _matchIdHash.requireExist();

        Match.State storage _matchState = matches[_matchIdHash];
        _matchState.requireExist();
        _matchState.requireIsFinished();

        require(
            _childTournament.canBeEliminated(),
            ChildTournamentCannotBeEliminated()
        );

        deleteMatch(
            _matchId,
            MatchDeletionReason.CHILD_TOURNAMENT,
            WinnerCommitment.NONE
        );
        delete matchIdFromInnerTournaments[_childTournament];
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
        TournamentArguments memory args = tournamentArguments();
        Tournament _tournament;
        IMultiLevelTournamentFactory tournamentFactory = _tournamentFactory();
        if (_level == args.levels - 1) {
            _tournament = tournamentFactory.instantiateBottom(
                _initialHash,
                _contestedCommitmentOne,
                _contestedFinalStateOne,
                _contestedCommitmentTwo,
                _contestedFinalStateTwo,
                _allowance,
                _startCycle,
                _level,
                args.provider
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
                args.provider
            );
        }

        return NonRootTournament(address(_tournament));
    }

    function _totalGasEstimate() internal view override returns (uint256) {
        return Gas.ADVANCE_MATCH * tournamentArguments().commitmentArgs.height
            + Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
            + Gas.WIN_INNER_TOURNAMENT;
    }

    function _tournamentFactory()
        internal
        view
        virtual
        returns (IMultiLevelTournamentFactory);
}
