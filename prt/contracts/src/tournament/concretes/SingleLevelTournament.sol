// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/tournament/abstracts/LeafTournament.sol";
import "prt-contracts/tournament/abstracts/RootTournament.sol";
import "prt-contracts/tournament/abstracts/Tournament.sol";

contract SingleLevelTournament is LeafTournament, RootTournament {
    using Clones for address;

    struct SingleLevelArguments {
        TournamentArguments tournamentArgs;
        IStateTransition stateTransition;
    }

    function tryRecoveringBond()
        public
        override(RootTournament, Tournament)
        returns (bool)
    {
        return super.tryRecoveringBond();
    }

    function _singleLevelArgs()
        internal
        view
        returns (SingleLevelArguments memory)
    {
        return
            abi.decode(address(this).fetchCloneArgs(), (SingleLevelArguments));
    }

    function tournamentArguments()
        public
        view
        override
        returns (TournamentArguments memory)
    {
        return _singleLevelArgs().tournamentArgs;
    }

    function _stateTransition()
        internal
        view
        override
        returns (IStateTransition)
    {
        return _singleLevelArgs().stateTransition;
    }
}
