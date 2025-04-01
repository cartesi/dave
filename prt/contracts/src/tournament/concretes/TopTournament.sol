// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "prt-contracts/tournament/abstracts/NonLeafTournament.sol";
import "prt-contracts/tournament/abstracts/RootTournament.sol";

import "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";

import "prt-contracts/types/TournamentParameters.sol";
import "prt-contracts/types/Machine.sol";

/// @notice Top tournament of a multi-level instance
contract TopTournament is NonLeafTournament, RootTournament {
    constructor(
        Machine.Hash _initialHash,
        TournamentParameters memory _tournamentParameters,
        IDataProvider _provider,
        IMultiLevelTournamentFactory _tournamentFactory
    )
        NonLeafTournament(_tournamentFactory)
        RootTournament(_initialHash, _tournamentParameters, _provider)
    {}
}
