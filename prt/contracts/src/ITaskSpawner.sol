// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @notice Spawner interface for tasks/proof systems.
interface ITaskSpawner {
    function spawn(Machine.Hash initial, IDataProvider provider)
        external
        returns (ITask);
}
