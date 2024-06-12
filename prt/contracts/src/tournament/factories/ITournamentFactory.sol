// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../abstracts/RootTournament.sol";

interface ITournamentFactory {
    event rootCreated(RootTournament);

    function instantiateRoot(Machine.Hash _initialHash)
        external
        returns (RootTournament);
}
