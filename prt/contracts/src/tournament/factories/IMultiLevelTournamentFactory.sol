// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {
    TournamentParameters
} from "prt-contracts/types/TournamentParameters.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

interface IMultiLevelTournamentFactory is ITournamentFactory {
    /// @notice Return the state transition configured for every tournament.
    function stateTransition() external view returns (IStateTransition);

    /// @notice Return the number of configured tournament levels.
    function tournamentLevelCount() external view returns (uint64);

    /// @notice Return the parameters configured for `level`.
    /// @dev The provider-backed table is trusted to remain coherent and stable
    /// for the factory's lifetime. Every row's `levels` repeats
    /// `tournamentLevelCount()`.
    function tournamentParameters(uint64 level)
        external
        view
        returns (TournamentParameters memory);

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
    ) external returns (ITournament);
}
