use std::error::Error;

use async_trait::async_trait;
use primitive_types::H160;

use crate::{
    machine::MachineProof,
    merkle::{Digest, MerkleProof},
};

pub type Address = H160;

#[async_trait]
pub trait Arena: Send + Sync {
    async fn create_root_tournament(&self, initial_hash: Digest) -> Result<Address, Box<dyn Error>>;

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
        commitment_hash: Digest,
    ) -> Result<Vec<MatchCreatedEvent>, Box<dyn Error>>;

    async fn commitment(
        &self,
        tournament: Address,
        commitment_hash: Digest,
    ) -> Result<(ClockState, Digest), Box<dyn Error>>;

    async fn match_state(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<Option<MatchState>, Box<dyn Error>>;

    async fn root_tournament_winner(
        &self,
        tournament: Address,
    ) -> Result<Option<(Digest, Digest)>, Box<dyn Error>>;

    async fn tournament_winner(&self, tournament: Address) -> Result<Option<Digest>, Box<dyn Error>>;

    async fn maximum_delay(&self, tournament: Address) -> Result<u64, Box<dyn Error>>;
}

#[derive(Clone, Copy)]

pub struct TournamentCreatedEvent {
    pub parent_match_id_hash: Digest,
    pub new_tournament_address: Address,
}

#[derive(Clone, Copy)]

pub struct MatchCreatedEvent {
    pub id: MatchID,
    pub left_hash: Digest,
}

#[derive(Clone, Copy)]
pub struct MatchID {
    pub commitment_one: Digest,
    pub commitment_two: Digest,
}

impl MatchID {
    pub fn hash(&self) -> Digest {
        self.commitment_one.join(self.commitment_two)
    }
}

#[derive(Clone, Copy)]
pub struct ClockState {
    pub allowance: u64,
    pub start_instant: u64,
}

#[derive(Clone, Copy)]
pub struct MatchState {
    pub other_parent: Digest,
    pub left_node: Digest,
    pub right_node: Digest,
    pub running_leaf_position: u64,
    pub current_height: u64,
    pub level: u64,
}
