// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../../concretes/TopTournament.sol";

contract TopTournamentFactory {
    constructor() {}

    function instantiate(
        Machine.Hash _initialHash,
        uint64 _levels,
        uint64 _log2step,
        uint64 _height
    ) external returns (TopTournament) {
        TopTournament _tournament = new TopTournament(
            _initialHash,
            _levels,
            _log2step,
            _height,
            IMultiLevelTournamentFactory(msg.sender)
        );

        return _tournament;
    }
}
