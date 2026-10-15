//! Pinned contract observations decoded into wire-independent values.
//!
//! Events own dispute structure and match cleanup schedules. This module reads
//! only the root tournament's immutable descriptor, current tournament
//! standings, the one clocked or sealed-leaf match the Hero engages at a
//! level, and a join's bond. It decodes a child's descriptor from its creation
//! event and bounds it by its parent's, so a delegated match needs no read.

use std::collections::HashMap;

use alloy::primitives::{Address, U256};
use anyhow::{Context, Result as AnyResult};
use cartesi_prt_contracts::tournament::{
    self,
    ITournament::{
        BisectingMatchView as AbiBisectingMatchView,
        ReadyToSealMatchView as AbiReadyToSealMatchView, SealedMatchView as AbiSealedMatchView,
        TournamentDescriptor as AbiTournamentDescriptor,
        TournamentStandingView as AbiTournamentStandingView,
    },
};
use futures::{StreamExt, TryStreamExt, stream};
use thiserror::Error;

use crate::{
    chain::{Chain, ChainHead},
    merkle::Digest,
    tournament::{
        MatchID,
        dispute::{Dispute, Match, MatchStatus, Tournament},
        domain::{
            DomainError, InnerEliminationReason, InnerWinner, LiveMatch, LiveMatchState,
            MatchCoordinate, MatchSide, RootWinner, SealedDivergence, TimeoutDisposition,
            TournamentDescriptor, TournamentKind, TournamentStanding, UnresolvedMatch,
            WaitingChildren, validate_match_geometry,
        },
    },
};

type ObserverResult<T> = std::result::Result<T, ObserverError>;

pub(crate) const POINT_READ_CONCURRENCY: usize = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchPhase {
    Absent,
    Bisecting,
    ReadyToSeal,
    Sealed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TimeoutRead {
    phase: MatchPhase,
    disposition: TimeoutDisposition,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum ObserverError {
    #[error("unknown match phase discriminant {0}")]
    UnknownMatchPhase(u8),
    #[error("unknown timeout outcome discriminant {0}")]
    UnknownTimeoutOutcome(u8),
    #[error("unknown tournament kind discriminant {0}")]
    UnknownTournamentKind(u8),
    #[error("unknown tournament standing discriminant {0}")]
    UnknownTournamentStanding(u8),
    #[error("unknown commitment side discriminant {0}")]
    UnknownCommitmentSide(u8),
    #[error(
        "{projection} projection phase {projection_phase:?} disagrees with expected phase {expected_phase:?}"
    )]
    ProjectionPhaseMismatch {
        projection: &'static str,
        expected_phase: MatchPhase,
        projection_phase: MatchPhase,
    },
    #[error(
        "event-derived {event_status} match {match_id_hash} disagrees with observed phase {observed_phase:?}"
    )]
    EventPhaseMismatch {
        match_id_hash: Digest,
        event_status: &'static str,
        observed_phase: MatchPhase,
    },
    #[error("cannot observe resolved match {match_id_hash}")]
    ResolvedMatchSelected { match_id_hash: Digest },
    #[error("tournament standing is not legal for this root/inner position")]
    StandingKindMismatch,
    #[error("standing {standing} reports no candidate")]
    StandingCandidateShape { standing: u8 },
    #[error("inner winner does not map to either side of its recursive parent match")]
    InnerWinnerOutsideParentMatch,
    #[error("live match {match_id_hash} carries an impossible child relationship")]
    MatchChildTopology { match_id_hash: Digest },
    #[error(transparent)]
    Domain(#[from] DomainError),
}

/// Read one immutable descriptor at a caller-supplied block hash.
///
/// The reader calls this for the root when it folds from the root's creation
/// block: the node reads no factory logs, so no event carries the root's. A
/// child's comes with its `NewInnerTournament` event ([`decode_descriptor`]).
pub async fn read_descriptor(
    chain: &Chain,
    address: Address,
    head: ChainHead,
) -> AnyResult<TournamentDescriptor> {
    let wire = tournament::Tournament::new(address, chain.provider())
        .tournamentDescriptor()
        .block(head.block_id())
        .call()
        .await
        .with_context(|| format!("read descriptor for tournament {address}"))?;
    decode_descriptor(address, wire)
        .with_context(|| format!("decode descriptor for tournament {address}"))
}

/// Read a tournament's join bond at the block of the intent being
/// fulfilled. The contract rejects a join that deposits less.
pub async fn read_bond(chain: &Chain, tournament: Address, head: ChainHead) -> AnyResult<U256> {
    tournament::Tournament::new(tournament, chain.provider())
        .bondValue()
        .block(head.block_id())
        .call()
        .await
        .with_context(|| format!("read bond for tournament {tournament}"))
}

/// Read one current standing for every tournament behind a live parent match.
///
/// All calls are pinned to `head.hash` and provider pressure is bounded. The
/// event-derived tree supplies root/inner position and the exact parent match
/// used to interpret an inner winner. It is not reconciled with redundant
/// match-count, final-state, or topology projections. Fields the decoded
/// standing does not carry (a nonterminal candidate, the finish and
/// winner-expiry instants, a non-active standing's join flag) go unchecked:
/// events own commitment placement, Hero acts only on current state, and a
/// value that disagrees with the standing must not stall a tick.
pub async fn read_standings(
    chain: &Chain,
    dispute: &Dispute,
    head: ChainHead,
) -> AnyResult<HashMap<Address, TournamentStanding>> {
    let mut requests = Vec::new();
    collect_standing_requests(dispute.root(), None, &mut requests);
    let at = head.block_id();

    let decoded = stream::iter(requests.into_iter().map(|request| {
        let contract = tournament::Tournament::new(request.descriptor.address(), chain.provider());
        async move {
            let wire = contract
                .tournamentStanding()
                .block(at)
                .call()
                .await
                .with_context(|| {
                    format!(
                        "observe standing for tournament {}",
                        request.descriptor.address()
                    )
                })?;
            let address = request.descriptor.address();
            let standing = decode_standing(request.descriptor, request.parent_match, wire)
                .with_context(|| format!("decode standing for tournament {address}"))?;
            Ok::<_, anyhow::Error>((address, standing))
        }
    }))
    .buffered(POINT_READ_CONCURRENCY)
    .try_collect::<HashMap<_, _>>()
    .await?;
    Ok(decoded)
}

/// Observe the one event-selected live match needed for a Hero decision.
///
/// Clocked and sealed-leaf matches need a timeout classification plus exactly
/// one phase projection. A delegated match is answered from events: its local
/// clocks no longer apply, and nothing the Hero sends from it reads its sealed
/// divergence. Its child's descriptor is bounded by the parent's instead.
pub async fn read_match(
    chain: &Chain,
    tournament: &Tournament,
    match_: &Match,
    head: ChainHead,
) -> AnyResult<LiveMatch> {
    let descriptor = tournament.descriptor();
    let id = match_.id();
    let match_id_hash = match_.id_hash();
    let at = head.block_id();
    let contract = tournament::Tournament::new(descriptor.address(), chain.provider());

    let (state, disposition) = match match_.status() {
        MatchStatus::Resolved { .. } => {
            return Err(ObserverError::ResolvedMatchSelected { match_id_hash }.into());
        }
        MatchStatus::Inner { child } => {
            // A Leaf tournament cannot delegate: its child would sit one
            // level past the pinned table, where context assembly panics.
            if descriptor.kind() != TournamentKind::NonLeaf {
                return Err(ObserverError::MatchChildTopology { match_id_hash }.into());
            }
            validate_child_geometry(descriptor, child.descriptor())?;
            (
                LiveMatchState::AwaitingChild(child.address()),
                TimeoutDisposition::None,
            )
        }
        MatchStatus::Clocked { .. } | MatchStatus::Leaf { .. } => {
            let timeout_wire = contract
                .classifyMatchTimeout(id.into())
                .block(at)
                .call()
                .await
                .with_context(|| {
                    format!(
                        "observe timeout for match {match_id_hash} in tournament {}",
                        descriptor.address()
                    )
                })?;
            let timeout = decode_timeout(timeout_wire.actualPhase, timeout_wire.outcome)?;
            validate_event_phase(match_id_hash, match_.status(), timeout.phase)?;

            let state = match timeout.phase {
                MatchPhase::Bisecting => {
                    let wire = contract
                        .bisectingMatch(match_id_hash.into())
                        .block(at)
                        .call()
                        .await
                        .with_context(|| {
                            format!(
                                "observe bisection for match {match_id_hash} in tournament {}",
                                descriptor.address()
                            )
                        })?;
                    decode_bisecting(wire.actualPhase, wire.value)?
                }
                MatchPhase::ReadyToSeal => {
                    let wire = contract
                        .readyToSealMatch(match_id_hash.into())
                        .block(at)
                        .call()
                        .await
                        .with_context(|| {
                            format!(
                                "observe ready-to-seal match {match_id_hash} in tournament {}",
                                descriptor.address()
                            )
                        })?;
                    decode_ready(wire.actualPhase, wire.value, descriptor.kind())?
                }
                MatchPhase::Sealed => {
                    let wire = contract
                        .sealedMatch(match_id_hash.into())
                        .block(at)
                        .call()
                        .await
                        .with_context(|| {
                            format!(
                                "observe sealed match {match_id_hash} in tournament {}",
                                descriptor.address()
                            )
                        })?;
                    decode_sealed(
                        wire.actualPhase,
                        wire.value,
                        descriptor.kind(),
                        match_id_hash,
                    )?
                }
                MatchPhase::Absent => unreachable!("event phase validation rejects absence"),
            };
            (state, timeout.disposition)
        }
    };

    validate_match_geometry(descriptor, state)?;
    Ok(LiveMatch::new(state, disposition))
}

#[derive(Clone, Copy)]
struct StandingRequest {
    descriptor: TournamentDescriptor,
    parent_match: Option<MatchID>,
}

fn collect_standing_requests(
    tournament: &Tournament,
    parent_match: Option<MatchID>,
    requests: &mut Vec<StandingRequest>,
) {
    requests.push(StandingRequest {
        descriptor: tournament.descriptor(),
        parent_match,
    });
    for match_ in tournament.matches() {
        if let MatchStatus::Inner { child } = match_.status() {
            collect_standing_requests(child, Some(match_.id()), requests);
        }
    }
}

pub(crate) fn decode_descriptor(
    address: Address,
    wire: AbiTournamentDescriptor,
) -> ObserverResult<TournamentDescriptor> {
    // startInstant/allowance describe the join window for observers; Hero
    // acts eagerly on current state, so they are not decoded here.
    TournamentDescriptor::try_new(
        address,
        wire.level,
        decode_tournament_kind(wire.kind)?,
        wire.initialHash.into(),
        wire.baseCycle,
        wire.log2Stride,
        wire.height,
    )
    .map_err(Into::into)
}

fn decode_standing(
    descriptor: TournamentDescriptor,
    parent_match: Option<MatchID>,
    wire: AbiTournamentStandingView,
) -> ObserverResult<TournamentStanding> {
    if descriptor.is_root() != parent_match.is_none() {
        return Err(ObserverError::StandingKindMismatch);
    }

    let standing = match wire.standing {
        0 => TournamentStanding::MatchesActive {
            accepts_joins: wire.acceptsJoins,
        },
        1 => TournamentStanding::AwaitingClosure,
        2 => {
            if !descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            TournamentStanding::RootWinner(RootWinner::new(
                require_candidate(&wire)?,
                wire.finalState.into(),
            ))
        }
        3 => {
            if !descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            TournamentStanding::RootFailed
        }
        4 => {
            if descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            // finalState carries the winner's claimed final state, which
            // events own; it is discarded.
            let parent_commitment: Digest = wire.parentCommitment.into();
            let parent_match = parent_match.expect("non-root position has a parent match");
            if parent_commitment != parent_match.commitment_one
                && parent_commitment != parent_match.commitment_two
            {
                return Err(ObserverError::InnerWinnerOutsideParentMatch);
            }
            TournamentStanding::InnerWinner(InnerWinner::new(
                parent_commitment,
                require_candidate(&wire)?,
            ))
        }
        5 => {
            if descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            TournamentStanding::InnerEliminable {
                reason: InnerEliminationReason::NoCandidate,
            }
        }
        6 => {
            if descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            TournamentStanding::InnerEliminable {
                reason: InnerEliminationReason::WinnerExpired {
                    candidate: require_candidate(&wire)?,
                },
            }
        }
        other => return Err(ObserverError::UnknownTournamentStanding(other)),
    };

    Ok(standing)
}

/// The deferred charge is not decoded: winning by timeout sends no charge.
fn decode_timeout(phase: u8, outcome: u8) -> ObserverResult<TimeoutRead> {
    let phase = decode_match_phase(phase)?;
    let disposition = match outcome {
        0 => TimeoutDisposition::None,
        1 => TimeoutDisposition::OneWins,
        2 => TimeoutDisposition::TwoWins,
        3 => TimeoutDisposition::EliminateBoth,
        other => return Err(ObserverError::UnknownTimeoutOutcome(other)),
    };
    Ok(TimeoutRead { phase, disposition })
}

fn validate_event_phase(
    match_id_hash: Digest,
    status: &MatchStatus,
    observed_phase: MatchPhase,
) -> ObserverResult<()> {
    let (event_status, valid) = match status {
        MatchStatus::Clocked { .. } => (
            "clocked",
            matches!(
                observed_phase,
                MatchPhase::Bisecting | MatchPhase::ReadyToSeal
            ),
        ),
        MatchStatus::Leaf { .. } => ("sealed leaf", observed_phase == MatchPhase::Sealed),
        MatchStatus::Inner { .. } => unreachable!("a delegated match is answered from events"),
        MatchStatus::Resolved { .. } => {
            return Err(ObserverError::ResolvedMatchSelected { match_id_hash });
        }
    };
    if valid {
        Ok(())
    } else {
        Err(ObserverError::EventPhaseMismatch {
            match_id_hash,
            event_status,
            observed_phase,
        })
    }
}

/// A delegated child must sit one level below its parent, with its base cycle
/// on one of the parent's leaves: exactly the cycles a sealed divergence in
/// the parent can name. This bound runs before context assembly computes the
/// child's commitment, so it keeps every child coordinate, and every cycle
/// the engine proves, inside the parent's span.
fn validate_child_geometry(
    parent: TournamentDescriptor,
    child: TournamentDescriptor,
) -> ObserverResult<()> {
    if parent
        .level()
        .checked_add(1)
        .is_none_or(|expected| child.level() != expected)
    {
        return Err(DomainError::ChildLevelMismatch.into());
    }
    // TournamentDescriptor::try_new keeps stride plus height below 256.
    let leaf = U256::from(1) << parent.log2_stride();
    let span = leaf << parent.height().get();
    let on_a_leaf = child
        .base_cycle()
        .checked_sub(parent.base_cycle())
        .is_some_and(|offset| offset < span && (offset % leaf).is_zero());
    if !on_a_leaf {
        return Err(DomainError::ChildOutsideParentLeaf.into());
    }
    Ok(())
}

fn decode_bisecting(
    actual_phase: u8,
    wire: AbiBisectingMatchView,
) -> ObserverResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != MatchPhase::Bisecting {
        return Err(ObserverError::ProjectionPhaseMismatch {
            projection: "bisectingMatch",
            expected_phase: MatchPhase::Bisecting,
            projection_phase,
        });
    }

    Ok(LiveMatchState::Bisecting(UnresolvedMatch {
        revealing_parent: wire.revealingParent.into(),
        waiting_children: WaitingChildren::new(wire.waitingLeft.into(), wire.waitingRight.into()),
        coordinate: MatchCoordinate::new(wire.segmentStartPosition, wire.segmentStartCycle),
        height: wire.currentHeight,
        responder: decode_side(wire.responder)?,
    }))
}

fn decode_ready(
    actual_phase: u8,
    wire: AbiReadyToSealMatchView,
    kind: TournamentKind,
) -> ObserverResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != MatchPhase::ReadyToSeal {
        return Err(ObserverError::ProjectionPhaseMismatch {
            projection: "readyToSealMatch",
            expected_phase: MatchPhase::ReadyToSeal,
            projection_phase,
        });
    }

    let value = UnresolvedMatch {
        revealing_parent: wire.revealingParent.into(),
        waiting_children: WaitingChildren::new(wire.waitingLeft.into(), wire.waitingRight.into()),
        coordinate: MatchCoordinate::new(wire.segmentStartPosition, wire.segmentStartCycle),
        height: 1,
        responder: decode_side(wire.responder)?,
    };
    Ok(match kind {
        TournamentKind::Leaf => LiveMatchState::ReadyToSealLeaf(value),
        TournamentKind::NonLeaf => LiveMatchState::ReadyToDelegate(value),
    })
}

fn decode_sealed(
    actual_phase: u8,
    wire: AbiSealedMatchView,
    kind: TournamentKind,
    match_id_hash: Digest,
) -> ObserverResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != MatchPhase::Sealed {
        return Err(ObserverError::ProjectionPhaseMismatch {
            projection: "sealedMatch",
            expected_phase: MatchPhase::Sealed,
            projection_phase,
        });
    }

    let divergence = SealedDivergence::new(
        wire.agreeState.into(),
        MatchCoordinate::new(wire.divergencePosition, wire.divergenceCycle),
        wire.finalStateOne.into(),
        wire.finalStateTwo.into(),
    );
    match kind {
        TournamentKind::Leaf => Ok(LiveMatchState::SealedLeaf(divergence)),
        TournamentKind::NonLeaf => Err(ObserverError::MatchChildTopology { match_id_hash }),
    }
}

fn decode_match_phase(value: u8) -> ObserverResult<MatchPhase> {
    match value {
        0 => Ok(MatchPhase::Absent),
        1 => Ok(MatchPhase::Bisecting),
        2 => Ok(MatchPhase::ReadyToSeal),
        3 => Ok(MatchPhase::Sealed),
        other => Err(ObserverError::UnknownMatchPhase(other)),
    }
}

fn decode_tournament_kind(value: u8) -> ObserverResult<TournamentKind> {
    match value {
        0 => Ok(TournamentKind::Leaf),
        1 => Ok(TournamentKind::NonLeaf),
        other => Err(ObserverError::UnknownTournamentKind(other)),
    }
}

fn decode_side(value: u8) -> ObserverResult<MatchSide> {
    match value {
        0 => Ok(MatchSide::One),
        1 => Ok(MatchSide::Two),
        other => Err(ObserverError::UnknownCommitmentSide(other)),
    }
}

fn require_candidate(wire: &AbiTournamentStandingView) -> ObserverResult<Digest> {
    if wire.hasCandidate {
        Ok(wire.candidate.into())
    } else {
        Err(ObserverError::StandingCandidateShape {
            standing: wire.standing,
        })
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::B256;

    use super::*;
    use crate::{
        chain::recording::recording_provider,
        tournament::{
            dispute::{Event, EventKind, WinnerCommitment},
            domain::MatchDeletionReason,
        },
    };

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn hash(byte: u8) -> B256 {
        digest(byte).into()
    }

    fn descriptor(
        at: Address,
        level: u64,
        kind: TournamentKind,
        initial_hash: Digest,
        base_cycle: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(at, level, kind, initial_hash, U256::from(base_cycle), 3, 4)
            .unwrap()
    }

    fn descriptor_wire(level: u64, kind: u8) -> AbiTournamentDescriptor {
        AbiTournamentDescriptor {
            initialHash: hash(9),
            baseCycle: U256::ZERO,
            log2Stride: 3,
            height: 4,
            level,
            kind,
            startInstant: 100,
            allowance: 20,
        }
    }

    fn standing_wire(
        standing: u8,
        accepts_joins: bool,
        candidate: Option<Digest>,
    ) -> AbiTournamentStandingView {
        AbiTournamentStandingView {
            standing,
            acceptsJoins: accepts_joins,
            hasCandidate: candidate.is_some(),
            candidate: candidate.map_or(B256::ZERO, Into::into),
            finalState: B256::ZERO,
            parentCommitment: B256::ZERO,
            finishedAt: u64::from(standing >= 2),
            winnerExpiresAt: if standing == 4 { 130 } else { 0 },
        }
    }

    fn bisecting_wire() -> AbiBisectingMatchView {
        AbiBisectingMatchView {
            revealingParent: hash(3),
            waitingLeft: hash(4),
            waitingRight: hash(5),
            segmentStartPosition: U256::ZERO,
            segmentStartCycle: U256::ZERO,
            currentHeight: 2,
            responder: 0,
        }
    }

    fn ready_wire() -> AbiReadyToSealMatchView {
        AbiReadyToSealMatchView {
            revealingParent: hash(3),
            waitingLeft: hash(4),
            waitingRight: hash(5),
            segmentStartPosition: U256::ZERO,
            segmentStartCycle: U256::ZERO,
            responder: 1,
        }
    }

    fn sealed_wire() -> AbiSealedMatchView {
        AbiSealedMatchView {
            agreeState: hash(20),
            divergencePosition: U256::from(3),
            divergenceCycle: U256::from(24),
            finalStateOne: hash(21),
            finalStateTwo: hash(22),
        }
    }

    fn event(tournament: Address, kind: EventKind) -> Event {
        Event { tournament, kind }
    }

    fn join(tournament: Address, root: Digest) -> Event {
        event(tournament, EventKind::CommitmentJoined { root })
    }

    #[test]
    fn descriptor_decode_accepts_contract_kind_and_validates_geometry() {
        let at = address(1);
        assert_eq!(
            decode_descriptor(at, descriptor_wire(0, 2)),
            Err(ObserverError::UnknownTournamentKind(2))
        );
        assert_eq!(
            decode_descriptor(at, descriptor_wire(7, 1))
                .unwrap()
                .level(),
            7,
            "the descriptor is not reconciled with a second level source"
        );

        let mut zero_height = descriptor_wire(0, 0);
        zero_height.height = 0;
        assert_eq!(
            decode_descriptor(at, zero_height),
            Err(ObserverError::Domain(DomainError::ZeroCommitmentHeight))
        );

        let mut overflowing = descriptor_wire(0, 0);
        overflowing.baseCycle = U256::MAX;
        assert_eq!(
            decode_descriptor(at, overflowing),
            Err(ObserverError::Domain(
                DomainError::TournamentCycleRangeOverflow
            ))
        );
    }

    #[test]
    fn standing_decode_rejects_unknown_discriminants_and_missing_candidates() {
        let root = descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0);
        let child = descriptor(address(2), 1, TournamentKind::Leaf, digest(9), 0);
        let parent_match = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };

        assert_eq!(
            decode_standing(root, None, standing_wire(7, false, Some(digest(1)))),
            Err(ObserverError::UnknownTournamentStanding(7))
        );

        assert_eq!(
            decode_standing(root, None, standing_wire(2, false, None)),
            Err(ObserverError::StandingCandidateShape { standing: 2 })
        );
        let mut inner_winner = standing_wire(4, false, None);
        inner_winner.parentCommitment = hash(1);
        assert_eq!(
            decode_standing(child, Some(parent_match), inner_winner),
            Err(ObserverError::StandingCandidateShape { standing: 4 })
        );
        assert_eq!(
            decode_standing(child, Some(parent_match), standing_wire(6, false, None)),
            Err(ObserverError::StandingCandidateShape { standing: 6 })
        );
    }

    #[test]
    fn standing_decode_takes_join_flags_and_winner_expiry_as_reported() {
        let root = descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0);
        let child = descriptor(address(2), 1, TournamentKind::Leaf, digest(9), 0);
        let parent_match = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        let inner_winner = |accepts_joins, winner_expires_at| {
            let mut wire = standing_wire(4, accepts_joins, Some(digest(30)));
            wire.parentCommitment = hash(2);
            wire.winnerExpiresAt = winner_expires_at;
            wire
        };
        let mut root_winner = standing_wire(2, true, Some(digest(77)));
        root_winner.finalState = hash(88);

        let cases = [
            (
                child,
                inner_winner(false, 0),
                TournamentStanding::InnerWinner(InnerWinner::new(digest(2), digest(30))),
            ),
            (
                root,
                standing_wire(1, false, None),
                TournamentStanding::AwaitingClosure,
            ),
            (
                root,
                root_winner,
                TournamentStanding::RootWinner(RootWinner::new(digest(77), digest(88))),
            ),
            (
                root,
                standing_wire(3, true, None),
                TournamentStanding::RootFailed,
            ),
            (
                child,
                inner_winner(true, 130),
                TournamentStanding::InnerWinner(InnerWinner::new(digest(2), digest(30))),
            ),
            (
                child,
                standing_wire(5, true, None),
                TournamentStanding::InnerEliminable {
                    reason: InnerEliminationReason::NoCandidate,
                },
            ),
            (
                child,
                standing_wire(6, true, Some(digest(30))),
                TournamentStanding::InnerEliminable {
                    reason: InnerEliminationReason::WinnerExpired {
                        candidate: digest(30),
                    },
                },
            ),
        ];
        for (descriptor, wire, expected) in cases {
            let parent = (!descriptor.is_root()).then_some(parent_match);
            assert_eq!(decode_standing(descriptor, parent, wire), Ok(expected));
        }
    }

    #[test]
    fn standing_retains_only_fields_needed_for_actions() {
        let root = descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0);
        let mut wire = standing_wire(2, false, Some(digest(77)));
        wire.finalState = hash(88);
        wire.finishedAt = 42;

        assert_eq!(
            decode_standing(root, None, wire).unwrap(),
            TournamentStanding::RootWinner(RootWinner::new(digest(77), digest(88)))
        );
        assert_eq!(
            decode_standing(root, None, standing_wire(0, false, Some(digest(66))),).unwrap(),
            TournamentStanding::MatchesActive {
                accepts_joins: false,
            }
        );
    }

    #[test]
    fn inner_winner_maps_through_the_recursive_parent_match() {
        let child = descriptor(address(2), 1, TournamentKind::Leaf, digest(9), 0);
        let parent_match = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        let mut wire = standing_wire(4, false, Some(digest(30)));
        wire.parentCommitment = hash(2);
        wire.finalState = hash(31);

        assert_eq!(
            decode_standing(child, Some(parent_match), wire.clone()).unwrap(),
            TournamentStanding::InnerWinner(InnerWinner::new(digest(2), digest(30)))
        );

        wire.parentCommitment = hash(99);
        assert_eq!(
            decode_standing(child, Some(parent_match), wire),
            Err(ObserverError::InnerWinnerOutsideParentMatch)
        );
    }

    #[test]
    fn standing_requests_follow_only_live_recursive_parent_matches() {
        let root_descriptor = descriptor(address(1), 0, TournamentKind::NonLeaf, digest(9), 0);
        let child_descriptor = descriptor(address(2), 1, TournamentKind::Leaf, digest(20), 24);
        let root = root_descriptor.address();
        let id = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        let dispute = Dispute::try_new(root_descriptor)
            .unwrap()
            .apply_block([join(root, digest(1))])
            .unwrap()
            .apply_block([
                join(root, digest(2)),
                event(
                    root,
                    EventKind::MatchCreated {
                        id,
                        eliminable_at: 10,
                    },
                ),
            ])
            .unwrap()
            .apply_block([event(
                root,
                EventKind::NewInnerTournament {
                    match_id_hash: id.hash(),
                    child: child_descriptor,
                },
            )])
            .unwrap();

        let mut requests = Vec::new();
        collect_standing_requests(dispute.root(), None, &mut requests);
        assert_eq!(
            requests
                .iter()
                .map(|request| (request.descriptor.address(), request.parent_match))
                .collect::<Vec<_>>(),
            vec![(root, None), (child_descriptor.address(), Some(id))]
        );

        let dispute = dispute
            .apply_block([join(child_descriptor.address(), digest(3))])
            .unwrap()
            .apply_block([event(
                root,
                EventKind::MatchDeleted {
                    match_id_hash: id.hash(),
                    reason: MatchDeletionReason::ChildTournament,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap();
        let mut requests = Vec::new();
        collect_standing_requests(dispute.root(), None, &mut requests);
        assert_eq!(requests.len(), 1, "a resolution drops its child");
        assert_eq!(requests[0].descriptor.address(), root);
        assert_eq!(requests[0].parent_match, None);
    }

    #[test]
    fn standing_kind_follows_recursive_position() {
        let root = descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0);
        let child = descriptor(address(2), 1, TournamentKind::Leaf, digest(9), 0);
        let parent_match = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };

        assert_eq!(
            decode_standing(root, Some(parent_match), standing_wire(0, true, None)),
            Err(ObserverError::StandingKindMismatch)
        );
        assert_eq!(
            decode_standing(child, None, standing_wire(0, true, None)),
            Err(ObserverError::StandingKindMismatch)
        );

        let mut root_winner = standing_wire(2, false, Some(digest(1)));
        root_winner.finalState = hash(11);
        assert_eq!(
            decode_standing(child, Some(parent_match), root_winner),
            Err(ObserverError::StandingKindMismatch)
        );

        let mut inner_winner = standing_wire(4, false, Some(digest(1)));
        inner_winner.parentCommitment = hash(1);
        assert_eq!(
            decode_standing(root, None, inner_winner),
            Err(ObserverError::StandingKindMismatch)
        );
    }

    #[test]
    fn timeout_decode_rejects_unknown_discriminants() {
        assert_eq!(
            decode_timeout(4, 0),
            Err(ObserverError::UnknownMatchPhase(4))
        );
        assert_eq!(
            decode_timeout(1, 4),
            Err(ObserverError::UnknownTimeoutOutcome(4))
        );
        assert_eq!(
            decode_timeout(1, 2).unwrap().disposition,
            TimeoutDisposition::TwoWins
        );
    }

    #[test]
    fn event_status_accepts_only_its_action_local_phases() {
        let match_id_hash = digest(8);
        let clocked = MatchStatus::Clocked { eliminable_at: 9 };
        assert!(validate_event_phase(match_id_hash, &clocked, MatchPhase::Bisecting).is_ok());
        assert!(validate_event_phase(match_id_hash, &clocked, MatchPhase::ReadyToSeal).is_ok());
        assert_eq!(
            validate_event_phase(match_id_hash, &clocked, MatchPhase::Sealed),
            Err(ObserverError::EventPhaseMismatch {
                match_id_hash,
                event_status: "clocked",
                observed_phase: MatchPhase::Sealed,
            })
        );

        let leaf = MatchStatus::Leaf { eliminable_at: 10 };
        assert!(validate_event_phase(match_id_hash, &leaf, MatchPhase::Sealed).is_ok());
        assert_eq!(
            validate_event_phase(match_id_hash, &leaf, MatchPhase::Absent),
            Err(ObserverError::EventPhaseMismatch {
                match_id_hash,
                event_status: "sealed leaf",
                observed_phase: MatchPhase::Absent,
            })
        );

        let resolved = MatchStatus::Resolved {
            reason: MatchDeletionReason::Timeout,
            winner: WinnerCommitment::Neither,
        };
        assert_eq!(
            validate_event_phase(match_id_hash, &resolved, MatchPhase::Absent),
            Err(ObserverError::ResolvedMatchSelected { match_id_hash })
        );
    }

    #[test]
    fn projections_decode_only_their_own_phase() {
        for actual_phase in 0..=3 {
            let result = decode_bisecting(actual_phase, bisecting_wire());
            if actual_phase == 1 {
                assert!(matches!(result, Ok(LiveMatchState::Bisecting(_))));
            } else {
                assert!(matches!(
                    result,
                    Err(ObserverError::ProjectionPhaseMismatch {
                        projection: "bisectingMatch",
                        expected_phase: MatchPhase::Bisecting,
                        ..
                    })
                ));
            }

            let result = decode_ready(actual_phase, ready_wire(), TournamentKind::Leaf);
            if actual_phase == 2 {
                assert!(matches!(result, Ok(LiveMatchState::ReadyToSealLeaf(_))));
            } else {
                assert!(matches!(
                    result,
                    Err(ObserverError::ProjectionPhaseMismatch {
                        projection: "readyToSealMatch",
                        expected_phase: MatchPhase::ReadyToSeal,
                        ..
                    })
                ));
            }

            let result =
                decode_sealed(actual_phase, sealed_wire(), TournamentKind::Leaf, digest(8));
            if actual_phase == 3 {
                assert!(matches!(result, Ok(LiveMatchState::SealedLeaf(_))));
            } else {
                assert!(matches!(
                    result,
                    Err(ObserverError::ProjectionPhaseMismatch {
                        projection: "sealedMatch",
                        expected_phase: MatchPhase::Sealed,
                        ..
                    })
                ));
            }
        }

        assert_eq!(
            decode_bisecting(
                1,
                AbiBisectingMatchView {
                    responder: 2,
                    ..bisecting_wire()
                }
            ),
            Err(ObserverError::UnknownCommitmentSide(2))
        );
    }

    #[test]
    fn a_sealed_match_decodes_only_in_a_leaf_tournament() {
        assert!(matches!(
            decode_ready(2, ready_wire(), TournamentKind::NonLeaf),
            Ok(LiveMatchState::ReadyToDelegate(_))
        ));
        assert!(matches!(
            decode_sealed(3, sealed_wire(), TournamentKind::Leaf, digest(8)),
            Ok(LiveMatchState::SealedLeaf(_))
        ));
        assert_eq!(
            decode_sealed(3, sealed_wire(), TournamentKind::NonLeaf, digest(8)),
            Err(ObserverError::MatchChildTopology {
                match_id_hash: digest(8),
            })
        );
    }

    #[test]
    fn a_delegated_child_sits_one_level_down_on_a_parent_leaf() {
        // Stride 2^3 and height 4: a parent's leaves start every 8 cycles
        // across a span of 128.
        let parent = |base_cycle| {
            descriptor(
                address(1),
                0,
                TournamentKind::NonLeaf,
                digest(9),
                base_cycle,
            )
        };
        let child = |level, base_cycle| {
            descriptor(
                address(2),
                level,
                TournamentKind::Leaf,
                digest(20),
                base_cycle,
            )
        };

        for (parent_base, child_base) in [(0, 0), (0, 120), (128, 128), (128, 248)] {
            assert_eq!(
                validate_child_geometry(parent(parent_base), child(1, child_base)),
                Ok(())
            );
        }
        // One leaf past the span, below the parent, and between two leaves.
        for (parent_base, child_base) in [(0, 128), (128, 0), (0, 4)] {
            assert_eq!(
                validate_child_geometry(parent(parent_base), child(1, child_base)),
                Err(ObserverError::Domain(DomainError::ChildOutsideParentLeaf))
            );
        }
        assert_eq!(
            validate_child_geometry(parent(0), child(2, 0)),
            Err(ObserverError::Domain(DomainError::ChildLevelMismatch))
        );
    }

    fn delegated(root_kind: TournamentKind, child_base_cycle: u64) -> (Dispute, MatchID) {
        let root = descriptor(address(1), 0, root_kind, digest(9), 0);
        let child = descriptor(
            address(2),
            1,
            TournamentKind::Leaf,
            digest(20),
            child_base_cycle,
        );
        let id = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        let dispute = Dispute::try_new(root)
            .unwrap()
            .apply_block([
                join(root.address(), digest(1)),
                join(root.address(), digest(2)),
                event(
                    root.address(),
                    EventKind::MatchCreated {
                        id,
                        eliminable_at: 10,
                    },
                ),
            ])
            .unwrap()
            .apply_block([event(
                root.address(),
                EventKind::NewInnerTournament {
                    match_id_hash: id.hash(),
                    child,
                },
            )])
            .unwrap();
        (dispute, id)
    }

    #[tokio::test]
    async fn a_delegated_match_is_answered_without_a_read() {
        let (provider, _asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        let head = ChainHead {
            number: 7,
            hash: hash(7),
        };

        let (dispute, id) = delegated(TournamentKind::NonLeaf, 24);
        let root = dispute.root();
        let match_ = root.match_by_id_hash(&id.hash()).unwrap();
        assert_eq!(
            read_match(&chain, root, match_, head).await.unwrap(),
            LiveMatch::new(
                LiveMatchState::AwaitingChild(address(2)),
                TimeoutDisposition::None
            )
        );

        for (root_kind, child_base_cycle, expected) in [
            (
                TournamentKind::Leaf,
                24,
                ObserverError::MatchChildTopology {
                    match_id_hash: id.hash(),
                },
            ),
            (
                TournamentKind::NonLeaf,
                128,
                ObserverError::Domain(DomainError::ChildOutsideParentLeaf),
            ),
        ] {
            let (dispute, id) = delegated(root_kind, child_base_cycle);
            let root = dispute.root();
            let match_ = root.match_by_id_hash(&id.hash()).unwrap();
            let error = read_match(&chain, root, match_, head).await.unwrap_err();
            assert_eq!(error.downcast_ref::<ObserverError>(), Some(&expected));
        }

        assert!(requests.lock().unwrap().is_empty());
    }
}
