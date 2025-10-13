// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/tournament/abstracts/LeafTournament.sol";
import "prt-contracts/tournament/abstracts/NonRootTournament.sol";

/// @notice Bottom tournament of a multi-level instance
contract BottomTournament is LeafTournament, NonRootTournament {
    using Clones for address;

    struct BottomArguments {
        TournamentArguments tournamentArgs;
        NonRootArguments nonRootTournamentArgs;
        IStateTransition stateTransition;
    }

    function _bottomArgs() internal view returns (BottomArguments memory) {
        return abi.decode(address(this).fetchCloneArgs(), (BottomArguments));
    }

    function tournamentArguments()
        public
        view
        override
        returns (TournamentArguments memory)
    {
        return _bottomArgs().tournamentArgs;
    }

    function _nonRootTournamentArgs()
        internal
        view
        override
        returns (NonRootArguments memory)
    {
        return _bottomArgs().nonRootTournamentArgs;
    }

    function _stateTransition()
        internal
        view
        override
        returns (IStateTransition)
    {
        return _bottomArgs().stateTransition;
    }
}
