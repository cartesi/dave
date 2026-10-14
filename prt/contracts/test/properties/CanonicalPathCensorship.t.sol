// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {CanonicalTournamentParametersProvider} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Clock} from "src/tournament/libs/Clock.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";
import {Tree} from "src/types/Tree.sol";
import {ScriptProviderArguments} from "test/fixtures/ScriptProviderArguments.sol";

import {ConfigurableCommitmentFixture} from "test/fixtures/ConfigurableCommitmentFixture.sol";
import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {ProofSelectedStateTransition} from "test/fixtures/ProofSelectedStateTransition.sol";
import {TournamentInspector} from "test/fixtures/TournamentInspector.sol";

/// @dev The canonical provider exactly as `DeploymentScript.run` encodes it
/// for the current chain id.
/// @dev Lead, not an exploit: modality "chain assumptions", questions 4 and 5.
///
/// Runs one canonical root-to-leaf path ([54, 38] over [38, 0]) against the
/// real canonical provider, deployed with the script's own arguments for a
/// registered chain id, and a proof-selected settlement stub. The Sybil is
/// commitment one at both levels and acts in the block it may; the honest
/// party is commitment two and lands each action `delay` blocks after it
/// becomes possible (a censoring sequencer's forced-inclusion latency).
///
/// Uncensored, the honest party takes exactly 50 actions on the path: the
/// root join, 26 advances and the inner seal at height 54, the child join,
/// 18 advances and the leaf seal at height 38, the leaf proof, and the
/// propagation. The return refill equals the provider's `T + 2G` exactly.
///
/// Censored by a sequencer at the registered block times, a correct
/// commitment loses at the root: Arbitrum One (12 s, C = 1 week) after 7
/// landed actions at a 24 h forced-inclusion delay, OP Mainnet (2 s,
/// C = 1 week) after 14 at 12 h, and the 8 h testnet rows cannot even land
/// the root join. The violated assumption is the model's cumulative
/// censorship bound, which a single sequencer is not bound by; registration
/// is not support (dispute-game.md, Clock model), so this prices a non-claim.
contract CanonicalPathCensorshipTest is Test, ConfigurableCommitmentFixture {
    using TournamentInspector for ITournament;
    using Tree for Tree.Node;
    using Time for Time.Instant;
    using Time for Time.Duration;
    using {unwrapped} for Time.Duration;

    uint64 constant ROOT_H = 54;
    uint64 constant LEAF_H = 38;
    uint64 constant START = 1_000;

    Machine.Hash constant A = Machine.Hash.wrap(bytes32(uint256(0xa)));
    Machine.Hash constant B = Machine.Hash.wrap(bytes32(uint256(0xb)));
    Machine.Hash constant C = Machine.Hash.wrap(bytes32(uint256(0xc)));

    address constant HONEST = address(0xa11ce);
    address constant SYBIL = address(0xbad);

    // The correct computation is all-A; the Sybil differs at the last leaf.
    CommitmentShape constant HONEST_SHAPE = CommitmentShape.SAME;
    CommitmentShape constant SYBIL_SHAPE = CommitmentShape.RIGHTMOST_DIFFERENT;

    MultiLevelTournamentFactory factory;
    TournamentParameters row;
    uint256 honestActions;

    ITournament root;
    ITournament child;
    Match.Id rootId;
    Match.Id childId;

    function setUp() public {
        initializeCommitmentFixture(ROOT_H, A, B, C);
        vm.fee(0);
        vm.txGasPrice(0);
    }

    //
    // Leads
    //

    function testTraceCanonicalPathTakesFiftyHonestActions() public {
        _deployFor(1);
        assertTrue(_runPath(0, 0), "uncensored path must succeed");
        assertEq(honestActions, 50, "honest actions on one canonical path");

        vm.roll(_closure(root));
        ITournament.TournamentStandingView memory s = root.tournamentStanding();
        assertEq(
            uint8(s.standing), uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(s.candidate.eq(node(HONEST_SHAPE, ROOT_H)));
    }

    function testTraceArbitrumOneSequencerDefeatsCanonicalPath() public {
        // 24 h at the registered 12 s parent-chain block.
        _assertCensoredLoss(42161, 24 hours / 12 seconds, 7);
    }

    function testTraceOpMainnetSequencerDefeatsCanonicalPath() public {
        // 12 h at the registered 2 s L2 block.
        _assertCensoredLoss(10, 12 hours / 2 seconds, 14);
    }

    /// @dev The root segment binds a uniform per-action latency `D`: the join
    /// costs `D` and each of the 27 root responses `D - G`, so the seal lands
    /// only while `28 D < maxAllowance + 26 G`. At Ethereum's row that is
    /// 1848 blocks (about 6.2 h, the same wall time at any block time for a
    /// one-week C); the child is easier because its allowance is the pair's
    /// larger remainder.
    function testTraceEthereumUniformDelayThreshold() public {
        _deployFor(1);
        uint64 g = row.responseBudget.unwrapped();
        uint64 threshold = (row.maxAllowance.unwrapped() + 26 * g - 1) / 28;
        assertEq(threshold, 1848);

        honestActions = 0;
        assertTrue(_runPath(threshold, row.commitmentBudget.unwrapped()));
        assertEq(honestActions, 50);

        _deployFor(1);
        honestActions = 0;
        assertFalse(_runPath(threshold + 1, row.commitmentBudget.unwrapped()));
        assertEq(honestActions, 27, "the inner seal is the first refused");
    }

    function testTraceTestnetSequencerBlocksTheRootJoin() public {
        _assertCensoredLoss(421614, 24 hours / 12 seconds, 0);
        _assertCensoredLoss(11155420, 12 hours / 2 seconds, 0);
    }

    //
    // Path
    //

    function _assertCensoredLoss(
        uint256 chainId,
        uint64 delay,
        uint256 expectedLanded
    ) internal {
        _deployFor(chainId);
        honestActions = 0;
        assertFalse(_runPath(delay, row.commitmentBudget.unwrapped()));
        assertEq(honestActions, expectedLanded, "honest actions landed");

        if (expectedLanded > 0) {
            // The honest clock is overdue; the Sybil, paused with nearly its
            // whole allowance, claims the root match.
            (Tree.Node l, Tree.Node r) = children(SYBIL_SHAPE, ROOT_H);
            root.winMatchByTimeout(rootId, l, r);
        }
        vm.roll(_max(block.number, _closure(root)));
        ITournament.TournamentStandingView memory s = root.tournamentStanding();
        assertEq(
            uint8(s.standing), uint8(ITournament.TournamentStanding.ROOT_WINNER)
        );
        assertTrue(s.candidate.eq(node(SYBIL_SHAPE, ROOT_H)), "wrong winner");
        assertEq(Machine.Hash.unwrap(s.finalState), Machine.Hash.unwrap(B));
    }

    /// @return survived whether every honest action landed
    function _runPath(uint64 delay, uint64 build) internal returns (bool) {
        vm.roll(START);
        root = factory.instantiate(A, IDataProvider(address(0)));
        assertTrue(_join(root, SYBIL_SHAPE, SYBIL), "sybil root join");

        vm.roll(block.number + delay);
        if (!_join(root, HONEST_SHAPE, HONEST)) return false;
        ++honestActions;
        rootId = Match.Id(node(SYBIL_SHAPE, ROOT_H), node(HONEST_SHAPE, ROOT_H));
        if (!_bisect(root, rootId, ROOT_H, delay)) return false;

        // Height 54 is even, so commitment two (honest) reveals last.
        vm.roll(block.number + delay);
        (Tree.Node l, Tree.Node r) = children(HONEST_SHAPE, 1);
        vm.recordLogs();
        try root.sealInnerMatchAndCreateInnerTournament(
            rootId,
            l,
            r,
            secondLastState(HONEST_SHAPE, ROOT_H),
            agreeProofForSecondLast(HONEST_SHAPE, ROOT_H)
        ) {}
        catch {
            return false;
        }
        ++honestActions;
        child = _recordedChild(root, vm.getRecordedLogs());

        assertTrue(_join(child, SYBIL_SHAPE, SYBIL), "sybil child join");
        vm.roll(block.number + build + delay);
        if (!_join(child, HONEST_SHAPE, HONEST)) return false;
        ++honestActions;
        childId =
            Match.Id(node(SYBIL_SHAPE, LEAF_H), node(HONEST_SHAPE, LEAF_H));
        if (!_bisect(child, childId, LEAF_H, delay)) return false;

        vm.roll(block.number + delay);
        try child.sealLeafMatch(
            childId,
            l,
            r,
            secondLastState(HONEST_SHAPE, LEAF_H),
            agreeProofForSecondLast(HONEST_SHAPE, LEAF_H)
        ) {}
        catch {
            return false;
        }
        ++honestActions;

        vm.roll(block.number + delay);
        (l, r) = children(HONEST_SHAPE, LEAF_H);
        try child.winLeafMatch(
            childId, l, r, abi.encode(Machine.Hash.unwrap(A))
        ) {}
        catch {
            return false;
        }
        ++honestActions;

        vm.roll(_max(block.number, _closure(child)) + delay);
        uint64 carried = child.innerResult().pausedAllowance.unwrapped();
        uint64 envelope = _max64(
            _allowance(root, rootId.commitmentOne),
            _allowance(root, rootId.commitmentTwo)
        );
        (l, r) = children(HONEST_SHAPE, ROOT_H);
        try root.winInnerTournament(child, l, r) {}
        catch {
            return false;
        }
        ++honestActions;

        // winInnerTournament refills by the row's T + 2G, which is the
        // refill ClockBudgets folds into maxAllowance.
        uint64 refill = row.commitmentBudget.unwrapped() + 2
            * row.responseBudget.unwrapped();
        assertEq(
            _allowance(root, rootId.commitmentTwo),
            _min64(carried + refill, envelope),
            "refill"
        );
        return true;
    }

    /// @dev Commitment one reveals at the full height; the honest side, two,
    /// answers on every odd step below it.
    function _bisect(
        ITournament t,
        Match.Id memory id,
        uint64 height,
        uint64 delay
    ) internal returns (bool) {
        for (uint64 h = height; h > 1; --h) {
            if ((height - h) % 2 == 1) {
                vm.roll(block.number + delay);
                if (!_advance(t, id, HONEST_SHAPE, h)) return false;
                ++honestActions;
            } else {
                assertTrue(_advance(t, id, SYBIL_SHAPE, h), "sybil advance");
            }
        }
        return true;
    }

    //
    // Helpers
    //

    function _deployFor(uint256 chainId) internal {
        vm.chainId(chainId);
        bytes memory code = abi.encodePacked(
            type(CanonicalTournamentParametersProvider).creationCode,
            new ScriptProviderArguments().providerArguments()
        );
        address provider;
        assembly ("memory-safe") {
            provider := create(0, add(code, 32), mload(code))
        }
        require(provider != address(0), "provider deployment failed");
        factory = new MultiLevelTournamentFactory(
            new InspectableTournament(),
            ITournamentParametersProvider(provider),
            new ProofSelectedStateTransition()
        );
        row = factory.tournamentParameters(0);
        assertEq(row.levels, ArbitrationConstants.LEVELS);
        assertEq(row.height, ROOT_H);
        assertEq(factory.tournamentParameters(1).height, LEAF_H);
    }

    function _join(ITournament t, CommitmentShape shape, address who)
        internal
        returns (bool)
    {
        (,,, uint64 h) = t.tournamentLevelConstants();
        (Tree.Node l, Tree.Node r) = children(shape, h);
        uint256 bond = t.bondValue();
        vm.deal(who, bond);
        vm.prank(who);
        try t.joinTournament{value: bond}(
            finalState(shape, h), finalProof(shape, h), l, r
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _advance(
        ITournament t,
        Match.Id memory id,
        CommitmentShape shape,
        uint64 h
    ) internal returns (bool) {
        (Tree.Node l, Tree.Node r) = children(shape, h);
        (Tree.Node nl, Tree.Node nr) = children(shape, h - 1);
        try t.advanceMatch(id, l, r, nl, nr) {
            return true;
        } catch {
            return false;
        }
    }

    function _recordedChild(ITournament parent, Vm.Log[] memory logs)
        internal
        pure
        returns (ITournament)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(parent)
                    && logs[i].topics[0]
                        == ITournament.NewInnerTournament.selector
            ) {
                return ITournament(address(uint160(uint256(logs[i].topics[2]))));
            }
        }
        revert("no child recorded");
    }

    function _allowance(ITournament t, Tree.Node commitment)
        internal
        view
        returns (uint64)
    {
        (Clock.State memory clock,) = t.getCommitment(commitment);
        return clock.allowance.unwrapped();
    }

    function _closure(ITournament t) internal view returns (uint256) {
        ITournament.TournamentArguments memory args = t.tournamentArguments();
        return Time.Instant.unwrap(args.startInstant.add(args.allowance));
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _max64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a : b;
    }

    function _min64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }
}

function unwrapped(Time.Duration d) pure returns (uint64) {
    return Time.Duration.unwrap(d);
}
