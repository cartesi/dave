// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";
import {SmallTwoLevelTournamentFactory} from "test/fixtures/SmallTwoLevelTournament.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Lead, not an exploit: modality "factory identity", question 1.
///
/// Clones are created with CREATE from the factory's one nonce, which every
/// caller and every application shares, and a clone's arguments name no
/// parent. So a child's address is fixed only with the block that seals it,
/// and a clone with byte-identical arguments can sit at any address.
///
/// On chain nothing breaks: the parent records the child inside the sealing
/// call, a reorg replays that call, and `winInnerTournament` accepts only the
/// recorded child. What breaks is a client that keys on an address read
/// from a block that later reorgs out:
///
/// - one-block reorg, then a permissionless `instantiateInner` with the same
///   arguments ahead of the re-included seal: the cached address now holds
///   an indistinguishable orphan, the client joins it, the real child runs
///   without the correct commitment, and the parent seats the Sybil;
/// - the same reorg without the front-run: a join sent to the cached address
///   before the seal is re-included reaches an address with no code, so it
///   succeeds as a plain value transfer, and the clone later created there
///   absorbs the bond without the commitment having joined.
///
/// The Rust node joins only from finalized state (dimensioning.md, the
/// commitment-budget paragraph; epoch-lifecycle.md, Hero loop), so it is not
/// exposed. The price is a reorg, which is a chain event outside the
/// censorship model, plus one clone deployment.
contract FactoryNonceReorgTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using TournamentInspector for InspectableTournament;
    using Tree for Tree.Node;
    using Match for Match.Id;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    SmallTwoLevelTournamentFactory factory;
    InspectableTournament root;
    Tree.Node[] honest;
    Tree.Node[] sybil;

    function _readyToSeal()
        internal
        returns (
            SmallFullTree.Data memory hRoot,
            SmallFullTree.Data memory sRoot
        )
    {
        vm.roll(100);
        factory = twoLevelFactory(G, T, ALLOWANCE);
        root = newRoot(factory);
        honest = fineLeaves(1);
        sybil = fineLeaves(1, 10, 2);
        hRoot = rootTreeOf(honest);
        sRoot = rootTreeOf(sybil);
        join(root, hRoot, HONEST);
        join(root, sRoot, SYBIL);
        advanceToSeal(root, hRoot, sRoot);
    }

    function testTraceReorgHandsCachedChildAddressToTwin() public {
        (SmallFullTree.Data memory hRoot, SmallFullTree.Data memory sRoot) =
            _readyToSeal();
        uint256 sealBlock = block.number;
        uint256 snapshot = vm.snapshotState();

        // Block B: the seal. A client caches the child from its event.
        (InspectableTournament cached, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        ITournament.TournamentArguments memory args =
            cached.tournamentArguments();

        // B is reorged out. In B' a permissionless factory call with the same
        // arguments lands before the re-included seal.
        vm.revertToState(snapshot);
        vm.roll(sealBlock);
        vm.prank(SYBIL);
        (ITournament twin,) = factory.instantiateInner(
            args.commitmentArgs.initialHash,
            args.nestedDispute.contestedCommitmentOne,
            args.nestedDispute.contestedFinalStateOne,
            args.nestedDispute.contestedCommitmentTwo,
            args.nestedDispute.contestedFinalStateTwo,
            args.allowance,
            args.commitmentArgs.startCycle,
            args.level,
            args.provider
        );
        (InspectableTournament real,) = sealInner(root, hRoot, sRoot);

        assertEq(address(twin), address(cached), "cached address reassigned");
        assertTrue(address(real) != address(cached));
        assertEq(
            keccak256(
                abi.encode(
                    InspectableTournament(address(twin)).tournamentArguments()
                )
            ),
            keccak256(abi.encode(real.tournamentArguments())),
            "twin and child have byte-identical arguments"
        );
        Match.Id memory rootMatch = matchId(hRoot, sRoot);
        assertEq(
            Match.IdHash
            .unwrap(root.observedOriginatingMatch(real).hashFromId()),
            Match.IdHash.unwrap(rootMatch.hashFromId())
        );
        assertTrue(root.observedOriginatingMatch(twin).commitmentOne.isZero());

        // The client joins the cached address; the Sybil joins the real child.
        SmallFullTree.Data memory hChild = childTreeOf(honest, segment);
        SmallFullTree.Data memory sChild = childTreeOf(sybil, segment);
        rollBy(T + 1);
        join(InspectableTournament(address(twin)), hChild, HONEST);
        join(real, sChild, SYBIL);

        rollTo(closureOf(real));
        (Tree.Node l, Tree.Node r) = hRoot.children(ROOT_HEIGHT, 0);
        vm.expectRevert();
        root.winInnerTournament(twin, l, r);

        propagate(root, real, sRoot);
        rollTo(closureOf(root));
        assertEq(
            uint8(standing(root)),
            uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(dangling(root).eq(sRoot.root()), "the Sybil is seated");
    }

    function testTraceJoinToUncreatedChildIsASilentTransfer() public {
        (SmallFullTree.Data memory hRoot, SmallFullTree.Data memory sRoot) =
            _readyToSeal();
        address next = vm.computeCreateAddress(
            address(factory), vm.getNonce(address(factory))
        );
        assertEq(next.code.length, 0);

        // The fine leaves diverge at 10, inside root segment 2.
        SmallFullTree.Data memory hChild = childTreeOf(honest, 2);
        (Tree.Node l, Tree.Node r) = hChild.children(LEAF_HEIGHT, 0);
        uint256 bond = Bond.bondValue(LEAF_HEIGHT, true);
        vm.prank(HONEST);
        (bool ok,) = next.call{value: bond}(
            abi.encodeCall(
                ITournament.joinTournament,
                (hChild.finalState(), hChild.finalProof(), l, r)
            )
        );
        assertTrue(ok, "a call to an address without code succeeds");

        (InspectableTournament child, uint256 segment) =
            sealInner(root, hRoot, sRoot);
        assertEq(segment, 2);
        assertEq(address(child), next);
        assertEq(next.balance, bond, "the clone absorbed the stranded bond");
        assertFalse(child.commitmentStanding(hChild.root()).joined);
    }
}
