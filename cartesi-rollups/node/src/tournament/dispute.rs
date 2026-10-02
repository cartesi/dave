// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The event-derived dispute tree.
//!
//! Each tournament applies its own events one at a time, in log order. The
//! fold does not re-prove what the contracts guarantee: it rejects only an
//! event it cannot apply without guessing (an unknown match or commitment, a
//! second join, a transition from the wrong match status). A commitment's
//! standing is derived from its latest match, so the intermediate states
//! inside one contract call (a winner re-paired before its old match is
//! deleted) need no special handling.

use std::collections::HashMap;

use alloy::primitives::Address;
use thiserror::Error;

use crate::merkle::Digest;

use super::{
    MatchID,
    domain::{MatchSide, TournamentDescriptor},
};

/// Why a match was resolved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchDeletionReason {
    Step,
    Timeout,
    ChildTournament,
}

/// Which commitment survived a resolved match.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinnerCommitment {
    Neither,
    One,
    Two,
}

impl WinnerCommitment {
    fn preserves(self, id: MatchID, commitment: Digest) -> bool {
        match self {
            Self::Neither => false,
            Self::One => id.commitment_one == commitment,
            Self::Two => id.commitment_two == commitment,
        }
    }
}

/// One semantic event routed to the tournament that emitted it, for test
/// fixtures that build a whole tree at once.
#[cfg(test)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub tournament: Address,
    pub kind: EventKind,
}

/// The event vocabulary needed to derive tournament structure and deadlines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventKind {
    CommitmentJoined {
        root: Digest,
    },
    MatchCreated {
        id: MatchID,
        /// The first block at which this match can be eliminated.
        eliminable_at: u64,
    },
    MatchAdvanced {
        match_id_hash: Digest,
        /// The replacement inclusive elimination boundary.
        eliminable_at: u64,
    },
    LeafMatchSealed {
        match_id_hash: Digest,
        /// The replacement inclusive elimination boundary.
        eliminable_at: u64,
    },
    NewInnerTournament {
        match_id_hash: Digest,
        /// Loaded once, at discovery, from the child named by the raw event.
        child: TournamentDescriptor,
    },
    MatchDeleted {
        match_id_hash: Digest,
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
    },
}

/// A commitment that joined one tournament.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commitment {
    root: Digest,
    latest_match: Option<Digest>,
}

impl Commitment {
    pub const fn root(&self) -> Digest {
        self.root
    }
}

/// The event-derived lifecycle of one match.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MatchStatus {
    Clocked {
        /// The first block at which this match can be eliminated.
        eliminable_at: u64,
    },
    Leaf {
        /// The first block at which the sealed leaf race can be eliminated.
        eliminable_at: u64,
    },
    Inner {
        child: Box<Tournament>,
    },
    /// A resolution drops any child: nothing reads a resolved subtree, and
    /// bond recovery walks the tournaments through its own logs.
    Resolved {
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
    },
}

/// One match and its current event-derived status.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    id: MatchID,
    status: MatchStatus,
}

impl Match {
    pub const fn id(&self) -> MatchID {
        self.id
    }

    pub fn id_hash(&self) -> Digest {
        self.id.hash()
    }

    pub const fn status(&self) -> &MatchStatus {
        &self.status
    }

    pub const fn is_live(&self) -> bool {
        !matches!(&self.status, MatchStatus::Resolved { .. })
    }

    #[cfg(test)]
    fn child(&self) -> Option<&Tournament> {
        match &self.status {
            MatchStatus::Inner { child } => Some(child),
            MatchStatus::Clocked { .. }
            | MatchStatus::Leaf { .. }
            | MatchStatus::Resolved { .. } => None,
        }
    }

    fn child_mut(&mut self) -> Option<&mut Box<Tournament>> {
        match &mut self.status {
            MatchStatus::Inner { child } => Some(child),
            MatchStatus::Clocked { .. }
            | MatchStatus::Leaf { .. }
            | MatchStatus::Resolved { .. } => None,
        }
    }
}

/// One commitment's current location within a particular tournament.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitmentPosition<'a> {
    NotJoined,
    Candidate {
        commitment: &'a Commitment,
    },
    Engaged {
        commitment: &'a Commitment,
        match_: &'a Match,
        side: MatchSide,
    },
    Eliminated {
        commitment: &'a Commitment,
        match_: &'a Match,
        reason: MatchDeletionReason,
    },
}

/// One tournament and the child tournaments of its live matches.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tournament {
    descriptor: TournamentDescriptor,
    commitments: HashMap<Digest, Commitment>,
    matches: Vec<Match>,
}

impl Tournament {
    /// Constructs the valid empty state for an already observed descriptor.
    pub fn new(descriptor: TournamentDescriptor) -> Self {
        Self {
            descriptor,
            commitments: HashMap::new(),
            matches: Vec::new(),
        }
    }

    pub const fn descriptor(&self) -> TournamentDescriptor {
        self.descriptor
    }

    pub const fn address(&self) -> Address {
        self.descriptor.address()
    }

    pub fn commitment(&self, root: &Digest) -> Option<&Commitment> {
        self.commitments.get(root)
    }

    pub fn matches(&self) -> impl Iterator<Item = &Match> {
        self.matches.iter()
    }

    pub fn match_by_id_hash(&self, id_hash: &Digest) -> Option<&Match> {
        self.matches
            .iter()
            .find(|match_| match_.id_hash() == *id_hash)
    }

    /// Finds this tournament's latest match for one commitment.
    pub fn match_for(&self, commitment: &Digest) -> Option<&Match> {
        let id_hash = self.commitments.get(commitment)?.latest_match?;
        self.match_by_id_hash(&id_hash)
    }

    /// Classifies one commitment from its latest match.
    ///
    /// A commitment with no match, or one that won its latest match and has
    /// not been paired since, is the candidate. Every win path pairs the
    /// winner before deleting its match, so a re-paired winner already reads
    /// as engaged when the old match resolves.
    pub fn position(&self, root: &Digest) -> CommitmentPosition<'_> {
        let Some(commitment) = self.commitments.get(root) else {
            return CommitmentPosition::NotJoined;
        };
        let Some(match_) = self.match_for(root) else {
            return CommitmentPosition::Candidate { commitment };
        };
        match &match_.status {
            MatchStatus::Clocked { .. } | MatchStatus::Leaf { .. } | MatchStatus::Inner { .. } => {
                CommitmentPosition::Engaged {
                    commitment,
                    match_,
                    side: if match_.id.commitment_one == *root {
                        MatchSide::One
                    } else {
                        MatchSide::Two
                    },
                }
            }
            MatchStatus::Resolved { winner, .. } if winner.preserves(match_.id, *root) => {
                CommitmentPosition::Candidate { commitment }
            }
            MatchStatus::Resolved { reason, .. } => CommitmentPosition::Eliminated {
                commitment,
                match_,
                reason: *reason,
            },
        }
    }

    /// Applies one event emitted by this tournament.
    pub(crate) fn apply(&mut self, event: EventKind) -> Result<(), DisputeError> {
        match event {
            EventKind::CommitmentJoined { root } => {
                // A second join would reset the latest match and silently
                // turn an engaged commitment into the candidate.
                if self.commitments.contains_key(&root) {
                    return Err(DisputeError::DuplicateCommitment {
                        tournament: self.address(),
                        commitment: root,
                    });
                }
                self.commitments.insert(
                    root,
                    Commitment {
                        root,
                        latest_match: None,
                    },
                );
            }

            EventKind::MatchCreated { id, eliminable_at } => {
                for commitment in [id.commitment_one, id.commitment_two] {
                    if !self.commitments.contains_key(&commitment) {
                        return Err(DisputeError::UnknownCommitment {
                            tournament: self.address(),
                            commitment,
                        });
                    }
                }
                let id_hash = id.hash();
                self.matches.push(Match {
                    id,
                    status: MatchStatus::Clocked { eliminable_at },
                });
                for commitment in [id.commitment_one, id.commitment_two] {
                    self.commitments
                        .get_mut(&commitment)
                        .expect("both commitments were checked")
                        .latest_match = Some(id_hash);
                }
            }

            EventKind::MatchAdvanced {
                match_id_hash,
                eliminable_at,
            } => {
                self.clocked_match(match_id_hash)?.status = MatchStatus::Clocked { eliminable_at };
            }

            EventKind::LeafMatchSealed {
                match_id_hash,
                eliminable_at,
            } => {
                self.clocked_match(match_id_hash)?.status = MatchStatus::Leaf { eliminable_at };
            }

            // Only a clocked match may delegate: replacing a live child
            // would silently discard its state.
            EventKind::NewInnerTournament {
                match_id_hash,
                child,
            } => {
                self.clocked_match(match_id_hash)?.status = MatchStatus::Inner {
                    child: Box::new(Self::new(child)),
                };
            }

            // Any reason may delete any live match: the contract owns which
            // deletions are legal, and a stricter fold could only stall on
            // one it did not foresee.
            EventKind::MatchDeleted {
                match_id_hash,
                reason,
                winner,
            } => {
                let tournament = self.address();
                let match_ = self.match_by_id_hash_mut(&match_id_hash)?;
                if !match_.is_live() {
                    return Err(DisputeError::MatchAlreadyResolved {
                        tournament,
                        match_id_hash,
                    });
                }
                match_.status = MatchStatus::Resolved { reason, winner };
            }
        }

        Ok(())
    }

    fn clocked_match(&mut self, match_id_hash: Digest) -> Result<&mut Match, DisputeError> {
        let tournament = self.address();
        let match_ = self.match_by_id_hash_mut(&match_id_hash)?;
        if matches!(&match_.status, MatchStatus::Clocked { .. }) {
            Ok(match_)
        } else {
            Err(DisputeError::MatchNotClocked {
                tournament,
                match_id_hash,
            })
        }
    }

    fn match_by_id_hash_mut(&mut self, id_hash: &Digest) -> Result<&mut Match, DisputeError> {
        let tournament = self.address();
        self.matches
            .iter_mut()
            .find(|match_| match_.id_hash() == *id_hash)
            .ok_or(DisputeError::UnknownMatch {
                tournament,
                match_id_hash: *id_hash,
            })
    }

    #[cfg(test)]
    fn tournament(&self, address: &Address) -> Option<&Tournament> {
        if self.address() == *address {
            return Some(self);
        }
        self.matches
            .iter()
            .filter_map(Match::child)
            .find_map(|child| child.tournament(address))
    }

    #[cfg(test)]
    fn tournament_mut(&mut self, address: &Address) -> Option<&mut Tournament> {
        if self.address() == *address {
            return Some(self);
        }
        for match_ in &mut self.matches {
            if let Some(child) = match_.child_mut()
                && let Some(tournament) = child.tournament_mut(address)
            {
                return Some(tournament);
            }
        }
        None
    }

    /// Replaces each direct child with an empty shell of the same identity.
    ///
    /// This is crate-visible so the fused loader can move each child through
    /// recursive extension, then restore it before publishing the tree.
    pub(crate) fn take_children(&mut self) -> Vec<(Digest, Box<Tournament>)> {
        let mut children = Vec::new();
        for match_ in &mut self.matches {
            let id_hash = match_.id_hash();
            let Some(child) = match_.child_mut() else {
                continue;
            };
            let placeholder = Box::new(Self::new(child.descriptor));
            children.push((id_hash, std::mem::replace(child, placeholder)));
        }
        children
    }

    /// Restores one child taken by [`Self::take_children`] and returns the
    /// displaced shell. Only the child's own stream folds in between, so its
    /// parent match is still live.
    pub(crate) fn restore_child(
        &mut self,
        match_id_hash: Digest,
        mut child: Box<Tournament>,
    ) -> Box<Tournament> {
        let slot = self
            .matches
            .iter_mut()
            .find(|match_| match_.id_hash() == match_id_hash)
            .and_then(Match::child_mut)
            .expect("a taken child returns to its live parent match");
        debug_assert_eq!(slot.descriptor, child.descriptor);
        std::mem::swap(slot, &mut child);
        child
    }
}

/// The recursively owned state of one dispute.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dispute {
    root: Tournament,
}

impl Dispute {
    pub fn try_new(root: TournamentDescriptor) -> Result<Self, DisputeError> {
        if !root.is_root() {
            return Err(DisputeError::RootTournamentHasLevel(root.level()));
        }
        Ok(Self {
            root: Tournament::new(root),
        })
    }

    pub const fn root(&self) -> &Tournament {
        &self.root
    }

    pub(crate) fn into_root(self) -> Tournament {
        self.root
    }

    pub(crate) const fn from_root(root: Tournament) -> Self {
        Self { root }
    }

    /// Finds this tournament or one behind a live match.
    #[cfg(test)]
    pub fn tournament(&self, address: &Address) -> Option<&Tournament> {
        self.root.tournament(address)
    }

    /// Applies events in order, routing each to the tournament that emitted it.
    #[cfg(test)]
    pub fn apply_block(
        mut self,
        events: impl IntoIterator<Item = Event>,
    ) -> Result<Self, DisputeError> {
        for event in events {
            self.root
                .tournament_mut(&event.tournament)
                .expect("test events name a tournament in the tree")
                .apply(event.kind)?;
        }
        Ok(self)
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DisputeError {
    #[error("root tournament has nonzero level {0}")]
    RootTournamentHasLevel(u64),
    #[error("commitment {commitment} joined tournament {tournament} twice")]
    DuplicateCommitment {
        tournament: Address,
        commitment: Digest,
    },
    #[error("match in tournament {tournament} refers to unknown commitment {commitment}")]
    UnknownCommitment {
        tournament: Address,
        commitment: Digest,
    },
    #[error("event for unknown match {match_id_hash} in tournament {tournament}")]
    UnknownMatch {
        tournament: Address,
        match_id_hash: Digest,
    },
    #[error("match {match_id_hash} in tournament {tournament} is not clocked")]
    MatchNotClocked {
        tournament: Address,
        match_id_hash: Digest,
    },
    #[error("match {match_id_hash} in tournament {tournament} was already resolved")]
    MatchAlreadyResolved {
        tournament: Address,
        match_id_hash: Digest,
    },
}

#[cfg(test)]
mod tests {
    use alloy::primitives::U256;

    use super::*;
    use crate::tournament::domain::TournamentKind;

    fn digest(byte: u8) -> Digest {
        Digest::from([byte; 32])
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn descriptor(byte: u8, level: u64, kind: TournamentKind) -> TournamentDescriptor {
        TournamentDescriptor::try_new(address(byte), level, kind, digest(250), U256::ZERO, 0, 1)
            .unwrap()
    }

    fn event(tournament: Address, kind: EventKind) -> Event {
        Event { tournament, kind }
    }

    fn join(tournament: Address, root: Digest) -> Event {
        event(tournament, EventKind::CommitmentJoined { root })
    }

    fn create(tournament: Address, id: MatchID, eliminable_at: u64) -> Event {
        event(tournament, EventKind::MatchCreated { id, eliminable_at })
    }

    fn paired_dispute(
        descriptor: TournamentDescriptor,
        one: Digest,
        two: Digest,
        eliminable_at: u64,
    ) -> (Dispute, MatchID) {
        let tournament = descriptor.address();
        let id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let dispute = Dispute::try_new(descriptor)
            .unwrap()
            .apply_block([join(tournament, one)])
            .unwrap()
            .apply_block([join(tournament, two), create(tournament, id, eliminable_at)])
            .unwrap();
        (dispute, id)
    }

    #[test]
    fn recursive_tournament_and_commitment_lookup() {
        let root_descriptor = descriptor(1, 0, TournamentKind::NonLeaf);
        let child_descriptor = descriptor(2, 1, TournamentKind::Leaf);
        let root_address = root_descriptor.address();
        let child_address = child_descriptor.address();
        let (dispute, root_match) = paired_dispute(root_descriptor, digest(10), digest(20), 10);

        let dispute = dispute
            .apply_block([event(
                root_address,
                EventKind::NewInnerTournament {
                    match_id_hash: root_match.hash(),
                    child: child_descriptor,
                },
            )])
            .unwrap()
            .apply_block([join(child_address, digest(30))])
            .unwrap();
        let child_match = MatchID {
            commitment_one: digest(30),
            commitment_two: digest(40),
        };
        let dispute = dispute
            .apply_block([
                join(child_address, digest(40)),
                create(child_address, child_match, 20),
            ])
            .unwrap();

        let child = dispute.tournament(&child_address).unwrap();
        assert_eq!(child.match_for(&digest(30)).unwrap().id(), child_match);
        assert_eq!(child.match_for(&digest(40)).unwrap().id(), child_match);
        assert_eq!(
            dispute.root().match_for(&digest(10)).unwrap().id(),
            root_match
        );
    }

    fn status(dispute: &Dispute, id: MatchID) -> &MatchStatus {
        dispute
            .root()
            .match_by_id_hash(&id.hash())
            .unwrap()
            .status()
    }

    #[test]
    fn deadlines_are_replaced_and_inner_cancels_local_timing() {
        let leaf_descriptor = descriptor(1, 0, TournamentKind::Leaf);
        let leaf_address = leaf_descriptor.address();
        let (dispute, id) = paired_dispute(leaf_descriptor, digest(10), digest(20), 10);
        assert_eq!(
            status(&dispute, id),
            &MatchStatus::Clocked { eliminable_at: 10 }
        );

        let dispute = dispute
            .apply_block([event(
                leaf_address,
                EventKind::MatchAdvanced {
                    match_id_hash: id.hash(),
                    eliminable_at: 20,
                },
            )])
            .unwrap();
        assert_eq!(
            status(&dispute, id),
            &MatchStatus::Clocked { eliminable_at: 20 }
        );
        let dispute = dispute
            .apply_block([event(
                leaf_address,
                EventKind::LeafMatchSealed {
                    match_id_hash: id.hash(),
                    eliminable_at: 30,
                },
            )])
            .unwrap();
        assert_eq!(
            status(&dispute, id),
            &MatchStatus::Leaf { eliminable_at: 30 }
        );
        assert!(
            dispute
                .clone()
                .apply_block([event(
                    leaf_address,
                    EventKind::LeafMatchSealed {
                        match_id_hash: id.hash(),
                        eliminable_at: 40,
                    },
                )])
                .is_err(),
            "a leaf seal is a transition, not an idempotent deadline update"
        );
        assert!(
            dispute
                .clone()
                .apply_block([event(
                    leaf_address,
                    EventKind::MatchAdvanced {
                        match_id_hash: id.hash(),
                        eliminable_at: 40,
                    },
                )])
                .is_err(),
            "a sealed leaf cannot advance"
        );
        assert!(
            dispute
                .clone()
                .apply_block([event(
                    leaf_address,
                    EventKind::MatchDeleted {
                        match_id_hash: id.hash(),
                        reason: MatchDeletionReason::Timeout,
                        winner: WinnerCommitment::Neither,
                    },
                )])
                .is_ok(),
            "a sealed leaf remains timeout-eliminable"
        );
        assert!(
            dispute
                .clone()
                .apply_block([event(
                    leaf_address,
                    EventKind::MatchDeleted {
                        match_id_hash: id.hash(),
                        reason: MatchDeletionReason::Step,
                        winner: WinnerCommitment::One,
                    },
                )])
                .is_ok(),
            "a sealed leaf can resolve by a step with a winner"
        );

        let parent_descriptor = descriptor(3, 0, TournamentKind::NonLeaf);
        let parent_address = parent_descriptor.address();
        let (dispute, id) = paired_dispute(parent_descriptor, digest(11), digest(21), 10);
        let dispute = dispute
            .apply_block([event(
                parent_address,
                EventKind::NewInnerTournament {
                    match_id_hash: id.hash(),
                    child: descriptor(4, 1, TournamentKind::Leaf),
                },
            )])
            .unwrap();
        assert!(matches!(status(&dispute, id), MatchStatus::Inner { .. }));
    }

    fn delegated_dispute() -> (Dispute, MatchID, Address) {
        let root_descriptor = descriptor(1, 0, TournamentKind::NonLeaf);
        let child_descriptor = descriptor(2, 1, TournamentKind::Leaf);
        let root_address = root_descriptor.address();
        let child_address = child_descriptor.address();
        let (dispute, root_match) = paired_dispute(root_descriptor, digest(10), digest(20), 10);
        let child_match = MatchID {
            commitment_one: digest(30),
            commitment_two: digest(40),
        };
        let dispute = dispute
            .apply_block([event(
                root_address,
                EventKind::NewInnerTournament {
                    match_id_hash: root_match.hash(),
                    child: child_descriptor,
                },
            )])
            .unwrap()
            .apply_block([join(child_address, digest(30))])
            .unwrap()
            .apply_block([
                join(child_address, digest(40)),
                create(child_address, child_match, 5),
            ])
            .unwrap();
        (dispute, root_match, child_address)
    }

    #[test]
    fn children_move_through_extension_and_drop_on_resolution() {
        let (dispute, root_match, child_address) = delegated_dispute();

        let mut root = dispute.root.clone();
        let mut children = root.take_children();
        assert_eq!(children.len(), 1);
        assert!(
            root.tournament(&child_address)
                .unwrap()
                .commitment(&digest(30))
                .is_none()
        );
        let (match_id_hash, child) = children.pop().unwrap();
        let displaced = root.restore_child(match_id_hash, child);
        assert!(displaced.commitment(&digest(30)).is_none());
        assert_eq!(root, dispute.root);

        let dispute = dispute
            .apply_block([event(
                address(1),
                EventKind::MatchDeleted {
                    match_id_hash: root_match.hash(),
                    reason: MatchDeletionReason::ChildTournament,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap();
        assert_eq!(
            status(&dispute, root_match),
            &MatchStatus::Resolved {
                reason: MatchDeletionReason::ChildTournament,
                winner: WinnerCommitment::One,
            }
        );
        assert!(dispute.tournament(&child_address).is_none());
    }

    #[test]
    fn a_delegated_match_deleted_by_timeout_folds() {
        let (dispute, root_match, child_address) = delegated_dispute();
        let dispute = dispute
            .apply_block([event(
                address(1),
                EventKind::MatchDeleted {
                    match_id_hash: root_match.hash(),
                    reason: MatchDeletionReason::Timeout,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap();
        assert!(dispute.tournament(&child_address).is_none());
        assert!(matches!(
            dispute.root().position(&digest(10)),
            CommitmentPosition::Candidate { .. }
        ));
        assert!(matches!(
            dispute.root().position(&digest(20)),
            CommitmentPosition::Eliminated {
                reason: MatchDeletionReason::Timeout,
                ..
            }
        ));
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Standing {
        NotJoined,
        Candidate,
        Engaged(MatchSide),
        Eliminated(MatchDeletionReason),
    }

    fn standing(dispute: &Dispute, root: Digest) -> Standing {
        match dispute.root().position(&root) {
            CommitmentPosition::NotJoined => Standing::NotJoined,
            CommitmentPosition::Candidate { .. } => Standing::Candidate,
            CommitmentPosition::Engaged { side, .. } => Standing::Engaged(side),
            CommitmentPosition::Eliminated { reason, .. } => Standing::Eliminated(reason),
        }
    }

    fn delete(
        tournament: Address,
        id: MatchID,
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
    ) -> Event {
        event(
            tournament,
            EventKind::MatchDeleted {
                match_id_hash: id.hash(),
                reason,
                winner,
            },
        )
    }

    #[test]
    fn positions_derive_from_the_latest_match() {
        use MatchDeletionReason::{Step, Timeout};
        use Standing::{Candidate, Eliminated, Engaged, NotJoined};

        let descriptor = descriptor(1, 0, TournamentKind::Leaf);
        let t = descriptor.address();
        let [c1, c2, c3, c4, c5] = [1, 2, 3, 4, 5].map(digest);
        let pair = |one, two| MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let (m12, m32, m45) = (pair(c1, c2), pair(c3, c2), pair(c4, c5));

        let blocks = [
            (vec![join(t, c1)], vec![(c1, Candidate), (c2, NotJoined)]),
            (
                vec![join(t, c2), create(t, m12, 10)],
                vec![(c1, Engaged(MatchSide::One)), (c2, Engaged(MatchSide::Two))],
            ),
            (vec![join(t, c3)], vec![(c3, Candidate)]),
            // The step winner is re-paired with the dangling commitment
            // before its old match is deleted, in the same block.
            (
                vec![
                    create(t, m32, 20),
                    delete(t, m12, Step, WinnerCommitment::Two),
                ],
                vec![
                    (c1, Eliminated(Step)),
                    (c2, Engaged(MatchSide::Two)),
                    (c3, Engaged(MatchSide::One)),
                ],
            ),
            (
                vec![join(t, c4), join(t, c5), create(t, m45, 30)],
                vec![(c4, Engaged(MatchSide::One)), (c5, Engaged(MatchSide::Two))],
            ),
            (
                vec![delete(t, m45, Timeout, WinnerCommitment::Neither)],
                vec![(c4, Eliminated(Timeout)), (c5, Eliminated(Timeout))],
            ),
            // A timeout winner nobody re-pairs dangles as the candidate.
            (
                vec![delete(t, m32, Timeout, WinnerCommitment::One)],
                vec![(c3, Candidate), (c2, Eliminated(Timeout))],
            ),
        ];

        let mut dispute = Dispute::try_new(descriptor).unwrap();
        for (events, expected) in blocks {
            dispute = dispute.apply_block(events).unwrap();
            for (commitment, expected_standing) in expected {
                assert_eq!(standing(&dispute, commitment), expected_standing);
            }
        }
    }

    #[test]
    fn a_pairing_folds_before_its_old_match_is_deleted() {
        let descriptor = descriptor(1, 0, TournamentKind::Leaf);
        let t = descriptor.address();
        let [one, two, dangling] = [10, 20, 30].map(digest);
        let old_match = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let replacement = MatchID {
            commitment_one: dangling,
            commitment_two: one,
        };
        let dispute = Dispute::try_new(descriptor)
            .unwrap()
            .apply_block([join(t, one)])
            .unwrap()
            .apply_block([join(t, two), create(t, old_match, 10)])
            .unwrap()
            .apply_block([join(t, dangling)])
            .unwrap();

        // The contract pairs and deletes in one call; the fold must not
        // depend on both landing in the same block.
        let dispute = dispute.apply_block([create(t, replacement, 20)]).unwrap();
        assert_eq!(standing(&dispute, one), Standing::Engaged(MatchSide::Two));
        assert_eq!(standing(&dispute, two), Standing::Engaged(MatchSide::Two));
        assert_eq!(
            standing(&dispute, dangling),
            Standing::Engaged(MatchSide::One)
        );

        let dispute = dispute
            .apply_block([delete(
                t,
                old_match,
                MatchDeletionReason::Timeout,
                WinnerCommitment::One,
            )])
            .unwrap();
        assert_eq!(standing(&dispute, one), Standing::Engaged(MatchSide::Two));
        assert_eq!(
            standing(&dispute, two),
            Standing::Eliminated(MatchDeletionReason::Timeout)
        );
        assert_eq!(dispute.root().match_for(&one).unwrap().id(), replacement);
    }
}
