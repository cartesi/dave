// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/Machine.sol";
import {Tree} from "prt-contracts/Tree.sol";

contract DaveConsensus {
    /// @notice Minimum number of blocks per epoch
    uint256 immutable _minBlocksPerEpoch;

    /// @notice Data provider for tournaments
    IDataProvider immutable _dataProvider;

    /// @notice The contract used to instantiate tournaments
    ITournamentFactory immutable _tournamentFactory;

    /// @notice Minimum block number before sealing epoch
    uint256 _minBlockNumberForSettling;

    /// @notice Latest tournament
    ITournament _tournament;

    constructor(
        uint256 minBlocksPerEpoch,
        IDataProvider dataProvider,
        ITournamentFactory tournamentFactory,
        Machine.Hash initialMachineStateHash
    ) {
        _minBlocksPerEpoch = minBlocksPerEpoch;
        _dataProvider = dataProvider;
        _tournamentFactory = tournamentFactory;
        _minBlockNumberForSettling = block.number + minBlocksPerEpoch;
        _tournament = tournamentFactory.instantiate(initialMachineStateHash, dataProvider);
    }

    function canSettle() external view returns (bool) {
        if (_minBlockNumberForSettling <= block.number) {
            (bool isFinished,,) = _tournament.arbitrationResult();
            return isFinished;
        } else {
            return false;
        }
    }

    function settle() external {
        require(_minBlockNumberForSettling <= block.number, "Dave: too early to settle");
        (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournament.arbitrationResult();
        require(isFinished, "Dave: tournament not finished");
        _tournament = _tournamentFactory.instantiate(finalMachineStateHash, _dataProvider);
        _minBlockNumberForSettling = block.number + _minBlocksPerEpoch;
    }

    function tournament() external view returns (ITournament) {
        return _tournament;
    }
}
