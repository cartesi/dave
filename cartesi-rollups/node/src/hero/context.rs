//! Actor-relative projection from one accepted tournament observation.
//!
//! The contract observer and event fold describe the whole reachable dispute.
//! Hero policy needs less: its local commitment at each level and the one live
//! child path that commitment is defending. This module builds that semantic
//! path and retains the local engine coordinates beside it for later action
//! fulfillment. No provider reads or transaction decisions happen here.

use std::collections::HashMap;

use alloy::primitives::{Address, U256};
use thiserror::Error;

use crate::{
    engine::{DisputeSource, LevelCoords, RulerFactory},
    merkle::Digest,
    tournament::{
        adapter::TournamentObservation,
        domain::{
            DomainError, EliminationReason, EliminationRecord, Engagement, LiveMatchState,
            LocalCommitmentStanding, MatchSide, ParentLink, SemanticSnapshot, TournamentDescriptor,
        },
        fold::{Fold, MatchDeletionReason, TournamentFold, WinnerCommitment},
    },
};

/// Local engine material for one tournament level.
///
/// This stays outside [`SemanticSnapshot`]: coordinates and cached computation
/// roots belong to action fulfillment, not pure Hero policy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LevelMaterial {
    descriptor: TournamentDescriptor,
    coords: LevelCoords,
    root: Digest,
}

impl LevelMaterial {
    pub const fn descriptor(&self) -> TournamentDescriptor {
        self.descriptor
    }

    pub const fn coords(&self) -> &LevelCoords {
        &self.coords
    }

    pub const fn root(&self) -> Digest {
        self.root
    }
}

/// The Hero's policy input plus the local material needed to fulfill its intent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeroContext {
    snapshot: SemanticSnapshot,
    levels: HashMap<Address, LevelMaterial>,
}

impl HeroContext {
    /// Project the Hero's local path from one accepted fold and observation set.
    pub fn assemble<F: RulerFactory>(
        epoch: u64,
        epoch_initial_hash: Digest,
        fold: &Fold,
        observations: &HashMap<Address, TournamentObservation>,
        source: &mut DisputeSource<F>,
    ) -> Result<Self, ContextError> {
        let root = fold.root();
        let mut levels = HashMap::new();
        let snapshot = assemble_tournament(
            epoch,
            epoch_initial_hash,
            root,
            None,
            fold,
            observations,
            source,
            &mut levels,
        )?;
        Ok(Self { snapshot, levels })
    }

    pub const fn snapshot(&self) -> &SemanticSnapshot {
        &self.snapshot
    }

    pub const fn root_tournament(&self) -> Address {
        self.snapshot.descriptor().address()
    }

    /// Find one tournament on the retained local path.
    pub fn snapshot_at(&self, tournament: Address) -> Option<&SemanticSnapshot> {
        let mut snapshot = &self.snapshot;
        loop {
            if snapshot.descriptor().address() == tournament {
                return Some(snapshot);
            }
            snapshot = snapshot.child()?;
        }
    }

    pub fn level(&self, tournament: &Address) -> Option<&LevelMaterial> {
        self.levels.get(tournament)
    }

    pub fn levels(&self) -> &HashMap<Address, LevelMaterial> {
        &self.levels
    }
}

#[derive(Debug, Error)]
pub enum ContextError {
    #[error("fold is missing tournament {tournament}")]
    MissingFoldTournament { tournament: Address },
    #[error("accepted observations are missing tournament {tournament}")]
    MissingObservation { tournament: Address },
    #[error(
        "observation descriptor address {observed} disagrees with requested tournament {expected}"
    )]
    DescriptorAddressMismatch {
        expected: Address,
        observed: Address,
    },
    #[error(
        "observation descriptor level {observed} disagrees with folded level {expected} for tournament {tournament}"
    )]
    DescriptorLevelMismatch {
        tournament: Address,
        expected: u64,
        observed: u64,
    },
    #[error(
        "root tournament {tournament} initial hash {observed} disagrees with epoch anchor {expected}"
    )]
    RootInitialHashMismatch {
        tournament: Address,
        expected: Digest,
        observed: Digest,
    },
    #[error("tournament {tournament} base cycle {base_cycle} is not aligned to level span {span}")]
    MisalignedBaseCycle {
        tournament: Address,
        base_cycle: U256,
        span: U256,
    },
    #[error("local engine failed to compute tournament {tournament} commitment: {source}")]
    CommitmentComputation {
        tournament: Address,
        #[source]
        source: anyhow::Error,
    },
    #[error("local path visits tournament {tournament} more than once")]
    DuplicateLocalTournament { tournament: Address },
    #[error(
        "commitment {commitment} in tournament {tournament} points outside the folded match list"
    )]
    LatestMatchOutOfRange {
        tournament: Address,
        commitment: Digest,
    },
    #[error("live folded match {match_id_hash} is absent from tournament {tournament} observation")]
    MissingLiveMatch {
        tournament: Address,
        match_id_hash: Digest,
    },
    #[error("local commitment {commitment} is not a side of its folded match {match_id_hash}")]
    LocalCommitmentOutsideMatch {
        commitment: Digest,
        match_id_hash: Digest,
    },
    #[error("local child path topology disagrees with the fold for tournament {tournament}")]
    ParentTopologyMismatch { tournament: Address },
    #[error("semantic projection failed for tournament {tournament}: {source}")]
    Domain {
        tournament: Address,
        #[source]
        source: DomainError,
    },
}

#[allow(clippy::too_many_arguments)]
fn assemble_tournament<F: RulerFactory>(
    epoch: u64,
    epoch_initial_hash: Digest,
    tournament: Address,
    parent: Option<ParentLink>,
    fold: &Fold,
    observations: &HashMap<Address, TournamentObservation>,
    source: &mut DisputeSource<F>,
    levels: &mut HashMap<Address, LevelMaterial>,
) -> Result<SemanticSnapshot, ContextError> {
    let tournament_fold = fold
        .tournament(&tournament)
        .ok_or(ContextError::MissingFoldTournament { tournament })?;
    validate_parent_topology(fold, tournament_fold, parent)?;

    let observation = observations
        .get(&tournament)
        .ok_or(ContextError::MissingObservation { tournament })?;
    let descriptor = observation.descriptor();
    if descriptor.address() != tournament {
        return Err(ContextError::DescriptorAddressMismatch {
            expected: tournament,
            observed: descriptor.address(),
        });
    }
    if descriptor.level() != tournament_fold.level {
        return Err(ContextError::DescriptorLevelMismatch {
            tournament,
            expected: tournament_fold.level,
            observed: descriptor.level(),
        });
    }
    if tournament == fold.root() && descriptor.initial_hash() != epoch_initial_hash {
        return Err(ContextError::RootInitialHashMismatch {
            tournament,
            expected: epoch_initial_hash,
            observed: descriptor.initial_hash(),
        });
    }

    let coords = level_coords(epoch, descriptor)?;
    let root = source
        .node(&coords.root())
        .map_err(|source| ContextError::CommitmentComputation { tournament, source })?;
    let material = LevelMaterial {
        descriptor,
        coords,
        root,
    };
    if levels.insert(tournament, material).is_some() {
        return Err(ContextError::DuplicateLocalTournament { tournament });
    }

    let local_standing = project_local_standing(tournament_fold, observation, root)?;
    let child = match local_standing {
        LocalCommitmentStanding::Engaged(engagement) => match engagement.live().state() {
            LiveMatchState::AwaitingChild(awaiting) => {
                let link = ParentLink::try_new(tournament, engagement.match_id(), root)
                    .map_err(|source| ContextError::Domain { tournament, source })?;
                Some(assemble_tournament(
                    epoch,
                    epoch_initial_hash,
                    awaiting.child_tournament(),
                    Some(link),
                    fold,
                    observations,
                    source,
                    levels,
                )?)
            }
            _ => None,
        },
        _ => None,
    };

    SemanticSnapshot::try_new(
        descriptor,
        observation.standing(),
        root,
        local_standing,
        parent,
        child,
    )
    .map_err(|source| ContextError::Domain { tournament, source })
}

fn level_coords(epoch: u64, descriptor: TournamentDescriptor) -> Result<LevelCoords, ContextError> {
    let tournament = descriptor.address();
    let height = descriptor.height().get();
    let log2_span = descriptor
        .log2_stride()
        .checked_add(height)
        .expect("validated descriptors have a representable row extent");

    let span = U256::from(1) << log2_span;
    if descriptor.base_cycle() % span != U256::ZERO {
        return Err(ContextError::MisalignedBaseCycle {
            tournament,
            base_cycle: descriptor.base_cycle(),
            span,
        });
    }

    Ok(LevelCoords::new(
        epoch,
        descriptor.base_cycle(),
        descriptor.log2_stride(),
        height,
    ))
}

fn project_local_standing(
    tournament: &TournamentFold,
    observation: &TournamentObservation,
    local_commitment: Digest,
) -> Result<LocalCommitmentStanding, ContextError> {
    let Some(commitment) = tournament.commitments.get(&local_commitment) else {
        return Ok(LocalCommitmentStanding::NotJoined);
    };
    let Some(index) = commitment.latest_match else {
        return Ok(LocalCommitmentStanding::Candidate);
    };
    let match_fold = tournament
        .matches
        .get(index)
        .ok_or(ContextError::LatestMatchOutOfRange {
            tournament: tournament.address,
            commitment: local_commitment,
        })?;
    if match_fold.id.commitment_one == match_fold.id.commitment_two {
        return Err(ContextError::Domain {
            tournament: tournament.address,
            source: DomainError::DuplicateMatchCommitment,
        });
    }

    let local_side = match_side(local_commitment, match_fold.id).ok_or(
        ContextError::LocalCommitmentOutsideMatch {
            commitment: local_commitment,
            match_id_hash: match_fold.id.hash(),
        },
    )?;

    if let Some((reason, winner)) = match_fold.deleted {
        let survivor = winner_side(winner);
        if survivor == Some(local_side) {
            return Ok(LocalCommitmentStanding::Candidate);
        }
        let record = EliminationRecord::try_new(
            local_commitment,
            match_fold.id,
            elimination_reason(reason),
            survivor,
        )
        .map_err(|source| ContextError::Domain {
            tournament: tournament.address,
            source,
        })?;
        return Ok(LocalCommitmentStanding::Eliminated(record));
    }

    let id_hash = match_fold.id.hash();
    let observed =
        observation
            .match_by_id_hash(&id_hash)
            .ok_or(ContextError::MissingLiveMatch {
                tournament: tournament.address,
                match_id_hash: id_hash,
            })?;
    let live = observed.live();
    let engagement = Engagement::try_new(
        local_commitment,
        match_fold.id,
        live.state(),
        live.timeout(),
    )
    .map_err(|source| ContextError::Domain {
        tournament: tournament.address,
        source,
    })?;
    Ok(LocalCommitmentStanding::Engaged(engagement))
}

fn validate_parent_topology(
    fold: &Fold,
    tournament: &TournamentFold,
    parent: Option<ParentLink>,
) -> Result<(), ContextError> {
    let expected = parent.map(|link| (link.parent_tournament(), link.parent_match().hash()));
    let valid = if tournament.address == fold.root() {
        expected.is_none() && tournament.parent.is_none()
    } else {
        tournament.parent == expected
    };
    if valid {
        Ok(())
    } else {
        Err(ContextError::ParentTopologyMismatch {
            tournament: tournament.address,
        })
    }
}

fn match_side(commitment: Digest, match_id: crate::tournament::MatchID) -> Option<MatchSide> {
    if commitment == match_id.commitment_one {
        Some(MatchSide::One)
    } else if commitment == match_id.commitment_two {
        Some(MatchSide::Two)
    } else {
        None
    }
}

const fn winner_side(winner: WinnerCommitment) -> Option<MatchSide> {
    match winner {
        WinnerCommitment::Neither => None,
        WinnerCommitment::One => Some(MatchSide::One),
        WinnerCommitment::Two => Some(MatchSide::Two),
    }
}

const fn elimination_reason(reason: MatchDeletionReason) -> EliminationReason {
    match reason {
        MatchDeletionReason::Step => EliminationReason::Step,
        MatchDeletionReason::Timeout => EliminationReason::Timeout,
        MatchDeletionReason::ChildTournament => EliminationReason::ChildTournament,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        engine::spec::{S_SMALL, toy_source},
        tournament::{
            MatchID,
            adapter::ObservedMatch,
            domain::{
                AwaitingChildMatch, BisectingMatch, JoinDisposition, LiveMatch, MatchCoordinate,
                SealedDivergence, TimeoutDisposition, TournamentStanding, WaitingChildren,
            },
            fold::{EventKind, TournamentEvent},
        },
    };

    const ROOT: Address = Address::new([0x11; 20]);
    const CHILD: Address = Address::new([0x22; 20]);

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn descriptor(
        address: Address,
        level: u64,
        levels: u64,
        initial_hash: Digest,
        base_cycle: u64,
        log2_stride: u64,
        height: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            levels,
            initial_hash,
            U256::from(base_cycle),
            log2_stride,
            height,
        )
        .unwrap()
    }

    fn root_descriptor(initial_hash: Digest, levels: u64) -> TournamentDescriptor {
        descriptor(ROOT, 0, levels, initial_hash, 0, 3, 4)
    }

    fn child_descriptor(initial_hash: Digest) -> TournamentDescriptor {
        descriptor(CHILD, 1, 2, initial_hash, 0, 0, 3)
    }

    fn source() -> DisputeSource<crate::engine::ToyFactory> {
        toy_source(S_SMALL, &[])
    }

    fn local_root(descriptor: TournamentDescriptor) -> Digest {
        let mut source = source();
        source
            .node(
                &LevelCoords::new(
                    0,
                    descriptor.base_cycle(),
                    descriptor.log2_stride(),
                    descriptor.height().get(),
                )
                .root(),
            )
            .unwrap()
    }

    fn event(tournament: Address, block: u64, kind: EventKind) -> TournamentEvent {
        TournamentEvent {
            tournament,
            block,
            kind,
        }
    }

    fn join(root: Digest, final_state: Digest) -> EventKind {
        EventKind::CommitmentJoined { root, final_state }
    }

    fn standing(candidate: Option<Digest>) -> TournamentStanding {
        TournamentStanding::AwaitingClosure { candidate }
    }

    fn observation(
        descriptor: TournamentDescriptor,
        standing: TournamentStanding,
        matches: impl IntoIterator<Item = (MatchID, LiveMatch)>,
    ) -> TournamentObservation {
        TournamentObservation::from_parts(
            descriptor,
            standing,
            matches
                .into_iter()
                .map(|(id, live)| (id.hash(), ObservedMatch::from_parts(id, live)))
                .collect(),
        )
    }

    fn live_match(descriptor: TournamentDescriptor) -> LiveMatch {
        LiveMatch::try_new(
            LiveMatchState::Bisecting(
                BisectingMatch::try_new(
                    digest(0x40),
                    WaitingChildren::new(digest(0x41), digest(0x42)),
                    MatchCoordinate::new(U256::ZERO, descriptor.base_cycle()),
                    descriptor.height().get(),
                    MatchSide::One,
                )
                .unwrap(),
            ),
            TimeoutDisposition::None,
        )
        .unwrap()
        .validate_in(descriptor)
        .unwrap()
    }

    fn assemble(
        initial_hash: Digest,
        fold: &Fold,
        observations: &HashMap<Address, TournamentObservation>,
    ) -> Result<HeroContext, ContextError> {
        HeroContext::assemble(0, initial_hash, fold, observations, &mut source())
    }

    #[test]
    fn projects_not_joined_and_candidate_with_level_material() {
        let initial_hash = digest(0x90);
        let descriptor = root_descriptor(initial_hash, 1);
        let local = local_root(descriptor);

        let fold = Fold::new(ROOT);
        let observations = HashMap::from([(ROOT, observation(descriptor, standing(None), []))]);
        let context = assemble(initial_hash, &fold, &observations).unwrap();
        assert_eq!(
            context.snapshot().local_standing(),
            LocalCommitmentStanding::NotJoined
        );
        let material = context.level(&ROOT).unwrap();
        assert_eq!(material.root(), local);
        assert_eq!(material.descriptor(), descriptor);
        assert_eq!(
            material.coords().root(),
            LevelCoords::new(0, U256::ZERO, 3, 4).root()
        );

        let mut fold = Fold::new(ROOT);
        fold.apply(&event(ROOT, 1, join(local, digest(0x91))))
            .unwrap();
        let observations =
            HashMap::from([(ROOT, observation(descriptor, standing(Some(local)), []))]);
        let context = assemble(initial_hash, &fold, &observations).unwrap();
        assert_eq!(
            context.snapshot().local_standing(),
            LocalCommitmentStanding::Candidate
        );
    }

    #[test]
    fn projects_live_engagement_in_both_match_orientations() {
        let initial_hash = digest(0x90);
        let descriptor = root_descriptor(initial_hash, 1);
        let local = local_root(descriptor);
        let opponent = digest(0x51);

        for (id, expected_side) in [
            (
                MatchID {
                    commitment_one: local,
                    commitment_two: opponent,
                },
                MatchSide::One,
            ),
            (
                MatchID {
                    commitment_one: opponent,
                    commitment_two: local,
                },
                MatchSide::Two,
            ),
        ] {
            let mut fold = Fold::new(ROOT);
            fold.apply(&event(ROOT, 1, join(local, digest(0x91))))
                .unwrap();
            fold.apply(&event(ROOT, 2, join(opponent, digest(0x92))))
                .unwrap();
            fold.apply(&event(
                ROOT,
                3,
                EventKind::MatchCreated {
                    one: id.commitment_one,
                    two: id.commitment_two,
                    left_of_two: digest(0x52),
                },
            ))
            .unwrap();

            let observations = HashMap::from([(
                ROOT,
                observation(
                    descriptor,
                    TournamentStanding::MatchesActive {
                        candidate: None,
                        joins: JoinDisposition::Closed,
                    },
                    [(id, live_match(descriptor))],
                ),
            )]);
            let context = assemble(initial_hash, &fold, &observations).unwrap();
            let LocalCommitmentStanding::Engaged(engagement) = context.snapshot().local_standing()
            else {
                panic!("local commitment should be engaged");
            };
            assert_eq!(engagement.match_id(), id);
            assert_eq!(engagement.local_side(), expected_side);
        }
    }

    #[test]
    fn projects_every_legal_deletion_outcome_in_both_orientations() {
        let initial_hash = digest(0x90);
        let descriptor = root_descriptor(initial_hash, 1);
        let local = local_root(descriptor);
        let opponent = digest(0x51);
        let reasons = [
            (MatchDeletionReason::Step, EliminationReason::Step),
            (MatchDeletionReason::Timeout, EliminationReason::Timeout),
            (
                MatchDeletionReason::ChildTournament,
                EliminationReason::ChildTournament,
            ),
        ];

        for local_side in [MatchSide::One, MatchSide::Two] {
            let id = match local_side {
                MatchSide::One => MatchID {
                    commitment_one: local,
                    commitment_two: opponent,
                },
                MatchSide::Two => MatchID {
                    commitment_one: opponent,
                    commitment_two: local,
                },
            };
            let local_winner = match local_side {
                MatchSide::One => WinnerCommitment::One,
                MatchSide::Two => WinnerCommitment::Two,
            };
            let opponent_side = local_side.opposite();
            let opponent_winner = match opponent_side {
                MatchSide::One => WinnerCommitment::One,
                MatchSide::Two => WinnerCommitment::Two,
            };

            for (fold_reason, domain_reason) in reasons {
                for (winner, candidate) in [
                    (local_winner, Some(local)),
                    (opponent_winner, Some(opponent)),
                    (WinnerCommitment::Neither, None),
                ] {
                    let mut fold = Fold::new(ROOT);
                    fold.apply(&event(ROOT, 1, join(local, digest(0x91))))
                        .unwrap();
                    fold.apply(&event(ROOT, 2, join(opponent, digest(0x92))))
                        .unwrap();
                    fold.apply(&event(
                        ROOT,
                        3,
                        EventKind::MatchCreated {
                            one: id.commitment_one,
                            two: id.commitment_two,
                            left_of_two: digest(0x52),
                        },
                    ))
                    .unwrap();
                    fold.apply(&event(
                        ROOT,
                        4,
                        EventKind::MatchDeleted {
                            match_id_hash: id.hash(),
                            reason: fold_reason,
                            winner,
                        },
                    ))
                    .unwrap();

                    let observations =
                        HashMap::from([(ROOT, observation(descriptor, standing(candidate), []))]);
                    let projected = assemble(initial_hash, &fold, &observations);

                    if winner == local_winner {
                        assert_eq!(
                            projected.unwrap().snapshot().local_standing(),
                            LocalCommitmentStanding::Candidate
                        );
                    } else if fold_reason == MatchDeletionReason::Step
                        && winner == WinnerCommitment::Neither
                    {
                        assert!(matches!(
                            projected,
                            Err(ContextError::Domain {
                                source: DomainError::StepDeletionMissingSurvivor,
                                ..
                            })
                        ));
                    } else {
                        let context = projected.unwrap();
                        let LocalCommitmentStanding::Eliminated(record) =
                            context.snapshot().local_standing()
                        else {
                            panic!("non-survivor should be eliminated");
                        };
                        assert_eq!(record.local_side(), local_side);
                        assert_eq!(record.reason(), domain_reason);
                        assert_eq!(
                            record.survivor(),
                            if winner == WinnerCommitment::Neither {
                                None
                            } else {
                                Some(opponent_side)
                            }
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn latest_repair_replaces_survived_match_history() {
        let initial_hash = digest(0x90);
        let descriptor = root_descriptor(initial_hash, 1);
        let local = local_root(descriptor);
        let first_opponent = digest(0x51);
        let second_opponent = digest(0x52);
        let first = MatchID {
            commitment_one: local,
            commitment_two: first_opponent,
        };
        let second = MatchID {
            commitment_one: second_opponent,
            commitment_two: local,
        };

        let mut fold = Fold::new(ROOT);
        for (block, commitment) in [(1, local), (2, first_opponent), (5, second_opponent)] {
            fold.apply(&event(ROOT, block, join(commitment, digest(0x91))))
                .unwrap();
        }
        fold.apply(&event(
            ROOT,
            3,
            EventKind::MatchCreated {
                one: first.commitment_one,
                two: first.commitment_two,
                left_of_two: digest(0x60),
            },
        ))
        .unwrap();
        fold.apply(&event(
            ROOT,
            4,
            EventKind::MatchDeleted {
                match_id_hash: first.hash(),
                reason: MatchDeletionReason::Step,
                winner: WinnerCommitment::One,
            },
        ))
        .unwrap();
        fold.apply(&event(
            ROOT,
            6,
            EventKind::MatchCreated {
                one: second.commitment_one,
                two: second.commitment_two,
                left_of_two: digest(0x61),
            },
        ))
        .unwrap();

        let observations = HashMap::from([(
            ROOT,
            observation(
                descriptor,
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins: JoinDisposition::Closed,
                },
                [(second, live_match(descriptor))],
            ),
        )]);
        let context = assemble(initial_hash, &fold, &observations).unwrap();
        let LocalCommitmentStanding::Engaged(engagement) = context.snapshot().local_standing()
        else {
            panic!("re-paired commitment should be engaged");
        };
        assert_eq!(engagement.match_id(), second);
        assert_eq!(engagement.local_side(), MatchSide::Two);
    }

    #[test]
    fn recursively_projects_only_the_local_child_path() {
        let root_initial = digest(0x90);
        let agree_state = digest(0x91);
        let parent_descriptor = root_descriptor(root_initial, 2);
        let child_descriptor = child_descriptor(agree_state);
        let parent_local = local_root(parent_descriptor);
        let child_local = local_root(child_descriptor);
        let parent_opponent = digest(0x51);
        let parent_id = MatchID {
            commitment_one: parent_local,
            commitment_two: parent_opponent,
        };

        let mut fold = Fold::new(ROOT);
        fold.apply(&event(ROOT, 1, join(parent_local, digest(0xa1))))
            .unwrap();
        fold.apply(&event(ROOT, 2, join(parent_opponent, digest(0xa2))))
            .unwrap();
        fold.apply(&event(
            ROOT,
            3,
            EventKind::MatchCreated {
                one: parent_id.commitment_one,
                two: parent_id.commitment_two,
                left_of_two: digest(0x52),
            },
        ))
        .unwrap();
        fold.apply(&event(
            ROOT,
            4,
            EventKind::NewInnerTournament {
                match_id_hash: parent_id.hash(),
                child: CHILD,
            },
        ))
        .unwrap();
        fold.apply(&event(CHILD, 5, join(child_local, digest(0xa1))))
            .unwrap();

        let divergence = SealedDivergence::new(
            agree_state,
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            digest(0xa1),
            digest(0xa2),
        );
        let parent_live = LiveMatch::try_new(
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, CHILD).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap()
        .validate_in(parent_descriptor)
        .unwrap();
        let observations = HashMap::from([
            (
                ROOT,
                observation(
                    parent_descriptor,
                    TournamentStanding::MatchesActive {
                        candidate: None,
                        joins: JoinDisposition::Closed,
                    },
                    [(parent_id, parent_live)],
                ),
            ),
            (
                CHILD,
                observation(child_descriptor, standing(Some(child_local)), []),
            ),
        ]);

        let context = assemble(root_initial, &fold, &observations).unwrap();
        assert_eq!(context.root_tournament(), ROOT);
        assert_eq!(context.levels().len(), 2);
        assert_eq!(context.level(&ROOT).unwrap().root(), parent_local);
        assert_eq!(context.level(&CHILD).unwrap().root(), child_local);
        assert_eq!(
            context.snapshot_at(ROOT).unwrap().local_commitment(),
            parent_local
        );
        assert_eq!(
            context.snapshot_at(CHILD).unwrap().local_commitment(),
            child_local
        );
        assert!(context.snapshot_at(Address::new([0x33; 20])).is_none());
        let child = context.snapshot().child().unwrap();
        assert_eq!(child.local_commitment(), child_local);
        assert_eq!(child.local_standing(), LocalCommitmentStanding::Candidate);
        let parent = child.parent().unwrap();
        assert_eq!(parent.parent_tournament(), ROOT);
        assert_eq!(parent.parent_match(), parent_id);
        assert_eq!(parent.parent_commitment(), parent_local);
        assert_eq!(parent.parent_side(), MatchSide::One);
    }

    #[test]
    fn rejects_root_anchor_and_alignment_before_engine_construction() {
        let expected_initial = digest(0x90);
        let observed_initial = digest(0x91);
        let fold = Fold::new(ROOT);
        let root = root_descriptor(observed_initial, 1);
        let observations = HashMap::from([(ROOT, observation(root, standing(None), []))]);
        assert!(matches!(
            assemble(expected_initial, &fold, &observations),
            Err(ContextError::RootInitialHashMismatch { .. })
        ));

        let misaligned = descriptor(ROOT, 0, 1, expected_initial, 1, 0, 3);
        let observations = HashMap::from([(ROOT, observation(misaligned, standing(None), []))]);
        assert!(matches!(
            assemble(expected_initial, &fold, &observations),
            Err(ContextError::MisalignedBaseCycle {
                base_cycle,
                span,
                ..
            }) if base_cycle == U256::from(1) && span == U256::from(8)
        ));
    }
}
