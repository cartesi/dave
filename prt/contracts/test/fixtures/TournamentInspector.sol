// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Clones} from "@openzeppelin-contracts-5.5.0/proxy/Clones.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {ITournament} from "prt-contracts/ITournament.sol";
import {Clock} from "prt-contracts/tournament/libs/Clock.sol";
import {Commitment} from "prt-contracts/tournament/libs/Commitment.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {MatchClocks} from "prt-contracts/tournament/libs/MatchClocks.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @notice Test-only replacements for the retired raw ITournament views.
/// @dev Raw state comes from `vm.load` against the pinned storage layout, so
/// these tests remain the raw-layout compatibility witnesses. Closure and
/// finish predicates are re-derived from the clone arguments and block
/// number, independent of the observer ABI, so assertions against them are
/// oracle checks rather than echoes. Only `arbitrationResult` reads through
/// the production `tournamentStanding` surface, mirroring DaveConsensus.
library TournamentInspector {
    using Time for Time.Instant;
    using Time for Time.Duration;
    using Tree for Tree.Node;
    using Commitment for Commitment.Arguments;
    using Match for Match.Id;
    using Match for Match.State;

    Vm private constant VM =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Pinned Tournament storage layout (semantic layout hash is gated by
    // compatibility-hashes; update together).
    uint256 private constant MATCH_COUNT_SLOT = 1;
    uint256 private constant LAST_MATCH_DELETED_SLOT = 2;
    uint256 private constant CLOCKS_SLOT = 8;
    uint256 private constant FINAL_STATES_SLOT = 9;
    uint256 private constant MATCHES_SLOT = 11;

    function tournamentArguments(ITournament tournament)
        internal
        view
        returns (ITournament.TournamentArguments memory)
    {
        return abi.decode(
            Clones.fetchCloneArgs(address(tournament)),
            (ITournament.TournamentArguments)
        );
    }

    function tournamentLevelConstants(ITournament tournament)
        internal
        view
        returns (uint64 maxLevel, uint64 level, uint64 log2step, uint64 height)
    {
        ITournament.TournamentArguments memory args =
            tournamentArguments(tournament);
        return (
            args.levels,
            args.level,
            args.commitmentArgs.log2step,
            args.commitmentArgs.height
        );
    }

    function isClosed(ITournament tournament) internal view returns (bool) {
        ITournament.TournamentArguments memory args =
            tournamentArguments(tournament);
        return args.startInstant.timeoutElapsed(args.allowance);
    }

    function isFinished(ITournament tournament) internal view returns (bool) {
        return isClosed(tournament) && _matchCount(tournament) == 0;
    }

    function timeFinished(ITournament tournament)
        internal
        view
        returns (bool, Time.Instant)
    {
        if (!isFinished(tournament)) {
            return (false, Time.ZERO_INSTANT);
        }

        ITournament.TournamentArguments memory args =
            tournamentArguments(tournament);
        Time.Instant closedAt = args.startInstant.add(args.allowance);
        Time.Instant lastMatchDeleted = Time.Instant
            .wrap(
                uint64(
                    uint256(
                        VM.load(
                            address(tournament),
                            bytes32(LAST_MATCH_DELETED_SLOT)
                        )
                    )
                )
            );
        return (true, closedAt.max(lastMatchDeleted));
    }

    function arbitrationResult(ITournament tournament)
        internal
        view
        returns (bool, Tree.Node, Machine.Hash)
    {
        ITournament.TournamentStandingView memory standing =
            tournament.tournamentStanding();
        if (standing.standing == ITournament.TournamentStanding.ROOT_WINNER) {
            return (true, standing.candidate, standing.finalState);
        } else if (
            standing.standing == ITournament.TournamentStanding.ROOT_FAILED
        ) {
            revert ITournament.TournamentFailedNoWinner();
        } else {
            return (false, Tree.ZERO_NODE, Machine.ZERO_STATE);
        }
    }

    function canBeEliminated(ITournament tournament)
        internal
        view
        returns (bool)
    {
        return tournament.innerResult().disposition
            == ITournament.InnerTournamentDisposition.ELIMINABLE;
    }

    function innerTournamentWinner(ITournament tournament)
        internal
        view
        returns (bool, Tree.Node, Tree.Node, Clock.State memory)
    {
        ITournament.InnerResultView memory result = tournament.innerResult();
        Clock.State memory clock;
        if (result.disposition != ITournament.InnerTournamentDisposition.WINNER)
        {
            return (false, Tree.ZERO_NODE, Tree.ZERO_NODE, clock);
        }

        clock.allowance = result.pausedAllowance;
        return (
            true,
            result.parentCommitment,
            tournament.tournamentStanding().candidate,
            clock
        );
    }

    function getCommitment(ITournament tournament, Tree.Node commitmentRoot)
        internal
        view
        returns (Clock.State memory clock, Machine.Hash finalState)
    {
        uint256 packed = uint256(
            VM.load(
                address(tournament),
                keccak256(abi.encode(commitmentRoot, CLOCKS_SLOT))
            )
        );
        clock.allowance = Time.Duration.wrap(uint64(packed));
        clock.startInstant = Time.Instant.wrap(uint64(packed >> 64));
        finalState = Machine.Hash
            .wrap(
                VM.load(
                    address(tournament),
                    keccak256(abi.encode(commitmentRoot, FINAL_STATES_SLOT))
                )
            );
    }

    function getMatch(ITournament tournament, Match.IdHash matchIdHash)
        internal
        view
        returns (Match.State memory state)
    {
        uint256 base = uint256(keccak256(abi.encode(matchIdHash, MATCHES_SLOT)));
        state.otherParent =
            Tree.Node.wrap(VM.load(address(tournament), bytes32(base)));
        state.leftNode =
            Tree.Node.wrap(VM.load(address(tournament), bytes32(base + 1)));
        state.rightNode =
            Tree.Node.wrap(VM.load(address(tournament), bytes32(base + 2)));
        state.runningLeafPosition =
            uint256(VM.load(address(tournament), bytes32(base + 3)));
        uint256 packed =
            uint256(VM.load(address(tournament), bytes32(base + 4)));
        state.currentHeight = uint64(packed);
        state.isInit = uint8(packed >> 64) != 0;
    }

    function getMatchCycle(ITournament tournament, Match.IdHash matchIdHash)
        internal
        view
        returns (uint256)
    {
        Match.State memory state = getMatch(tournament, matchIdHash);
        require(state.exists(), ITournament.MatchDoesNotExist());
        ITournament.TournamentArguments memory args =
            tournamentArguments(tournament);
        return args.commitmentArgs.toCycle(state.runningLeafPosition);
    }

    function canWinMatchByTimeout(
        ITournament tournament,
        Match.Id memory matchId
    ) internal view returns (bool) {
        if (!getMatch(tournament, matchId.hashFromId()).exists()) {
            return false;
        }

        (Clock.State memory one,) =
            getCommitment(tournament, matchId.commitmentOne);
        (Clock.State memory two,) =
            getCommitment(tournament, matchId.commitmentTwo);
        MatchClocks.TimeoutStatus memory status =
            MatchClocks.classifyTimeoutAt(one, two, Time.currentTime());
        return status.outcome == MatchClocks.TimeoutOutcome.ONE_WINS
            || status.outcome == MatchClocks.TimeoutOutcome.TWO_WINS;
    }

    function _matchCount(ITournament tournament)
        private
        view
        returns (uint256)
    {
        return uint256(VM.load(address(tournament), bytes32(MATCH_COUNT_SLOT)));
    }
}
