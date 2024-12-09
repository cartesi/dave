// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../concretes/SingleLevelTournament.sol";
import "../../ITournamentFactory.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    uint64 immutable log2step;
    uint64 immutable height;

    constructor(uint64 _log2step, uint64 _height) {
        log2step = _log2step;
        height = _height;
    }

    function instantiateSingleLevel(Machine.Hash _initialHash)
        external
        returns (SingleLevelTournament)
    {
        SingleLevelTournament _tournament =
            new SingleLevelTournament(_initialHash, log2step, height);

        emit tournamentCreated(_tournament);

        return _tournament;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider)
        external
        returns (ITournament)
    {
        return this.instantiateSingleLevel(_initialHash);
    }
}
