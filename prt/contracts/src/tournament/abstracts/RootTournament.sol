// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Tournament} from "./Tournament.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @notice Root tournament has no parent
abstract contract RootTournament is Tournament {
    function validContestedFinalState(Machine.Hash)
        internal
        pure
        override
        returns (bool, Machine.Hash, Machine.Hash)
    {
        // always returns true in root tournament
        return (true, Machine.ZERO_STATE, Machine.ZERO_STATE);
    }
}
