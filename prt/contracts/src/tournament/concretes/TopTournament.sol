// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";

import {ITournament} from "prt-contracts/ITournament.sol";
import {
    NonLeafTournament
} from "prt-contracts/tournament/abstracts/NonLeafTournament.sol";
import {
    RootTournament
} from "prt-contracts/tournament/abstracts/RootTournament.sol";
import {
    IMultiLevelTournamentFactory
} from "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

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

    function canBeEliminated() external view returns (bool) {
        revert ITournament.NotImplemented();
    }

    function innerTournamentWinner()
        external
        view
        returns (bool, Tree.Node, Tree.Node, Clock.State memory)
    {
        revert ITournament.NotImplemented();
    }

    function sealLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external {
        revert ITournament.NotImplemented();
    }

    function winLeafMatch(
        Match.Id calldata _matchId,
        Tree.Node _leftNode,
        Tree.Node _rightNode,
        bytes calldata proofs
    ) external {
        revert ITournament.NotImplemented();
    }
}
