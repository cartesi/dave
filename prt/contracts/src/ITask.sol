// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {
    IERC165
} from "@openzeppelin-contracts-5.5.0/utils/introspection/IERC165.sol";

import {Machine} from "prt-contracts/types/Machine.sol";

/// @notice Task interface for asynchronous proof systems.
/// @dev A task computes the final machine state for a fixed input range.
/// Consumers that only need the settled result should depend on this
/// interface rather than on a concrete proof system.
interface ITask is IERC165 {
    /// @notice Get the task result.
    /// @dev Implementations may revert on catastrophic terminal states
    /// (e.g. a tournament that finished with every commitment eliminated)
    /// rather than encode them in the return value.
    /// @return finished Whether the task has finished
    /// @return finalState The finalized machine state (if finished)
    function result()
        external
        view
        returns (bool finished, Machine.Hash finalState);

    /// @notice Best-effort cleanup hook for post-settlement actions.
    /// @dev Should be safe to call multiple times and return false if not applicable.
    /// @dev Reentrancy hazard: implementations may call untrusted contracts
    /// (e.g. an Ether transfer to a bond recipient). Callers MUST follow
    /// checks-effects-interactions and invoke this only after all state
    /// transitions have been performed.
    /// @return cleaned Whether any cleanup action succeeded.
    function cleanup() external returns (bool cleaned);
}
