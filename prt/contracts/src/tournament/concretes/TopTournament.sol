// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {
    NonLeafTournament
} from "prt-contracts/tournament/abstracts/NonLeafTournament.sol";
import {
    RootTournament
} from "prt-contracts/tournament/abstracts/RootTournament.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";

/// @notice Top tournament of a multi-level instance
contract TopTournament is NonLeafTournament, RootTournament {
    using Clones for address;

    struct TopArguments {
        TournamentArguments tournamentArgs;
        IMultiLevelTournamentFactory tournamentFactory;
    }

    function _topArgs() internal view returns (TopArguments memory) {
        return abi.decode(address(this).fetchCloneArgs(), (TopArguments));
    }

    function tournamentArguments()
        public
        view
        override
        returns (TournamentArguments memory)
    {
        return _topArgs().tournamentArgs;
    }

    function _tournamentFactory()
        internal
        view
        override
        returns (IMultiLevelTournamentFactory)
    {
        return _topArgs().tournamentFactory;
    }
}
