// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {
    ITournamentParametersProvider
} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/IMultiLevelTournamentFactory.sol";
import {ITournament} from "prt-contracts/tournament/ITournament.sol";
import {Tournament} from "prt-contracts/tournament/Tournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    using Clones for address;

    event TournamentCreated(ITournament tournament);

    Tournament immutable IMPL;
    ITournamentParametersProvider immutable TOURNAMENT_PARAMETERS_PROVIDER;
    IStateTransition immutable STATE_TRANSITION;

    function spawn(Machine.Hash _initialHash, IDataProvider _provider)
        external
        override
        returns (ITask)
    {
        return this.instantiate(_initialHash, _provider);
    }

    constructor(
        Tournament _impl,
        ITournamentParametersProvider _tournamentParametersProvider,
        IStateTransition _stateTransition
    ) {
        IMPL = _impl;
        TOURNAMENT_PARAMETERS_PROVIDER = _tournamentParametersProvider;
        STATE_TRANSITION = _stateTransition;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider _provider)
        external
        returns (ITournament)
    {
        ITournament _tournament = instantiateTop(_initialHash, _provider);
        emit TournamentCreated(_tournament);
        return _tournament;
    }

    /// @notice Instantiate a top-level tournament (root tournament at level 0).
    /// @dev
    /// - Always passes STATE_TRANSITION and tournamentFactory (address(this)).
    /// - Uses `address(this)` instead of `this` to avoid circular dependency:
    ///   ITournament imports IMultiLevelTournamentFactory, and IMultiLevelTournamentFactory imports ITournament.
    ///   Storing as `address` breaks the cycle; it's cast back to IMultiLevelTournamentFactory when needed.
    /// - For single-level tournaments (levels == 1): factory is set but unused (leaf tournaments don't create inner tournaments).
    /// - For multi-level tournaments (levels > 1): factory is used to create inner tournaments.
    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        private
        returns (ITournament)
    {
        TournamentParameters memory params = _getTournamentParameters(0);

        ITournament.TournamentArguments memory args =
            ITournament.TournamentArguments({
                commitmentArgs: Commitment.Arguments({
                    initialHash: _initialHash,
                    startCycle: 0,
                    log2step: params.log2step,
                    height: params.height
                }),
                level: 0,
                levels: params.levels,
                startInstant: Time.currentTime(),
                allowance: params.maxAllowance,
                maxAllowance: params.maxAllowance,
                matchEffort: params.matchEffort,
                provider: _provider,
                nestedDispute: ITournament.NestedDispute({
                    contestedCommitmentOne: Tree.ZERO_NODE,
                    contestedFinalStateOne: Machine.ZERO_STATE,
                    contestedCommitmentTwo: Tree.ZERO_NODE,
                    contestedFinalStateTwo: Machine.ZERO_STATE
                }),
                stateTransition: STATE_TRANSITION,
                tournamentFactory: address(this)
            });

        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        return ITournament(clone);
    }

    /// @notice Instantiate an inner tournament (middle or bottom level).
    /// @dev
    /// - Always passes STATE_TRANSITION and tournamentFactory (address(this)).
    /// - Uses `address(this)` instead of `this` to avoid circular dependency:
    ///   ITournament imports IMultiLevelTournamentFactory, and IMultiLevelTournamentFactory imports ITournament.
    ///   Storing as `address` breaks the cycle; it's cast back to IMultiLevelTournamentFactory when needed.
    /// - For leaf tournaments (`_level == params.levels - 1`): factory is set but unused (can't create deeper tournaments).
    /// - For non-leaf tournaments (`_level < params.levels - 1`): factory is used to create deeper tournaments.
    function instantiateInner(
        Machine.Hash _initialHash,
        Tree.Node _contestedCommitmentOne,
        Machine.Hash _contestedFinalStateOne,
        Tree.Node _contestedCommitmentTwo,
        Machine.Hash _contestedFinalStateTwo,
        Time.Duration _allowance,
        uint256 _startCycle,
        uint64 _level,
        IDataProvider _provider
    ) external override returns (ITournament) {
        TournamentParameters memory params = _getTournamentParameters(_level);

        ITournament.TournamentArguments memory args =
            ITournament.TournamentArguments({
                commitmentArgs: Commitment.Arguments({
                    initialHash: _initialHash,
                    startCycle: _startCycle,
                    log2step: params.log2step,
                    height: params.height
                }),
                level: _level,
                levels: params.levels,
                startInstant: Time.currentTime(),
                allowance: _allowance,
                maxAllowance: params.maxAllowance,
                matchEffort: params.matchEffort,
                provider: _provider,
                nestedDispute: ITournament.NestedDispute({
                    contestedCommitmentOne: _contestedCommitmentOne,
                    contestedFinalStateOne: _contestedFinalStateOne,
                    contestedCommitmentTwo: _contestedCommitmentTwo,
                    contestedFinalStateTwo: _contestedFinalStateTwo
                }),
                stateTransition: STATE_TRANSITION,
                tournamentFactory: address(this)
            });

        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        return ITournament(clone);
    }

    function _getTournamentParameters(uint64 _level)
        internal
        view
        returns (TournamentParameters memory)
    {
        return TOURNAMENT_PARAMETERS_PROVIDER.tournamentParameters(_level);
    }
}
