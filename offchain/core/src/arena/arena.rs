//! This module defines the trait [Arena] that is responsible for the creation and
//! management of tournaments. It also defines some structs that are used to communicate events.

use async_trait::async_trait;
use ethers::types::{Address, U256};
use std::{collections::HashMap, error::Error};

use crate::{
    machine::{constants, MachineProof},
    merkle::{Digest, MerkleProof},
};

/// The [Arena] trait defines the interface for the creation and management of tournaments.
#[async_trait]
pub trait Arena: Send + Sync {
    /// Creates a new tournament and returns its address.
    async fn create_root_tournament(&self, initial_hash: Digest)
        -> Result<Address, Box<dyn Error>>;

    async fn join_tournament(
        &self,
        tournament: Address,
        final_state: Digest,
        proof: MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<(), Box<dyn Error>>;

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<(), Box<dyn Error>>;

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>>;

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<(), Box<dyn Error>>;

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>>;

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<(), Box<dyn Error>>;

    async fn created_tournament(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<Option<TournamentCreatedEvent>, Box<dyn Error>>;

    async fn created_matches(
        &self,
        tournament: Address,
    ) -> Result<Vec<MatchCreatedEvent>, Box<dyn Error>>;

    async fn joined_commitments(
        &self,
        tournament: Address,
    ) -> Result<Vec<CommitmentJoinedEvent>, Box<dyn Error>>;

    async fn get_commitment(
        &self,
        tournament: Address,
        commitment_hash: Digest,
    ) -> Result<CommitmentState, Box<dyn Error>>;

    async fn fetch_from_root(
        &self,
        root_tournament: Address,
    ) -> Result<HashMap<Address, TournamentState>, Box<dyn Error>>;

    async fn fetch_tournament(
        &self,
        tournament_state: TournamentState,
        states: HashMap<Address, TournamentState>,
    ) -> Result<HashMap<Address, TournamentState>, Box<dyn Error>>;

    async fn fetch_match(
        &self,
        match_state: MatchState,
        states: HashMap<Address, TournamentState>,
    ) -> Result<(MatchState, HashMap<Address, TournamentState>), Box<dyn Error>>;

    async fn root_tournament_winner(
        &self,
        tournament: Address,
    ) -> Result<Option<TournamentWinner>, Box<dyn Error>>;

    async fn tournament_winner(
        &self,
        tournament: Address,
    ) -> Result<Option<TournamentWinner>, Box<dyn Error>>;

    async fn maximum_delay(&self, tournament: Address) -> Result<u64, Box<dyn Error>>;
}

/// This struct is used to communicate the creation of a new tournament.
#[derive(Clone, Copy)]
pub struct TournamentCreatedEvent {
    pub parent_match_id_hash: Digest,
    pub new_tournament_address: Address,
}

/// This struct is used to communicate the enrollment of a new commitment.
#[derive(Clone, Copy)]
pub struct CommitmentJoinedEvent {
    pub root: Digest,
}

/// This struct is used to communicate the creation of a new match.
#[derive(Clone, Copy)]
pub struct MatchCreatedEvent {
    pub id: MatchID,
    pub left_hash: Digest,
}

/// Struct used to identify a match.
#[derive(Clone, Copy)]
pub struct MatchID {
    pub commitment_one: Digest,
    pub commitment_two: Digest,
}

impl MatchID {
    /// Generates a new [Digest]
    pub fn hash(&self) -> Digest {
        self.commitment_one.join(&self.commitment_two)
    }
}

/// Struct used to communicate the state of a commitment.
#[derive(Clone, Copy)]
pub struct CommitmentState {
    pub clock: ClockState,
    pub final_state: Digest,
    pub latest_match: Option<usize>,
}

/// Struct used to communicate the state of a clock.
#[derive(Clone, Copy)]
pub struct ClockState {
    pub allowance: u64,
    pub start_instant: u64,
    pub block_time: U256,
}

/// Enum used to represent the winner of a tournament.
#[derive(Clone, PartialEq)]
pub enum TournamentWinner {
    Root((Digest, Digest)),
    Inner(Digest),
}

/// Struct used to communicate the state of a tournament.
#[derive(Clone)]
pub struct TournamentState {
    pub address: Address,
    pub base_big_cycle: u64,
    pub level: u64,
    pub parent: Option<Address>,
    pub commitment_states: HashMap<Digest, CommitmentState>,
    pub matches: Vec<MatchState>,
    pub winner: Option<TournamentWinner>,
}

impl TournamentState {
    pub fn new_root(address: Address) -> Self {
        TournamentState {
            address,
            base_big_cycle: 0,
            level: constants::LEVELS,
            parent: None,
            commitment_states: HashMap::new(),
            matches: vec![],
            winner: None,
        }
    }

    pub fn new_inner(address: Address, level: u64, base_big_cycle: u64, parent: Address) -> Self {
        TournamentState {
            address,
            base_big_cycle,
            level,
            parent: Some(parent),
            commitment_states: HashMap::new(),
            matches: vec![],
            winner: None,
        }
    }
}

/// Struct used to communicate the state of a match.
#[derive(Clone, Copy)]
pub struct MatchState {
    pub id: MatchID,
    pub other_parent: Digest,
    pub left_node: Digest,
    pub right_node: Digest,
    pub running_leaf_position: u64,
    pub current_height: u64,
    pub level: u64,
    pub leaf_cycle: u64,
    pub base_big_cycle: u64,
    pub tournament: Address,
    pub inner_tournament: Option<Address>,
}
