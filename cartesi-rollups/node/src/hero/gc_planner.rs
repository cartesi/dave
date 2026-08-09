//! Pure, actor-neutral cleanup planning over one accepted dispute observation.
//!
//! The Hero snapshot follows only the local commitment path. Cleanup must see
//! every reachable live match, so it plans directly from the structural fold
//! and semantic tournament observations. The returned order is deterministic:
//! fold creation order, with child cleanup before its parent match.

use std::collections::HashMap;

use alloy::primitives::Address;
use thiserror::Error;

use crate::{
    merkle::Digest,
    tournament::{
        adapter::TournamentObservation,
        domain::{GcIntent, LiveMatchState, TimeoutDisposition, TournamentStanding},
        fold::Fold,
    },
};

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum GcPlanError {
    #[error("reachable tournament {0} has no semantic observation")]
    MissingTournament(Address),
    #[error("live match {match_id_hash} in tournament {tournament} has no semantic observation")]
    MissingMatch {
        tournament: Address,
        match_id_hash: Digest,
    },
    #[error("awaiting-child match names undiscovered tournament {0}")]
    MissingChild(Address),
}

/// Return every currently legal cleanup intent in deterministic
/// innermost-first order.
pub fn plan_gc(
    fold: &Fold,
    observations: &HashMap<Address, TournamentObservation>,
) -> Result<Vec<GcIntent>, GcPlanError> {
    let mut planned = Vec::new();
    plan_tournament(fold.root(), fold, observations, &mut planned)?;
    // Stable depth ordering makes "innermost first" global across independent
    // branches while preserving fold creation order within one level.
    planned.sort_by_key(|entry| std::cmp::Reverse(entry.depth));
    Ok(planned.into_iter().map(|entry| entry.intent).collect())
}

struct PlannedGc {
    depth: u64,
    intent: GcIntent,
}

fn plan_tournament(
    tournament_address: Address,
    fold: &Fold,
    observations: &HashMap<Address, TournamentObservation>,
    intents: &mut Vec<PlannedGc>,
) -> Result<(), GcPlanError> {
    let tournament = fold
        .tournament(&tournament_address)
        .ok_or(GcPlanError::MissingTournament(tournament_address))?;
    let observation = observations
        .get(&tournament_address)
        .ok_or(GcPlanError::MissingTournament(tournament_address))?;

    for match_fold in tournament.live_matches() {
        let match_id_hash = match_fold.id.hash();
        let observed =
            observation
                .match_by_id_hash(&match_id_hash)
                .ok_or(GcPlanError::MissingMatch {
                    tournament: tournament_address,
                    match_id_hash,
                })?;

        if let LiveMatchState::AwaitingChild(awaiting) = observed.live().state() {
            let child_address = awaiting.child_tournament();
            let child_fold = fold
                .tournament(&child_address)
                .ok_or(GcPlanError::MissingChild(child_address))?;
            let child = observations
                .get(&child_address)
                .ok_or(GcPlanError::MissingChild(child_address))?;
            if matches!(child.standing(), TournamentStanding::InnerEliminable { .. }) {
                intents.push(PlannedGc {
                    depth: child_fold.level,
                    intent: GcIntent::EliminateChild {
                        parent_tournament: tournament_address,
                        child_tournament: child_address,
                    },
                });
            } else {
                plan_tournament(child_address, fold, observations, intents)?;
            }
        }

        if observed.live().timeout() == TimeoutDisposition::EliminateBoth {
            intents.push(PlannedGc {
                depth: tournament.level,
                intent: GcIntent::EliminateMatch {
                    tournament: tournament_address,
                    match_id: observed.id(),
                },
            });
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use alloy::primitives::U256;

    use super::*;
    use crate::{
        merkle::Digest,
        tournament::{
            MatchID,
            adapter::ObservedMatch,
            domain::{
                AwaitingChildMatch, BisectingMatch, InnerEliminationReason, JoinDisposition,
                LiveMatch, MatchCoordinate, MatchSide, ReadyToSealMatch, SealedDivergence,
                SealedLeafMatch, TournamentDescriptor, TournamentKind, WaitingChildren,
            },
            fold::{EventKind, TournamentEvent},
        },
    };

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn apply(fold: &mut Fold, tournament: Address, block: u64, kind: EventKind) {
        fold.apply(&TournamentEvent {
            tournament,
            block,
            kind,
        })
        .unwrap();
    }

    fn create_match(
        fold: &mut Fold,
        tournament: Address,
        one: Digest,
        two: Digest,
        block: u64,
    ) -> MatchID {
        for (root, final_state) in [(one, digest(80)), (two, digest(81))] {
            apply(
                fold,
                tournament,
                block,
                EventKind::CommitmentJoined { root, final_state },
            );
        }
        apply(
            fold,
            tournament,
            block,
            EventKind::MatchCreated {
                one,
                two,
                left_of_two: digest(82),
            },
        );
        MatchID {
            commitment_one: one,
            commitment_two: two,
        }
    }

    fn descriptor(address: Address, level: u64, kind: TournamentKind) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            kind,
            digest(90 + u8::try_from(level).unwrap()),
            U256::ZERO,
            0,
            4,
        )
        .unwrap()
    }

    fn bisecting(timeout: TimeoutDisposition) -> LiveMatch {
        LiveMatch::try_new(
            LiveMatchState::Bisecting(
                BisectingMatch::try_new(
                    digest(40),
                    WaitingChildren::new(digest(41), digest(42)),
                    MatchCoordinate::new(U256::ZERO, U256::ZERO),
                    4,
                    MatchSide::One,
                )
                .unwrap(),
            ),
            timeout,
        )
        .unwrap()
    }

    fn observation(
        descriptor: TournamentDescriptor,
        standing: TournamentStanding,
        matches: impl IntoIterator<Item = ObservedMatch>,
    ) -> TournamentObservation {
        TournamentObservation::from_parts(
            descriptor,
            standing,
            matches
                .into_iter()
                .map(|observed| (observed.id().hash(), observed))
                .collect(),
        )
    }

    fn active_standing() -> TournamentStanding {
        TournamentStanding::MatchesActive {
            candidate: None,
            joins: JoinDisposition::Open,
        }
    }

    #[test]
    fn plans_matches_in_fold_creation_order() {
        let root = address(1);
        let mut fold = Fold::new(root);
        let first = create_match(&mut fold, root, digest(1), digest(2), 1);
        let second = create_match(&mut fold, root, digest(3), digest(4), 2);
        let observed_first =
            ObservedMatch::from_parts(first, bisecting(TimeoutDisposition::EliminateBoth));
        let observed_second =
            ObservedMatch::from_parts(second, bisecting(TimeoutDisposition::EliminateBoth));
        let observations = HashMap::from([(
            root,
            observation(
                descriptor(root, 0, TournamentKind::Leaf),
                active_standing(),
                [observed_first, observed_second],
            ),
        )]);

        assert_eq!(
            plan_gc(&fold, &observations).unwrap(),
            vec![
                GcIntent::EliminateMatch {
                    tournament: root,
                    match_id: first,
                },
                GcIntent::EliminateMatch {
                    tournament: root,
                    match_id: second,
                },
            ]
        );
    }

    #[test]
    fn plans_nested_cleanup_before_parent_sibling() {
        let root = address(1);
        let child = address(2);
        let mut fold = Fold::new(root);
        let parent_match = create_match(&mut fold, root, digest(1), digest(2), 1);
        apply(
            &mut fold,
            root,
            2,
            EventKind::NewInnerTournament {
                match_id_hash: parent_match.hash(),
                child,
            },
        );
        let root_sibling = create_match(&mut fold, root, digest(3), digest(4), 3);
        let child_match = create_match(&mut fold, child, digest(5), digest(6), 4);

        let divergence = SealedDivergence::new(
            digest(91),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            digest(21),
            digest(22),
        );
        let awaiting = LiveMatch::try_new(
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, child).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap();
        let root_observation = observation(
            descriptor(root, 0, TournamentKind::NonLeaf),
            active_standing(),
            [
                ObservedMatch::from_parts(parent_match, awaiting),
                ObservedMatch::from_parts(
                    root_sibling,
                    bisecting(TimeoutDisposition::EliminateBoth),
                ),
            ],
        );
        let child_observation = observation(
            descriptor(child, 1, TournamentKind::Leaf),
            active_standing(),
            [ObservedMatch::from_parts(
                child_match,
                bisecting(TimeoutDisposition::EliminateBoth),
            )],
        );
        let observations = HashMap::from([(root, root_observation), (child, child_observation)]);

        assert_eq!(
            plan_gc(&fold, &observations).unwrap(),
            vec![
                GcIntent::EliminateMatch {
                    tournament: child,
                    match_id: child_match,
                },
                GcIntent::EliminateMatch {
                    tournament: root,
                    match_id: root_sibling,
                },
            ]
        );
    }

    #[test]
    fn globally_prioritizes_deeper_later_branch() {
        let root = address(1);
        let child = address(2);
        let mut fold = Fold::new(root);
        let shallow = create_match(&mut fold, root, digest(1), digest(2), 1);
        let parent_match = create_match(&mut fold, root, digest(3), digest(4), 2);
        apply(
            &mut fold,
            root,
            3,
            EventKind::NewInnerTournament {
                match_id_hash: parent_match.hash(),
                child,
            },
        );
        let child_match = create_match(&mut fold, child, digest(5), digest(6), 4);

        let divergence = SealedDivergence::new(
            digest(91),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            digest(21),
            digest(22),
        );
        let awaiting = LiveMatch::try_new(
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, child).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap();
        let observations = HashMap::from([
            (
                root,
                observation(
                    descriptor(root, 0, TournamentKind::NonLeaf),
                    active_standing(),
                    [
                        ObservedMatch::from_parts(
                            shallow,
                            bisecting(TimeoutDisposition::EliminateBoth),
                        ),
                        ObservedMatch::from_parts(parent_match, awaiting),
                    ],
                ),
            ),
            (
                child,
                observation(
                    descriptor(child, 1, TournamentKind::Leaf),
                    active_standing(),
                    [ObservedMatch::from_parts(
                        child_match,
                        bisecting(TimeoutDisposition::EliminateBoth),
                    )],
                ),
            ),
        ]);

        assert_eq!(
            plan_gc(&fold, &observations).unwrap(),
            vec![
                GcIntent::EliminateMatch {
                    tournament: child,
                    match_id: child_match,
                },
                GcIntent::EliminateMatch {
                    tournament: root,
                    match_id: shallow,
                },
            ]
        );
    }

    #[test]
    fn eliminable_child_replaces_recursive_cleanup() {
        let root = address(1);
        let child = address(2);
        let mut fold = Fold::new(root);
        let parent_match = create_match(&mut fold, root, digest(1), digest(2), 1);
        apply(
            &mut fold,
            root,
            2,
            EventKind::NewInnerTournament {
                match_id_hash: parent_match.hash(),
                child,
            },
        );

        let divergence = SealedDivergence::new(
            digest(91),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            digest(21),
            digest(22),
        );
        let awaiting = LiveMatch::try_new(
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, child).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap();
        let observations = HashMap::from([
            (
                root,
                observation(
                    descriptor(root, 0, TournamentKind::NonLeaf),
                    active_standing(),
                    [ObservedMatch::from_parts(parent_match, awaiting)],
                ),
            ),
            (
                child,
                observation(
                    descriptor(child, 1, TournamentKind::Leaf),
                    TournamentStanding::InnerEliminable {
                        reason: InnerEliminationReason::NoCandidate,
                    },
                    [],
                ),
            ),
        ]);

        assert_eq!(
            plan_gc(&fold, &observations).unwrap(),
            vec![GcIntent::EliminateChild {
                parent_tournament: root,
                child_tournament: child,
            }]
        );
    }

    #[test]
    fn expired_child_candidate_is_directly_eliminable() {
        let root = address(1);
        let child = address(2);
        let child_candidate = digest(9);
        let mut fold = Fold::new(root);
        let parent_match = create_match(&mut fold, root, digest(1), digest(2), 1);
        apply(
            &mut fold,
            root,
            2,
            EventKind::NewInnerTournament {
                match_id_hash: parent_match.hash(),
                child,
            },
        );
        apply(
            &mut fold,
            child,
            3,
            EventKind::CommitmentJoined {
                root: child_candidate,
                final_state: digest(10),
            },
        );

        let divergence = SealedDivergence::new(
            digest(91),
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            digest(21),
            digest(22),
        );
        let awaiting = LiveMatch::try_new(
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, child).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap();
        let observations = HashMap::from([
            (
                root,
                observation(
                    descriptor(root, 0, TournamentKind::NonLeaf),
                    active_standing(),
                    [ObservedMatch::from_parts(parent_match, awaiting)],
                ),
            ),
            (
                child,
                observation(
                    descriptor(child, 1, TournamentKind::Leaf),
                    TournamentStanding::InnerEliminable {
                        reason: InnerEliminationReason::WinnerExpired {
                            candidate: child_candidate,
                        },
                    },
                    [],
                ),
            ),
        ]);

        assert_eq!(
            plan_gc(&fold, &observations).unwrap(),
            vec![GcIntent::EliminateChild {
                parent_tournament: root,
                child_tournament: child,
            }]
        );
    }

    #[test]
    fn ignores_non_eliminable_timeouts() {
        let root = address(1);
        let mut fold = Fold::new(root);
        let match_id = create_match(&mut fold, root, digest(1), digest(2), 1);
        let observations = HashMap::from([(
            root,
            observation(
                descriptor(root, 0, TournamentKind::Leaf),
                active_standing(),
                [ObservedMatch::from_parts(
                    match_id,
                    bisecting(TimeoutDisposition::TwoWins {
                        deferred_charge: crate::tournament::domain::BlockDuration::from_blocks(3),
                    }),
                )],
            ),
        )]);

        assert!(plan_gc(&fold, &observations).unwrap().is_empty());
    }

    #[test]
    fn eliminate_both_is_cleanup_in_ready_and_sealed_leaf_phases() {
        let root = address(1);
        let mut fold = Fold::new(root);
        let match_id = create_match(&mut fold, root, digest(1), digest(2), 1);
        let coordinate = MatchCoordinate::new(U256::ZERO, U256::ZERO);
        let ready = LiveMatch::try_new(
            LiveMatchState::ReadyToSealLeaf(ReadyToSealMatch::new(
                digest(40),
                WaitingChildren::new(digest(41), digest(42)),
                coordinate,
                MatchSide::One,
            )),
            TimeoutDisposition::EliminateBoth,
        )
        .unwrap();
        let sealed = LiveMatch::try_new(
            LiveMatchState::SealedLeaf(SealedLeafMatch::new(SealedDivergence::new(
                digest(43),
                coordinate,
                digest(44),
                digest(45),
            ))),
            TimeoutDisposition::EliminateBoth,
        )
        .unwrap();

        for live in [ready, sealed] {
            let observations = HashMap::from([(
                root,
                observation(
                    descriptor(root, 0, TournamentKind::Leaf),
                    active_standing(),
                    [ObservedMatch::from_parts(match_id, live)],
                ),
            )]);
            assert_eq!(
                plan_gc(&fold, &observations).unwrap(),
                vec![GcIntent::EliminateMatch {
                    tournament: root,
                    match_id,
                }]
            );
        }
    }
}
