use std::collections::HashMap;
use std::path::PathBuf;

use ::log::{debug, error, info};
use alloy::primitives::Address;
use anyhow::Result;
use async_recursion::async_recursion;
use num_traits::{cast::ToPrimitive, One};
use ruint::aliases::U256;

use crate::{
    arena::{
        ArenaSender, BlockchainConfig, CommitmentMap, CommitmentState, MatchState, StateReader,
        TournamentState, TournamentStateMap, TournamentWinner,
    },
    db::compute_state_access::{ComputeStateAccess, Input, Leaf},
    machine::{constants, CachingMachineCommitmentBuilder, MachineCommitment, MachineInstance},
    strategy::gc::GarbageCollector,
};
use cartesi_dave_merkle::{Digest, MerkleProof};

#[derive(Debug)]
pub enum PlayerTournamentResult {
    TournamentWon,
    TournamentLost,
}

pub struct Player {
    db: ComputeStateAccess,
    machine_path: String,
    commitment_builder: CachingMachineCommitmentBuilder,
    root_tournament: Address,
    reader: StateReader,
    gc: GarbageCollector,
}

impl Player {
    pub fn new(
        inputs: Option<Vec<Input>>,
        leafs: Vec<Leaf>,
        blockchain_config: &BlockchainConfig,
        machine_path: String,
        root_tournament: Address,
        state_dir: PathBuf,
    ) -> Result<Self> {
        let db = ComputeStateAccess::new(
            inputs,
            leafs,
            root_tournament.to_string(),
            state_dir.join("compute_path"),
        )?;
        let reader = StateReader::new(blockchain_config)?;
        let gc = GarbageCollector::new(root_tournament);
        let commitment_builder = CachingMachineCommitmentBuilder::new(machine_path.clone());
        Ok(Self {
            db,
            machine_path,
            commitment_builder,
            root_tournament,
            reader,
            gc,
        })
    }

    pub async fn react<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        interval: u64,
    ) -> Result<PlayerTournamentResult> {
        loop {
            let result = self.react_once(arena_sender).await;
            match result {
                Err(e) => error!("{}", e),
                Ok(player_tournament_result) => {
                    if let Some(r) = player_tournament_result {
                        return Ok(r);
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        }
    }

    pub async fn react_once<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
    ) -> Result<Option<PlayerTournamentResult>> {
        let tournament_states = self.reader.fetch_from_root(self.root_tournament).await?;
        self.gc.react_once(arena_sender, &tournament_states).await?;
        self.react_tournament(
            arena_sender,
            HashMap::new(),
            self.root_tournament,
            &tournament_states,
        )
        .await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        mut commitments: CommitmentMap,
        tournament_address: Address,
        tournament_states: &TournamentStateMap,
    ) -> Result<Option<PlayerTournamentResult>> {
        info!("Enter tournament at address: {}", tournament_address);
        // TODO: print final state one and final state two
        let tournament_state = get_tournament_state(tournament_states, tournament_address);

        commitments.insert(
            tournament_state.address,
            self.commitment_builder.build_commitment(
                tournament_state.base_big_cycle,
                tournament_state.level,
                tournament_state.log2_stride,
                tournament_state.log2_stride_count,
                &self.db,
            )?,
        );
        let commitment = get_commitment(&commitments, tournament_address);

        if let Some(winner) = &tournament_state.winner {
            match winner {
                TournamentWinner::Root(winner_commitment, winner_state) => {
                    info!(
                        "tournament finished, winner commitment: {}, state hash: {}",
                        winner_commitment, winner_state,
                    );
                    if commitment.merkle.root_hash() == *winner_commitment {
                        return Ok(Some(PlayerTournamentResult::TournamentWon));
                    } else {
                        return Ok(Some(PlayerTournamentResult::TournamentLost));
                    }
                }
                TournamentWinner::Inner(parent_commitment, _) => {
                    let old_commitment = get_commitment(
                        &commitments,
                        tournament_state
                            .parent
                            .expect("parent tournament state not found"),
                    );
                    if *parent_commitment != old_commitment.merkle.root_hash() {
                        info!("player lost tournament {}", tournament_state.address);
                        return Ok(Some(PlayerTournamentResult::TournamentLost));
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
                        arena_sender
                            .win_inner_match(
                                tournament_state
                                    .parent
                                    .expect("parent tournament state not found"),
                                tournament_state.address,
                                left.root_hash(),
                                right.root_hash(),
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
                    let match_state = tournament_state
                        .matches
                        .get(m)
                        .expect("match state not found");

                    self.react_match(
                        arena_sender,
                        &match_state,
                        commitments,
                        tournament_state,
                        tournament_states,
                    )
                    .await?;
                } else {
                    info!(
                        "no match found for commitment: {}",
                        commitment.merkle.root_hash()
                    );
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
        arena_sender
            .join_tournament(
                tournament_state.address,
                &proof_last,
                left.root_hash(),
                right.root_hash(),
            )
            .await?;

        Ok(())
    }

    #[async_recursion]
    async fn react_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitments: CommitmentMap,
        tournament_state: &TournamentState,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        info!("Enter match at HEIGHT: {}", match_state.current_height);

        let commitment_states = &tournament_state.commitment_states;
        let commitment = get_commitment(&commitments, match_state.tournament_address);

        self.win_timeout_match(
            arena_sender,
            match_state,
            commitment,
            commitment_states,
            tournament_state.level,
        )
        .await?;

        if match_state.current_height == 0 {
            self.react_sealed_match(
                arena_sender,
                match_state,
                commitments,
                tournament_state.level,
                tournament_state.max_level,
                tournament_states,
            )
            .await?;
        } else if match_state.current_height == 1 {
            self.react_unsealed_match(
                arena_sender,
                match_state,
                commitment,
                tournament_state.level,
                tournament_state.max_level,
            )
            .await?;
        } else {
            self.react_running_match(
                arena_sender,
                match_state,
                commitment,
                tournament_state.level,
            )
            .await?;
        }

        Ok(())
    }

    async fn win_timeout_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        commitment_states: &HashMap<Digest, CommitmentState>,
        tournament_level: u64,
    ) -> Result<()> {
        let opponent_clock;
        if commitment.merkle.root_hash() == match_state.id.commitment_one {
            opponent_clock = commitment_states
                .get(&match_state.id.commitment_two)
                .unwrap()
                .clock;
        } else {
            opponent_clock = commitment_states
                .get(&match_state.id.commitment_one)
                .unwrap()
                .clock;
        }

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

            arena_sender
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
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitments: CommitmentMap,
        tournament_level: u64,
        tournament_max_level: u64,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        if tournament_level == (tournament_max_level - 1) {
            let commitment = get_commitment(&commitments, match_state.tournament_address);
            let (left, right) = commitment
                .merkle
                .subtrees()
                .expect("merkle tree should have subtrees");

            let finished = match_state.other_parent.is_zeroed();
            if finished {
                return Ok(());
            }

            let cycle = match_state.base_big_cycle;
            let ucycle = (match_state.leaf_cycle & U256::from(constants::UARCH_SPAN))
                .to_u64()
                .expect("fail to convert ucycle");

            let proof = {
                let mut machine = MachineInstance::new(&self.machine_path)?;
                if let Some(snapshot) = self.db.closest_snapshot(cycle)? {
                    machine.load_snapshot(&snapshot.1, snapshot.0)?;
                };
                machine.get_logs(cycle, ucycle, &self.db)?
            };

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
                    left.root_hash(),
                    right.root_hash(),
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
        let Some(r) = commitment.merkle.find_child(&match_state.other_parent) else {
            info!("not my turn to react");
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
            arena_sender
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
            arena_sender
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

    async fn react_running_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        commitment: &MachineCommitment,
        tournament_level: u64,
    ) -> Result<()> {
        let Some(r) = commitment.merkle.find_child(&match_state.other_parent) else {
            info!("not my turn to react");
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
        arena_sender
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

fn get_commitment(map: &CommitmentMap, tournament_address: Address) -> &MachineCommitment {
    map.get(&tournament_address).expect("commitment not found")
}
