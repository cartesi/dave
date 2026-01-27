// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Machine} from "prt-contracts/types/Machine.sol";

/// @notice Task interface for asynchronous proof systems.
interface ITask {
    /// @notice Get the task result.
    /// @return finished Whether the task has finished
    /// @return finalState The finalized machine state (if finished)
    function result()
        external
        view
        returns (bool finished, Machine.Hash finalState);

    /// @notice Best-effort cleanup hook for post-settlement actions.
    /// @dev Should be safe to call multiple times and return false if not applicable.
    /// @return cleaned Whether any cleanup action succeeded.
    function cleanup() external returns (bool cleaned);
}
