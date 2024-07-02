// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../concretes/SingleLevelTournament.sol";
import "../../ITournamentFactory.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    constructor() {}

    function instantiateSingleLevel(Machine.Hash _initialHash)
        external
        returns (SingleLevelTournament)
    {
        SingleLevelTournament _tournament =
            new SingleLevelTournament(_initialHash);

        emit tournamentCreated(_tournament);

        return _tournament;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider provider)
        external
        returns (ITournament)
    {
        return this.instantiateSingleLevel(_initialHash);
    }
}
