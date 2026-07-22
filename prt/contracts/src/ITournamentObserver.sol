// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

/// @notice Total, semantic observations over one tournament clone.
/// @dev These DTOs are independent from the storage structs retained by
/// `ITournament`. A projection always returns the match's actual phase; payload
/// fields are meaningful only when that phase matches the projection.
interface ITournamentObserver {
    enum MatchTimeoutOutcome {
        NONE,
        ONE_WINS,
        TWO_WINS,
        ELIMINATE_BOTH
    }

    enum TournamentKind {
        LEAF,
        NON_LEAF
    }

    enum TournamentStanding {
        MATCHES_ACTIVE,
        AWAITING_CLOSURE,
        ROOT_WINNER,
        ROOT_FAILED,
        INNER_WINNER,
        INNER_ELIMINABLE_NO_WINNER,
        INNER_ELIMINABLE_WINNER_EXPIRED
    }

    struct BisectingMatchView {
        Tree.Node revealingParent;
        Tree.Node waitingLeft;
        Tree.Node waitingRight;
        uint256 segmentStartPosition;
        uint256 segmentStartCycle;
        uint64 currentHeight;
        Match.CommitmentSide responder;
    }

    struct ReadyToSealMatchView {
        Tree.Node revealingParent;
        Tree.Node waitingLeft;
        Tree.Node waitingRight;
        uint256 segmentStartPosition;
        uint256 segmentStartCycle;
        Match.CommitmentSide responder;
    }

    struct SealedMatchView {
        Machine.Hash agreeState;
        uint256 divergencePosition;
        uint256 divergenceCycle;
        Machine.Hash finalStateOne;
        Machine.Hash finalStateTwo;
    }

    struct TournamentDescriptor {
        Machine.Hash initialHash;
        uint256 baseCycle;
        uint64 log2step;
        uint64 height;
        uint64 level;
        uint64 levels;
        TournamentKind kind;
    }

    struct TournamentStandingView {
        TournamentStanding standing;
        bool acceptsJoins;
        bool hasCandidate;
        Tree.Node candidate;
        Machine.Hash finalState;
        Tree.Node parentCommitment;
    }

    /// @notice Project an active, non-terminal bisection by its storage key.
    /// @dev Always returns the stored match's actual phase. `value` is
    /// canonically all-zero unless that phase is `BISECTING`. `responder`
    /// identifies the commitment side whose clock and opening turn are active.
    function bisectingMatch(Match.IdHash matchIdHash)
        external
        view
        returns (Match.Phase actualPhase, BisectingMatchView memory value);

    /// @notice Project the final bisection step by its storage key.
    /// @dev Always returns the stored match's actual phase. `value` is
    /// canonically all-zero unless that phase is `READY_TO_SEAL`. `responder`
    /// identifies the commitment side whose clock and sealing turn are active.
    function readyToSealMatch(Match.IdHash matchIdHash)
        external
        view
        returns (Match.Phase actualPhase, ReadyToSealMatchView memory value);

    /// @notice Project a sealed divergence by its storage key.
    /// @dev Always returns the stored match's actual phase. `value` is
    /// canonically all-zero unless that phase is `SEALED`. Final states are
    /// oriented to commitment sides one and two, independent of reveal order.
    function sealedMatch(Match.IdHash matchIdHash)
        external
        view
        returns (Match.Phase actualPhase, SealedMatchView memory value);

    /// @notice Classify the timeout action available for one full match id now.
    /// @dev Match existence is established before reading historical clocks.
    /// An absent or deleted match returns `(UNINITIALIZED, NONE, 0)`.
    /// `deferredCharge` is zero for `NONE`, `ELIMINATE_BOTH`, and a leaf-race
    /// winner; an active-match winner may carry the expired responder's overdue
    /// duration. Existing matches with impossible phase/clock shapes revert.
    function matchTimeoutStatus(Match.Id calldata matchId)
        external
        view
        returns (
            Match.Phase actualPhase,
            MatchTimeoutOutcome outcome,
            Time.Duration deferredCharge
        );

    /// @notice Return immutable geometry and level identity for this clone.
    /// @dev `kind` distinguishes leaf from non-leaf; root versus inner is
    /// derived from `level`.
    function tournamentDescriptor()
        external
        view
        returns (TournamentDescriptor memory);

    /// @notice Return the tournament's current settlement disposition.
    /// @dev Inactive fields are canonically zero. `acceptsJoins` is exactly
    /// `!isClosed()` for every standing, including closed tournaments that
    /// still have active matches. `hasCandidate` disambiguates the zero node.
    /// `finalState` is populated only for `ROOT_WINNER`, and
    /// `parentCommitment` only for `INNER_WINNER`.
    function tournamentStanding()
        external
        view
        returns (TournamentStandingView memory);
}
