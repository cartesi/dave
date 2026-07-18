// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {Match} from "src/tournament/libs/Match.sol";
import {Tree} from "src/types/Tree.sol";

contract MatchIdentityTest is Test {
    bytes32 internal constant ZERO_PAIR_ID =
        0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5;

    function testZeroNodePairHasAConcreteNonzeroId() public pure {
        Match.Id memory id = Match.Id({
            commitmentOne: Tree.ZERO_NODE, commitmentTwo: Tree.ZERO_NODE
        });

        bytes32 idHash = Match.IdHash.unwrap(Match.hashFromId(id));
        assertEq(idHash, ZERO_PAIR_ID);
        assertNotEq(idHash, bytes32(0));
    }

    function testCommitmentOrderChangesMatchIdentity() public pure {
        Tree.Node one = Tree.Node.wrap(bytes32(uint256(1)));
        Tree.Node two = Tree.Node.wrap(bytes32(uint256(2)));

        Match.Id memory forward =
            Match.Id({commitmentOne: one, commitmentTwo: two});
        Match.Id memory reverse =
            Match.Id({commitmentOne: two, commitmentTwo: one});

        assertNotEq(
            Match.IdHash.unwrap(Match.hashFromId(forward)),
            Match.IdHash.unwrap(Match.hashFromId(reverse))
        );
    }
}
