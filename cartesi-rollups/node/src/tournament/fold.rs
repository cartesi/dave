// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Tournament state = fold(events): the pure half of the tournament
//! reader (docs/plans/node-refactor.md, workstream 5).
//!
//! The chain's event vocabulary fully determines the dispute's
//! STRUCTURE: which tournaments exist (inner ones are discovered by
//! the fold itself), which commitments joined with which final
//! states, which matches were created, sealed into inner tournaments,
//! or deleted with which winner. The fold derives exactly that, from
//! genesis, every tick - ticks are seconds apart and a full dispute
//! is hundreds of events, so compute is nothing, no derived state is
//! ever persisted, and cold start equals tick.
//!
//! What events deliberately do NOT determine stays out of the fold
//! and in the per-tick point-read overlay:
//!
//! - Live match positions (runningLeafPosition, currentHeight,
//!   otherParent/leftNode): MatchAdvanced names the new otherParent,
//!   but when a node's children are equal hashes (real in padded
//!   regions) the descent direction is ambiguous from events alone,
//!   and the position depends on it. The contract knows; getMatch is
//!   the authority.
//! - Clocks: every Clock mutation is deterministic in (state, block),
//!   but MatchAdvanced does not name the mover, so allowances are not
//!   attributable from events alone. getCommitment is the authority.
//! - Winners and elimination: arbitrationResult,
//!   innerTournamentWinner, and canBeEliminated encode validity logic
//!   the chain owns; MatchDeleted's winner is recorded as structure,
//!   but the tournament-level verdict stays a point read.

use std::collections::HashMap;

use crate::merkle::Digest;
use alloy::{primitives::Address, rpc::types::Log, sol_types::SolEvent};
use anyhow::{Result, anyhow, bail, ensure};
use cartesi_prt_contracts::tournament::Tournament;

use crate::tournament::MatchID;

/// Why a match left the bracket (ITournament.MatchDeletionReason).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchDeletionReason {
    Step,
    Timeout,
    ChildTournament,
}

/// Which commitment survived a deleted match
/// (ITournament.WinnerCommitment).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinnerCommitment {
    Neither,
    One,
    Two,
}

/// One tournament event, as the contracts emit it. Carries its
/// tournament address and block number; inner tournaments are
/// discovered by the fold (a NewInnerTournament names the address
/// whose log stream must also be fetched).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TournamentEvent {
    pub tournament: Address,
    pub block: u64,
    pub kind: EventKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EventKind {
    CommitmentJoined {
        root: Digest,
        final_state: Digest,
    },
    MatchCreated {
        one: Digest,
        two: Digest,
        left_of_two: Digest,
    },
    MatchAdvanced {
        match_id_hash: Digest,
        other_parent: Digest,
        left_node: Digest,
    },
    MatchDeleted {
        match_id_hash: Digest,
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
    },
    NewInnerTournament {
        match_id_hash: Digest,
        child: Address,
    },
}

/// Decodes a raw chain log into a tournament event, through the same
/// bindings the fetcher uses. `None` for any log that is not one of
/// the tournament's five structural events (bond refunds and foreign
/// contracts' logs among them); the caller filters by address.
pub fn decode_event(log: &Log) -> Result<Option<TournamentEvent>> {
    let tournament = log.address();
    let block = log
        .block_number
        .ok_or_else(|| anyhow!("chain log without a block number"))?;
    let primitive = &log.inner;

    let kind = if let Ok(e) = Tournament::CommitmentJoined::decode_log(primitive) {
        EventKind::CommitmentJoined {
            root: e.commitment.into(),
            final_state: e.finalStateHash.into(),
        }
    } else if let Ok(e) = Tournament::MatchCreated::decode_log(primitive) {
        EventKind::MatchCreated {
            one: e.one.into(),
            two: e.two.into(),
            left_of_two: e.leftOfTwo.into(),
        }
    } else if let Ok(e) = Tournament::MatchAdvanced::decode_log(primitive) {
        EventKind::MatchAdvanced {
            match_id_hash: e.matchIdHash.into(),
            other_parent: e.otherParent.into(),
            left_node: e.leftNode.into(),
        }
    } else if let Ok(e) = Tournament::MatchDeleted::decode_log(primitive) {
        EventKind::MatchDeleted {
            match_id_hash: e.matchIdHash.into(),
            // The bindings model Solidity enums as u8 newtypes; the
            // discriminants mirror ITournament.sol's declaration order.
            reason: match e.reason {
                0 => MatchDeletionReason::Step,
                1 => MatchDeletionReason::Timeout,
                2 => MatchDeletionReason::ChildTournament,
                other => bail!("unknown match deletion reason {other}"),
            },
            winner: match e.winnerCommitment {
                0 => WinnerCommitment::Neither,
                1 => WinnerCommitment::One,
                2 => WinnerCommitment::Two,
                other => bail!("unknown winner commitment {other}"),
            },
        }
    } else if let Ok(e) = Tournament::NewInnerTournament::decode_log(primitive) {
        EventKind::NewInnerTournament {
            match_id_hash: e.matchIdHash.into(),
            child: e.childTournament,
        }
    } else {
        return Ok(None);
    };

    Ok(Some(TournamentEvent {
        tournament,
        block,
        kind,
    }))
}

/// A commitment's structural record.
#[derive(Debug, Clone, PartialEq)]
pub struct CommitmentFold {
    pub root: Digest,
    pub final_state: Digest,
    pub joined_at_block: u64,
    /// Index into the tournament's match list, most recent first.
    pub latest_match: Option<usize>,
}

/// A match's structural record, from creation to deletion.
#[derive(Debug, Clone, PartialEq)]
pub struct MatchFold {
    pub id: MatchID,
    pub created_at_block: u64,
    /// MatchAdvanced count: how far the bisection has descended.
    pub advances: u64,
    /// The last event-reported (otherParent, leftNode). Structural
    /// breadcrumbs only - live positioning reads the chain (see the
    /// module doc on descent ambiguity).
    pub last_other_parent: Digest,
    pub last_left_node: Digest,
    pub inner_tournament: Option<Address>,
    pub deleted: Option<(MatchDeletionReason, WinnerCommitment)>,
}

impl MatchFold {
    pub fn is_live(&self) -> bool {
        self.deleted.is_none()
    }
}

/// A tournament's structural record.
#[derive(Debug, Clone, PartialEq)]
pub struct TournamentFold {
    pub address: Address,
    /// The parent tournament and the sealed match that spawned this
    /// one; None for the root.
    pub parent: Option<(Address, Digest)>,
    /// Root is 0; each inner tournament is one deeper.
    pub level: u64,
    pub commitments: HashMap<Digest, CommitmentFold>,
    pub matches: Vec<MatchFold>,
    match_index: HashMap<Digest, usize>,
}

impl TournamentFold {
    fn new(address: Address, parent: Option<(Address, Digest)>, level: u64) -> Self {
        TournamentFold {
            address,
            parent,
            level,
            commitments: HashMap::new(),
            matches: Vec::new(),
            match_index: HashMap::new(),
        }
    }

    pub fn match_by_id_hash(&self, id_hash: &Digest) -> Option<&MatchFold> {
        self.match_index.get(id_hash).map(|i| &self.matches[*i])
    }

    pub fn live_matches(&self) -> impl Iterator<Item = &MatchFold> {
        self.matches.iter().filter(|m| m.is_live())
    }
}

/// The pure fold. Feed it every event of every discovered tournament,
/// in block order per tournament; it derives the dispute's structure
/// and nothing else. Applying is fallible only against MALFORMED
/// streams (an advance for a match never created, a duplicate
/// creation): those mean a broken fetcher or a wrong address set, and
/// the fold refuses loudly rather than folding garbage.
#[derive(Debug, Clone, PartialEq)]
pub struct Fold {
    root: Address,
    tournaments: HashMap<Address, TournamentFold>,
    /// Discovery order: parents before children.
    order: Vec<Address>,
}

impl Fold {
    pub fn new(root: Address) -> Self {
        let mut tournaments = HashMap::new();
        tournaments.insert(root, TournamentFold::new(root, None, 0));
        Fold {
            root,
            tournaments,
            order: vec![root],
        }
    }

    pub fn root(&self) -> Address {
        self.root
    }

    /// Every discovered tournament, parents before children: the
    /// fetch set. A fetch round that discovers a new inner tournament
    /// must fetch its logs and fold again; depth is bounded by the
    /// level count, so the loop closes in at most that many rounds.
    pub fn addresses(&self) -> Vec<Address> {
        self.order.clone()
    }

    pub fn tournament(&self, address: &Address) -> Option<&TournamentFold> {
        self.tournaments.get(address)
    }

    pub fn tournaments(&self) -> impl Iterator<Item = &TournamentFold> {
        self.order.iter().map(|a| &self.tournaments[a])
    }

    pub fn apply(&mut self, event: &TournamentEvent) -> Result<()> {
        let tournament = self
            .tournaments
            .get_mut(&event.tournament)
            .ok_or_else(|| anyhow!("event for undiscovered tournament {}", event.tournament))?;

        match &event.kind {
            EventKind::CommitmentJoined { root, final_state } => {
                // Rejoining is a chain-side impossibility; two events
                // for one root mean a double-fetched range.
                ensure!(
                    !tournament.commitments.contains_key(root),
                    "commitment {root} joined twice (double-fetched range?)"
                );
                tournament.commitments.insert(
                    *root,
                    CommitmentFold {
                        root: *root,
                        final_state: *final_state,
                        joined_at_block: event.block,
                        latest_match: None,
                    },
                );
            }

            EventKind::MatchCreated {
                one,
                two,
                left_of_two,
            } => {
                let id = MatchID {
                    commitment_one: *one,
                    commitment_two: *two,
                };
                let id_hash = id.hash();
                ensure!(
                    !tournament.match_index.contains_key(&id_hash),
                    "match {id_hash} created twice (double-fetched range?)"
                );
                let index = tournament.matches.len();
                tournament.matches.push(MatchFold {
                    id,
                    created_at_block: event.block,
                    advances: 0,
                    last_other_parent: *one,
                    last_left_node: *left_of_two,
                    inner_tournament: None,
                    deleted: None,
                });
                tournament.match_index.insert(id_hash, index);
                for commitment in [one, two] {
                    tournament
                        .commitments
                        .get_mut(commitment)
                        .ok_or_else(|| {
                            anyhow!("match created for unjoined commitment {commitment}")
                        })?
                        .latest_match = Some(index);
                }
            }

            EventKind::MatchAdvanced {
                match_id_hash,
                other_parent,
                left_node,
            } => {
                let m = mutable_match(tournament, match_id_hash)?;
                ensure!(m.is_live(), "advance on a deleted match {match_id_hash}");
                m.advances += 1;
                m.last_other_parent = *other_parent;
                m.last_left_node = *left_node;
            }

            EventKind::MatchDeleted {
                match_id_hash,
                reason,
                winner,
            } => {
                let m = mutable_match(tournament, match_id_hash)?;
                ensure!(m.is_live(), "match {match_id_hash} deleted twice");
                m.deleted = Some((*reason, *winner));
            }

            EventKind::NewInnerTournament {
                match_id_hash,
                child,
            } => {
                let level = tournament.level;
                let parent_address = tournament.address;
                let m = mutable_match(tournament, match_id_hash)?;
                ensure!(
                    m.inner_tournament.is_none(),
                    "match {match_id_hash} sealed twice"
                );
                m.inner_tournament = Some(*child);

                ensure!(
                    !self.tournaments.contains_key(child),
                    "inner tournament {child} created twice"
                );
                self.tournaments.insert(
                    *child,
                    TournamentFold::new(*child, Some((parent_address, *match_id_hash)), level + 1),
                );
                self.order.push(*child);
            }
        }

        Ok(())
    }
}

fn mutable_match<'a>(
    tournament: &'a mut TournamentFold,
    id_hash: &Digest,
) -> Result<&'a mut MatchFold> {
    let index = *tournament
        .match_index
        .get(id_hash)
        .ok_or_else(|| anyhow!("event for unknown match {id_hash}"))?;
    Ok(&mut tournament.matches[index])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest(byte: u8) -> Digest {
        Digest::from_digest(&[byte; 32]).unwrap()
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn event(tournament: Address, block: u64, kind: EventKind) -> TournamentEvent {
        TournamentEvent {
            tournament,
            block,
            kind,
        }
    }

    fn join(root: u8) -> EventKind {
        EventKind::CommitmentJoined {
            root: digest(root),
            final_state: digest(root + 100),
        }
    }

    /// A two-commitment dispute descending into an inner tournament
    /// and resolving: the whole structural vocabulary in one script.
    #[test]
    fn fold_derives_the_dispute_tree() {
        let root = address(1);
        let inner = address(2);
        let mut fold = Fold::new(root);

        let id = MatchID {
            commitment_one: digest(10),
            commitment_two: digest(20),
        };
        let id_hash = id.hash();

        let script = [
            event(root, 5, join(10)),
            event(root, 6, join(20)),
            event(
                root,
                7,
                EventKind::MatchCreated {
                    one: digest(10),
                    two: digest(20),
                    left_of_two: digest(21),
                },
            ),
            event(
                root,
                8,
                EventKind::MatchAdvanced {
                    match_id_hash: id_hash,
                    other_parent: digest(21),
                    left_node: digest(11),
                },
            ),
            event(
                root,
                9,
                EventKind::NewInnerTournament {
                    match_id_hash: id_hash,
                    child: inner,
                },
            ),
            event(inner, 10, join(30)),
            event(inner, 11, join(40)),
            event(
                inner,
                12,
                EventKind::MatchCreated {
                    one: digest(30),
                    two: digest(40),
                    left_of_two: digest(41),
                },
            ),
        ];
        for e in &script {
            fold.apply(e).unwrap();
        }

        assert_eq!(fold.addresses(), vec![root, inner]);

        let t = fold.tournament(&root).unwrap();
        assert_eq!(t.level, 0);
        assert!(t.parent.is_none());
        assert_eq!(t.commitments.len(), 2);
        assert_eq!(
            t.commitments[&digest(10)].final_state,
            digest(110),
            "final state rides the join event"
        );
        let m = t.match_by_id_hash(&id_hash).unwrap();
        assert_eq!(m.advances, 1);
        assert_eq!(m.inner_tournament, Some(inner));
        assert!(m.is_live());

        let t = fold.tournament(&inner).unwrap();
        assert_eq!(t.level, 1);
        assert_eq!(t.parent, Some((root, id_hash)));
        assert_eq!(t.matches.len(), 1);
        assert_eq!(t.commitments[&digest(30)].latest_match, Some(0));

        // The inner resolves; the parent match is closed by the child.
        let inner_id = MatchID {
            commitment_one: digest(30),
            commitment_two: digest(40),
        };
        let mut fold2 = fold.clone();
        fold2
            .apply(&event(
                inner,
                20,
                EventKind::MatchDeleted {
                    match_id_hash: inner_id.hash(),
                    reason: MatchDeletionReason::Step,
                    winner: WinnerCommitment::One,
                },
            ))
            .unwrap();
        fold2
            .apply(&event(
                root,
                21,
                EventKind::MatchDeleted {
                    match_id_hash: id_hash,
                    reason: MatchDeletionReason::ChildTournament,
                    winner: WinnerCommitment::One,
                },
            ))
            .unwrap();
        let m = fold2.tournament(&root).unwrap().matches[0].clone();
        assert_eq!(
            m.deleted,
            Some((MatchDeletionReason::ChildTournament, WinnerCommitment::One))
        );
        assert_eq!(fold2.tournament(&root).unwrap().live_matches().count(), 0);
    }

    /// The fold refuses malformed streams instead of folding garbage.
    #[test]
    fn fold_refuses_malformed_streams() {
        let root = address(1);
        let mut fold = Fold::new(root);

        // unknown tournament
        assert!(fold.apply(&event(address(9), 1, join(10))).is_err());

        // advance before creation
        assert!(
            fold.apply(&event(
                root,
                1,
                EventKind::MatchAdvanced {
                    match_id_hash: digest(1),
                    other_parent: digest(2),
                    left_node: digest(3),
                },
            ))
            .is_err()
        );

        // match between unjoined commitments
        assert!(
            fold.apply(&event(
                root,
                1,
                EventKind::MatchCreated {
                    one: digest(10),
                    two: digest(20),
                    left_of_two: digest(21),
                },
            ))
            .is_err()
        );

        // double join
        fold.apply(&event(root, 1, join(10))).unwrap();
        assert!(fold.apply(&event(root, 2, join(10))).is_err());
    }
}
