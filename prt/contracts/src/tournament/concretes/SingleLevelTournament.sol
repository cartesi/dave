// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../abstracts/RootTournament.sol";
import "../abstracts/LeafTournament.sol";

import "../../TournamentParameters.sol";

contract SingleLevelTournament is LeafTournament, RootTournament {
    constructor(
        Machine.Hash _initialHash,
        TournamentParameters memory _tournamentParameters,
        IDataProvider _provider,
        IStateTransition _stateTransition
    )
        LeafTournament(_stateTransition)
        RootTournament(_initialHash, _tournamentParameters, _provider)
    {}
}
