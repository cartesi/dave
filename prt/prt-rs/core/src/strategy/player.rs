use std::collections::HashMap;

use ::log::info;
use anyhow::Result;
use async_recursion::async_recursion;
use ethers::types::Address;

use crate::{
    arena::{ArenaSender, MatchState, TournamentState, TournamentStateMap, TournamentWinner},
    machine::{constants, CachingMachineCommitmentBuilder, MachineCommitment, MachineInstance},
    merkle::MerkleProof,
};

#[derive(Debug)]
pub enum PlayerTournamentResult {
    TournamentWon,
    TournamentLost,
}

pub struct Player {
    machine_path: String,
    commitment_builder: CachingMachineCommitmentBuilder,
    root_tournamet: Address,
}

impl Player {
    pub fn new(
        machine_path: String,
        commitment_builder: CachingMachineCommitmentBuilder,
        root_tournamet: Address,
    ) -> Self {
        Self {
            machine_path,
            commitment_builder,
            root_tournamet,
        }
    }

    pub async fn react<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        tournament_states: TournamentStateMap,
    ) -> Result<Option<PlayerTournamentResult>> {
        self.react_tournament(
            arena_sender,
            HashMap::new(),
            self.root_tournamet,
            tournament_states,
        )
        .await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        commitments: HashMap<Address, MachineCommitment>,
        tournament_address: Address,
        tournament_states: TournamentStateMap,
    ) -> Result<Option<PlayerTournamentResult>> {
        info!("Enter tournament at address: {}", tournament_address);
        let tournament_state = tournament_states
            .get(&tournament_address)
            .expect("tournament state not found");
        let mut new_commitments = commitments.clone();

        let commitment = new_commitments
            .entry(tournament_state.address)
            .or_insert(self.commitment_builder.build_commitment(
                tournament_state.base_big_cycle,
                tournament_state.level,
                tournament_state.log2_stride,
                tournament_state.log2_stride_count,
            )?)
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
                        arena_sender
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
                        arena_sender,
                        &tournament_state
                            .matches
                            .get(m)
                            .expect("match state not found")
                            .clone(),
                        &commitment,
                        new_commitments,
                        tournament_state.level,
                        tournament_state.max_level,
                        tournament_states,
                    )
                    .await?;
                }
            }
            None => {
                self.join_tournament_if_needed(arena_sender, tournament_state, &commitment)
                    .await?;
            }
        }

        Ok(None)
    }

    async fn join_tournament_if_needed<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        tournament_state: &TournamentState,
        commitment: &MachineCommitment,
    ) -> Result<()> {
        let (left, right) = commitment.merkle.root_children();
        let (last, proof) = commitment.merkle.last();

        info!(
            "join tournament {} of level {} with commitment {}",
            tournament_state.address,
            tournament_state.level,
            commitment.merkle.root_hash(),
        );
        arena_sender
            .join_tournament(tournament_state.address, last, proof, left, right)
            .await?;

        Ok(())
    }

    #[async_recursion]
    async fn react_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        commitments: HashMap<Address, MachineCommitment>,
        tournament_level: u64,
        tournament_max_level: u64,
        tournament_states: TournamentStateMap,
    ) -> Result<()> {
        info!("Enter match at HEIGHT: {}", match_state.current_height);
        if match_state.current_height == 0 {
            self.react_sealed_match(
                arena_sender,
                match_state,
                commitment,
                commitments,
                tournament_level,
                tournament_max_level,
                tournament_states,
            )
            .await
        } else if match_state.current_height == 1 {
            self.react_unsealed_match(
                arena_sender,
                match_state,
                commitment,
                tournament_level,
                tournament_max_level,
            )
            .await
        } else {
            self.react_running_match(arena_sender, match_state, commitment, tournament_level)
                .await
        }
    }

    #[async_recursion]
    async fn react_sealed_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        commitments: HashMap<Address, MachineCommitment>,
        tournament_level: u64,
        tournament_max_level: u64,
        tournament_states: TournamentStateMap,
    ) -> Result<()> {
        if tournament_level == (tournament_max_level - 1) {
            let (left, right) = commitment.merkle.root_children();

            let finished = match_state.other_parent.is_zeroed();
            if finished {
                return Ok(());
            }

            let cycle = match_state.base_big_cycle;
            let ucycle = match_state.leaf_cycle & constants::UARCH_SPAN;
            let proof = MachineInstance::new(&self.machine_path)?.get_logs(cycle, ucycle)?;

            info!(
                "win leaf match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            arena_sender
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
                arena_sender,
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

    async fn react_unsealed_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        tournament_level: u64,
        tournament_max_level: u64,
    ) -> Result<()> {
        let (left, right) =
            if let Some(children) = commitment.merkle.node_children(match_state.other_parent) {
                children
            } else {
                return Ok(());
            };

        let (agree_state, agree_state_proof) = if match_state.running_leaf_position == 0 {
            (commitment.implicit_hash, MerkleProof::default())
        } else {
            commitment
                .merkle
                .prove_leaf(match_state.running_leaf_position - 1)
        };

        if tournament_level == (tournament_max_level - 1) {
            info!(
                "seal leaf match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            arena_sender
                .seal_leaf_match(
                    match_state.tournament_address,
                    match_state.id,
                    left,
                    right,
                    agree_state,
                    agree_state_proof,
                )
                .await?;
        } else {
            info!(
                "seal inner match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            arena_sender
                .seal_inner_match(
                    match_state.tournament_address,
                    match_state.id,
                    left,
                    right,
                    agree_state,
                    agree_state_proof,
                )
                .await?;
        }

        Ok(())
    }

    async fn react_running_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        tournament_level: u64,
    ) -> Result<()> {
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
        arena_sender
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
