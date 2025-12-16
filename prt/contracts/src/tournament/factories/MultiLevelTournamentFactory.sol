// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {IMultiLevelTournamentFactory} from "./IMultiLevelTournamentFactory.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    ITournamentParametersProvider
} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import {Tournament} from "prt-contracts/tournament/concretes/Tournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract MultiLevelTournamentFactory is IMultiLevelTournamentFactory {
    using Clones for address;

    Tournament immutable IMPL;
    ITournamentParametersProvider immutable TOURNAMENT_PARAMETERS_PROVIDER;
    IStateTransition immutable STATE_TRANSITION;

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
        override
        returns (ITournament)
    {
        ITournament _tournament = instantiateTop(_initialHash, _provider);
        emit TournamentCreated(_tournament);
        return _tournament;
    }

    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        public
        override
        returns (ITournament)
    {
        TournamentParameters memory params = _getTournamentParameters(0);

        Tournament.CloneArguments memory args = Tournament.CloneArguments({
            tournamentArgs: ITournament.TournamentArguments({
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
                provider: _provider
            }),
            nonRootTournamentArgs: ITournament.NonRootArguments({
                contestedCommitmentOne: Tree.ZERO_NODE,
                contestedFinalStateOne: Machine.ZERO_STATE,
                contestedCommitmentTwo: Tree.ZERO_NODE,
                contestedFinalStateTwo: Machine.ZERO_STATE
            }),
            stateTransition: IStateTransition(address(0)),
            tournamentFactory: this
        });

        address clone = address(IMPL).cloneWithImmutableArgs(abi.encode(args));
        return ITournament(clone);
    }

    /// @notice Instantiate an inner tournament (middle or bottom level).
    /// @dev
    /// - Determines leaf vs non-leaf configuration based on `_level`:
    ///   * If `_level == params.levels - 1`: leaf tournament
    ///     → uses `STATE_TRANSITION`, no factory (can't create deeper tournaments)
    ///   * Otherwise: non-leaf tournament
    ///     → no state transition, uses `this` factory (can create deeper tournaments)
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

        // Determine if this is a leaf tournament (bottom level)
        bool isLeaf = _level == params.levels - 1;

        Tournament.CloneArguments memory args = Tournament.CloneArguments({
            tournamentArgs: ITournament.TournamentArguments({
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
                provider: _provider
            }),
            nonRootTournamentArgs: ITournament.NonRootArguments({
                contestedCommitmentOne: _contestedCommitmentOne,
                contestedFinalStateOne: _contestedFinalStateOne,
                contestedCommitmentTwo: _contestedCommitmentTwo,
                contestedFinalStateTwo: _contestedFinalStateTwo
            }),
            stateTransition: isLeaf
                ? STATE_TRANSITION
                : IStateTransition(address(0)),
            tournamentFactory: isLeaf
                ? IMultiLevelTournamentFactory(address(0))
                : this
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
