// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";
import {Errors} from "@openzeppelin-contracts-5.5.0/utils/Errors.sol";

import {IMultiLevelTournamentFactory} from "./IMultiLevelTournamentFactory.sol";
import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    ITournamentParametersProvider
} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";
import {Tournament} from "prt-contracts/tournament/Tournament.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @dev The immutable provider is the sole authority for a parameter table
/// trusted to remain coherent and stable for this factory's lifetime.
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
        // Clones accepts a no-code implementation, while the other dependencies
        // would otherwise fail only when a tournament is instantiated or used.
        require(address(_impl).code.length > 0, Errors.FailedDeployment());
        require(
            address(_tournamentParametersProvider).code.length > 0,
            Errors.FailedDeployment()
        );
        require(
            address(_stateTransition).code.length > 0, Errors.FailedDeployment()
        );

        IMPL = _impl;
        TOURNAMENT_PARAMETERS_PROVIDER = _tournamentParametersProvider;
        STATE_TRANSITION = _stateTransition;
    }

    /// @inheritdoc IMultiLevelTournamentFactory
    function tournamentLevelCount() external view override returns (uint64) {
        return tournamentParameters(0).levels;
    }

    /// @inheritdoc IMultiLevelTournamentFactory
    function tournamentParameters(uint64 _level)
        public
        view
        override
        returns (TournamentParameters memory)
    {
        return TOURNAMENT_PARAMETERS_PROVIDER.tournamentParameters(_level);
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

    /// @notice Instantiate a top-level tournament (root tournament at level 0).
    /// @dev
    /// - Always passes STATE_TRANSITION and tournamentFactory (address(this)).
    /// - Uses `address(this)` instead of `this` to avoid circular dependency:
    ///   ITournament imports IMultiLevelTournamentFactory, and IMultiLevelTournamentFactory imports ITournament.
    ///   Storing as `address` breaks the cycle; it's cast back to IMultiLevelTournamentFactory when needed.
    /// - For leaf roots: factory is set but unused.
    /// - For non-leaf roots: factory is used to create inner tournaments.
    function instantiateTop(Machine.Hash _initialHash, IDataProvider _provider)
        private
        returns (ITournament)
    {
        TournamentParameters memory params = tournamentParameters(0);

        ITournament.TournamentArguments memory args =
            ITournament.TournamentArguments({
                commitmentArgs: Commitment.Arguments({
                    initialHash: _initialHash,
                    startCycle: 0,
                    log2step: params.log2step,
                    height: params.height
                }),
                level: 0,
                kind: _kindFor(0, params.levels),
                startInstant: Time.currentTime(),
                allowance: params.maxAllowance,
                responseBudget: params.responseBudget,
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
    /// - For leaf tournaments: factory is set but unused.
    /// - For non-leaf tournaments: factory is used to create deeper tournaments.
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
        TournamentParameters memory params = tournamentParameters(_level);

        ITournament.TournamentArguments memory args =
            ITournament.TournamentArguments({
                commitmentArgs: Commitment.Arguments({
                    initialHash: _initialHash,
                    startCycle: _startCycle,
                    log2step: params.log2step,
                    height: params.height
                }),
                level: _level,
                kind: _kindFor(_level, params.levels),
                startInstant: Time.currentTime(),
                allowance: _allowance,
                responseBudget: params.responseBudget,
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

    function _kindFor(uint64 _level, uint64 _levels)
        private
        pure
        returns (ITournament.TournamentKind)
    {
        return _level == _levels - 1
            ? ITournament.TournamentKind.LEAF
            : ITournament.TournamentKind.NON_LEAF;
    }
}
