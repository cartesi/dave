// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITask} from "prt-contracts/ITask.sol";
import {ITaskSpawner} from "prt-contracts/ITaskSpawner.sol";
import {
    MAX_SENTRIES,
    SafetyGateTask
} from "prt-contracts/safety-gate-task/SafetyGateTask.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

/// @title SafetyGateTaskSpawner
/// @notice Spawns safety-gated tasks around an inner task spawner.
/// @dev The sentry list is mutable here, but immutable per spawned task:
/// rotating sentries takes effect on the next spawned task (next epoch).
contract SafetyGateTaskSpawner is ITaskSpawner {
    using Time for Time.Duration;

    /// @notice Address allowed to rotate the sentry set.
    /// @dev In production this role is expected to be held by a high-threshold
    /// governance body (e.g. a security council). Note its powers stop there:
    /// it cannot affect results or in-flight tasks.
    address public immutable SENTRY_MANAGER;
    /// @notice Inner task spawner (e.g., Dave/PRT factory).
    ITaskSpawner public immutable INNER_SPAWNER;
    /// @notice Delay window before falling back to the inner task result.
    Time.Duration public immutable DISAGREEMENT_WINDOW;

    /// @notice Current sentry list used for future tasks.
    address[] public sentries;

    /// @notice Emitted when a safety-gated task is spawned.
    event SafetyGateTaskSpawned(
        SafetyGateTask indexed task, ITask indexed innerTask
    );
    /// @notice Emitted when the sentry list is replaced.
    event SentriesUpdated(address[] sentries);

    error NotSentryManager();
    error TooManySentries();
    error ZeroSentry();
    error ZeroDisagreementWindow();

    /// @dev Restricts to the sentry manager.
    modifier onlySentryManager() {
        require(msg.sender == SENTRY_MANAGER, NotSentryManager());
        _;
    }

    /// @notice Create a safety-gate task spawner.
    /// @param sentryManager The address allowed to rotate the sentry set.
    /// @param innerSpawner The inner task spawner to wrap.
    /// @param disagreementWindow Delay window before fallback to inner result.
    /// @param initialSentries Initial sentry list for future tasks.
    constructor(
        address sentryManager,
        ITaskSpawner innerSpawner,
        Time.Duration disagreementWindow,
        address[] memory initialSentries
    ) {
        // A zero window is a delay-only gate with no delay: reject the
        // (likely accidental) misconfiguration rather than deploy a gate
        // that provides no protection.
        require(!disagreementWindow.isZero(), ZeroDisagreementWindow());

        SENTRY_MANAGER = sentryManager;
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
        onlySentryManager
    {
        _overrideSentries(newSentries);
    }

    /// @notice Get the full sentry list used for future tasks.
    function getSentries() external view returns (address[] memory) {
        return sentries;
    }

    /// @notice Returns whether an address is a sentry in the spawner list.
    function isSentry(address sentry) external view returns (bool) {
        for (uint256 i = 0; i < sentries.length; i++) {
            if (sentries[i] == sentry) {
                return true;
            }
        }
        return false;
    }

    /// @dev Bounds the length and rejects the zero address at the point the
    /// list is set, so those mistakes surface loudly to whoever set it
    /// (deployer or sentry manager) and so a spawned task's constructor can
    /// never revert on them and freeze settlement. The length bound is the
    /// anti-brick guarantee; duplicates are left in place (a spawned task
    /// deduplicates them harmlessly).
    function _overrideSentries(address[] memory newSentries) private {
        require(newSentries.length <= MAX_SENTRIES, TooManySentries());

        delete sentries;

        for (uint256 i = 0; i < newSentries.length; i++) {
            require(newSentries[i] != address(0), ZeroSentry());
            sentries.push(newSentries[i]);
        }

        emit SentriesUpdated(sentries);
    }
}
