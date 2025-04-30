// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/tournament/abstracts/LeafTournament.sol";
import "prt-contracts/tournament/abstracts/NonRootTournament.sol";

/// @notice Bottom tournament of a multi-level instance
contract BottomTournament is LeafTournament, NonRootTournament {
    using Clones for address;

    struct Args {
        TournamentArgs tournamentArgs;
        NonRootTournamentArgs nonRootTournamentArgs;
        IStateTransition stateTransition;
    }

    function _args() internal view returns (Args memory) {
        return abi.decode(address(this).fetchCloneArgs(), (Args));
    }

    function _tournamentArgs()
        internal
        view
        override
        returns (TournamentArgs memory)
    {
        return _args().tournamentArgs;
    }

    function _nonRootTournamentArgs()
        internal
        view
        override
        returns (NonRootTournamentArgs memory)
    {
        return _args().nonRootTournamentArgs;
    }

    function _stateTransition()
        internal
        view
        override
        returns (IStateTransition)
    {
        return _args().stateTransition;
    }
}
