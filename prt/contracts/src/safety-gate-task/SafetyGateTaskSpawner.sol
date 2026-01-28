// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {ITaskSpawner} from "prt-contracts/ITaskSpawner.sol";
import {
    SafetyGateTask
} from "prt-contracts/safety-gate-task/SafetyGateTask.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @title SafetyGateTaskSpawner
/// @notice Spawns safety-gated tasks around an inner task spawner.
/// @dev The sentry list is mutable here, but immutable per spawned task.
contract SafetyGateTaskSpawner is ITaskSpawner {
    /// @notice Security council address that manages the sentry set.
    address public immutable SECURITY_COUNCIL;
    /// @notice Inner task spawner (e.g., Dave/PRT factory).
    ITaskSpawner public immutable INNER_SPAWNER;
    /// @notice Delay window before falling back to the inner task result.
    Time.Duration public immutable DISAGREEMENT_WINDOW;

    /// @notice Current sentry list used for future tasks.
    /// @dev Tooling can read the full list from this public array getter.
    address[] public sentries;
    /// @notice Emitted when a safety-gated task is spawned.
    event SafetyGateTaskSpawned(
        SafetyGateTask indexed task, ITask indexed innerTask
    );
    /// @notice Emitted when the sentry list is replaced.
    event SentriesUpdated(address[] sentries);

    error NotSecurityCouncil();

    /// @dev Restricts to the security council.
    modifier onlySecurityCouncil() {
        require(msg.sender == SECURITY_COUNCIL, NotSecurityCouncil());
        _;
    }

    /// @notice Create a safety-gate task spawner.
    /// @param securityCouncil The security council address.
    /// @param innerSpawner The inner task spawner to wrap.
    /// @param disagreementWindow Delay window before fallback to inner result.
    /// @param initialSentries Initial sentry list for future tasks.
    constructor(
        address securityCouncil,
        ITaskSpawner innerSpawner,
        Time.Duration disagreementWindow,
        address[] memory initialSentries
    ) {
        SECURITY_COUNCIL = securityCouncil;
        INNER_SPAWNER = innerSpawner;
        DISAGREEMENT_WINDOW = disagreementWindow;

        _overrideSentries(initialSentries);
    }

    /// @inheritdoc ITaskSpawner
    /// @dev Uses a snapshot of the current sentry list; later changes do not
    ///      affect already-spawned tasks.
    function spawn(Machine.Hash initial, IDataProvider provider)
        external
        override
        returns (ITask)
    {
        ITask innerTask = INNER_SPAWNER.spawn(initial, provider);
        SafetyGateTask task =
            new SafetyGateTask(innerTask, DISAGREEMENT_WINDOW, sentries);
        emit SafetyGateTaskSpawned(task, innerTask);
        return ITask(address(task));
    }

    /// @notice Replace the full sentry list (affects future tasks only).
    /// @dev This does not validate the list; governance is responsible for correctness.
    function setSentries(address[] calldata newSentries)
        external
        onlySecurityCouncil
    {
        _overrideSentries(newSentries);
    }

    /// @notice Returns whether an address is a sentry in the spawner list.
    /// @dev If duplicates are present, this still returns true on the first match.
    function isSentry(address sentry) external view returns (bool) {
        address[] memory current = sentries;
        for (uint256 i = 0; i < current.length; i++) {
            if (current[i] == sentry) {
                return true;
            }
        }
        return false;
    }

    /// @dev No validation: list is stored verbatim.
    function _overrideSentries(address[] memory newSentries) private {
        delete sentries;

        for (uint256 i = 0; i < newSentries.length; i++) {
            sentries.push(newSentries[i]);
        }

        emit SentriesUpdated(sentries);
    }
}
