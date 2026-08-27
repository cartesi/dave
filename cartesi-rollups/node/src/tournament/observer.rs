//! Pinned contract observations decoded into wire-independent values.
//!
//! Events own dispute structure and match cleanup schedules. This module reads
//! only the immutable descriptor of a newly discovered tournament, current
//! tournament standings, and the one live match selected by Hero.

use std::collections::HashMap;

#[cfg(test)]
use alloy::primitives::U256;
use alloy::primitives::{Address, B256};
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
            AwaitingChildMatch, BisectingMatch, BlockDuration, DomainError, InnerEliminationReason,
            InnerWinner, JoinDisposition, LiveMatch, LiveMatchState, MatchCoordinate, MatchSide,
            ReadyToSealMatch, RootWinner, SealedDivergence, SealedLeafMatch, TimeoutDisposition,
            TournamentDescriptor, TournamentKind, TournamentStanding, WaitingChildren,
        },
    },
};

type ObserverResult<T> = std::result::Result<T, ObserverError>;

const POINT_READ_CONCURRENCY: usize = 16;

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
    #[error("{view} returned noncanonical inactive field {field}")]
    NonCanonicalInactiveField {
        view: &'static str,
        field: &'static str,
    },
    #[error("timeout outcome {outcome} requires zero deferred charge")]
    NonCanonicalTimeoutCharge { outcome: u8 },
    #[error("absent match timeout must be NONE with zero charge")]
    NonCanonicalAbsentTimeout,
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
    #[error("standing {standing} has invalid acceptsJoins value {accepts_joins}")]
    StandingJoinMismatch { standing: u8, accepts_joins: bool },
    #[error("standing {standing} has invalid hasCandidate value {has_candidate}")]
    StandingCandidateShape { standing: u8, has_candidate: bool },
    #[error("standing {standing} has invalid finishedAt value {finished_at}")]
    StandingFinishedAtShape { standing: u8, finished_at: u64 },
    #[error("inner winner does not map to either side of its recursive parent match")]
    InnerWinnerOutsideParentMatch,
    #[error("live match {match_id_hash} carries an impossible child relationship")]
    MatchChildTopology { match_id_hash: Digest },
    #[error(transparent)]
    Domain(#[from] DomainError),
}

/// Read one immutable descriptor at a caller-supplied block hash.
///
/// The reader calls this once when an event first discovers a tournament and
/// stores the resulting value in the recursive dispute tree.
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

/// Read one current standing for every tournament behind a live parent match.
///
/// All calls are pinned to `head.hash` and provider pressure is bounded. The
/// event-derived tree supplies root/inner position and the exact parent match
/// used to interpret an inner winner. It is not reconciled with redundant
/// match-count, final-state, or topology projections. Nonterminal candidate
/// payloads and finish instants are canonicality-checked and then discarded
/// because events own commitment placement and Hero acts only on current state.
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
    .try_collect::<Vec<_>>()
    .await?;

    let mut standings = HashMap::with_capacity(decoded.len());
    for (address, standing) in decoded {
        let previous = standings.insert(address, standing);
        debug_assert!(previous.is_none(), "Dispute guarantees unique addresses");
    }
    Ok(standings)
}

/// Observe the one event-selected live match needed for a Hero decision.
///
/// Clocked and sealed-leaf matches need a timeout classification plus exactly
/// one phase projection. A delegated match is already known from events to
/// have no local timeout; it needs only `sealedMatch` for Hero calldata and
/// event-child geometry validation.
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
            // NewInnerTournament makes the parent match's local clocks
            // inapplicable. Events own the child address; the sealed projection
            // supplies only the divergence needed for Hero calldata and child
            // geometry validation.
            let wire = contract
                .sealedMatch(match_id_hash.into())
                .block(at)
                .call()
                .await
                .with_context(|| {
                    format!(
                        "observe delegated match {match_id_hash} in tournament {}",
                        descriptor.address()
                    )
                })?;
            let projection_phase = decode_match_phase(wire.actualPhase)?;
            validate_event_phase(match_id_hash, match_.status(), projection_phase)?;
            let state = decode_sealed(
                MatchPhase::Sealed,
                wire.actualPhase,
                wire.value,
                descriptor.kind(),
                Some(child.address()),
                match_id_hash,
            )?;
            let LiveMatchState::AwaitingChild(awaiting) = state else {
                unreachable!("an inner match decodes only as awaiting its child");
            };
            validate_child_geometry(descriptor, child.descriptor(), awaiting.divergence())?;
            (state, TimeoutDisposition::None)
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
            let timeout = decode_timeout(
                timeout_wire.actualPhase,
                timeout_wire.outcome,
                timeout_wire.deferredCharge,
            )?;
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
                    decode_bisecting(timeout.phase, wire.actualPhase, wire.value)?
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
                    decode_ready(
                        timeout.phase,
                        wire.actualPhase,
                        wire.value,
                        descriptor.kind(),
                    )?
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
                        timeout.phase,
                        wire.actualPhase,
                        wire.value,
                        descriptor.kind(),
                        None,
                        match_id_hash,
                    )?
                }
                MatchPhase::Absent => unreachable!("event phase validation rejects absence"),
            };
            (state, timeout.disposition)
        }
    };

    Ok(LiveMatch::try_new(state, disposition)?.validate_in(descriptor)?)
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

fn decode_descriptor(
    address: Address,
    wire: AbiTournamentDescriptor,
) -> ObserverResult<TournamentDescriptor> {
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

    let standing_discriminant = wire.standing;
    let candidate =
        decode_candidate_shape(standing_discriminant, wire.hasCandidate, wire.candidate)?;
    validate_finished_at_shape(standing_discriminant, wire.finishedAt)?;

    let standing = match standing_discriminant {
        0 => {
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            require_zero_hash(
                "tournamentStanding",
                "parentCommitment",
                wire.parentCommitment,
            )?;
            TournamentStanding::MatchesActive {
                joins: if wire.acceptsJoins {
                    JoinDisposition::Open
                } else {
                    JoinDisposition::Closed
                },
            }
        }
        1 => {
            if !wire.acceptsJoins {
                return Err(ObserverError::StandingJoinMismatch {
                    standing: standing_discriminant,
                    accepts_joins: wire.acceptsJoins,
                });
            }
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            require_zero_hash(
                "tournamentStanding",
                "parentCommitment",
                wire.parentCommitment,
            )?;
            TournamentStanding::AwaitingClosure
        }
        2 => {
            if !descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            require_terminal_shape(standing_discriminant, &wire, true)?;
            require_zero_hash(
                "tournamentStanding",
                "parentCommitment",
                wire.parentCommitment,
            )?;
            TournamentStanding::RootWinner(RootWinner::new(
                candidate.expect("shape requires a candidate"),
                wire.finalState.into(),
            ))
        }
        3 => {
            if !descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            require_terminal_shape(standing_discriminant, &wire, false)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            TournamentStanding::RootFailed
        }
        4 => {
            if descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            require_terminal_shape(standing_discriminant, &wire, true)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            let parent_commitment: Digest = wire.parentCommitment.into();
            let parent_match = parent_match.expect("non-root position has a parent match");
            if parent_commitment != parent_match.commitment_one
                && parent_commitment != parent_match.commitment_two
            {
                return Err(ObserverError::InnerWinnerOutsideParentMatch);
            }
            TournamentStanding::InnerWinner(InnerWinner::new(
                parent_commitment,
                candidate.expect("shape requires a candidate"),
            ))
        }
        5 => {
            if descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            require_terminal_shape(standing_discriminant, &wire, false)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            TournamentStanding::InnerEliminable {
                reason: InnerEliminationReason::NoCandidate,
            }
        }
        6 => {
            if descriptor.is_root() {
                return Err(ObserverError::StandingKindMismatch);
            }
            require_terminal_shape(standing_discriminant, &wire, true)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            TournamentStanding::InnerEliminable {
                reason: InnerEliminationReason::WinnerExpired {
                    candidate: candidate.expect("shape requires a candidate"),
                },
            }
        }
        other => return Err(ObserverError::UnknownTournamentStanding(other)),
    };

    Ok(standing)
}

fn decode_timeout(phase: u8, outcome: u8, deferred_charge: u64) -> ObserverResult<TimeoutRead> {
    let phase = decode_match_phase(phase)?;
    let disposition = match outcome {
        0 => TimeoutDisposition::None,
        1 => TimeoutDisposition::OneWins {
            deferred_charge: BlockDuration::from_blocks(deferred_charge),
        },
        2 => TimeoutDisposition::TwoWins {
            deferred_charge: BlockDuration::from_blocks(deferred_charge),
        },
        3 => TimeoutDisposition::EliminateBoth,
        other => return Err(ObserverError::UnknownTimeoutOutcome(other)),
    };

    if phase == MatchPhase::Absent
        && (disposition != TimeoutDisposition::None || deferred_charge != 0)
    {
        return Err(ObserverError::NonCanonicalAbsentTimeout);
    }
    if matches!(
        disposition,
        TimeoutDisposition::None | TimeoutDisposition::EliminateBoth
    ) && deferred_charge != 0
    {
        return Err(ObserverError::NonCanonicalTimeoutCharge { outcome });
    }

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
        MatchStatus::Inner { .. } => ("delegated", observed_phase == MatchPhase::Sealed),
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

fn validate_child_geometry(
    parent: TournamentDescriptor,
    child: TournamentDescriptor,
    divergence: SealedDivergence,
) -> ObserverResult<()> {
    if parent
        .level()
        .checked_add(1)
        .is_none_or(|expected| child.level() != expected)
    {
        return Err(DomainError::ChildLevelMismatch.into());
    }
    if child.initial_hash() != divergence.agree_state() {
        return Err(DomainError::ChildInitialHashMismatch.into());
    }
    if child.base_cycle() != divergence.coordinate().cycle() {
        return Err(DomainError::ChildBaseCycleMismatch.into());
    }
    Ok(())
}

fn decode_bisecting(
    expected_phase: MatchPhase,
    actual_phase: u8,
    wire: AbiBisectingMatchView,
) -> ObserverResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != expected_phase || projection_phase != MatchPhase::Bisecting {
        return Err(ObserverError::ProjectionPhaseMismatch {
            projection: "bisectingMatch",
            expected_phase,
            projection_phase,
        });
    }

    Ok(LiveMatchState::Bisecting(BisectingMatch::try_new(
        wire.revealingParent.into(),
        WaitingChildren::new(wire.waitingLeft.into(), wire.waitingRight.into()),
        MatchCoordinate::new(wire.segmentStartPosition, wire.segmentStartCycle),
        wire.currentHeight,
        decode_side(wire.responder)?,
    )?))
}

fn decode_ready(
    expected_phase: MatchPhase,
    actual_phase: u8,
    wire: AbiReadyToSealMatchView,
    kind: TournamentKind,
) -> ObserverResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != expected_phase || projection_phase != MatchPhase::ReadyToSeal {
        return Err(ObserverError::ProjectionPhaseMismatch {
            projection: "readyToSealMatch",
            expected_phase,
            projection_phase,
        });
    }

    let value = ReadyToSealMatch::new(
        wire.revealingParent.into(),
        WaitingChildren::new(wire.waitingLeft.into(), wire.waitingRight.into()),
        MatchCoordinate::new(wire.segmentStartPosition, wire.segmentStartCycle),
        decode_side(wire.responder)?,
    );
    Ok(match kind {
        TournamentKind::Leaf => LiveMatchState::ReadyToSealLeaf(value),
        TournamentKind::NonLeaf => LiveMatchState::ReadyToDelegate(value),
    })
}

fn decode_sealed(
    expected_phase: MatchPhase,
    actual_phase: u8,
    wire: AbiSealedMatchView,
    kind: TournamentKind,
    child: Option<Address>,
    match_id_hash: Digest,
) -> ObserverResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != expected_phase || projection_phase != MatchPhase::Sealed {
        return Err(ObserverError::ProjectionPhaseMismatch {
            projection: "sealedMatch",
            expected_phase,
            projection_phase,
        });
    }

    let divergence = SealedDivergence::new(
        wire.agreeState.into(),
        MatchCoordinate::new(wire.divergencePosition, wire.divergenceCycle),
        wire.finalStateOne.into(),
        wire.finalStateTwo.into(),
    );
    match (kind, child) {
        (TournamentKind::Leaf, None) => {
            Ok(LiveMatchState::SealedLeaf(SealedLeafMatch::new(divergence)))
        }
        (TournamentKind::NonLeaf, Some(child)) => Ok(LiveMatchState::AwaitingChild(
            AwaitingChildMatch::try_new(divergence, child)?,
        )),
        (TournamentKind::Leaf, Some(_)) | (TournamentKind::NonLeaf, None) => {
            Err(ObserverError::MatchChildTopology { match_id_hash })
        }
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

fn decode_candidate_shape(
    standing: u8,
    has_candidate: bool,
    candidate: B256,
) -> ObserverResult<Option<Digest>> {
    let required = match standing {
        0 | 1 => None,
        2 | 4 | 6 => Some(true),
        3 | 5 => Some(false),
        other => return Err(ObserverError::UnknownTournamentStanding(other)),
    };
    if required.is_some_and(|required| required != has_candidate) {
        return Err(ObserverError::StandingCandidateShape {
            standing,
            has_candidate,
        });
    }
    if has_candidate {
        Ok(Some(candidate.into()))
    } else {
        require_zero_hash("tournamentStanding", "candidate", candidate)?;
        Ok(None)
    }
}

fn validate_finished_at_shape(standing: u8, finished_at: u64) -> ObserverResult<()> {
    let valid = match standing {
        0 | 1 => finished_at == 0,
        2..=6 => finished_at != 0,
        other => return Err(ObserverError::UnknownTournamentStanding(other)),
    };
    if valid {
        Ok(())
    } else {
        Err(ObserverError::StandingFinishedAtShape {
            standing,
            finished_at,
        })
    }
}

fn require_terminal_shape(
    standing: u8,
    wire: &AbiTournamentStandingView,
    has_candidate: bool,
) -> ObserverResult<()> {
    if wire.acceptsJoins {
        return Err(ObserverError::StandingJoinMismatch {
            standing,
            accepts_joins: wire.acceptsJoins,
        });
    }
    if wire.hasCandidate != has_candidate {
        return Err(ObserverError::StandingCandidateShape {
            standing,
            has_candidate: wire.hasCandidate,
        });
    }
    if standing != 4 {
        require_zero_hash(
            "tournamentStanding",
            "parentCommitment",
            wire.parentCommitment,
        )?;
    }
    Ok(())
}

fn require_zero_hash(view: &'static str, field: &'static str, value: B256) -> ObserverResult<()> {
    if value == B256::ZERO {
        Ok(())
    } else {
        Err(ObserverError::NonCanonicalInactiveField { view, field })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tournament::dispute::{Event, EventKind, MatchDeletionReason, WinnerCommitment};

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
        event(
            tournament,
            EventKind::CommitmentJoined {
                root,
                final_state: digest(root.data()[0].wrapping_add(100)),
                submitter: address(root.data()[0]),
            },
        )
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
    fn standing_decode_rejects_discriminants_and_inactive_payloads() {
        let root = descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0);

        assert_eq!(
            decode_standing(root, None, standing_wire(7, false, Some(digest(1)))),
            Err(ObserverError::UnknownTournamentStanding(7))
        );

        let mut active = standing_wire(0, true, Some(digest(1)));
        active.finalState = hash(11);
        assert_eq!(
            decode_standing(root, None, active),
            Err(ObserverError::NonCanonicalInactiveField {
                view: "tournamentStanding",
                field: "finalState",
            })
        );

        assert_eq!(
            decode_standing(root, None, standing_wire(1, false, Some(digest(1)))),
            Err(ObserverError::StandingJoinMismatch {
                standing: 1,
                accepts_joins: false,
            })
        );

        let mut winner = standing_wire(2, false, None);
        winner.finalState = hash(11);
        assert_eq!(
            decode_standing(root, None, winner),
            Err(ObserverError::StandingCandidateShape {
                standing: 2,
                has_candidate: false,
            })
        );

        let mut active = standing_wire(0, false, Some(digest(1)));
        active.parentCommitment = hash(1);
        assert_eq!(
            decode_standing(root, None, active),
            Err(ObserverError::NonCanonicalInactiveField {
                view: "tournamentStanding",
                field: "parentCommitment",
            })
        );

        let mut active = standing_wire(0, false, None);
        active.candidate = hash(1);
        assert_eq!(
            decode_standing(root, None, active),
            Err(ObserverError::NonCanonicalInactiveField {
                view: "tournamentStanding",
                field: "candidate",
            })
        );
    }

    #[test]
    fn standing_finished_at_shape_matches_terminality() {
        for standing in [0, 1] {
            assert_eq!(validate_finished_at_shape(standing, 0), Ok(()));
            assert_eq!(
                validate_finished_at_shape(standing, 42),
                Err(ObserverError::StandingFinishedAtShape {
                    standing,
                    finished_at: 42,
                })
            );
        }
        for standing in 2..=6 {
            assert_eq!(validate_finished_at_shape(standing, 42), Ok(()));
            assert_eq!(
                validate_finished_at_shape(standing, 0),
                Err(ObserverError::StandingFinishedAtShape {
                    standing,
                    finished_at: 0,
                })
            );
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
                joins: JoinDisposition::Closed,
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
        assert_eq!(requests.len(), 1, "resolved children are recovery history");
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
    fn timeout_decode_rejects_unknown_and_noncanonical_combinations() {
        assert_eq!(
            decode_timeout(4, 0, 0),
            Err(ObserverError::UnknownMatchPhase(4))
        );
        assert_eq!(
            decode_timeout(1, 4, 0),
            Err(ObserverError::UnknownTimeoutOutcome(4))
        );
        assert_eq!(
            decode_timeout(0, 1, 0),
            Err(ObserverError::NonCanonicalAbsentTimeout)
        );
        assert_eq!(
            decode_timeout(0, 0, 1),
            Err(ObserverError::NonCanonicalAbsentTimeout)
        );
        assert_eq!(
            decode_timeout(1, 0, 1),
            Err(ObserverError::NonCanonicalTimeoutCharge { outcome: 0 })
        );
        assert_eq!(
            decode_timeout(3, 3, 1),
            Err(ObserverError::NonCanonicalTimeoutCharge { outcome: 3 })
        );
        assert_eq!(
            decode_timeout(1, 2, 7).unwrap().disposition,
            TimeoutDisposition::TwoWins {
                deferred_charge: BlockDuration::from_blocks(7),
            }
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

        let child = Tournament::new(descriptor(
            address(2),
            1,
            TournamentKind::Leaf,
            digest(9),
            0,
        ));
        let inner = MatchStatus::Inner {
            child: Box::new(child),
        };
        assert!(validate_event_phase(match_id_hash, &inner, MatchPhase::Sealed).is_ok());
        assert_eq!(
            validate_event_phase(match_id_hash, &inner, MatchPhase::ReadyToSeal),
            Err(ObserverError::EventPhaseMismatch {
                match_id_hash,
                event_status: "delegated",
                observed_phase: MatchPhase::ReadyToSeal,
            })
        );

        let resolved = MatchStatus::Resolved {
            reason: MatchDeletionReason::Timeout,
            winner: WinnerCommitment::Neither,
            child: None,
        };
        assert_eq!(
            validate_event_phase(match_id_hash, &resolved, MatchPhase::Absent),
            Err(ObserverError::ResolvedMatchSelected { match_id_hash })
        );
    }

    #[test]
    fn projections_reject_every_phase_cross_product_before_payload_decode() {
        let phases = [
            (MatchPhase::Absent, 0),
            (MatchPhase::Bisecting, 1),
            (MatchPhase::ReadyToSeal, 2),
            (MatchPhase::Sealed, 3),
        ];

        for &(expected_phase, _) in &phases {
            for &(projection_phase, actual_phase) in &phases {
                let result = decode_bisecting(expected_phase, actual_phase, bisecting_wire());
                if expected_phase == MatchPhase::Bisecting
                    && projection_phase == MatchPhase::Bisecting
                {
                    assert!(matches!(result, Ok(LiveMatchState::Bisecting(_))));
                } else {
                    assert!(matches!(
                        result,
                        Err(ObserverError::ProjectionPhaseMismatch {
                            projection: "bisectingMatch",
                            ..
                        })
                    ));
                }
            }
        }

        for &(expected_phase, _) in &phases {
            for &(projection_phase, actual_phase) in &phases {
                let result = decode_ready(
                    expected_phase,
                    actual_phase,
                    ready_wire(),
                    TournamentKind::Leaf,
                );
                if expected_phase == MatchPhase::ReadyToSeal
                    && projection_phase == MatchPhase::ReadyToSeal
                {
                    assert!(matches!(result, Ok(LiveMatchState::ReadyToSealLeaf(_))));
                } else {
                    assert!(matches!(
                        result,
                        Err(ObserverError::ProjectionPhaseMismatch {
                            projection: "readyToSealMatch",
                            ..
                        })
                    ));
                }
            }
        }

        for &(expected_phase, _) in &phases {
            for &(projection_phase, actual_phase) in &phases {
                let result = decode_sealed(
                    expected_phase,
                    actual_phase,
                    sealed_wire(),
                    TournamentKind::Leaf,
                    None,
                    digest(8),
                );
                if expected_phase == MatchPhase::Sealed && projection_phase == MatchPhase::Sealed {
                    assert!(matches!(result, Ok(LiveMatchState::SealedLeaf(_))));
                } else {
                    assert!(matches!(
                        result,
                        Err(ObserverError::ProjectionPhaseMismatch {
                            projection: "sealedMatch",
                            ..
                        })
                    ));
                }
            }
        }

        assert_eq!(
            decode_bisecting(
                MatchPhase::Bisecting,
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
    fn sealed_projection_uses_the_event_child_and_validates_its_geometry() {
        assert!(matches!(
            decode_ready(
                MatchPhase::ReadyToSeal,
                2,
                ready_wire(),
                TournamentKind::NonLeaf,
            ),
            Ok(LiveMatchState::ReadyToDelegate(_))
        ));
        let state = decode_sealed(
            MatchPhase::Sealed,
            3,
            sealed_wire(),
            TournamentKind::NonLeaf,
            Some(address(2)),
            digest(8),
        )
        .unwrap();
        let LiveMatchState::AwaitingChild(awaiting) = state else {
            panic!("a non-leaf sealed match must await its event-derived child");
        };
        assert_eq!(awaiting.child_tournament(), address(2));
        assert_eq!(
            decode_sealed(
                MatchPhase::Sealed,
                3,
                sealed_wire(),
                TournamentKind::NonLeaf,
                None,
                digest(8),
            ),
            Err(ObserverError::MatchChildTopology {
                match_id_hash: digest(8),
            })
        );
        assert_eq!(
            decode_sealed(
                MatchPhase::Sealed,
                3,
                sealed_wire(),
                TournamentKind::Leaf,
                Some(address(2)),
                digest(8),
            ),
            Err(ObserverError::MatchChildTopology {
                match_id_hash: digest(8),
            })
        );

        let parent = descriptor(address(1), 0, TournamentKind::NonLeaf, digest(9), 0);
        let divergence = awaiting.divergence();
        let child = descriptor(address(2), 1, TournamentKind::Leaf, digest(20), 24);
        assert!(validate_child_geometry(parent, child, divergence).is_ok());
        assert_eq!(
            validate_child_geometry(
                parent,
                descriptor(address(2), 1, TournamentKind::Leaf, digest(99), 24),
                divergence,
            ),
            Err(ObserverError::Domain(DomainError::ChildInitialHashMismatch))
        );
        assert_eq!(
            validate_child_geometry(
                parent,
                descriptor(address(2), 1, TournamentKind::Leaf, digest(20), 25),
                divergence,
            ),
            Err(ObserverError::Domain(DomainError::ChildBaseCycleMismatch))
        );
    }
}
