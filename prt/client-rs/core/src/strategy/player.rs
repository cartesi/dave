use std::collections::HashMap;
use std::{path::PathBuf, sync::Arc};
use tokio::sync::Mutex;

use crate::strategy::error::Result;
use ::log::{debug, error, info};
use alloy::{primitives::Address, providers::DynProvider};
use async_recursion::async_recursion;
use num_traits::One;
use ruint::aliases::U256;

use crate::{
    db::dispute_state_access::{DisputeStateAccess, Input, Leaf},
    machine::{MachineCommitment, MachineCommitmentBuilder, MachineInstance},
    strategy::gc::GarbageCollector,
    tournament::{
        ArenaSender, CommitmentState, MatchState, StateReader, TournamentState, TournamentStateMap,
        TournamentWinner,
    },
};
use cartesi_dave_merkle::{Digest, MerkleProof};

#[derive(Debug, PartialEq)]
pub enum PlayerTournamentResult {
    TournamentLost,
    TournamentRunning,
    TournamentWon,
}

pub struct Player<AS: ArenaSender> {
    arena_sender: Arc<Mutex<AS>>,
    db: DisputeStateAccess,
    machine_path: String,
    commitment_builder: MachineCommitmentBuilder,
    root_tournament: Address,
    reader: StateReader,
    gc: GarbageCollector<AS>,
}

impl<AS: ArenaSender> Player<AS> {
    pub fn new(
        arena_sender: Arc<Mutex<AS>>,
        inputs: Vec<Input>,
        leafs: Vec<Leaf>,
        provider: DynProvider,
        machine_path: String,
        root_tournament: Address,
        block_created_number: u64,
        state_dir: PathBuf,
    ) -> Result<Self> {
        let db = DisputeStateAccess::new(inputs, leafs, root_tournament.to_string(), state_dir)?;
        let reader = StateReader::new(provider.clone(), block_created_number)?;
        let gc = GarbageCollector::new(arena_sender.clone(), root_tournament);
        let commitment_builder = MachineCommitmentBuilder::new(machine_path.clone());
        Ok(Self {
            arena_sender,
            db,
            machine_path,
            commitment_builder,
            root_tournament,
            reader,
            gc,
        })
    }

    pub async fn react(&mut self) -> Result<PlayerTournamentResult> {
        let tournament_states = self.reader.fetch_from_root(self.root_tournament).await?;

        self.gc.react(&tournament_states).await?;
        self.react_tournament(None, self.root_tournament, &tournament_states)
            .await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &mut self,
        old_commitment: Option<&MachineCommitment>,
        tournament_address: Address,
        tournament_states: &TournamentStateMap,
    ) -> Result<PlayerTournamentResult> {
        info!("Enter tournament at address: {}", tournament_address);
        // TODO: print final state one and final state two
        let tournament_state = get_tournament_state(tournament_states, tournament_address);

        let commitment = self.commitment_builder.build_commitment(
            tournament_state.base_cycle,
            tournament_state.level,
            tournament_state.log2_stride,
            tournament_state.log2_stride_count,
            &self.db,
        )?;

        if let Some(winner) = &tournament_state.winner {
            match winner {
                TournamentWinner::Root(winner_commitment, winner_state) => {
                    info!(
                        "tournament finished, winner commitment: {}, state hash: {}",
                        winner_commitment, winner_state,
                    );
                    if commitment.merkle.root_hash() == *winner_commitment {
                        info!("player won tournament {}", tournament_state.address);
                        return Ok(PlayerTournamentResult::TournamentWon);
                    } else {
                        error!("player lost tournament {}", tournament_state.address);
                        return Ok(PlayerTournamentResult::TournamentLost);
                    }
                }
                TournamentWinner::Inner(parent_commitment, _) => {
                    match old_commitment {
                        Some(old_commitment) => {
                            if *parent_commitment != old_commitment.merkle.root_hash() {
                                error!("player lost tournament {}", tournament_state.address);
                                return Ok(PlayerTournamentResult::TournamentLost);
                            } else {
                                info!(
                                    "win tournament {} of level {} for commitment {}",
                                    tournament_state.address,
                                    tournament_state.level,
                                    commitment.merkle.root_hash(),
                                );
                                let (left, right) = old_commitment
                                    .merkle
                                    .subtrees()
                                    .expect("merkle tree should have subtrees");
                                self.arena_sender
                                    .lock()
                                    .await
                                    .win_inner_match(
                                        tournament_state
                                            .parent
                                            .expect("parent tournament state not found"),
                                        tournament_state.address,
                                        left.root_hash(),
                                        right.root_hash(),
                                    )
                                    .await?;

                                return Ok(PlayerTournamentResult::TournamentRunning);
                            }
                        }
                        None => {
                            panic!("parent tournament state not found for inner tournament");
                        }
                    };
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
                    let match_state = tournament_state
                        .matches
                        .get(m)
                        .expect("match state not found");

                    self.react_match(match_state, commitment, tournament_state, tournament_states)
                        .await?;
                } else {
                    info!(
                        "no match found for commitment: {}",
                        commitment.merkle.root_hash()
                    );
                }
            }
            None => {
                self.join_tournament_if_needed(tournament_state, &commitment)
                    .await?;
            }
        }

        Ok(PlayerTournamentResult::TournamentRunning)
    }

    async fn join_tournament_if_needed(
        &mut self,
        tournament_state: &TournamentState,
        commitment: &MachineCommitment,
    ) -> Result<()> {
        let (left, right) = commitment
            .merkle
            .subtrees()
            .expect("commitment should have subtrees");
        let proof_last = commitment.merkle.prove_last();

        info!(
            "join tournament {} of level {} with commitment {}",
            tournament_state.address,
            tournament_state.level,
            commitment.merkle.root_hash(),
        );

        // Get the bond value required for joining the tournament
        let bond_value = self
            .arena_sender
            .lock()
            .await
            .bond_value(tournament_state.address)
            .await?;

        self.arena_sender
            .lock()
            .await
            .join_tournament(
                tournament_state.address,
                &proof_last,
                left.root_hash(),
                right.root_hash(),
                bond_value,
            )
            .await?;

        Ok(())
    }

    #[async_recursion]
    async fn react_match<'a>(
        &mut self,
        match_state: &MatchState,
        commitment: MachineCommitment,
        tournament_state: &TournamentState,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        info!("Enter match at HEIGHT: {}", match_state.current_height);

        let commitment_states = &tournament_state.commitment_states;

        self.win_timeout_match(
            match_state,
            &commitment,
            commitment_states,
            tournament_state.level,
        )
        .await?;

        if match_state.current_height == 0 {
            self.react_sealed_match(
                match_state,
                &commitment,
                tournament_state.level,
                tournament_state.max_level,
                tournament_states,
            )
            .await?;
        } else if match_state.current_height == 1 {
            self.react_unsealed_match(
                match_state,
                &commitment,
                tournament_state.level,
                tournament_state.max_level,
            )
            .await?;
        } else {
            self.react_running_match(match_state, &commitment, tournament_state.level)
                .await?;
        }
        Ok(())
    }

    async fn win_timeout_match(
        &mut self,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        commitment_states: &HashMap<Digest, CommitmentState>,
        tournament_level: u64,
    ) -> Result<()> {
        let opponent_clock = if commitment.merkle.root_hash() == match_state.id.commitment_one {
            commitment_states
                .get(&match_state.id.commitment_two)
                .unwrap()
                .clock
        } else {
            commitment_states
                .get(&match_state.id.commitment_one)
                .unwrap()
                .clock
        };

        if !opponent_clock.has_time() {
            let (left, right) = commitment
                .merkle
                .subtrees()
                .expect("merkle tree should have subtrees");

            info!(
                "win match by timeout in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );

            self.arena_sender
                .lock()
                .await
                .win_timeout_match(
                    match_state.tournament_address,
                    match_state.id,
                    left.root_hash(),
                    right.root_hash(),
                )
                .await?;
        }
        Ok(())
    }

    #[async_recursion]
    async fn react_sealed_match<'a>(
        &mut self,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        tournament_level: u64,
        tournament_max_level: u64,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        if tournament_level == (tournament_max_level - 1) {
            let (left, right) = commitment
                .merkle
                .subtrees()
                .expect("merkle tree should have subtrees");

            let proof = {
                MachineInstance::get_logs(
                    &self.machine_path,
                    match_state.other_parent,
                    match_state.leaf_cycle,
                    &self.db,
                )?
            };

            info!(
                "win leaf match in tournament {} of level {} for commitment {}, proof size {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
                proof.0.len()
            );
            self.arena_sender
                .lock()
                .await
                .win_leaf_match(
                    match_state.tournament_address,
                    match_state.id,
                    left.root_hash(),
                    right.root_hash(),
                    proof.0,
                )
                .await?;
        } else {
            self.react_tournament(
                Some(commitment),
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
        tournament_max_level: u64,
    ) -> Result<()> {
        let Some(r) = commitment.merkle.find_child(&match_state.other_parent) else {
            debug!("not my turn to react");
            return Ok(());
        };

        let (left, right) = r.subtrees().expect("merkle tree should have subtrees");

        let running_leaf_position = {
            if left.root_hash() != match_state.left_node {
                // disagree on left
                match_state.running_leaf_position
            } else {
                // disagree on right
                match_state.running_leaf_position + U256::one()
            }
        };

        let agree_state_proof = if running_leaf_position.is_zero() {
            MerkleProof::leaf(commitment.implicit_hash, U256::ZERO)
        } else {
            commitment
                .merkle
                .prove_leaf(running_leaf_position - U256::one())
        };

        if tournament_level == (tournament_max_level - 1) {
            info!(
                "seal leaf match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            self.arena_sender
                .lock()
                .await
                .seal_leaf_match(
                    match_state.tournament_address,
                    match_state.id,
                    left.root_hash(),
                    right.root_hash(),
                    &agree_state_proof,
                )
                .await?;
        } else {
            info!(
                "seal inner match in tournament {} of level {} for commitment {}",
                match_state.tournament_address,
                tournament_level,
                commitment.merkle.root_hash(),
            );
            self.arena_sender
                .lock()
                .await
                .seal_inner_match(
                    match_state.tournament_address,
                    match_state.id,
                    left.root_hash(),
                    right.root_hash(),
                    &agree_state_proof,
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
    ) -> Result<()> {
        let Some(r) = commitment.merkle.find_child(&match_state.other_parent) else {
            debug!("not my turn to react");
            return Ok(());
        };

        let (left, right) = r.subtrees().expect("merkle tree should have subtrees");

        let (new_left, new_right) = if left.root_hash() != match_state.left_node {
            debug!("going down to the left");
            left.subtrees().expect("left tree should have subtrees")
        } else {
            debug!("going down to the right");
            right.subtrees().expect("right tree should have subtrees")
        };

        info!(
            "advance match with current height {} in tournament {} of level {} for commitment {}",
            match_state.current_height,
            match_state.tournament_address,
            tournament_level,
            commitment.merkle.root_hash(),
        );
        self.arena_sender
            .lock()
            .await
            .advance_match(
                match_state.tournament_address,
                match_state.id,
                left.root_hash(),
                right.root_hash(),
                new_left.root_hash(),
                new_right.root_hash(),
            )
            .await?;
        Ok(())
    }
}

fn get_tournament_state(map: &TournamentStateMap, tournament_address: Address) -> &TournamentState {
    map.get(&tournament_address)
        .expect("tournament state not found")
}
