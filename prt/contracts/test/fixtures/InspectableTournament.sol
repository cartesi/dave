// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

/// @dev Test-only views into topology that the production ABI does not expose.
/// This subclass deliberately adds no storage or initialization behavior.
contract InspectableTournament is Tournament {
    function observedTopology()
        external
        view
        returns (
            Tree.Node dangling,
            uint256 activeMatchCount,
            Time.Instant mostRecentDeletion
        )
    {
        return (danglingCommitment, matchCount, lastMatchDeleted);
    }

    function observedClaimer(Tree.Node commitment)
        external
        view
        returns (address)
    {
        return claimers[commitment];
    }

    function observedOriginatingMatch(ITournament child)
        external
        view
        returns (Match.Id memory)
    {
        return matchIdFromInnerTournaments[child];
    }
}
