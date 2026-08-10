//! Actor-relative projection of one event-derived dispute.
//!
//! Events choose the Hero's local path and own match lifecycle. Pinned point
//! reads supply only current tournament standings and the action payload for
//! the one engaged match at each visited level. The resulting semantic path is
//! assembled from the leaf upward and retains local engine coordinates beside
//! it for later action fulfillment.

use std::collections::HashMap;

use alloy::primitives::{Address, U256};
use thiserror::Error;

use crate::{
    chain::{Chain, ChainHead},
    engine::{DisputeSource, LevelCoords, RulerFactory},
    merkle::Digest,
    tournament::{
        dispute::{
            CommitmentPosition, Dispute, Match, MatchDeletionReason, MatchStatus, WinnerCommitment,
        },
        domain::{
            DomainError, EliminationReason, EliminationRecord, Engagement, LocalCommitmentStanding,
            MatchSide, ParentLink, SemanticSnapshot, TournamentDescriptor, TournamentStanding,
        },
        observer::read_match,
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
    #[cfg(test)]
    pub(crate) const fn from_parts(
        descriptor: TournamentDescriptor,
        coords: LevelCoords,
        root: Digest,
    ) -> Self {
        Self {
            descriptor,
            coords,
            root,
        }
    }

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
    #[cfg(test)]
    pub(crate) fn from_parts(
        snapshot: SemanticSnapshot,
        levels: impl IntoIterator<Item = LevelMaterial>,
    ) -> Self {
        let levels = levels
            .into_iter()
            .map(|material| (material.descriptor().address(), material))
            .collect();
        Self { snapshot, levels }
    }

    /// Project the Hero's one local path at a caller-supplied chain head.
    #[allow(clippy::too_many_arguments)]
    pub async fn assemble<F: RulerFactory>(
        chain: &Chain,
        head: ChainHead,
        epoch: u64,
        epoch_initial_hash: Digest,
        dispute: &Dispute,
        standings: &HashMap<Address, TournamentStanding>,
        source: &mut DisputeSource<F>,
    ) -> Result<Self, ContextError> {
        let root_descriptor = dispute.root().descriptor();
        if root_descriptor.initial_hash() != epoch_initial_hash {
            return Err(ContextError::RootInitialHashMismatch {
                tournament: root_descriptor.address(),
                expected: epoch_initial_hash,
                observed: root_descriptor.initial_hash(),
            });
        }

        let mut path = Vec::new();
        let mut levels = HashMap::new();
        let mut tournament = dispute.root();
        let mut parent = None;

        loop {
            let descriptor = tournament.descriptor();
            let address = descriptor.address();
            let standing = *standings
                .get(&address)
                .ok_or(ContextError::MissingStanding {
                    tournament: address,
                })?;
            let material = level_material(epoch, descriptor, source)?;
            let local_commitment = material.root();

            let (local_standing, next) = match tournament.position(&local_commitment) {
                CommitmentPosition::NotJoined => (LocalCommitmentStanding::NotJoined, None),
                CommitmentPosition::Candidate { .. } => (LocalCommitmentStanding::Candidate, None),
                CommitmentPosition::Eliminated { match_, reason, .. } => (
                    LocalCommitmentStanding::Eliminated(project_elimination(
                        address,
                        local_commitment,
                        match_,
                        reason,
                    )?),
                    None,
                ),
                CommitmentPosition::Engaged { match_, .. } => {
                    let live =
                        read_match(chain, tournament, match_, head)
                            .await
                            .map_err(|source| ContextError::MatchRead {
                                tournament: address,
                                match_id_hash: match_.id_hash(),
                                source,
                            })?;
                    let engagement = Engagement::try_new(
                        local_commitment,
                        match_.id(),
                        live.state(),
                        live.timeout(),
                    )
                    .map_err(|source| ContextError::Domain {
                        tournament: address,
                        source,
                    })?;

                    let next = match match_.status() {
                        MatchStatus::Inner { child } => {
                            let link = ParentLink::try_new(address, match_.id(), local_commitment)
                                .map_err(|source| ContextError::Domain {
                                    tournament: address,
                                    source,
                                })?;
                            Some((child.as_ref(), link))
                        }
                        MatchStatus::Clocked { .. } | MatchStatus::Leaf { .. } => None,
                        MatchStatus::Resolved { .. } => {
                            unreachable!("an engaged commitment has a live match")
                        }
                    };
                    (LocalCommitmentStanding::Engaged(engagement), next)
                }
            };

            let replaced = levels.insert(address, material);
            debug_assert!(replaced.is_none(), "Dispute guarantees unique addresses");
            path.push(PathLevel {
                descriptor,
                standing,
                local_commitment,
                local_standing,
                parent,
            });

            let Some((child, link)) = next else {
                break;
            };
            tournament = child;
            parent = Some(link);
        }

        let snapshot = assemble_snapshots(path)?;
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
    #[error("accepted standings are missing tournament {tournament}")]
    MissingStanding { tournament: Address },
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
    #[error("failed to read match {match_id_hash} in tournament {tournament}: {source}")]
    MatchRead {
        tournament: Address,
        match_id_hash: Digest,
        #[source]
        source: anyhow::Error,
    },
    #[error("semantic projection failed for tournament {tournament}: {source}")]
    Domain {
        tournament: Address,
        #[source]
        source: DomainError,
    },
}

#[derive(Clone, Copy)]
struct PathLevel {
    descriptor: TournamentDescriptor,
    standing: TournamentStanding,
    local_commitment: Digest,
    local_standing: LocalCommitmentStanding,
    parent: Option<ParentLink>,
}

fn assemble_snapshots(path: Vec<PathLevel>) -> Result<SemanticSnapshot, ContextError> {
    let mut child = None;
    for level in path.into_iter().rev() {
        let tournament = level.descriptor.address();
        child = Some(
            SemanticSnapshot::try_new(
                level.descriptor,
                level.standing,
                level.local_commitment,
                level.local_standing,
                level.parent,
                child,
            )
            .map_err(|source| ContextError::Domain { tournament, source })?,
        );
    }
    Ok(child.expect("every Dispute has a root tournament"))
}

fn level_material<F: RulerFactory>(
    epoch: u64,
    descriptor: TournamentDescriptor,
    source: &mut DisputeSource<F>,
) -> Result<LevelMaterial, ContextError> {
    let tournament = descriptor.address();
    let coords = level_coords(epoch, descriptor)?;
    let root = source
        .node(&coords.root())
        .map_err(|source| ContextError::CommitmentComputation { tournament, source })?;
    Ok(LevelMaterial {
        descriptor,
        coords,
        root,
    })
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

fn project_elimination(
    tournament: Address,
    local_commitment: Digest,
    match_: &Match,
    reason: MatchDeletionReason,
) -> Result<EliminationRecord, ContextError> {
    let MatchStatus::Resolved { winner, .. } = match_.status() else {
        unreachable!("an eliminated commitment has a resolved match")
    };
    EliminationRecord::try_new(
        local_commitment,
        match_.id(),
        elimination_reason(reason),
        winner_side(*winner),
    )
    .map_err(|source| ContextError::Domain { tournament, source })
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
    use crate::tournament::{
        MatchID,
        dispute::{Event, EventKind},
        domain::{
            AwaitingChildMatch, JoinDisposition, LiveMatchState, MatchCoordinate, SealedDivergence,
            TimeoutDisposition, TournamentKind,
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
        kind: TournamentKind,
        initial_hash: Digest,
        base_cycle: u64,
        log2_stride: u64,
        height: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            kind,
            initial_hash,
            U256::from(base_cycle),
            log2_stride,
            height,
        )
        .unwrap()
    }

    #[test]
    fn level_coordinates_reject_misaligned_base_cycles() {
        let descriptor = descriptor(ROOT, 0, TournamentKind::Leaf, digest(1), 1, 0, 3);
        assert!(matches!(
            level_coords(7, descriptor),
            Err(ContextError::MisalignedBaseCycle {
                tournament: ROOT,
                base_cycle,
                span,
            }) if base_cycle == U256::from(1) && span == U256::from(8)
        ));
    }

    #[test]
    fn level_coordinates_preserve_epoch_and_geometry() {
        let descriptor = descriptor(ROOT, 0, TournamentKind::Leaf, digest(1), 32, 2, 3);
        let coords = level_coords(7, descriptor).unwrap();
        assert_eq!(coords, LevelCoords::new(7, U256::from(32), 2, 3));
    }

    #[test]
    fn snapshot_path_is_built_from_leaf_to_root() {
        let agree_state = digest(2);
        let root_descriptor = descriptor(ROOT, 0, TournamentKind::NonLeaf, digest(1), 0, 3, 4);
        let child_descriptor = descriptor(CHILD, 1, TournamentKind::Leaf, agree_state, 0, 0, 3);
        let parent_match = MatchID {
            commitment_one: digest(3),
            commitment_two: digest(4),
        };
        let parent = ParentLink::try_new(ROOT, parent_match, digest(3)).unwrap();
        let divergence = SealedDivergence::new(
            agree_state,
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            digest(5),
            digest(6),
        );
        let engagement = Engagement::try_new(
            digest(3),
            parent_match,
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, CHILD).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap();

        let root = PathLevel {
            descriptor: root_descriptor,
            standing: TournamentStanding::MatchesActive {
                joins: JoinDisposition::Closed,
            },
            local_commitment: digest(3),
            local_standing: LocalCommitmentStanding::Engaged(engagement),
            parent: None,
        };

        let child = PathLevel {
            descriptor: child_descriptor,
            standing: TournamentStanding::AwaitingClosure,
            local_commitment: digest(5),
            local_standing: LocalCommitmentStanding::Candidate,
            parent: Some(parent),
        };

        let snapshot = assemble_snapshots(vec![root, child]).unwrap();
        assert_eq!(snapshot.descriptor().address(), ROOT);
        assert!(snapshot.parent().is_none());
        let child = snapshot.child().unwrap();
        assert_eq!(child.descriptor().address(), CHILD);
        assert_eq!(child.parent(), Some(parent));
        assert!(child.child().is_none());
    }

    #[test]
    fn eliminated_position_projects_the_recorded_winner_orientation() {
        let local = digest(3);
        let opponent = digest(4);
        let id = MatchID {
            commitment_one: opponent,
            commitment_two: local,
        };
        let dispute = Dispute::try_new(descriptor(
            ROOT,
            0,
            TournamentKind::Leaf,
            digest(1),
            0,
            0,
            3,
        ))
        .unwrap()
        .apply_block([
            Event {
                tournament: ROOT,
                kind: EventKind::CommitmentJoined {
                    root: opponent,
                    final_state: digest(5),
                    submitter: Address::new([0x31; 20]),
                },
            },
            Event {
                tournament: ROOT,
                kind: EventKind::CommitmentJoined {
                    root: local,
                    final_state: digest(6),
                    submitter: Address::new([0x32; 20]),
                },
            },
            Event {
                tournament: ROOT,
                kind: EventKind::MatchCreated {
                    id,
                    eliminable_at: 10,
                },
            },
            Event {
                tournament: ROOT,
                kind: EventKind::MatchDeleted {
                    match_id_hash: id.hash(),
                    reason: MatchDeletionReason::Timeout,
                    winner: WinnerCommitment::One,
                },
            },
        ])
        .unwrap();

        let CommitmentPosition::Eliminated { match_, reason, .. } = dispute.root().position(&local)
        else {
            panic!("local commitment should be eliminated");
        };
        let record = project_elimination(ROOT, local, match_, reason).unwrap();
        assert_eq!(record.match_id(), id);
        assert_eq!(record.local_side(), MatchSide::Two);
        assert_eq!(record.reason(), EliminationReason::Timeout);
        assert_eq!(record.survivor(), Some(MatchSide::One));
    }
}
