// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The event-derived dispute tree.
//!
//! A block is the smallest published fold unit. Some contract calls emit a new
//! match before deleting the match whose winner it re-pairs, so individual log
//! prefixes need not satisfy the domain invariants. [`Dispute::apply_block`]
//! consumes such prefixes privately and returns only a fully validated tree.

use std::collections::{HashMap, HashSet};

use alloy::primitives::Address;
use thiserror::Error;

use crate::merkle::Digest;

use super::{
    MatchID,
    domain::{MatchSide, TournamentDescriptor, TournamentKind},
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
    fn winner(self, id: MatchID) -> Option<Digest> {
        match self {
            Self::Neither => None,
            Self::One => Some(id.commitment_one),
            Self::Two => Some(id.commitment_two),
        }
    }

    fn preserves(self, id: MatchID, commitment: Digest) -> bool {
        self.winner(id) == Some(commitment)
    }
}

/// One semantic event routed to the tournament that emitted it.
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
        final_state: Digest,
        submitter: Address,
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
    final_state: Digest,
    submitter: Address,
    latest_match: Option<Digest>,
}

impl Commitment {
    pub const fn root(&self) -> Digest {
        self.root
    }

    pub const fn final_state(&self) -> Digest {
        self.final_state
    }

    pub const fn submitter(&self) -> Address {
        self.submitter
    }

    pub const fn latest_match_id_hash(&self) -> Option<Digest> {
        self.latest_match
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
    Resolved {
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
        /// A resolved child remains owned for later bond recovery.
        child: Option<Box<Tournament>>,
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

    pub fn contains(&self, commitment: Digest) -> bool {
        self.id.commitment_one == commitment || self.id.commitment_two == commitment
    }

    pub const fn is_live(&self) -> bool {
        !matches!(&self.status, MatchStatus::Resolved { .. })
    }

    fn active_child(&self) -> Option<&Tournament> {
        match &self.status {
            MatchStatus::Inner { child } => Some(child),
            MatchStatus::Clocked { .. }
            | MatchStatus::Leaf { .. }
            | MatchStatus::Resolved { .. } => None,
        }
    }

    fn historical_child(&self) -> Option<&Tournament> {
        match &self.status {
            MatchStatus::Inner { child } => Some(child),
            MatchStatus::Resolved {
                child: Some(child), ..
            } => Some(child),
            MatchStatus::Clocked { .. }
            | MatchStatus::Leaf { .. }
            | MatchStatus::Resolved { child: None, .. } => None,
        }
    }

    fn historical_child_mut(&mut self) -> Option<&mut Box<Tournament>> {
        match &mut self.status {
            MatchStatus::Inner { child } => Some(child),
            MatchStatus::Resolved {
                child: Some(child), ..
            } => Some(child),
            MatchStatus::Clocked { .. }
            | MatchStatus::Leaf { .. }
            | MatchStatus::Resolved { child: None, .. } => None,
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

/// The information needed to eliminate one match without another state read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EliminableMatch {
    pub tournament: Address,
    pub id: MatchID,
    pub eliminable_at: u64,
}

/// One tournament and every child tournament it has ever created.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tournament {
    descriptor: TournamentDescriptor,
    candidate: Option<Digest>,
    commitments: HashMap<Digest, Commitment>,
    matches: Vec<Match>,
}

impl Tournament {
    /// Constructs the valid empty state for an already observed descriptor.
    pub fn new(descriptor: TournamentDescriptor) -> Self {
        Self {
            descriptor,
            candidate: None,
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

    pub const fn candidate(&self) -> Option<Digest> {
        self.candidate
    }

    pub fn commitment(&self, root: &Digest) -> Option<&Commitment> {
        self.commitments.get(root)
    }

    pub fn commitments(&self) -> impl Iterator<Item = &Commitment> {
        self.commitments.values()
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

    /// Classifies one commitment without requiring another state read.
    pub fn position(&self, root: &Digest) -> CommitmentPosition<'_> {
        let Some(commitment) = self.commitments.get(root) else {
            return CommitmentPosition::NotJoined;
        };
        if self.candidate == Some(*root) {
            return CommitmentPosition::Candidate { commitment };
        }

        let match_ = self
            .match_for(root)
            .expect("a validated non-candidate commitment has a match");
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
            MatchStatus::Resolved { reason, winner, .. } => {
                debug_assert!(!winner.preserves(match_.id, *root));
                CommitmentPosition::Eliminated {
                    commitment,
                    match_,
                    reason: *reason,
                }
            }
        }
    }

    /// Folds one complete block without exposing its log prefixes.
    ///
    /// Only the emitting tournament is validated here. A recursive reader may
    /// load a parent's stream before the child stream that makes the completed
    /// tree valid. [`Dispute::apply_block`] and the reader validate the whole
    /// tree before publishing it.
    pub(crate) fn apply_block(
        mut self,
        events: impl IntoIterator<Item = Event>,
    ) -> Result<Self, DisputeError> {
        for event in events {
            self.apply_event(event)?;
        }
        self.validate_local_contents()?;
        Ok(self)
    }

    /// Checks local invariants, child geometry, and recursive address identity.
    pub fn validate(&self) -> Result<(), DisputeError> {
        self.validate_unique_addresses()?;
        self.validate_contents()
    }

    /// Ensures that every owned tournament address occurs exactly once.
    pub fn validate_unique_addresses(&self) -> Result<(), DisputeError> {
        let mut addresses = HashSet::new();
        self.collect_unique_addresses(&mut addresses)
    }

    /// Returns this tournament and every child behind a live parent match.
    pub fn reachable_tournaments(&self) -> Vec<&Tournament> {
        let mut tournaments = Vec::new();
        self.collect_reachable(&mut tournaments);
        tournaments
    }

    /// Returns this tournament and all children retained in its history.
    pub fn historical_tournaments(&self) -> Vec<&Tournament> {
        let mut tournaments = Vec::new();
        self.collect_historical(&mut tournaments);
        tournaments
    }

    fn apply_event(&mut self, event: Event) -> Result<(), DisputeError> {
        if let EventKind::NewInnerTournament { child, .. } = &event.kind {
            let child_address = child.address();
            if self.tournament(&child_address).is_some() {
                return Err(DisputeError::DuplicateTournament(child_address));
            }
        }

        let tournament = self
            .tournament_mut(&event.tournament)
            .ok_or(DisputeError::UnknownTournament(event.tournament))?;
        tournament.apply_local(event.kind)
    }

    fn apply_local(&mut self, event: EventKind) -> Result<(), DisputeError> {
        match event {
            EventKind::CommitmentJoined {
                root,
                final_state,
                submitter,
            } => {
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
                        final_state,
                        submitter,
                        latest_match: None,
                    },
                );
                if self.candidate.is_none() {
                    self.candidate = Some(root);
                }
            }

            EventKind::MatchCreated { id, eliminable_at } => {
                let id_hash = id.hash();
                if id.commitment_one == id.commitment_two {
                    return Err(self.invariant("a match cannot contain one commitment twice"));
                }
                if self.match_by_id_hash(&id_hash).is_some() {
                    return Err(DisputeError::DuplicateMatch {
                        tournament: self.address(),
                        match_id_hash: id_hash,
                    });
                }
                for commitment in [id.commitment_one, id.commitment_two] {
                    if !self.commitments.contains_key(&commitment) {
                        return Err(DisputeError::UnknownCommitment {
                            tournament: self.address(),
                            commitment,
                        });
                    }
                    if self.commitment_is_eliminated(commitment) {
                        return Err(self.invariant("an eliminated commitment was paired again"));
                    }
                }
                if self.candidate != Some(id.commitment_one) {
                    return Err(DisputeError::PairingCandidateMismatch {
                        tournament: self.address(),
                        expected: self.candidate,
                        actual: id.commitment_one,
                    });
                }

                self.candidate = None;
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
                self.replace_match_deadline(match_id_hash, eliminable_at)?;
            }

            EventKind::LeafMatchSealed {
                match_id_hash,
                eliminable_at,
            } => {
                if self.descriptor.kind() != TournamentKind::Leaf {
                    return Err(self.invariant("only a leaf tournament can seal a leaf match"));
                }
                let tournament = self.address();
                let match_ = self.match_by_id_hash_mut(&match_id_hash)?;
                if !matches!(&match_.status, MatchStatus::Clocked { .. }) {
                    return Err(DisputeError::MatchNotClocked {
                        tournament,
                        match_id_hash,
                    });
                }
                match_.status = MatchStatus::Leaf { eliminable_at };
            }

            EventKind::NewInnerTournament {
                match_id_hash,
                child,
            } => {
                if self.descriptor.kind() != TournamentKind::NonLeaf {
                    return Err(self.invariant("a leaf tournament cannot own an inner tournament"));
                }
                let expected_level = self.descriptor.level().checked_add(1).ok_or_else(|| {
                    self.invariant("the parent tournament level cannot be incremented")
                })?;
                if child.level() != expected_level {
                    return Err(DisputeError::InvalidChildLevel {
                        parent: self.address(),
                        child: child.address(),
                        expected: expected_level,
                        actual: child.level(),
                    });
                }

                let tournament = self.address();
                let match_ = self.match_by_id_hash_mut(&match_id_hash)?;
                if !matches!(&match_.status, MatchStatus::Clocked { .. }) {
                    return Err(DisputeError::MatchNotClocked {
                        tournament,
                        match_id_hash,
                    });
                }
                match_.status = MatchStatus::Inner {
                    child: Box::new(Self::new(child)),
                };
            }

            EventKind::MatchDeleted {
                match_id_hash,
                reason,
                winner,
            } => self.resolve_match(match_id_hash, reason, winner)?,
        }

        Ok(())
    }

    fn resolve_match(
        &mut self,
        match_id_hash: Digest,
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
    ) -> Result<(), DisputeError> {
        let index = self
            .matches
            .iter()
            .position(|match_| match_.id_hash() == match_id_hash)
            .ok_or(DisputeError::UnknownMatch {
                tournament: self.address(),
                match_id_hash,
            })?;
        let mut match_ = self.matches.remove(index);

        let child = match (reason, winner, match_.status) {
            (MatchDeletionReason::ChildTournament, _, MatchStatus::Inner { child }) => Some(child),
            (
                MatchDeletionReason::Step,
                WinnerCommitment::One | WinnerCommitment::Two,
                MatchStatus::Leaf { .. },
            )
            | (
                MatchDeletionReason::Timeout,
                _,
                MatchStatus::Clocked { .. } | MatchStatus::Leaf { .. },
            ) => None,
            (_, _, MatchStatus::Resolved { .. }) => {
                return Err(DisputeError::MatchAlreadyResolved {
                    tournament: self.address(),
                    match_id_hash,
                });
            }
            _ => {
                return Err(DisputeError::DeletionReasonMismatch {
                    tournament: self.address(),
                    match_id_hash,
                    reason,
                });
            }
        };

        if let Some(winner_root) = winner.winner(match_.id) {
            let latest_match = self
                .commitments
                .get(&winner_root)
                .expect("a match contains only joined commitments")
                .latest_match;
            if latest_match == Some(match_id_hash) {
                if self.candidate.is_some() {
                    return Err(
                        self.invariant("a winner was not paired with the existing candidate")
                    );
                }
                self.candidate = Some(winner_root);
            }
        }

        match_.status = MatchStatus::Resolved {
            reason,
            winner,
            child,
        };
        self.matches.insert(index, match_);
        Ok(())
    }

    fn replace_match_deadline(
        &mut self,
        match_id_hash: Digest,
        eliminable_at: u64,
    ) -> Result<(), DisputeError> {
        let tournament = self.address();
        let match_ = self.match_by_id_hash_mut(&match_id_hash)?;
        match &mut match_.status {
            MatchStatus::Clocked {
                eliminable_at: current,
            } => {
                *current = eliminable_at;
                Ok(())
            }
            MatchStatus::Leaf { .. } | MatchStatus::Inner { .. } | MatchStatus::Resolved { .. } => {
                Err(DisputeError::MatchNotClocked {
                    tournament,
                    match_id_hash,
                })
            }
        }
    }

    fn commitment_is_eliminated(&self, root: Digest) -> bool {
        let Some(match_) = self.match_for(&root) else {
            return false;
        };
        match &match_.status {
            MatchStatus::Resolved { winner, .. } => !winner.preserves(match_.id, root),
            MatchStatus::Clocked { .. } | MatchStatus::Leaf { .. } | MatchStatus::Inner { .. } => {
                false
            }
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

    fn tournament(&self, address: &Address) -> Option<&Tournament> {
        if self.address() == *address {
            return Some(self);
        }
        self.matches
            .iter()
            .filter_map(Match::historical_child)
            .find_map(|child| child.tournament(address))
    }

    fn tournament_mut(&mut self, address: &Address) -> Option<&mut Tournament> {
        if self.address() == *address {
            return Some(self);
        }
        for match_ in &mut self.matches {
            if let Some(child) = match_.historical_child_mut()
                && let Some(tournament) = child.tournament_mut(address)
            {
                return Some(tournament);
            }
        }
        None
    }

    fn collect_eliminable_matches(&self, at: u64, matches: &mut Vec<EliminableMatch>) {
        for match_ in &self.matches {
            match &match_.status {
                MatchStatus::Clocked { eliminable_at } if at >= *eliminable_at => {
                    matches.push(EliminableMatch {
                        tournament: self.address(),
                        id: match_.id,
                        eliminable_at: *eliminable_at,
                    });
                }
                MatchStatus::Leaf { eliminable_at } if at >= *eliminable_at => {
                    matches.push(EliminableMatch {
                        tournament: self.address(),
                        id: match_.id,
                        eliminable_at: *eliminable_at,
                    });
                }
                MatchStatus::Inner { child } => child.collect_eliminable_matches(at, matches),
                MatchStatus::Clocked { .. }
                | MatchStatus::Leaf { .. }
                | MatchStatus::Resolved { .. } => {}
            }
        }
    }

    fn collect_reachable<'a>(&'a self, tournaments: &mut Vec<&'a Tournament>) {
        tournaments.push(self);
        for child in self.matches.iter().filter_map(Match::active_child) {
            child.collect_reachable(tournaments);
        }
    }

    fn collect_historical<'a>(&'a self, tournaments: &mut Vec<&'a Tournament>) {
        tournaments.push(self);
        for child in self.matches.iter().filter_map(Match::historical_child) {
            child.collect_historical(tournaments);
        }
    }

    fn collect_unique_addresses(
        &self,
        addresses: &mut HashSet<Address>,
    ) -> Result<(), DisputeError> {
        if !addresses.insert(self.address()) {
            return Err(DisputeError::DuplicateTournament(self.address()));
        }
        for child in self.matches.iter().filter_map(Match::historical_child) {
            child.collect_unique_addresses(addresses)?;
        }
        Ok(())
    }

    fn validate_contents(&self) -> Result<(), DisputeError> {
        self.validate_local_contents()?;

        for match_ in &self.matches {
            let Some(child) = match_.historical_child() else {
                continue;
            };
            if matches!(&match_.status, MatchStatus::Resolved { .. })
                && child.matches.iter().any(Match::is_live)
            {
                return Err(
                    self.invariant("a resolved parent match retained a child with live matches")
                );
            }
            if matches!(
                &match_.status,
                MatchStatus::Resolved {
                    winner: WinnerCommitment::One | WinnerCommitment::Two,
                    ..
                }
            ) && child.candidate.is_none()
            {
                return Err(self.invariant("a child-tournament winner requires a child candidate"));
            }
            child.validate_contents()?;
        }
        Ok(())
    }

    fn validate_local_contents(&self) -> Result<(), DisputeError> {
        if let Some(candidate) = self.candidate
            && !self.commitments.contains_key(&candidate)
        {
            return Err(self.invariant("the candidate did not join this tournament"));
        }

        let mut match_ids = HashSet::new();
        let mut live_counts = HashMap::<Digest, usize>::new();
        let mut previous_matches = HashMap::<Digest, &Match>::new();
        for match_ in &self.matches {
            let id_hash = match_.id_hash();
            if !match_ids.insert(id_hash) {
                return Err(DisputeError::DuplicateMatch {
                    tournament: self.address(),
                    match_id_hash: id_hash,
                });
            }
            for commitment in [match_.id.commitment_one, match_.id.commitment_two] {
                if !self.commitments.contains_key(&commitment) {
                    return Err(DisputeError::UnknownCommitment {
                        tournament: self.address(),
                        commitment,
                    });
                }
                if let Some(previous) = previous_matches.insert(commitment, match_) {
                    let MatchStatus::Resolved { winner, .. } = &previous.status else {
                        return Err(self.invariant(
                            "a commitment entered another match before resolving its previous one",
                        ));
                    };
                    if !winner.preserves(previous.id, commitment) {
                        return Err(self.invariant(
                            "a commitment entered another match after it was eliminated",
                        ));
                    }
                }
                if match_.is_live() {
                    *live_counts.entry(commitment).or_default() += 1;
                }
            }

            match &match_.status {
                MatchStatus::Leaf { .. } if self.descriptor.kind() != TournamentKind::Leaf => {
                    return Err(
                        self.invariant("a non-leaf tournament contains a sealed leaf match")
                    );
                }
                MatchStatus::Inner { .. } if self.descriptor.kind() != TournamentKind::NonLeaf => {
                    return Err(self.invariant("a leaf tournament contains an inner tournament"));
                }
                MatchStatus::Resolved {
                    reason: MatchDeletionReason::ChildTournament,
                    child: None,
                    ..
                }
                | MatchStatus::Resolved {
                    reason: MatchDeletionReason::Step | MatchDeletionReason::Timeout,
                    child: Some(_),
                    ..
                } => return Err(self.invariant("a resolved match has an invalid child")),
                MatchStatus::Resolved {
                    reason: MatchDeletionReason::Step,
                    winner: WinnerCommitment::Neither,
                    ..
                } => return Err(self.invariant("a step resolution must name a winner")),
                MatchStatus::Clocked { .. }
                | MatchStatus::Leaf { .. }
                | MatchStatus::Inner { .. }
                | MatchStatus::Resolved { .. } => {}
            }

            if let Some(child) = match_.historical_child() {
                let expected_level = self.descriptor.level().checked_add(1).ok_or_else(|| {
                    self.invariant("the parent tournament level cannot be incremented")
                })?;
                if child.descriptor.level() != expected_level {
                    return Err(DisputeError::InvalidChildLevel {
                        parent: self.address(),
                        child: child.address(),
                        expected: expected_level,
                        actual: child.descriptor.level(),
                    });
                }
            }
        }

        for commitment in self.commitments.values() {
            let expected_latest = self
                .matches
                .iter()
                .rev()
                .find(|match_| match_.contains(commitment.root))
                .map(Match::id_hash);
            if commitment.latest_match != expected_latest {
                return Err(self.invariant("a commitment's latest match is inconsistent"));
            }

            let live_count = live_counts
                .get(&commitment.root)
                .copied()
                .unwrap_or_default();
            if live_count > 1 {
                return Err(self.invariant("a commitment is engaged in more than one live match"));
            }

            match self.match_for(&commitment.root) {
                None if self.candidate == Some(commitment.root) => {}
                None => return Err(self.invariant("an unmatched commitment is not the candidate")),
                Some(match_) if match_.is_live() => {
                    if live_count != 1 || self.candidate == Some(commitment.root) {
                        return Err(self.invariant("a live commitment has an invalid standing"));
                    }
                }
                Some(match_) => {
                    let MatchStatus::Resolved { winner, .. } = &match_.status else {
                        unreachable!("the live case was handled above");
                    };
                    let survived = winner.preserves(match_.id, commitment.root);
                    if survived != (self.candidate == Some(commitment.root)) || live_count != 0 {
                        return Err(self.invariant("a resolved commitment has an invalid standing"));
                    }
                }
            }
        }

        Ok(())
    }

    fn invariant(&self, detail: &'static str) -> DisputeError {
        DisputeError::InvariantViolation {
            tournament: self.address(),
            detail,
        }
    }

    /// Replaces each direct child with an empty shell of the same identity.
    ///
    /// This is crate-visible so the fused loader can move each child through
    /// recursive extension, then restore it before publishing the tree.
    pub(crate) fn take_historical_children(&mut self) -> Vec<(Digest, Box<Tournament>)> {
        let mut children = Vec::new();
        for match_ in &mut self.matches {
            let id_hash = match_.id_hash();
            let Some(child) = match_.historical_child_mut() else {
                continue;
            };
            let placeholder = Box::new(Self::new(child.descriptor));
            children.push((id_hash, std::mem::replace(child, placeholder)));
        }
        children
    }

    /// Restores one live or resolved child and returns the displaced shell.
    pub(crate) fn restore_child(
        &mut self,
        match_id_hash: Digest,
        mut child: Box<Tournament>,
    ) -> Result<Box<Tournament>, DisputeError> {
        let tournament = self.address();
        let match_ = self.match_by_id_hash_mut(&match_id_hash)?;
        let slot = match_
            .historical_child_mut()
            .ok_or(DisputeError::MatchHasNoChild {
                tournament,
                match_id_hash,
            })?;
        if slot.descriptor != child.descriptor {
            return Err(DisputeError::ChildDescriptorMismatch {
                tournament,
                match_id_hash,
            });
        }
        std::mem::swap(slot, &mut child);
        Ok(child)
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

    pub(crate) fn from_root(root: Tournament) -> Result<Self, DisputeError> {
        let dispute = Self { root };
        dispute.validate()?;
        Ok(dispute)
    }

    /// Finds a tournament, including children retained only for recovery.
    pub fn tournament(&self, address: &Address) -> Option<&Tournament> {
        self.root.tournament(address)
    }

    /// Folds one complete block without exposing its log prefixes.
    pub fn apply_block(
        self,
        events: impl IntoIterator<Item = Event>,
    ) -> Result<Self, DisputeError> {
        let root = self.root.apply_block(events)?;
        let dispute = Self { root };
        dispute.validate()?;
        Ok(dispute)
    }

    /// Returns matches whose inclusive elimination boundary has elapsed.
    ///
    /// Resolved child subtrees are intentionally excluded: they remain owned
    /// for recovery, but are no longer reachable dispute work.
    pub fn eliminable_matches(&self, at: u64) -> Vec<EliminableMatch> {
        let mut matches = Vec::new();
        self.root.collect_eliminable_matches(at, &mut matches);
        matches
    }

    /// Returns the root and every child behind a currently live parent match.
    pub fn reachable_tournaments(&self) -> Vec<&Tournament> {
        self.root.reachable_tournaments()
    }

    /// Returns every tournament, including children retained for recovery.
    pub fn historical_tournaments(&self) -> Vec<&Tournament> {
        self.root.historical_tournaments()
    }

    pub fn validate(&self) -> Result<(), DisputeError> {
        if !self.root.descriptor.is_root() {
            return Err(DisputeError::RootTournamentHasLevel(
                self.root.descriptor.level(),
            ));
        }
        self.root.validate()
    }

    pub fn validate_unique_addresses(&self) -> Result<(), DisputeError> {
        self.root.validate_unique_addresses()
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DisputeError {
    #[error("root tournament has nonzero level {0}")]
    RootTournamentHasLevel(u64),
    #[error("event for unknown tournament {0}")]
    UnknownTournament(Address),
    #[error("tournament {0} occurs more than once in the dispute tree")]
    DuplicateTournament(Address),
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
    #[error("match {match_id_hash} occurs twice in tournament {tournament}")]
    DuplicateMatch {
        tournament: Address,
        match_id_hash: Digest,
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
    #[error("match {match_id_hash} in tournament {tournament} cannot be deleted for {reason:?}")]
    DeletionReasonMismatch {
        tournament: Address,
        match_id_hash: Digest,
        reason: MatchDeletionReason,
    },
    #[error(
        "match creation in tournament {tournament} expected candidate {expected:?}, got {actual}"
    )]
    PairingCandidateMismatch {
        tournament: Address,
        expected: Option<Digest>,
        actual: Digest,
    },
    #[error("child {child} of tournament {parent} has level {actual}; expected level {expected}")]
    InvalidChildLevel {
        parent: Address,
        child: Address,
        expected: u64,
        actual: u64,
    },
    #[error("match {match_id_hash} in tournament {tournament} has no child")]
    MatchHasNoChild {
        tournament: Address,
        match_id_hash: Digest,
    },
    #[error(
        "replacement child for match {match_id_hash} in tournament {tournament} has another descriptor"
    )]
    ChildDescriptorMismatch {
        tournament: Address,
        match_id_hash: Digest,
    },
    #[error("invalid state in tournament {tournament}: {detail}")]
    InvariantViolation {
        tournament: Address,
        detail: &'static str,
    },
}

#[cfg(test)]
mod tests {
    use alloy::primitives::U256;

    use super::*;

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
        event(
            tournament,
            EventKind::CommitmentJoined {
                root,
                final_state: digest(root.data()[0].wrapping_add(100)),
                submitter: address(root.data()[0]),
            },
        )
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
        assert_eq!(
            dispute
                .reachable_tournaments()
                .into_iter()
                .map(Tournament::address)
                .collect::<Vec<_>>(),
            vec![root_address, child_address]
        );
        dispute.validate_unique_addresses().unwrap();
    }

    #[test]
    fn deadlines_are_replaced_inclusively_and_inner_cancels_local_timing() {
        let leaf_descriptor = descriptor(1, 0, TournamentKind::Leaf);
        let leaf_address = leaf_descriptor.address();
        let (dispute, id) = paired_dispute(leaf_descriptor, digest(10), digest(20), 10);
        assert!(dispute.eliminable_matches(9).is_empty());
        assert_eq!(dispute.eliminable_matches(10)[0].eliminable_at, 10);

        let dispute = dispute
            .apply_block([event(
                leaf_address,
                EventKind::MatchAdvanced {
                    match_id_hash: id.hash(),
                    eliminable_at: 20,
                },
            )])
            .unwrap();
        assert!(dispute.eliminable_matches(10).is_empty());
        assert_eq!(dispute.eliminable_matches(20)[0].eliminable_at, 20);
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
                .is_err(),
            "a bisection match cannot resolve by step before its leaf seal"
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
        assert!(dispute.eliminable_matches(29).is_empty());
        assert_eq!(dispute.eliminable_matches(30)[0].eliminable_at, 30);
        assert!(matches!(
            dispute
                .root()
                .match_by_id_hash(&id.hash())
                .unwrap()
                .status(),
            MatchStatus::Leaf { eliminable_at: 30 }
        ));
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
                        reason: MatchDeletionReason::Step,
                        winner: WinnerCommitment::Neither,
                    },
                )])
                .is_err(),
            "a step must identify its winner"
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
        assert!(dispute.eliminable_matches(u64::MAX).is_empty());
    }

    #[test]
    fn resolved_matches_retain_children_only_for_history_and_recovery() {
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
            .unwrap();
        let child_match = MatchID {
            commitment_one: digest(30),
            commitment_two: digest(40),
        };
        let dispute = dispute
            .apply_block([join(child_address, digest(30))])
            .unwrap()
            .apply_block([
                join(child_address, digest(40)),
                create(child_address, child_match, 5),
            ])
            .unwrap();
        assert!(
            dispute
                .clone()
                .apply_block([event(
                    root_address,
                    EventKind::MatchDeleted {
                        match_id_hash: root_match.hash(),
                        reason: MatchDeletionReason::ChildTournament,
                        winner: WinnerCommitment::One,
                    },
                )])
                .is_err(),
            "a parent cannot resolve while its child still has a live match"
        );
        let dispute = dispute
            .apply_block([event(
                child_address,
                EventKind::MatchDeleted {
                    match_id_hash: child_match.hash(),
                    reason: MatchDeletionReason::Timeout,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap()
            .apply_block([event(
                root_address,
                EventKind::MatchDeleted {
                    match_id_hash: root_match.hash(),
                    reason: MatchDeletionReason::ChildTournament,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap();

        let MatchStatus::Resolved {
            child: Some(child), ..
        } = dispute
            .root()
            .match_by_id_hash(&root_match.hash())
            .unwrap()
            .status()
        else {
            panic!("resolved inner match did not retain its child");
        };
        assert_eq!(child.match_for(&digest(30)).unwrap().id(), child_match);
        assert!(dispute.eliminable_matches(5).is_empty());
        assert_eq!(dispute.reachable_tournaments().len(), 1);
        assert_eq!(dispute.historical_tournaments().len(), 2);

        let mut root = dispute.root.clone();
        let mut children = root.take_historical_children();
        assert_eq!(children.len(), 1);
        assert!(
            root.tournament(&child_address)
                .unwrap()
                .commitments()
                .next()
                .is_none()
        );
        let (match_id_hash, child) = children.pop().unwrap();
        let displaced = root.restore_child(match_id_hash, child).unwrap();
        assert!(displaced.commitments().next().is_none());
        assert!(
            root.tournament(&child_address)
                .unwrap()
                .commitment(&digest(30))
                .is_some()
        );
        root.validate().unwrap();
    }

    #[test]
    fn join_pair_and_resolution_are_atomic_block_batches() {
        let descriptor = descriptor(1, 0, TournamentKind::Leaf);
        let tournament = descriptor.address();
        let one = digest(10);
        let two = digest(20);
        let candidate = digest(30);
        let old_match = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let dispute = Dispute::try_new(descriptor)
            .unwrap()
            .apply_block([join(tournament, one)])
            .unwrap();
        assert!(matches!(
            dispute.root().position(&one),
            CommitmentPosition::Candidate { .. }
        ));
        assert_eq!(
            dispute.root().position(&digest(99)),
            CommitmentPosition::NotJoined
        );

        assert!(
            dispute
                .clone()
                .apply_block([join(tournament, two)])
                .is_err(),
            "the second join is not a publishable state without its pair event"
        );
        let dispute = dispute
            .apply_block([join(tournament, two), create(tournament, old_match, 10)])
            .unwrap()
            .apply_block([join(tournament, candidate)])
            .unwrap();

        let replacement = MatchID {
            commitment_one: candidate,
            commitment_two: one,
        };
        assert!(
            dispute
                .clone()
                .apply_block([create(tournament, replacement, 20)])
                .is_err(),
            "the replacement creation is not publishable before old-match deletion"
        );
        assert!(
            dispute
                .clone()
                .apply_block([
                    create(tournament, replacement, 20),
                    event(
                        tournament,
                        EventKind::MatchDeleted {
                            match_id_hash: old_match.hash(),
                            reason: MatchDeletionReason::Timeout,
                            winner: WinnerCommitment::Two,
                        },
                    ),
                ])
                .is_err(),
            "an eventual loser cannot enter its next match earlier in the block"
        );
        let dispute = dispute
            .apply_block([
                create(tournament, replacement, 20),
                event(
                    tournament,
                    EventKind::MatchDeleted {
                        match_id_hash: old_match.hash(),
                        reason: MatchDeletionReason::Timeout,
                        winner: WinnerCommitment::One,
                    },
                ),
            ])
            .unwrap();

        assert_eq!(dispute.root().candidate(), None);
        assert_eq!(dispute.root().match_for(&one).unwrap().id(), replacement);
        assert_eq!(
            dispute.root().match_for(&candidate).unwrap().id(),
            replacement
        );
        assert!(matches!(
            dispute.root().position(&one),
            CommitmentPosition::Engaged {
                side: MatchSide::Two,
                ..
            }
        ));
        assert!(matches!(
            dispute.root().position(&two),
            CommitmentPosition::Eliminated {
                reason: MatchDeletionReason::Timeout,
                ..
            }
        ));
        assert!(matches!(
            dispute
                .root()
                .match_by_id_hash(&old_match.hash())
                .unwrap()
                .status(),
            MatchStatus::Resolved {
                winner: WinnerCommitment::One,
                ..
            }
        ));
    }
}
