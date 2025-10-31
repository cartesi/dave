// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.2.0/proxy/Clones.sol";

import "prt-contracts/tournament/abstracts/NonLeafTournament.sol";
import "prt-contracts/tournament/abstracts/NonRootTournament.sol";

import "prt-contracts/tournament/factories/IMultiLevelTournamentFactory.sol";

/// @notice Middle tournament is non-top, non-bottom of a multi-level instance
contract MiddleTournament is NonLeafTournament, NonRootTournament {
    using Clones for address;

    struct MiddleArguments {
        TournamentArguments tournamentArgs;
        NonRootArguments nonRootTournamentArgs;
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
        returns (NonRootArguments memory)
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
