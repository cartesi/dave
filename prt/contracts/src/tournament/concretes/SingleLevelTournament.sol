// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {
    LeafTournament
} from "prt-contracts/tournament/abstracts/LeafTournament.sol";

contract SingleLevelTournament is LeafTournament {
    using Clones for address;

    struct SingleLevelArguments {
        TournamentArguments tournamentArgs;
        IStateTransition stateTransition;
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
