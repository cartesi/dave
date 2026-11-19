// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

interface IVersionGetter {
    /// @notice Get the version of the smart contract project.
    /// @return major The major version
    /// @return minor The minor version
    /// @return patch The patch version
    /// @return preRelease The pre-release version (can be empty)
    /// @return buildMetadata The build metadata (can be empty)
    /// @dev Examples:
    /// - 1.2.3                    --> (1, 2, 3, "",        ""          )
    /// - 1.2.3-alpha.0            --> (1, 2, 3, "alpha.0", ""          )
    /// - 1.2.3+sha.a1b2c3         --> (1, 2, 3, "",        "sha.a1b2c3")
    /// - 1.2.3-alpha.0+sha.a1b2c3 --> (1, 2, 3, "alpha.0", "sha.a1b2c3")
    /// You can learn more about semantic versioning at <semver.org>.
    function version()
        external
        view
        returns (
            uint64 major,
            uint64 minor,
            uint64 patch,
            string memory preRelease,
            string memory buildMetadata
        );
}
