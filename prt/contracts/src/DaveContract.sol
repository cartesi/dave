// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {Strings} from "@openzeppelin-contracts-5.5.0/utils/Strings.sol";

import {EmulatorConstants} from "step/src/EmulatorConstants.sol";

import {IVersionGetter} from "prt-contracts/IVersionGetter.sol";
import "prt-contracts/Version.sol" as Version;

abstract contract DaveContract is IVersionGetter {
    /// @inheritdoc IVersionGetter
    /// @dev The build metadata is `march.<id>`, where `<id>` is the
    /// Cartesi Machine architecture ID (marchid) whose state transitions
    /// these contracts verify.
    function version()
        external
        pure
        override
        returns (
            uint64 major,
            uint64 minor,
            uint64 patch,
            string memory preRelease,
            string memory buildMetadata
        )
    {
        major = Version.MAJOR;
        minor = Version.MINOR;
        patch = Version.PATCH;
        preRelease = Version.PRE_RELEASE;
        buildMetadata = string.concat(
            "march.", Strings.toString(EmulatorConstants.CM_MARCHID)
        );
    }
}
