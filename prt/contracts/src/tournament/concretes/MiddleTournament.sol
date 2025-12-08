// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {
    NonLeafTournament
} from "prt-contracts/tournament/abstracts/NonLeafTournament.sol";
import {Tournament} from "prt-contracts/tournament/abstracts/Tournament.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";

/// @notice Middle tournament is non-top, non-bottom of a multi-level instance
contract MiddleTournament is NonLeafTournament {
    using Clones for address;

    struct MiddleArguments {
        TournamentArguments tournamentArgs;
        Tournament.NonRootArguments nonRootTournamentArgs;
        IMultiLevelTournamentFactory tournamentFactory;
    }

    function _middleArgs() internal view returns (MiddleArguments memory) {
        return abi.decode(address(this).fetchCloneArgs(), (MiddleArguments));
    }

    function tournamentArguments()
        public
        view
        override
        returns (TournamentArguments memory)
    {
        return _middleArgs().tournamentArgs;
    }

    function _nonRootTournamentArgs()
        internal
        view
        override
        returns (Tournament.NonRootArguments memory)
    {
        return _middleArgs().nonRootTournamentArgs;
    }

    function _tournamentFactory()
        internal
        view
        override
        returns (IMultiLevelTournamentFactory)
    {
        return _middleArgs().tournamentFactory;
    }
}
