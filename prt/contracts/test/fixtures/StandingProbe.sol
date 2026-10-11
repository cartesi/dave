// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {ITournament} from "src/ITournament.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

/// @dev Checks a `StandingChanged` emission against the production views at
/// every boundary it claims, then restores the chain state.
abstract contract StandingProbe is Test {
    struct Standing {
        uint256 matchCount;
        Tree.Node dangling;
        Tree.Node parentCommitment;
        uint64 resultAt;
        uint64 winnerExpiresAt;
    }

    bytes32 internal constant STANDING_TOPIC =
        keccak256("StandingChanged(uint256,bytes32,bytes32,uint64,uint64)");

    function _standings(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (uint256 count, Standing memory last)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != emitter
                    || logs[i].topics[0] != STANDING_TOPIC
            ) {
                continue;
            }
            ++count;
            (
                last.matchCount,
                last.dangling,
                last.parentCommitment,
                last.resultAt,
                last.winnerExpiresAt
            ) =
                abi.decode(
                    logs[i].data,
                    (uint256, Tree.Node, Tree.Node, uint64, uint64)
                );
        }
    }

    /// @dev Index of the first log of `emitter` with `topic0`, or max.
    function _indexOf(Vm.Log[] memory logs, address emitter, bytes32 topic0)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic0) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /// @dev Rolls to every boundary the event claims and compares with the
    /// production views, then restores the chain state.
    function _probe(ITournament t, Standing memory s) internal {
        uint256 snap = vm.snapshotState();
        uint256 nowB = vm.getBlockNumber();
        ITournament.TournamentDescriptor memory d = t.tournamentDescriptor();
        bool inner = d.level != 0;
        if (s.matchCount != 0) {
            assertEq(s.resultAt, 0, "resultAt nonzero with matches");
            assertEq(s.winnerExpiresAt, 0, "expiry nonzero with matches");
            assertEq(
                Tree.Node.unwrap(s.parentCommitment),
                0,
                "parentCommitment nonzero with matches"
            );
            assertEq(
                uint8(t.tournamentStanding().standing),
                uint8(ITournament.TournamentStanding.MATCHES_ACTIVE)
            );
            vm.revertToState(snap);
            return;
        }
        if (s.resultAt > nowB) {
            vm.roll(s.resultAt - 1);
            ITournament.TournamentStandingView memory before =
                t.tournamentStanding();
            assertEq(
                uint8(before.standing),
                uint8(ITournament.TournamentStanding.AWAITING_CLOSURE),
                "finished before resultAt"
            );
            assertEq(Time.Instant.unwrap(before.finishedAt), 0);
            if (inner) {
                assertEq(
                    uint8(t.innerResult().disposition),
                    uint8(ITournament.InnerTournamentDisposition.UNSETTLED)
                );
            }
        }
        if (s.resultAt > nowB) {
            vm.roll(s.resultAt);
        }
        ITournament.TournamentStandingView memory atResult =
            t.tournamentStanding();
        assertEq(
            Time.Instant.unwrap(atResult.finishedAt),
            s.resultAt,
            "finishedAt != resultAt"
        );
        assertEq(
            Tree.Node.unwrap(atResult.candidate), Tree.Node.unwrap(s.dangling)
        );
        if (!inner) {
            assertEq(s.winnerExpiresAt, 0);
            assertEq(Tree.Node.unwrap(s.parentCommitment), 0);
            assertEq(
                uint8(atResult.standing),
                Tree.Node.unwrap(s.dangling) == 0
                    ? uint8(ITournament.TournamentStanding.ROOT_FAILED)
                    : uint8(ITournament.TournamentStanding.ROOT_WINNER)
            );
            vm.revertToState(snap);
            return;
        }
        if (Tree.Node.unwrap(s.dangling) == 0) {
            assertEq(s.winnerExpiresAt, 0);
            assertEq(
                uint8(t.innerResult().disposition),
                uint8(ITournament.InnerTournamentDisposition.ELIMINABLE)
            );
            vm.revertToState(snap);
            return;
        }
        assertEq(
            Time.Instant.unwrap(atResult.winnerExpiresAt),
            s.winnerExpiresAt,
            "view winnerExpiresAt != event"
        );
        assertEq(
            Tree.Node.unwrap(atResult.parentCommitment),
            Tree.Node.unwrap(s.parentCommitment)
        );
        ITournament.InnerResultView memory r = t.innerResult();
        assertEq(
            uint8(r.disposition),
            uint8(ITournament.InnerTournamentDisposition.WINNER)
        );
        assertEq(
            Tree.Node.unwrap(r.parentCommitment),
            Tree.Node.unwrap(s.parentCommitment)
        );
        assertEq(
            uint256(Time.Duration.unwrap(r.pausedAllowance)),
            uint256(s.winnerExpiresAt - s.resultAt),
            "carried at resultAt"
        );
        vm.roll(s.winnerExpiresAt - 1);
        r = t.innerResult();
        assertEq(
            uint8(r.disposition),
            uint8(ITournament.InnerTournamentDisposition.WINNER),
            "not winner at expiry-1"
        );
        assertEq(Time.Duration.unwrap(r.pausedAllowance), 1);
        vm.roll(s.winnerExpiresAt);
        r = t.innerResult();
        assertEq(
            uint8(r.disposition),
            uint8(ITournament.InnerTournamentDisposition.ELIMINABLE),
            "not eliminable at expiry"
        );
        assertEq(
            uint8(t.tournamentStanding().standing),
            uint8(
                ITournament.TournamentStanding.INNER_ELIMINABLE_WINNER_EXPIRED
            )
        );
        vm.revertToState(snap);
    }
}
