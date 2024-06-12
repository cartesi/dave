// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../concretes/SingleLevelTournament.sol";
import "./ITournamentFactory.sol";

contract SingleLevelTournamentFactory is ITournamentFactory {
    constructor() {}

    function instantiateRoot(Machine.Hash _initialHash)
        external
        override
        returns (RootTournament)
    {
        SingleLevelTournament _tournament =
            new SingleLevelTournament(_initialHash);
        emit rootCreated(_tournament);

        return _tournament;
    }
}
