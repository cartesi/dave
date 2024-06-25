// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "src/tournament/concretes/TopTournament.sol";

contract TopTournamentFactory {
    constructor() {}

    function instantiate(Machine.Hash _initialHash)
        external
        returns (TopTournament)
    {
        TopTournament _tournament = new TopTournament(
            _initialHash, MultiLevelTournamentFactory(msg.sender)
        );

        return _tournament;
    }
}