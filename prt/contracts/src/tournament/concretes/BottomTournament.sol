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
    NonRootTournament
} from "prt-contracts/tournament/abstracts/NonRootTournament.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

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

    function eliminateInnerTournament(ITournament _childTournament) external {
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
