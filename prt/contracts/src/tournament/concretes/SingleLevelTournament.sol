// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {
    LeafTournament
} from "prt-contracts/tournament/abstracts/LeafTournament.sol";
import {
    RootTournament
} from "prt-contracts/tournament/abstracts/RootTournament.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

contract SingleLevelTournament is LeafTournament, RootTournament {
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

    function canBeEliminated() external view returns (bool) {
        revert ITournament.NotImplemented();
    }

    function eliminateInnerTournament(ITournament _childTournament) external {
        revert ITournament.NotImplemented();
    }

    function innerTournamentWinner()
        external
        view
        returns (bool, Tree.Node, Tree.Node, Clock.State memory)
    {
        revert ITournament.NotImplemented();
    }

    function sealInnerMatchAndCreateInnerTournament(
        Match.Id calldata _matchId,
        Tree.Node _leftLeaf,
        Tree.Node _rightLeaf,
        Machine.Hash _agreeHash,
        bytes32[] calldata _agreeHashProof
    ) external {
        revert ITournament.NotImplemented();
    }

    function winInnerTournament(
        ITournament _childTournament,
        Tree.Node _leftNode,
        Tree.Node _rightNode
    ) external {
        revert ITournament.NotImplemented();
    }
}
