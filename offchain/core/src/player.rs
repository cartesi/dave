use std::{collections::HashMap, error::Error};

use ::log::info;
use async_recursion::async_recursion;
use ethers::types::Address;

use crate::{
    arena::{Arena, MatchState, TournamentState, TournamentWinner},
    machine::{constants, CachingMachineCommitmentBuilder, MachineCommitment, MachineFactory},
    merkle::MerkleProof,
};

#[derive(Debug)]
pub enum PlayerTournamentResult {
    TournamentWon,
    TournamentLost,
}

pub struct Player<A: Arena> {
    arena: A,
    machine_factory: MachineFactory,
    machine_path: String,
    commitment_builder: CachingMachineCommitmentBuilder,
    root_tournamet: Address,
}

impl<A: Arena> Player<A> {
    pub fn new(
        arena: A,
        machine_factory: MachineFactory,
        machine_path: String,
        commitment_builder: CachingMachineCommitmentBuilder,
        root_tournamet: Address,
    ) -> Self {
        Player {
            arena,
            machine_factory,
            machine_path,
            commitment_builder,
            root_tournamet,
        }
    }

    pub async fn react(&mut self) -> Result<Option<PlayerTournamentResult>, Box<dyn Error>> {
        let tournament_states = self.arena.fetch_from_root(self.root_tournamet).await?;
        self.react_tournament(HashMap::new(), self.root_tournamet, tournament_states)
            .await
    }

    #[async_recursion]
    async fn react_tournament(
        &mut self,
        commitments: HashMap<Address, MachineCommitment>,
        tournament_address: Address,
        tournament_states: HashMap<Address, TournamentState>,
    ) -> Result<Option<PlayerTournamentResult>, Box<dyn Error>> {
        info!("Enter tournament at address: {}", tournament_address);
        let tournament_state = tournament_states
            .get(&tournament_address)
            .expect("tournament state not found");
        let mut new_commitments = commitments.clone();

        let commitment = new_commitments
            .entry(tournament_state.address)
            .or_insert(
                self.commitment_builder
                    .build_commitment(tournament_state.base_big_cycle, tournament_state.level)
                    .await?,
            )
            .clone();

        if let Some(winner) = tournament_state.winner.clone() {
            match winner {
                TournamentWinner::Root(winner_commitment, winner_state) => {
                    info!(
                        "tournament finished, winner commitment: {}, state hash: {}",
                        winner_commitment, winner_state,
                    );
                    if commitment.merkle.root_hash() == winner_commitment {
                        return Ok(Some(PlayerTournamentResult::TournamentWon));
                    } else {
                        return Ok(Some(PlayerTournamentResult::TournamentLost));
                    }
                }
                TournamentWinner::Inner(parent_commitment, _) => {
                    let old_commitment = commitments
                        .get(
                            &tournament_state
                                .parent
                                .expect("parent tournament state not found"),
                        )
                        .expect("parent commitment not found");
                    if parent_commitment != old_commitment.merkle.root_hash() {
                        info!("player lost tournament {}", tournament_state.address);
                        return Ok(Some(PlayerTournamentResult::TournamentLost));
                    } else {
                        info!(
                            "win tournament {} of level {} for commitment {}",
                            tournament_state.address,
                            tournament_state.level,
                            commitment.merkle.root_hash(),
                        );
                        let (left, right) = old_commitment.merkle.root_children();
                        self.arena
                            .win_inner_match(
                                tournament_state
                                    .parent
                                    .expect("parent tournament state not found"),
                                tournament_state.address,
                                left,
                                right,
                            )
                            .await?;

                        return Ok(None);
                    }
                }
            }
        }

        let commitment_state = tournament_state
            .commitment_states
            .get(&commitment.merkle.root_hash());
        match commitment_state {
            Some(c) => {
                info!("{}", c.clock);
                if let Some(m) = c.latest_match {
                    self.react_match(
                        &tournament_state
                            .matches
                            .get(m)
                            .expect("match state not found")
                            .clone(),
                        &commitment,
                        new_commitments,
                        tournament_state.level,
                        tournament_states,
                    )
                    .await?;
                }
            }
            None => {
                self.join_tournament_if_needed(tournament_state, &commitment)
                    .await?;
            }
        }

        Ok(None)
    }

    async fn join_tournament_if_needed(
        &mut self,
        tournament_state: &TournamentState,
        commitment: &MachineCommitment,
    ) -> Result<(), Box<dyn Error>> {
        let (left, right) = commitment.merkle.root_children();
        let (last, proof) = commitment.merkle.last();

        info!(
            "join tournament {} of level {} with commitment {}",
            tournament_state.address,
            tournament_state.level,
            commitment.merkle.root_hash(),
        );
        self.arena
            .join_tournament(tournament_state.address, last, proof, left, right)
            .await
    }

    #[async_recursion]
    async fn react_match(
        &mut self,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        commitments: HashMap<Address, MachineCommitment>,
        tournament_level: u64,
        tournament_states: HashMap<Address, TournamentState>,
    ) -> Result<(), Box<dyn Error>> {
        info!("Enter match at HEIGHT: {}", match_state.current_height);
        if match_state.current_height == 0 {
            self.react_sealed_match(
                match_state,
                commitment,
                commitments,
                tournament_level,
                tournament_states,
            )
            .await
        } else if match_state.current_height == 1 {
            self.react_unsealed_match(match_state, commitment, tournament_level)
                .await
        } else {
            self.react_running_match(match_state, commitment, tournament_level)
                .await
        }
    }

    #[async_recursion]
    async fn react_sealed_match(
        &mut self,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        commitments: HashMap<Address, MachineCommitment>,
        tournament_level: u64,
        tournament_states: HashMap<Address, TournamentState>,
    ) -> Result<(), Box<dyn Error>> {
        if tournament_level == 1 {
            let (left, right) = commitment.merkle.root_children();

            let finished = match_state.other_parent.is_zeroed();
            if finished {
                return Ok(());
            }

            let cycle = match_state.running_leaf_position >> constants::LOG2_UARCH_SPAN;
            let ucycle = match_state.running_leaf_position & constants::UARCH_SPAN;
            let proof = self
                .machine_factory
                .create_machine(&self.machine_path)
                .await?
                .get_logs(cycle, ucycle)
                .await?;

            info!(
                "win leaf match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            self.arena
                .win_leaf_match(
                    match_state.tournament_address,
                    match_state.id,
                    left,
                    right,
                    proof,
                )
                .await?;
        } else {
            self.react_tournament(
                commitments,
                match_state
                    .inner_tournament
                    .expect("inner tournament not found"),
                tournament_states,
            )
            .await?;
        }

        Ok(())
    }

    async fn react_unsealed_match(
        &mut self,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        tournament_level: u64,
    ) -> Result<(), Box<dyn Error>> {
        let (left, right) =
            if let Some(children) = commitment.merkle.node_children(match_state.other_parent) {
                children
            } else {
                return Ok(());
            };

        let (initial_hash, initial_hash_proof) = if match_state.running_leaf_position == 0 {
            (commitment.implicit_hash, MerkleProof::default())
        } else {
            commitment
                .merkle
                .prove_leaf(match_state.running_leaf_position)
        };

        if tournament_level == 1 {
            info!(
                "seal leaf match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            self.arena
                .seal_leaf_match(
                    match_state.tournament_address,
                    match_state.id,
                    left,
                    right,
                    initial_hash,
                    initial_hash_proof,
                )
                .await?;
        } else {
            info!(
                "seal inner match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            self.arena
                .seal_inner_match(
                    match_state.tournament_address,
                    match_state.id,
                    left,
                    right,
                    initial_hash,
                    initial_hash_proof,
                )
                .await?;
        }

        Ok(())
    }

    async fn react_running_match(
        &mut self,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        tournament_level: u64,
    ) -> Result<(), Box<dyn Error>> {
        let (left, right) =
            if let Some(children) = commitment.merkle.node_children(match_state.other_parent) {
                children
            } else {
                info!("not my turn to react");
                return Ok(());
            };
        let (new_left, new_right) = if left != match_state.left_node {
            commitment
                .merkle
                .node_children(left)
                .expect("left node does not have children")
        } else {
            commitment
                .merkle
                .node_children(right)
                .expect("right node does not have children")
        };

        info!(
            "advance match with current height {} in tournament {} of level {} for commitment {}",
            match_state.current_height,
            match_state.tournament_address,
            tournament_level,
            commitment.merkle.root_hash(),
        );
        self.arena
            .advance_match(
                match_state.tournament_address,
                match_state.id,
                left,
                right,
                new_left,
                new_right,
            )
            .await?;

        Ok(())
    }
}
