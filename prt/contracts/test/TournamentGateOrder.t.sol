// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "test/Util.sol";
import {HistoricalThreeLevelGeometry as HistoricalGeometry} from "test/fixtures/HistoricalThreeLevelGeometry.sol";

import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

using TournamentInspector for ITournament;

/// Pins the order in which the mutators check their gates. Most of these
/// calls would revert under any order; the order fixes which error a caller
/// sees, so dropping or reordering a gate must change an observed selector.
/// The lock's precedence is pinned in `RefundCallbacks.t.sol`.
contract TournamentGateOrderTest is Util {
    MultiLevelTournamentFactory immutable NON_LEAF_FACTORY;
    MultiLevelTournamentFactory immutable LEAF_FACTORY;

    constructor() {
        (NON_LEAF_FACTORY,) =
            Util.instantiateHistoricalThreeLevelTournamentFactory();
        LEAF_FACTORY = Util.instantiateSingleLevelTournamentFactory(
            HistoricalGeometry.log2step(0), HistoricalGeometry.height(0)
        );
    }

    receive() external payable {}

    function testFinishedGatePrecedesKindAndMatchChecksNonLeaf() public {
        _assertFinishedGateOnEveryMutator(_finished(NON_LEAF_FACTORY));
    }

    function testFinishedGatePrecedesKindAndMatchChecksLeaf() public {
        _assertFinishedGateOnEveryMutator(_finished(LEAF_FACTORY));
    }

    function testKindGatePrecedesMatchChecks() public {
        Match.Id memory id = _unknownMatchId();
        Tree.Node n = Tree.Node.wrap(bytes32(uint256(0xc)));
        bytes32[] memory empty = new bytes32[](0);

        ITournament nonLeaf = Util.initializePlayer0Tournament(NON_LEAF_FACTORY);
        vm.expectRevert(ITournament.RequireLeafTournament.selector);
        nonLeaf.sealLeafMatch(id, n, n, Machine.Hash.wrap(0), empty);
        vm.expectRevert(ITournament.RequireLeafTournament.selector);
        nonLeaf.winLeafMatch(id, n, n, new bytes(0));

        ITournament leaf = Util.initializePlayer0Tournament(LEAF_FACTORY);
        vm.expectRevert(ITournament.RequireNonLeafTournament.selector);
        leaf.sealInnerMatchAndCreateInnerTournament(
            id, n, n, Machine.Hash.wrap(0), empty
        );
        vm.expectRevert(ITournament.RequireNonLeafTournament.selector);
        leaf.winInnerTournament(ITournament(address(0xdead)), n, n);
        vm.expectRevert(ITournament.RequireNonLeafTournament.selector);
        leaf.eliminateInnerTournament(ITournament(address(0xdead)));
    }

    /// Join checks closure, then the bond, then the final-state proof, then
    /// the commitment's clock.
    function testJoinGateOrder() public {
        ITournament t = Util.initializePlayer0Tournament(LEAF_FACTORY);
        ITournament.TournamentDescriptor memory d = t.tournamentDescriptor();
        uint64 height = d.height;
        Tree.Node node = playerNodes[1][height - 1];
        bytes32[] memory badProof = new bytes32[](0);
        uint256 bond = t.bondValue();

        vm.expectRevert(ITournament.InsufficientBond.selector);
        t.joinTournament{value: bond - 1}(TWO_STATE, badProof, node, node);

        // The existing commitment with a final state its proof does not
        // bind fails both checks, so the proof error shows the proof runs
        // first.
        Tree.Node node0 = playerNodes[0][height - 1];
        bytes32[] memory proof0 = generateFinalStateProof(0, height);
        vm.expectPartialRevert(ITournament.CommitmentStateMismatch.selector);
        t.joinTournament{value: bond}(TWO_STATE, proof0, node0, node0);

        // A valid proof of an existing commitment reaches the clock check.
        vm.expectRevert(ITournament.ClockAlreadyInitialized.selector);
        t.joinTournament{value: bond}(ONE_STATE, proof0, node0, node0);

        vm.roll(
            Time.Instant.unwrap(d.startInstant)
                + Time.Duration.unwrap(d.allowance)
        );
        vm.expectRevert(ITournament.TournamentIsClosed.selector);
        t.joinTournament{value: 0}(TWO_STATE, badProof, node, node);
    }

    function _finished(MultiLevelTournamentFactory factory)
        private
        returns (ITournament tournament)
    {
        tournament = Util.initializePlayer0Tournament(factory);
        ITournament.TournamentDescriptor memory d =
            tournament.tournamentDescriptor();
        vm.roll(
            Time.Instant.unwrap(d.startInstant)
                + Time.Duration.unwrap(d.allowance)
        );
        assertTrue(tournament.isFinished(), "fixture must be finished");
    }

    function _unknownMatchId() private pure returns (Match.Id memory) {
        return Match.Id(
            Tree.Node.wrap(bytes32(uint256(0xa))),
            Tree.Node.wrap(bytes32(uint256(0xb)))
        );
    }

    /// Every match-taking mutator gets an unknown match and every child
    /// mutator an unknown child, so a missing finished gate would surface as
    /// a kind or match error instead.
    function _assertFinishedGateOnEveryMutator(ITournament t) private {
        Match.Id memory id = _unknownMatchId();
        Tree.Node n = Tree.Node.wrap(bytes32(uint256(0xc)));
        bytes32[] memory empty = new bytes32[](0);

        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.advanceMatch(id, n, n, n, n);
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.winMatchByTimeout(id, n, n);
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.eliminateMatchByTimeout(id);
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.sealLeafMatch(id, n, n, Machine.Hash.wrap(0), empty);
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.winLeafMatch(id, n, n, new bytes(0));
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.sealInnerMatchAndCreateInnerTournament(
            id, n, n, Machine.Hash.wrap(0), empty
        );
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.winInnerTournament(ITournament(address(0xdead)), n, n);
        vm.expectRevert(ITournament.TournamentIsFinished.selector);
        t.eliminateInnerTournament(ITournament(address(0xdead)));
    }
}
