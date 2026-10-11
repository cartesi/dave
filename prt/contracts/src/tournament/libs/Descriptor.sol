// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "prt-contracts/ITournament.sol";
import {Bond} from "prt-contracts/tournament/libs/Bond.sol";

/// @notice The public projection of a tournament's clone arguments.
library Descriptor {
    function fromArguments(ITournament.TournamentArguments memory args)
        internal
        pure
        returns (ITournament.TournamentDescriptor memory)
    {
        return ITournament.TournamentDescriptor({
            initialHash: args.commitmentArgs.initialHash,
            baseCycle: args.commitmentArgs.startCycle,
            log2Stride: args.commitmentArgs.log2step,
            height: args.commitmentArgs.height,
            level: args.level,
            kind: args.kind,
            startInstant: args.startInstant,
            allowance: args.allowance
        });
    }

    /// @notice The join bond of the tournament `descriptor` describes.
    /// @dev The same `Bond.bondValue` inputs the tournament's `bondValue()`
    /// reads from its arguments, so a client holding the descriptor can
    /// check the bond.
    function bondValue(ITournament.TournamentDescriptor memory descriptor)
        internal
        pure
        returns (uint256)
    {
        return Bond.bondValue(
            descriptor.height,
            descriptor.kind == ITournament.TournamentKind.LEAF
        );
    }
}
