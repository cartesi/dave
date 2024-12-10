// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../abstracts/RootTournament.sol";
import "../abstracts/NonLeafTournament.sol";

import "../../IMultiLevelTournamentFactory.sol";

import "../../Machine.sol";

/// @notice Top tournament of a multi-level instance
contract TopTournament is NonLeafTournament, RootTournament {
    constructor(
        Machine.Hash _initialHash,
        Time.Duration _matchEffort,
        Time.Duration _maxAllowance,
        uint64 _levels,
        uint64 _log2step,
        uint64 _height,
        IMultiLevelTournamentFactory _factory
    )
        NonLeafTournament(_factory)
        RootTournament(
            _initialHash,
            _matchEffort,
            _maxAllowance,
            _levels,
            _log2step,
            _height
        )
    {}
}
