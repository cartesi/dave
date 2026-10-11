// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

interface ITournamentFactory {
    /// @notice A root tournament was created.
    /// @param tournament The new tournament
    /// @param descriptor The new tournament's `tournamentDescriptor()`
    /// @param bondValue The new tournament's `bondValue()`, the value a join
    /// must send
    /// @dev Anyone can call `instantiate`, so a client trusts this event only
    /// for tournaments it reached through the consensus's `EpochSealed`.
    event TournamentCreated(
        ITournament tournament,
        ITournament.TournamentDescriptor descriptor,
        uint256 bondValue
    );

    function instantiate(Machine.Hash initialState, IDataProvider provider)
        external
        returns (ITournament);
}
