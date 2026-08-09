//! Strict boundary from generated observer DTOs plus the structural fold into
//! wire-independent tournament observations.
//!
//! The adapter owns ABI discriminants, active payload validation, and the
//! fold/view join. Hero context assembly and GC planning consume only these
//! validated observations.

use std::collections::HashMap;

#[cfg(test)]
use alloy::primitives::U256;
use alloy::{
    eips::BlockId,
    primitives::{Address, B256},
};
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
        domain::{
            AwaitingChildMatch, BisectingMatch, BlockDuration, DomainError, InnerEliminationReason,
            InnerWinner, JoinDisposition, LiveMatch, LiveMatchState, MatchCoordinate, MatchSide,
            ReadyToSealMatch, RootWinner, SealedDivergence, SealedLeafMatch, TimeoutDisposition,
            TournamentDescriptor, TournamentKind, TournamentStanding, WaitingChildren,
        },
        fold::{Fold, MatchFold, TournamentFold, WinnerCommitment},
    },
};

type AdapterResult<T> = std::result::Result<T, AdapterError>;

const POINT_READ_CONCURRENCY: usize = 16;

/// One full-ID live match after strict ABI and geometry validation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ObservedMatch {
    id: MatchID,
    live: LiveMatch,
}

impl ObservedMatch {
    #[cfg(test)]
    pub(crate) const fn from_parts(id: MatchID, live: LiveMatch) -> Self {
        Self { id, live }
    }

    pub const fn id(self) -> MatchID {
        self.id
    }

    pub const fn live(self) -> LiveMatch {
        self.live
    }
}

/// Actor-neutral current state for one reachable tournament.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TournamentObservation {
    descriptor: TournamentDescriptor,
    standing: TournamentStanding,
    matches: HashMap<Digest, ObservedMatch>,
}

impl TournamentObservation {
    #[cfg(test)]
    pub(crate) fn from_parts(
        descriptor: TournamentDescriptor,
        standing: TournamentStanding,
        matches: HashMap<Digest, ObservedMatch>,
    ) -> Self {
        Self {
            descriptor,
            standing,
            matches,
        }
    }

    pub const fn descriptor(&self) -> TournamentDescriptor {
        self.descriptor
    }

    pub const fn standing(&self) -> TournamentStanding {
        self.standing
    }

    pub fn match_by_id_hash(&self, id_hash: &Digest) -> Option<ObservedMatch> {
        self.matches.get(id_hash).copied()
    }
}

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
pub enum AdapterError {
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
        "{projection} projection phase {projection_phase:?} disagrees with timeout phase {timeout_phase:?}"
    )]
    ProjectionPhaseMismatch {
        projection: &'static str,
        timeout_phase: MatchPhase,
        projection_phase: MatchPhase,
    },
    #[error("fold sees live match {match_id_hash} but observer reports it absent")]
    FoldLiveMatchAbsent { match_id_hash: Digest },
    #[error("descriptor level {descriptor_level} disagrees with fold level {fold_level}")]
    DescriptorLevelMismatch {
        descriptor_level: u64,
        fold_level: u64,
    },
    #[error("tournament standing is not legal for this root/inner level")]
    StandingKindMismatch,
    #[error("standing {standing} has invalid acceptsJoins value {accepts_joins}")]
    StandingJoinMismatch { standing: u8, accepts_joins: bool },
    #[error("standing {standing} has invalid hasCandidate value {has_candidate}")]
    StandingCandidateShape { standing: u8, has_candidate: bool },
    #[error("fold derives more than one dangling candidate")]
    MultipleFoldCandidates,
    #[error("standing candidate {observed:?} disagrees with fold candidate {fold:?}")]
    CandidateMismatch {
        observed: Option<Digest>,
        fold: Option<Digest>,
    },
    #[error("root winner final state disagrees with the joined commitment record")]
    RootWinnerFinalStateMismatch,
    #[error("inner winner does not map to either side of the folded parent match")]
    InnerWinnerOutsideParentMatch,
    #[error("live match {match_id_hash} carries an impossible child relationship")]
    MatchChildTopology { match_id_hash: Digest },
    #[error("child tournament {child} has no live folded parent match")]
    ChildNotReachable { child: Address },
    #[error("child tournament {child} disagrees with its parent match topology")]
    ChildTopologyMismatch { child: Address },
    #[error("standing active-match state disagrees with the fold")]
    StandingMatchActivityMismatch,
    #[error(transparent)]
    Domain(#[from] DomainError),
}

/// Observe every fold-reachable tournament at one caller-supplied block hash.
/// This method never samples `latest` or requires continued canonicality.
pub async fn observe_fold(
    chain: &Chain,
    fold: &Fold,
    head: ChainHead,
) -> AnyResult<HashMap<Address, TournamentObservation>> {
    let at = head.block_id();
    let mut observations = HashMap::new();

    for tournament_fold in fold.tournaments() {
        if !fold_reachable(fold, tournament_fold, &observations)? {
            continue;
        }

        let parent_match = folded_parent_match(fold, tournament_fold)?.map(|value| value.id);
        let observation = observe_tournament(chain, tournament_fold, parent_match, at).await?;
        validate_parent_topology(fold, tournament_fold, &observations, &observation)?;
        observations.insert(tournament_fold.address, observation);
    }

    Ok(observations)
}

async fn observe_tournament(
    chain: &Chain,
    tournament_fold: &TournamentFold,
    parent_match: Option<MatchID>,
    at: BlockId,
) -> AnyResult<TournamentObservation> {
    let contract = tournament::Tournament::new(tournament_fold.address, chain.provider());

    let descriptor_call = async {
        contract
            .tournamentDescriptor()
            .block(at)
            .call()
            .await
            .with_context(|| {
                format!(
                    "observe descriptor for tournament {}",
                    tournament_fold.address
                )
            })
    };
    let standing_call = async {
        contract
            .tournamentStanding()
            .block(at)
            .call()
            .await
            .with_context(|| {
                format!(
                    "observe standing for tournament {}",
                    tournament_fold.address
                )
            })
    };
    let (descriptor_wire, standing_wire) = tokio::try_join!(descriptor_call, standing_call)?;
    let descriptor = decode_descriptor(tournament_fold, descriptor_wire)?;
    let standing = decode_standing(tournament_fold, descriptor, parent_match, standing_wire)?;

    // The two-stage schedule keeps every call at one pinned hash while
    // bounding provider pressure. `buffered` preserves fold order, so
    // simultaneous failures still surface deterministically.
    let live_matches: Vec<MatchFold> = tournament_fold.live_matches().cloned().collect();
    let timeout_reads = stream::iter(live_matches.into_iter().map(|match_fold| {
        let contract = &contract;
        async move {
            let timeout_wire = contract
                .classifyMatchTimeout(match_fold.id.into())
                .block(at)
                .call()
                .await
                .with_context(|| {
                    format!(
                        "observe timeout for match {} in tournament {}",
                        match_fold.id.hash(),
                        tournament_fold.address
                    )
                })?;
            let timeout = decode_timeout(
                timeout_wire.actualPhase,
                timeout_wire.outcome,
                timeout_wire.deferredCharge,
            )?;
            Ok::<_, anyhow::Error>((match_fold, timeout))
        }
    }))
    .buffered(POINT_READ_CONCURRENCY)
    .try_collect::<Vec<_>>()
    .await?;

    let observed = stream::iter(timeout_reads.into_iter().map(|(match_fold, timeout)| {
        let contract = &contract;
        async move {
            let state = match timeout.phase {
                MatchPhase::Absent => {
                    return Err(AdapterError::FoldLiveMatchAbsent {
                        match_id_hash: match_fold.id.hash(),
                    }
                    .into());
                }
                MatchPhase::Bisecting => {
                    let wire = contract
                        .bisectingMatch(match_fold.id.hash().into())
                        .block(at)
                        .call()
                        .await
                        .with_context(|| {
                            format!(
                                "observe bisection for match {} in tournament {}",
                                match_fold.id.hash(),
                                tournament_fold.address
                            )
                        })?;
                    decode_bisecting(timeout.phase, wire.actualPhase, wire.value)?
                }
                MatchPhase::ReadyToSeal => {
                    let wire = contract
                        .readyToSealMatch(match_fold.id.hash().into())
                        .block(at)
                        .call()
                        .await
                        .with_context(|| {
                            format!(
                                "observe ready-to-seal match {} in tournament {}",
                                match_fold.id.hash(),
                                tournament_fold.address
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
                        .sealedMatch(match_fold.id.hash().into())
                        .block(at)
                        .call()
                        .await
                        .with_context(|| {
                            format!(
                                "observe sealed match {} in tournament {}",
                                match_fold.id.hash(),
                                tournament_fold.address
                            )
                        })?;
                    decode_sealed(
                        match_fold.id.hash(),
                        timeout.phase,
                        wire.actualPhase,
                        wire.value,
                        descriptor.kind(),
                        match_fold.inner_tournament,
                    )?
                }
            };

            validate_match_child_topology(descriptor.kind(), &match_fold, state)?;
            let live = LiveMatch::try_new(state, timeout.disposition)?.validate_in(descriptor)?;
            Ok::<_, anyhow::Error>((
                match_fold.id.hash(),
                ObservedMatch {
                    id: match_fold.id,
                    live,
                },
            ))
        }
    }))
    .buffered(POINT_READ_CONCURRENCY)
    .try_collect::<Vec<_>>()
    .await?;

    let mut matches = HashMap::with_capacity(observed.len());
    for (id_hash, observed) in observed {
        let previous = matches.insert(id_hash, observed);
        debug_assert!(previous.is_none(), "fold guarantees unique live match IDs");
    }

    assemble_observation(descriptor, standing, matches).map_err(Into::into)
}

fn decode_descriptor(
    tournament_fold: &TournamentFold,
    wire: AbiTournamentDescriptor,
) -> AdapterResult<TournamentDescriptor> {
    let kind = decode_tournament_kind(wire.kind)?;
    if wire.level != tournament_fold.level {
        return Err(AdapterError::DescriptorLevelMismatch {
            descriptor_level: wire.level,
            fold_level: tournament_fold.level,
        });
    }

    TournamentDescriptor::try_new(
        tournament_fold.address,
        wire.level,
        kind,
        wire.initialHash.into(),
        wire.baseCycle,
        wire.log2Stride,
        wire.height,
    )
    .map_err(Into::into)
}

fn decode_standing(
    tournament_fold: &TournamentFold,
    descriptor: TournamentDescriptor,
    parent_match: Option<MatchID>,
    wire: AbiTournamentStandingView,
) -> AdapterResult<TournamentStanding> {
    let standing_discriminant = wire.standing;
    let candidate =
        decode_candidate_shape(standing_discriminant, wire.hasCandidate, wire.candidate)?;
    let expected_candidate = fold_candidate(tournament_fold)?;
    if candidate != expected_candidate {
        return Err(AdapterError::CandidateMismatch {
            observed: candidate,
            fold: expected_candidate,
        });
    }

    let standing = match standing_discriminant {
        0 => {
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            require_zero_hash(
                "tournamentStanding",
                "parentCommitment",
                wire.parentCommitment,
            )?;
            TournamentStanding::MatchesActive {
                candidate,
                joins: if wire.acceptsJoins {
                    JoinDisposition::Open
                } else {
                    JoinDisposition::Closed
                },
            }
        }
        1 => {
            if !wire.acceptsJoins {
                return Err(AdapterError::StandingJoinMismatch {
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
            TournamentStanding::AwaitingClosure { candidate }
        }
        2 => {
            require_terminal_shape(standing_discriminant, &wire, true)?;
            let candidate = candidate.expect("shape requires a candidate");
            let fold_final_state = tournament_fold
                .commitments
                .get(&candidate)
                .expect("fold candidate belongs to the commitment map")
                .final_state;
            let final_state: Digest = wire.finalState.into();
            if final_state != fold_final_state {
                return Err(AdapterError::RootWinnerFinalStateMismatch);
            }
            TournamentStanding::RootWinner(RootWinner::new(candidate, final_state))
        }
        3 => {
            require_terminal_shape(standing_discriminant, &wire, false)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            TournamentStanding::RootFailed
        }
        4 => {
            require_terminal_shape(standing_discriminant, &wire, true)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            let winner = candidate.expect("shape requires a candidate");
            let parent_commitment: Digest = wire.parentCommitment.into();
            let parent_match = parent_match.ok_or(AdapterError::StandingKindMismatch)?;
            if parent_commitment != parent_match.commitment_one
                && parent_commitment != parent_match.commitment_two
            {
                return Err(AdapterError::InnerWinnerOutsideParentMatch);
            }
            TournamentStanding::InnerWinner(InnerWinner::new(parent_commitment, winner))
        }
        5 => {
            require_terminal_shape(standing_discriminant, &wire, false)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            TournamentStanding::InnerEliminable {
                reason: InnerEliminationReason::NoCandidate,
            }
        }
        6 => {
            require_terminal_shape(standing_discriminant, &wire, true)?;
            require_zero_hash("tournamentStanding", "finalState", wire.finalState)?;
            TournamentStanding::InnerEliminable {
                reason: InnerEliminationReason::WinnerExpired {
                    candidate: candidate.expect("shape requires a candidate"),
                },
            }
        }
        other => return Err(AdapterError::UnknownTournamentStanding(other)),
    };

    let root_standing = matches!(
        standing,
        TournamentStanding::RootWinner(_) | TournamentStanding::RootFailed
    );
    let inner_standing = matches!(
        standing,
        TournamentStanding::InnerWinner(_) | TournamentStanding::InnerEliminable { .. }
    );
    if (root_standing && !descriptor.is_root()) || (inner_standing && descriptor.is_root()) {
        return Err(AdapterError::StandingKindMismatch);
    }

    Ok(standing)
}

fn decode_timeout(phase: u8, outcome: u8, deferred_charge: u64) -> AdapterResult<TimeoutRead> {
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
        other => return Err(AdapterError::UnknownTimeoutOutcome(other)),
    };

    if phase == MatchPhase::Absent
        && (disposition != TimeoutDisposition::None || deferred_charge != 0)
    {
        return Err(AdapterError::NonCanonicalAbsentTimeout);
    }
    if matches!(
        disposition,
        TimeoutDisposition::None | TimeoutDisposition::EliminateBoth
    ) && deferred_charge != 0
    {
        return Err(AdapterError::NonCanonicalTimeoutCharge { outcome });
    }

    Ok(TimeoutRead { phase, disposition })
}

fn decode_bisecting(
    timeout_phase: MatchPhase,
    actual_phase: u8,
    wire: AbiBisectingMatchView,
) -> AdapterResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != timeout_phase || projection_phase != MatchPhase::Bisecting {
        return Err(AdapterError::ProjectionPhaseMismatch {
            projection: "bisectingMatch",
            timeout_phase,
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
    timeout_phase: MatchPhase,
    actual_phase: u8,
    wire: AbiReadyToSealMatchView,
    kind: TournamentKind,
) -> AdapterResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != timeout_phase || projection_phase != MatchPhase::ReadyToSeal {
        return Err(AdapterError::ProjectionPhaseMismatch {
            projection: "readyToSealMatch",
            timeout_phase,
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
    match_id_hash: Digest,
    timeout_phase: MatchPhase,
    actual_phase: u8,
    wire: AbiSealedMatchView,
    kind: TournamentKind,
    child: Option<Address>,
) -> AdapterResult<LiveMatchState> {
    let projection_phase = decode_match_phase(actual_phase)?;
    if projection_phase != timeout_phase || projection_phase != MatchPhase::Sealed {
        return Err(AdapterError::ProjectionPhaseMismatch {
            projection: "sealedMatch",
            timeout_phase,
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
        TournamentKind::Leaf if child.is_none() => {
            Ok(LiveMatchState::SealedLeaf(SealedLeafMatch::new(divergence)))
        }
        TournamentKind::NonLeaf => {
            let child = child.ok_or(AdapterError::MatchChildTopology { match_id_hash })?;
            Ok(LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(
                divergence, child,
            )?))
        }
        TournamentKind::Leaf => Err(AdapterError::MatchChildTopology { match_id_hash }),
    }
}

fn assemble_observation(
    descriptor: TournamentDescriptor,
    standing: TournamentStanding,
    matches: HashMap<Digest, ObservedMatch>,
) -> AdapterResult<TournamentObservation> {
    if standing.has_active_matches() == matches.is_empty() {
        return Err(AdapterError::StandingMatchActivityMismatch);
    }

    Ok(TournamentObservation {
        descriptor,
        standing,
        matches,
    })
}

fn fold_candidate(tournament_fold: &TournamentFold) -> AdapterResult<Option<Digest>> {
    let mut candidate = None;
    for commitment in tournament_fold.commitments.values() {
        let is_candidate = match commitment.latest_match {
            None => true,
            Some(index) => {
                let match_fold = &tournament_fold.matches[index];
                match match_fold.deleted {
                    None => false,
                    Some((_, WinnerCommitment::Neither)) => false,
                    Some((_, WinnerCommitment::One)) => {
                        commitment.root == match_fold.id.commitment_one
                    }
                    Some((_, WinnerCommitment::Two)) => {
                        commitment.root == match_fold.id.commitment_two
                    }
                }
            }
        };

        if is_candidate && candidate.replace(commitment.root).is_some() {
            return Err(AdapterError::MultipleFoldCandidates);
        }
    }
    Ok(candidate)
}

fn folded_parent_match<'a>(
    fold: &'a Fold,
    tournament_fold: &TournamentFold,
) -> AdapterResult<Option<&'a MatchFold>> {
    let Some((parent_address, parent_match_hash)) = tournament_fold.parent else {
        return Ok(None);
    };
    let parent = fold
        .tournament(&parent_address)
        .ok_or(AdapterError::ChildNotReachable {
            child: tournament_fold.address,
        })?;
    let parent_match =
        parent
            .match_by_id_hash(&parent_match_hash)
            .ok_or(AdapterError::ChildNotReachable {
                child: tournament_fold.address,
            })?;
    Ok(Some(parent_match))
}

fn fold_reachable(
    fold: &Fold,
    tournament_fold: &TournamentFold,
    observations: &HashMap<Address, TournamentObservation>,
) -> AdapterResult<bool> {
    let Some((parent_address, parent_match_hash)) = tournament_fold.parent else {
        return Ok(true);
    };
    if !observations.contains_key(&parent_address) {
        return Ok(false);
    }
    let parent = fold
        .tournament(&parent_address)
        .ok_or(AdapterError::ChildNotReachable {
            child: tournament_fold.address,
        })?;
    let parent_match =
        parent
            .match_by_id_hash(&parent_match_hash)
            .ok_or(AdapterError::ChildNotReachable {
                child: tournament_fold.address,
            })?;
    Ok(parent_match.is_live())
}

fn validate_parent_topology(
    fold: &Fold,
    tournament_fold: &TournamentFold,
    observations: &HashMap<Address, TournamentObservation>,
    child: &TournamentObservation,
) -> AdapterResult<()> {
    let Some((parent_address, parent_match_hash)) = tournament_fold.parent else {
        return Ok(());
    };
    let parent_fold = fold
        .tournament(&parent_address)
        .ok_or(AdapterError::ChildNotReachable {
            child: tournament_fold.address,
        })?;
    let parent_match_fold = parent_fold
        .match_by_id_hash(&parent_match_hash)
        .filter(|m| m.is_live())
        .ok_or(AdapterError::ChildNotReachable {
            child: tournament_fold.address,
        })?;
    if parent_match_fold.inner_tournament != Some(tournament_fold.address) {
        return Err(AdapterError::ChildTopologyMismatch {
            child: tournament_fold.address,
        });
    }

    let parent = observations
        .get(&parent_address)
        .ok_or(AdapterError::ChildNotReachable {
            child: tournament_fold.address,
        })?;
    let parent_match =
        parent
            .match_by_id_hash(&parent_match_hash)
            .ok_or(AdapterError::ChildTopologyMismatch {
                child: tournament_fold.address,
            })?;
    let LiveMatchState::AwaitingChild(awaiting) = parent_match.live().state() else {
        return Err(AdapterError::ChildTopologyMismatch {
            child: tournament_fold.address,
        });
    };
    if awaiting.child_tournament() != tournament_fold.address
        || child.descriptor().level() != parent.descriptor().level() + 1
        || child.descriptor().initial_hash() != awaiting.divergence().agree_state()
        || child.descriptor().base_cycle() != awaiting.divergence().coordinate().cycle()
    {
        return Err(AdapterError::ChildTopologyMismatch {
            child: tournament_fold.address,
        });
    }

    if let TournamentStanding::InnerWinner(winner) = child.standing() {
        let child_final_state = tournament_fold
            .commitments
            .get(&winner.child_commitment())
            .ok_or(AdapterError::ChildTopologyMismatch {
                child: tournament_fold.address,
            })?
            .final_state;
        let expected_final_state = awaiting.divergence().final_state(
            if winner.parent_commitment() == parent_match.id().commitment_one {
                MatchSide::One
            } else if winner.parent_commitment() == parent_match.id().commitment_two {
                MatchSide::Two
            } else {
                return Err(AdapterError::ChildTopologyMismatch {
                    child: tournament_fold.address,
                });
            },
        );
        if child_final_state != expected_final_state {
            return Err(AdapterError::ChildTopologyMismatch {
                child: tournament_fold.address,
            });
        }
    }
    Ok(())
}

fn validate_match_child_topology(
    kind: TournamentKind,
    match_fold: &MatchFold,
    state: LiveMatchState,
) -> AdapterResult<()> {
    let valid = match (kind, state, match_fold.inner_tournament) {
        (
            TournamentKind::Leaf,
            LiveMatchState::Bisecting(_)
            | LiveMatchState::ReadyToSealLeaf(_)
            | LiveMatchState::SealedLeaf(_),
            None,
        )
        | (
            TournamentKind::NonLeaf,
            LiveMatchState::Bisecting(_) | LiveMatchState::ReadyToDelegate(_),
            None,
        ) => true,
        (TournamentKind::NonLeaf, LiveMatchState::AwaitingChild(awaiting), Some(child)) => {
            awaiting.child_tournament() == child
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(AdapterError::MatchChildTopology {
            match_id_hash: match_fold.id.hash(),
        })
    }
}

fn decode_match_phase(value: u8) -> AdapterResult<MatchPhase> {
    match value {
        0 => Ok(MatchPhase::Absent),
        1 => Ok(MatchPhase::Bisecting),
        2 => Ok(MatchPhase::ReadyToSeal),
        3 => Ok(MatchPhase::Sealed),
        other => Err(AdapterError::UnknownMatchPhase(other)),
    }
}

fn decode_tournament_kind(value: u8) -> AdapterResult<TournamentKind> {
    match value {
        0 => Ok(TournamentKind::Leaf),
        1 => Ok(TournamentKind::NonLeaf),
        other => Err(AdapterError::UnknownTournamentKind(other)),
    }
}

fn decode_side(value: u8) -> AdapterResult<MatchSide> {
    match value {
        0 => Ok(MatchSide::One),
        1 => Ok(MatchSide::Two),
        other => Err(AdapterError::UnknownCommitmentSide(other)),
    }
}

fn decode_candidate_shape(
    standing: u8,
    has_candidate: bool,
    candidate: B256,
) -> AdapterResult<Option<Digest>> {
    let required = match standing {
        0 | 1 => None,
        2 | 4 | 6 => Some(true),
        3 | 5 => Some(false),
        other => return Err(AdapterError::UnknownTournamentStanding(other)),
    };
    if required.is_some_and(|required| required != has_candidate) {
        return Err(AdapterError::StandingCandidateShape {
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

fn require_terminal_shape(
    standing: u8,
    wire: &AbiTournamentStandingView,
    has_candidate: bool,
) -> AdapterResult<()> {
    if wire.acceptsJoins {
        return Err(AdapterError::StandingJoinMismatch {
            standing,
            accepts_joins: wire.acceptsJoins,
        });
    }
    if wire.hasCandidate != has_candidate {
        return Err(AdapterError::StandingCandidateShape {
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

fn require_zero_hash(view: &'static str, field: &'static str, value: B256) -> AdapterResult<()> {
    if value == B256::ZERO {
        Ok(())
    } else {
        Err(AdapterError::NonCanonicalInactiveField { view, field })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tournament::fold::{EventKind, MatchDeletionReason, TournamentEvent};

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn hash(byte: u8) -> B256 {
        digest(byte).into()
    }

    fn apply(fold: &mut Fold, tournament: Address, kind: EventKind) {
        fold.apply(&TournamentEvent {
            tournament,
            block: 1,
            kind,
        })
        .unwrap();
    }

    fn join(fold: &mut Fold, tournament: Address, root: u8, final_state: u8) {
        apply(
            fold,
            tournament,
            EventKind::CommitmentJoined {
                root: digest(root),
                final_state: digest(final_state),
            },
        );
    }

    fn create_match(fold: &mut Fold, tournament: Address) -> MatchID {
        let id = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        apply(
            fold,
            tournament,
            EventKind::MatchCreated {
                one: id.commitment_one,
                two: id.commitment_two,
                left_of_two: digest(3),
            },
        );
        id
    }

    fn root_with_live_match() -> (Fold, MatchID) {
        let root = address(1);
        let mut fold = Fold::new(root);
        join(&mut fold, root, 1, 11);
        join(&mut fold, root, 2, 12);
        let id = create_match(&mut fold, root);
        (fold, id)
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

    fn live_match(state: LiveMatchState, timeout: TimeoutDisposition) -> LiveMatch {
        LiveMatch::try_new(state, timeout).unwrap()
    }

    fn sealed_divergence() -> SealedDivergence {
        SealedDivergence::new(
            digest(20),
            MatchCoordinate::new(U256::from(3), U256::from(24)),
            digest(21),
            digest(22),
        )
    }

    fn awaiting_parent_observation(
        fold: &Fold,
        parent_id: MatchID,
        observed_child: Address,
    ) -> TournamentObservation {
        let root = fold.root();
        let parent_descriptor = descriptor(root, 0, TournamentKind::NonLeaf, digest(9), 0);
        let awaiting = AwaitingChildMatch::try_new(sealed_divergence(), observed_child).unwrap();
        let parent_live = live_match(
            LiveMatchState::AwaitingChild(awaiting),
            TimeoutDisposition::None,
        )
        .validate_in(parent_descriptor)
        .unwrap();
        assemble_observation(
            parent_descriptor,
            TournamentStanding::MatchesActive {
                candidate: None,
                joins: JoinDisposition::Closed,
            },
            HashMap::from([(
                parent_id.hash(),
                ObservedMatch::from_parts(parent_id, parent_live),
            )]),
        )
        .unwrap()
    }

    #[test]
    fn descriptor_decode_accepts_authoritative_kind_and_rejects_bad_wire_values() {
        let fold = Fold::new(address(1));
        let root = fold.tournament(&address(1)).unwrap();

        assert_eq!(
            decode_descriptor(root, descriptor_wire(0, 2)),
            Err(AdapterError::UnknownTournamentKind(2))
        );
        assert_eq!(
            decode_descriptor(root, descriptor_wire(1, 0)),
            Err(AdapterError::DescriptorLevelMismatch {
                descriptor_level: 1,
                fold_level: 0,
            })
        );
        assert_eq!(
            decode_descriptor(root, descriptor_wire(0, 1))
                .unwrap()
                .kind(),
            TournamentKind::NonLeaf,
            "kind is contract-authoritative, not derived from level"
        );

        let mut zero_height = descriptor_wire(0, 0);
        zero_height.height = 0;
        assert_eq!(
            decode_descriptor(root, zero_height),
            Err(AdapterError::Domain(DomainError::ZeroCommitmentHeight))
        );

        let mut overflowing = descriptor_wire(0, 0);
        overflowing.baseCycle = U256::MAX;
        assert_eq!(
            decode_descriptor(root, overflowing),
            Err(AdapterError::Domain(
                DomainError::TournamentCycleRangeOverflow
            ))
        );
    }

    #[test]
    fn standing_decode_rejects_discriminants_and_inactive_payloads() {
        let root_address = address(1);
        let mut fold = Fold::new(root_address);
        join(&mut fold, root_address, 1, 11);
        let root = fold.tournament(&root_address).unwrap();
        let descriptor = descriptor(root_address, 0, TournamentKind::Leaf, digest(9), 0);

        let unknown = standing_wire(7, false, Some(digest(1)));
        assert_eq!(
            decode_standing(root, descriptor, None, unknown),
            Err(AdapterError::UnknownTournamentStanding(7))
        );

        let mut active = standing_wire(0, true, Some(digest(1)));
        active.finalState = hash(11);
        assert_eq!(
            decode_standing(root, descriptor, None, active),
            Err(AdapterError::NonCanonicalInactiveField {
                view: "tournamentStanding",
                field: "finalState",
            })
        );

        assert_eq!(
            decode_standing(
                root,
                descriptor,
                None,
                standing_wire(1, false, Some(digest(1))),
            ),
            Err(AdapterError::StandingJoinMismatch {
                standing: 1,
                accepts_joins: false,
            })
        );

        let mut winner = standing_wire(2, false, None);
        winner.finalState = hash(11);
        assert_eq!(
            decode_standing(root, descriptor, None, winner),
            Err(AdapterError::StandingCandidateShape {
                standing: 2,
                has_candidate: false,
            })
        );

        let mut winner_accepting_joins = standing_wire(2, true, Some(digest(1)));
        winner_accepting_joins.finalState = hash(11);
        assert_eq!(
            decode_standing(root, descriptor, None, winner_accepting_joins),
            Err(AdapterError::StandingJoinMismatch {
                standing: 2,
                accepts_joins: true,
            })
        );

        let mut active = standing_wire(0, false, Some(digest(1)));
        active.parentCommitment = hash(1);
        assert_eq!(
            decode_standing(root, descriptor, None, active),
            Err(AdapterError::NonCanonicalInactiveField {
                view: "tournamentStanding",
                field: "parentCommitment",
            })
        );
    }

    #[test]
    fn standing_candidate_is_derived_from_survival_history() {
        let root_address = address(1);
        let mut fold = Fold::new(root_address);
        join(&mut fold, root_address, 1, 11);
        join(&mut fold, root_address, 2, 12);

        let root = fold.tournament(&root_address).unwrap();
        let descriptor = descriptor(root_address, 0, TournamentKind::Leaf, digest(9), 0);
        assert_eq!(
            decode_standing(
                root,
                descriptor,
                None,
                standing_wire(0, true, Some(digest(1))),
            ),
            Err(AdapterError::MultipleFoldCandidates)
        );

        let id = create_match(&mut fold, root_address);
        apply(
            &mut fold,
            root_address,
            EventKind::MatchDeleted {
                match_id_hash: id.hash(),
                reason: MatchDeletionReason::Step,
                winner: WinnerCommitment::One,
            },
        );
        let root = fold.tournament(&root_address).unwrap();

        let mut winner = standing_wire(2, false, Some(digest(1)));
        winner.finalState = hash(11);
        assert_eq!(
            decode_standing(root, descriptor, None, winner).unwrap(),
            TournamentStanding::RootWinner(RootWinner::new(digest(1), digest(11)))
        );

        let mut wrong = standing_wire(2, false, Some(digest(2)));
        wrong.finalState = hash(12);
        assert_eq!(
            decode_standing(root, descriptor, None, wrong),
            Err(AdapterError::CandidateMismatch {
                observed: Some(digest(2)),
                fold: Some(digest(1)),
            })
        );
    }

    #[test]
    fn candidate_follows_re_pair_creation_before_old_match_deletion() {
        let root_address = address(1);
        let mut fold = Fold::new(root_address);
        join(&mut fold, root_address, 1, 11);
        join(&mut fold, root_address, 2, 12);
        let old_match = create_match(&mut fold, root_address);
        join(&mut fold, root_address, 3, 13);

        // pairCommitment emits the replacement MatchCreated before deleteMatch
        // emits MatchDeleted for the old match.
        let replacement = MatchID {
            commitment_one: digest(3),
            commitment_two: digest(1),
        };
        apply(
            &mut fold,
            root_address,
            EventKind::MatchCreated {
                one: replacement.commitment_one,
                two: replacement.commitment_two,
                left_of_two: digest(4),
            },
        );
        apply(
            &mut fold,
            root_address,
            EventKind::MatchDeleted {
                match_id_hash: old_match.hash(),
                reason: MatchDeletionReason::Timeout,
                winner: WinnerCommitment::One,
            },
        );

        let descriptor = descriptor(root_address, 0, TournamentKind::Leaf, digest(9), 0);
        let root = fold.tournament(&root_address).unwrap();
        assert_eq!(fold_candidate(root).unwrap(), None);
        assert_eq!(
            decode_standing(root, descriptor, None, standing_wire(0, false, None),).unwrap(),
            TournamentStanding::MatchesActive {
                candidate: None,
                joins: JoinDisposition::Closed,
            }
        );

        apply(
            &mut fold,
            root_address,
            EventKind::MatchDeleted {
                match_id_hash: replacement.hash(),
                reason: MatchDeletionReason::Step,
                winner: WinnerCommitment::Two,
            },
        );
        let root = fold.tournament(&root_address).unwrap();
        assert_eq!(fold_candidate(root).unwrap(), Some(digest(1)));
        let mut winner = standing_wire(2, false, Some(digest(1)));
        winner.finalState = hash(11);
        assert_eq!(
            decode_standing(root, descriptor, None, winner).unwrap(),
            TournamentStanding::RootWinner(RootWinner::new(digest(1), digest(11)))
        );
    }

    #[test]
    fn inner_winner_must_map_to_the_folded_parent_match() {
        let (mut fold, parent_id) = root_with_live_match();
        let root = address(1);
        let child = address(2);
        apply(
            &mut fold,
            root,
            EventKind::NewInnerTournament {
                match_id_hash: parent_id.hash(),
                child,
            },
        );
        join(&mut fold, child, 30, 40);
        let child_fold = fold.tournament(&child).unwrap();
        let child_descriptor = descriptor(child, 1, TournamentKind::Leaf, digest(20), 24);

        let mut standing = standing_wire(4, false, Some(digest(30)));
        standing.parentCommitment = hash(99);
        assert_eq!(
            decode_standing(child_fold, child_descriptor, Some(parent_id), standing,),
            Err(AdapterError::InnerWinnerOutsideParentMatch)
        );
    }

    #[test]
    fn timeout_decode_rejects_unknown_and_noncanonical_combinations() {
        assert_eq!(
            decode_timeout(4, 0, 0),
            Err(AdapterError::UnknownMatchPhase(4))
        );
        assert_eq!(
            decode_timeout(1, 4, 0),
            Err(AdapterError::UnknownTimeoutOutcome(4))
        );
        assert_eq!(
            decode_timeout(0, 1, 0),
            Err(AdapterError::NonCanonicalAbsentTimeout)
        );
        assert_eq!(
            decode_timeout(0, 0, 1),
            Err(AdapterError::NonCanonicalAbsentTimeout)
        );
        assert_eq!(
            decode_timeout(1, 0, 1),
            Err(AdapterError::NonCanonicalTimeoutCharge { outcome: 0 })
        );
        assert_eq!(
            decode_timeout(3, 3, 1),
            Err(AdapterError::NonCanonicalTimeoutCharge { outcome: 3 })
        );
        assert_eq!(
            decode_timeout(1, 2, 7).unwrap().disposition,
            TimeoutDisposition::TwoWins {
                deferred_charge: BlockDuration::from_blocks(7),
            }
        );
    }

    #[test]
    fn projections_reject_every_phase_cross_product_before_decoding_payloads() {
        let phases = [
            (MatchPhase::Absent, 0),
            (MatchPhase::Bisecting, 1),
            (MatchPhase::ReadyToSeal, 2),
            (MatchPhase::Sealed, 3),
        ];

        for &(timeout_phase, _) in &phases {
            for &(projection_phase, actual_phase) in &phases {
                let result = decode_bisecting(timeout_phase, actual_phase, bisecting_wire());
                if timeout_phase == MatchPhase::Bisecting
                    && projection_phase == MatchPhase::Bisecting
                {
                    assert!(matches!(result, Ok(LiveMatchState::Bisecting(_))));
                } else {
                    assert!(matches!(
                        result,
                        Err(AdapterError::ProjectionPhaseMismatch {
                            projection: "bisectingMatch",
                            ..
                        })
                    ));
                }
            }
        }

        for &(timeout_phase, _) in &phases {
            for &(projection_phase, actual_phase) in &phases {
                let result = decode_ready(
                    timeout_phase,
                    actual_phase,
                    ready_wire(),
                    TournamentKind::Leaf,
                );
                if timeout_phase == MatchPhase::ReadyToSeal
                    && projection_phase == MatchPhase::ReadyToSeal
                {
                    assert!(matches!(result, Ok(LiveMatchState::ReadyToSealLeaf(_))));
                } else {
                    assert!(matches!(
                        result,
                        Err(AdapterError::ProjectionPhaseMismatch {
                            projection: "readyToSealMatch",
                            ..
                        })
                    ));
                }
            }
        }

        for &(timeout_phase, _) in &phases {
            for &(projection_phase, actual_phase) in &phases {
                let result = decode_sealed(
                    digest(8),
                    timeout_phase,
                    actual_phase,
                    sealed_wire(),
                    TournamentKind::Leaf,
                    None,
                );
                if timeout_phase == MatchPhase::Sealed && projection_phase == MatchPhase::Sealed {
                    assert!(matches!(result, Ok(LiveMatchState::SealedLeaf(_))));
                } else {
                    assert!(matches!(
                        result,
                        Err(AdapterError::ProjectionPhaseMismatch {
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
            Err(AdapterError::UnknownCommitmentSide(2))
        );
    }

    #[test]
    fn phase_enrichment_requires_exact_leaf_and_child_topology() {
        assert!(matches!(
            decode_ready(
                MatchPhase::ReadyToSeal,
                2,
                ready_wire(),
                TournamentKind::NonLeaf,
            ),
            Ok(LiveMatchState::ReadyToDelegate(_))
        ));
        assert!(matches!(
            decode_sealed(
                digest(8),
                MatchPhase::Sealed,
                3,
                sealed_wire(),
                TournamentKind::NonLeaf,
                Some(address(2)),
            ),
            Ok(LiveMatchState::AwaitingChild(_))
        ));
        assert_eq!(
            decode_sealed(
                digest(8),
                MatchPhase::Sealed,
                3,
                sealed_wire(),
                TournamentKind::NonLeaf,
                None,
            ),
            Err(AdapterError::MatchChildTopology {
                match_id_hash: digest(8),
            })
        );
        assert_eq!(
            decode_sealed(
                digest(8),
                MatchPhase::Sealed,
                3,
                sealed_wire(),
                TournamentKind::Leaf,
                Some(address(2)),
            ),
            Err(AdapterError::MatchChildTopology {
                match_id_hash: digest(8),
            })
        );
    }

    #[test]
    fn fold_view_join_validates_child_reachability_and_coordinates() {
        let (mut fold, parent_id) = root_with_live_match();
        let root = address(1);
        let child_address = address(2);
        apply(
            &mut fold,
            root,
            EventKind::NewInnerTournament {
                match_id_hash: parent_id.hash(),
                child: child_address,
            },
        );

        let child_fold = fold.tournament(&child_address).unwrap();
        let child = assemble_observation(
            descriptor(child_address, 1, TournamentKind::Leaf, digest(20), 24),
            TournamentStanding::AwaitingClosure { candidate: None },
            HashMap::new(),
        )
        .unwrap();
        let parent = awaiting_parent_observation(&fold, parent_id, child_address);
        let observations = HashMap::from([(root, parent)]);
        assert!(fold_reachable(&fold, child_fold, &observations).unwrap());
        assert!(!fold_reachable(&fold, child_fold, &HashMap::new()).unwrap());
        assert!(validate_parent_topology(&fold, child_fold, &observations, &child,).is_ok());

        for wrong_descriptor in [
            descriptor(child_address, 0, TournamentKind::Leaf, digest(20), 24),
            descriptor(child_address, 1, TournamentKind::Leaf, digest(99), 24),
            descriptor(child_address, 1, TournamentKind::Leaf, digest(20), 25),
        ] {
            let wrong_child = assemble_observation(
                wrong_descriptor,
                TournamentStanding::AwaitingClosure { candidate: None },
                HashMap::new(),
            )
            .unwrap();
            assert_eq!(
                validate_parent_topology(&fold, child_fold, &observations, &wrong_child,),
                Err(AdapterError::ChildTopologyMismatch {
                    child: child_address,
                })
            );
        }

        let wrong_parent = awaiting_parent_observation(&fold, parent_id, address(3));
        let wrong_observations = HashMap::from([(root, wrong_parent)]);
        assert_eq!(
            validate_parent_topology(&fold, child_fold, &wrong_observations, &child,),
            Err(AdapterError::ChildTopologyMismatch {
                child: child_address,
            })
        );

        let mut settled = fold.clone();
        apply(
            &mut settled,
            root,
            EventKind::MatchDeleted {
                match_id_hash: parent_id.hash(),
                reason: MatchDeletionReason::ChildTournament,
                winner: WinnerCommitment::One,
            },
        );
        let settled_child = settled.tournament(&child_address).unwrap();
        assert!(!fold_reachable(&settled, settled_child, &observations).unwrap());
    }

    #[test]
    fn child_winner_final_state_must_map_to_the_returned_parent_side() {
        let (mut fold, parent_id) = root_with_live_match();
        let root = address(1);
        let child_address = address(2);
        apply(
            &mut fold,
            root,
            EventKind::NewInnerTournament {
                match_id_hash: parent_id.hash(),
                child: child_address,
            },
        );
        join(&mut fold, child_address, 30, 21);

        let parent = awaiting_parent_observation(&fold, parent_id, child_address);
        let observations = HashMap::from([(root, parent)]);
        let child_fold = fold.tournament(&child_address).unwrap();
        let child_descriptor = descriptor(child_address, 1, TournamentKind::Leaf, digest(20), 24);

        let mapped = assemble_observation(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(parent_id.commitment_one, digest(30))),
            HashMap::new(),
        )
        .unwrap();
        assert!(validate_parent_topology(&fold, child_fold, &observations, &mapped,).is_ok());

        let wrong_side = assemble_observation(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(parent_id.commitment_two, digest(30))),
            HashMap::new(),
        )
        .unwrap();
        assert_eq!(
            validate_parent_topology(&fold, child_fold, &observations, &wrong_side,),
            Err(AdapterError::ChildTopologyMismatch {
                child: child_address,
            })
        );

        let missing_winner = TournamentObservation::from_parts(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(parent_id.commitment_one, digest(99))),
            HashMap::new(),
        );
        assert_eq!(
            validate_parent_topology(&fold, child_fold, &observations, &missing_winner,),
            Err(AdapterError::ChildTopologyMismatch {
                child: child_address,
            })
        );
    }

    #[test]
    fn child_winner_final_state_maps_to_parent_side_two() {
        let (mut fold, parent_id) = root_with_live_match();
        let root = address(1);
        let child_address = address(2);
        apply(
            &mut fold,
            root,
            EventKind::NewInnerTournament {
                match_id_hash: parent_id.hash(),
                child: child_address,
            },
        );
        join(&mut fold, child_address, 31, 22);

        let parent = awaiting_parent_observation(&fold, parent_id, child_address);
        let observations = HashMap::from([(root, parent)]);
        let child_fold = fold.tournament(&child_address).unwrap();
        let child = assemble_observation(
            descriptor(child_address, 1, TournamentKind::Leaf, digest(20), 24),
            TournamentStanding::InnerWinner(InnerWinner::new(parent_id.commitment_two, digest(31))),
            HashMap::new(),
        )
        .unwrap();

        assert!(validate_parent_topology(&fold, child_fold, &observations, &child,).is_ok());
    }

    #[test]
    fn fold_view_join_rejects_active_standing_without_matches() {
        assert_eq!(
            assemble_observation(
                descriptor(address(1), 0, TournamentKind::Leaf, digest(9), 0),
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins: JoinDisposition::Open,
                },
                HashMap::new(),
            ),
            Err(AdapterError::StandingMatchActivityMismatch)
        );
    }
}
