// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

interface ISentryErrors {
    /// @notice This error is raised either when one tries to deploy a DaveConsensus
    /// contract or when the sentry manager tries to rotate a sentry. This is forbidden
    /// because the zero address is reserved as a sentinel value for non-sentries (when
    /// calling the `getSentryById` function with an invalid sentry ID).
    error ZeroSentryAddress();

    /// @notice This error is raised either when one tries to deploy a DaveConsensus
    /// contract or when the sentry manager tries to rotate a sentry. This is forbidden
    /// because each sentry address should be assigned a single unique sentry ID (which
    /// can be retrieved by calling the `getSentryId` function with the sentry address).
    /// @param sentryId The sentry ID
    /// @param sentry The sentry address
    error DuplicatedSentryAddress(uint256 sentryId, address sentry);
}
