//! Pure, actor-neutral cleanup planning over the recursive dispute tree.
//!
//! Match eliminability comes entirely from contract-authored schedules in the
//! event fold. Tournament eliminability remains the contract's current-state
//! decision and therefore uses one standing observation per reachable
//! tournament. The planner returns at most one action so maintenance never
//! leaves a nonce tail in front of the next Hero response.

use std::collections::HashMap;

use alloy::primitives::Address;
use thiserror::Error;

use crate::tournament::{
    dispute::{Dispute, MatchStatus, Tournament},
    domain::{GcIntent, TournamentStanding},
};

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum GcPlanError {
    #[error("reachable tournament {0} has no standing observation")]
    MissingTournament(Address),
}

/// Return the highest-priority cleanup currently known to be legal.
///
/// Deeper work wins globally; stable tree order breaks ties. When an inner
/// tournament is itself eliminable, its parent action replaces all cleanup
/// inside that subtree.
pub fn plan_gc(
    dispute: &Dispute,
    standings: &HashMap<Address, TournamentStanding>,
    at: u64,
) -> Result<Option<GcIntent>, GcPlanError> {
    let mut best = None;
    let mut order = 0;
    plan_tournament(dispute.root(), standings, at, &mut order, &mut best)?;
    Ok(best.map(|planned: PlannedGc| planned.intent))
}

struct PlannedGc {
    depth: u64,
    order: usize,
    intent: GcIntent,
}

fn plan_tournament(
    tournament: &Tournament,
    standings: &HashMap<Address, TournamentStanding>,
    at: u64,
    order: &mut usize,
    best: &mut Option<PlannedGc>,
) -> Result<(), GcPlanError> {
    standings
        .get(&tournament.address())
        .ok_or(GcPlanError::MissingTournament(tournament.address()))?;

    for match_ in tournament.matches() {
        match match_.status() {
            MatchStatus::Clocked { eliminable_at } | MatchStatus::Leaf { eliminable_at }
                if at >= *eliminable_at =>
            {
                consider(
                    PlannedGc {
                        depth: tournament.descriptor().level(),
                        order: next_order(order),
                        intent: GcIntent::EliminateMatch {
                            tournament: tournament.address(),
                            match_id: match_.id(),
                        },
                    },
                    best,
                );
            }
            MatchStatus::Inner { child } => {
                let child_standing = standings
                    .get(&child.address())
                    .ok_or(GcPlanError::MissingTournament(child.address()))?;
                if matches!(child_standing, TournamentStanding::InnerEliminable { .. }) {
                    consider(
                        PlannedGc {
                            depth: child.descriptor().level(),
                            order: next_order(order),
                            intent: GcIntent::EliminateChild {
                                parent_tournament: tournament.address(),
                                child_tournament: child.address(),
                            },
                        },
                        best,
                    );
                } else {
                    plan_tournament(child, standings, at, order, best)?;
                }
            }
            MatchStatus::Clocked { .. }
            | MatchStatus::Leaf { .. }
            | MatchStatus::Resolved { .. } => {}
        }
    }

    Ok(())
}

fn next_order(order: &mut usize) -> usize {
    let current = *order;
    *order += 1;
    current
}

fn consider(candidate: PlannedGc, best: &mut Option<PlannedGc>) {
    let replace = best.as_ref().is_none_or(|current| {
        candidate.depth > current.depth
            || (candidate.depth == current.depth && candidate.order < current.order)
    });
    if replace {
        *best = Some(candidate);
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::U256;

    use super::*;
    use crate::{
        merkle::Digest,
        tournament::{
            MatchID,
            dispute::{Event, EventKind},
            domain::{
                InnerEliminationReason, JoinDisposition, TournamentDescriptor, TournamentKind,
            },
        },
    };

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn descriptor(byte: u8, level: u64, kind: TournamentKind) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address(byte),
            level,
            kind,
            digest(90 + u8::try_from(level).unwrap()),
            U256::ZERO,
            0,
            4,
        )
        .unwrap()
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

    fn pair(tournament: Address, one: Digest, two: Digest, at: u64) -> [Event; 2] {
        [
            join(tournament, two),
            event(
                tournament,
                EventKind::MatchCreated {
                    id: MatchID {
                        commitment_one: one,
                        commitment_two: two,
                    },
                    eliminable_at: at,
                },
            ),
        ]
    }

    fn active() -> TournamentStanding {
        TournamentStanding::MatchesActive {
            joins: JoinDisposition::Open,
        }
    }

    #[test]
    fn inclusive_match_schedule_needs_no_point_read() {
        let root = address(1);
        let one = digest(1);
        let two = digest(2);
        let match_id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let dispute = Dispute::try_new(descriptor(1, 0, TournamentKind::Leaf))
            .unwrap()
            .apply_block([join(root, one)])
            .unwrap()
            .apply_block(pair(root, one, two, 10))
            .unwrap();
        let standings = HashMap::from([(root, active())]);

        assert_eq!(plan_gc(&dispute, &standings, 9).unwrap(), None);
        assert_eq!(
            plan_gc(&dispute, &standings, 10).unwrap(),
            Some(GcIntent::EliminateMatch {
                tournament: root,
                match_id,
            })
        );
    }

    #[test]
    fn deepest_due_work_wins_globally() {
        let root = address(1);
        let child = address(2);
        let shallow = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        let parent = MatchID {
            commitment_one: digest(3),
            commitment_two: digest(4),
        };
        let deep = MatchID {
            commitment_one: digest(5),
            commitment_two: digest(6),
        };

        let dispute = Dispute::try_new(descriptor(1, 0, TournamentKind::NonLeaf))
            .unwrap()
            .apply_block([join(root, shallow.commitment_one)])
            .unwrap()
            .apply_block(pair(
                root,
                shallow.commitment_one,
                shallow.commitment_two,
                5,
            ))
            .unwrap()
            .apply_block([join(root, parent.commitment_one)])
            .unwrap()
            .apply_block(pair(root, parent.commitment_one, parent.commitment_two, 5))
            .unwrap()
            .apply_block([event(
                root,
                EventKind::NewInnerTournament {
                    match_id_hash: parent.hash(),
                    child: descriptor(2, 1, TournamentKind::Leaf),
                },
            )])
            .unwrap()
            .apply_block([join(child, deep.commitment_one)])
            .unwrap()
            .apply_block(pair(child, deep.commitment_one, deep.commitment_two, 5))
            .unwrap();
        let standings = HashMap::from([(root, active()), (child, active())]);

        assert_eq!(
            plan_gc(&dispute, &standings, 5).unwrap(),
            Some(GcIntent::EliminateMatch {
                tournament: child,
                match_id: deep,
            })
        );
    }

    #[test]
    fn eliminable_child_replaces_its_subtree() {
        let root = address(1);
        let child = address(2);
        let parent = MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        };
        let dispute = Dispute::try_new(descriptor(1, 0, TournamentKind::NonLeaf))
            .unwrap()
            .apply_block([join(root, parent.commitment_one)])
            .unwrap()
            .apply_block(pair(root, parent.commitment_one, parent.commitment_two, 5))
            .unwrap()
            .apply_block([event(
                root,
                EventKind::NewInnerTournament {
                    match_id_hash: parent.hash(),
                    child: descriptor(2, 1, TournamentKind::Leaf),
                },
            )])
            .unwrap();
        let standings = HashMap::from([
            (root, active()),
            (
                child,
                TournamentStanding::InnerEliminable {
                    reason: InnerEliminationReason::NoCandidate,
                },
            ),
        ]);

        assert_eq!(
            plan_gc(&dispute, &standings, 5).unwrap(),
            Some(GcIntent::EliminateChild {
                parent_tournament: root,
                child_tournament: child,
            })
        );
    }
}
