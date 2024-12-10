// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import "../concretes/SingleLevelTournament.sol";
import "../../ITournamentFactory.sol";
import "../../ITournamentParameters.sol";

contract SingleLevelTournamentFactory is ITournamentFactory, ITournamentParameters {
    uint64 public constant levels = 1;
    Time.Duration public immutable matchEffort;
    Time.Duration public immutable maxAllowance;
    uint64 immutable log2step0;
    uint64 immutable height0;

    error IndexOutOfBounds();

    constructor(
        Time.Duration _matchEffort,
        Time.Duration _maxAllowance,
        uint64 _log2step,
        uint64 _height
    ) {
        matchEffort = _matchEffort;
        maxAllowance = _maxAllowance;
        log2step0 = _log2step;
        height0 = _height;
    }

    function instantiateSingleLevel(Machine.Hash _initialHash)
        external
        returns (SingleLevelTournament)
    {
        SingleLevelTournament _tournament =
            new SingleLevelTournament(_initialHash);

        emit tournamentCreated(_tournament);

        return _tournament;
    }

    function instantiate(Machine.Hash _initialHash, IDataProvider)
        external
        returns (ITournament)
    {
        return this.instantiateSingleLevel(_initialHash);
    }

    function log2step(uint256 level) external view override returns (uint64) {
        require(level == 0, IndexOutOfBounds());
        return log2step0;
    }

    function height(uint256 level) external view override returns (uint64) {
        require(level == 0, IndexOutOfBounds());
        return height0;
    }
}
