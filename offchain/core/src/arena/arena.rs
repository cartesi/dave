//! This module defines the struct [Reader] that is responsible for the reading the states
//! of tournaments; and the struct [Sender] that is responsible for the sending transactions
//! to tournaments

use std::{collections::HashMap, error::Error, str::FromStr, sync::Arc, time::Duration};

use async_recursion::async_recursion;
use async_trait::async_trait;

use ethers::{
    middleware::SignerMiddleware,
    providers::{Http, Middleware, Provider},
    signers::{LocalWallet, Signer},
    types::{Address, BlockNumber::Latest, Bytes, ValueOrArray::Value, U256},
};

use crate::{
    arena::config::ArenaConfig,
    contract::{
        leaf_tournament, non_leaf_tournament, non_root_tournament, root_tournament, tournament,
    },
    machine::{constants, MachineProof},
    merkle::{Digest, MerkleProof},
};

#[derive(Clone)]
pub struct Arena {
    client: Arc<SignerMiddleware<Provider<Http>, LocalWallet>>,
}

impl Arena {
    pub fn new(config: ArenaConfig) -> Result<Self, Box<dyn Error>> {
        let provider = Provider::<Http>::try_from(config.web3_rpc_url.clone())?
            .interval(Duration::from_millis(10u64));
        let wallet = LocalWallet::from_str(config.web3_private_key.as_str())?;
        let client = Arc::new(SignerMiddleware::new(
            provider,
            wallet.with_chain_id(config.web3_chain_id),
        ));

        Ok(Self { client })
    }

    async fn created_tournament(
        &self,
        tournament_address: Address,
        match_id: MatchID,
    ) -> Result<Option<TournamentCreatedEvent>, Box<dyn Error>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament_address, self.client.clone());
        let events = tournament
            .new_inner_tournament_filter()
            .address(Value(tournament_address))
            .from_block(0)
            .to_block(Latest)
            .query()
            .await?;
        if let Some(event) = events.last() {
            Ok(Some(TournamentCreatedEvent {
                parent_match_id_hash: match_id.hash(),
                new_tournament_address: event.1,
            }))
        } else {
            Ok(None)
        }
    }

    async fn created_matches(
        &self,
        tournament_address: Address,
    ) -> Result<Vec<MatchCreatedEvent>, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament_address, self.client.clone());
        let events: Vec<MatchCreatedEvent> = tournament
            .match_created_filter()
            .address(Value(tournament_address))
            .from_block(0)
            .to_block(Latest)
            .query()
            .await?
            .iter()
            .map(|event| MatchCreatedEvent {
                id: MatchID {
                    commitment_one: event.one.into(),
                    commitment_two: event.two.into(),
                },
                left_hash: event.left_of_two.into(),
            })
            .collect();
        Ok(events)
    }

    async fn joined_commitments(
        &self,
        tournament_address: Address,
    ) -> Result<Vec<CommitmentJoinedEvent>, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament_address, self.client.clone());
        let events = tournament
            .commitment_joined_filter()
            .address(Value(tournament_address))
            .from_block(0)
            .to_block(Latest)
            .query()
            .await?
            .iter()
            .map(|c| CommitmentJoinedEvent {
                root: Digest::from(c.root),
            })
            .collect();
        Ok(events)
    }

    async fn get_commitment(
        &self,
        tournament: Address,
        commitment_hash: Digest,
    ) -> Result<CommitmentState, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let (clock_state, hash) = tournament
            .get_commitment(commitment_hash.into())
            .call()
            .await?;
        let block_time = self
            .client
            .get_block(Latest)
            .await?
            .expect("cannot get last block")
            .timestamp;
        let clock_state = ClockState {
            allowance: clock_state.allowance,
            start_instant: clock_state.start_instant,
            block_time,
        };
        Ok(CommitmentState {
            clock: clock_state,
            final_state: Digest::from(hash),
            latest_match: None,
        })
    }

    pub async fn fetch_from_root(
        &self,
        root_tournament: Address,
    ) -> Result<HashMap<Address, TournamentState>, Box<dyn Error>> {
        self.fetch_tournament(TournamentState::new_root(root_tournament), HashMap::new())
            .await
    }

    #[async_recursion]
    async fn fetch_tournament(
        &self,
        tournament_state: TournamentState,
        states: HashMap<Address, TournamentState>,
    ) -> Result<HashMap<Address, TournamentState>, Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament_state.address, self.client.clone());
        let created_matches = self.created_matches(tournament_state.address).await?;
        let commitments_joined = self.joined_commitments(tournament_state.address).await?;

        let mut commitment_states = HashMap::new();
        for commitment in commitments_joined {
            let commitment_state = self
                .get_commitment(tournament_state.address, commitment.root)
                .await?;
            commitment_states.insert(commitment.root, commitment_state);
        }

        let mut matches = vec![];
        let mut new_states = states.clone();
        for match_event in created_matches {
            let match_id = match_event.id;
            let m = tournament.get_match(match_id.hash().into()).call().await?;

            let running_leaf_position = m.running_leaf_position.as_u64();
            let base = tournament_state.base_big_cycle;
            let step = 1 << constants::LOG2_STEP[(tournament_state.level - 1) as usize];
            let leaf_cycle = base + (step * running_leaf_position);
            let base_big_cycle = leaf_cycle >> constants::LOG2_UARCH_SPAN;
            let prev_states = new_states.clone();
            let match_state;

            // if !Digest::from(m.other_parent).is_zeroed() {
            (match_state, new_states) = self
                .fetch_match(
                    MatchState {
                        id: match_id,
                        other_parent: m.other_parent.into(),
                        left_node: m.left_node.into(),
                        right_node: m.right_node.into(),
                        running_leaf_position,
                        current_height: m.current_height,
                        tournament_address: tournament_state.address,
                        level: m.level,
                        leaf_cycle,
                        base_big_cycle,
                        inner_tournament: None,
                    },
                    prev_states,
                    tournament_state.level,
                )
                .await?;

            commitment_states
                .get_mut(&match_id.commitment_one)
                .expect("cannot find commitment one state")
                .latest_match = Some(matches.len());
            commitment_states
                .get_mut(&match_id.commitment_two)
                .expect("cannot find commitment two state")
                .latest_match = Some(matches.len());
            matches.push(match_state);
        }
        // }

        let winner = match tournament_state.parent {
            Some(_) => self.tournament_winner(tournament_state.address).await?,
            None => {
                self.root_tournament_winner(tournament_state.address)
                    .await?
            }
        };

        let mut state = tournament_state.clone();
        state.winner = winner;
        state.matches = matches;
        state.commitment_states = commitment_states;

        new_states.insert(tournament_state.address, state);

        Ok(new_states)
    }

    #[async_recursion]
    async fn fetch_match(
        &self,
        match_state: MatchState,
        states: HashMap<Address, TournamentState>,
        tournament_level: u64,
    ) -> Result<(MatchState, HashMap<Address, TournamentState>), Box<dyn Error>> {
        let mut state = match_state.clone();
        let created_tournament = self
            .created_tournament(match_state.tournament_address, match_state.id)
            .await?;
        if let Some(inner) = created_tournament {
            let inner_tournament = TournamentState::new_inner(
                inner.new_tournament_address,
                tournament_level - 1,
                match_state.base_big_cycle,
                match_state.tournament_address,
            );
            let new_states = self.fetch_tournament(inner_tournament, states).await?;
            state.inner_tournament = Some(inner.new_tournament_address);

            return Ok((state, new_states));
        }

        Ok((state, states))
    }

    async fn root_tournament_winner(
        &self,
        root_tournament: Address,
    ) -> Result<Option<TournamentWinner>, Box<dyn Error>> {
        let root_tournament =
            root_tournament::RootTournament::new(root_tournament, self.client.clone());
        let (finished, commitment, state) = root_tournament.arbitration_result().call().await?;
        if finished {
            Ok(Some(TournamentWinner::Root(
                Digest::from(commitment),
                Digest::from(state),
            )))
        } else {
            Ok(None)
        }
    }

    async fn tournament_winner(
        &self,
        tournament: Address,
    ) -> Result<Option<TournamentWinner>, Box<dyn Error>> {
        let tournament =
            non_root_tournament::NonRootTournament::new(tournament, self.client.clone());
        let (finished, parent_commitment, dangling_commitment) =
            tournament.inner_tournament_winner().call().await?;
        if finished {
            Ok(Some(TournamentWinner::Inner(
                Digest::from(parent_commitment),
                Digest::from(dangling_commitment),
            )))
        } else {
            Ok(None)
        }
    }
}

/// The [ArenaSender] trait defines the interface for the creation and management of tournaments.
#[async_trait]
pub trait ArenaSender: Send + Sync {
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

    async fn eliminate_match(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<(), Box<dyn Error>>;
}

#[async_trait]
impl ArenaSender for Arena {
    async fn join_tournament(
        &self,
        tournament: Address,
        final_state: Digest,
        proof: MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let proof = proof.iter().map(|h| -> [u8; 32] { (*h).into() }).collect();
        tournament
            .join_tournament(
                final_state.into(),
                proof,
                left_child.into(),
                right_child.into(),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let match_id = tournament::Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        tournament
            .advance_match(
                match_id,
                left_node.into(),
                right_node.into(),
                new_left_node.into(),
                new_right_node.into(),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        let match_id = non_leaf_tournament::Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        let initial_hash_proof = initial_hash_proof
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .seal_inner_match_and_create_inner_tournament(
                match_id,
                left_leaf.into(),
                right_leaf.into(),
                initial_hash.into(),
                initial_hash_proof,
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<(), Box<dyn Error>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament, self.client.clone());
        tournament
            .win_inner_match(child_tournament, left_node.into(), right_node.into())
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash: Digest,
        initial_hash_proof: MerkleProof,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = leaf_tournament::LeafTournament::new(tournament, self.client.clone());
        let match_id = leaf_tournament::Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        let initial_hash_proof = initial_hash_proof
            .iter()
            .map(|h| -> [u8; 32] { (*h).into() })
            .collect();
        tournament
            .seal_leaf_match(
                match_id,
                left_leaf.into(),
                right_leaf.into(),
                initial_hash.into(),
                initial_hash_proof,
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = leaf_tournament::LeafTournament::new(tournament, self.client.clone());
        let match_id = leaf_tournament::Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        tournament
            .win_leaf_match(
                match_id,
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .send()
            .await?
            .await?;
        Ok(())
    }

    async fn eliminate_match(
        &self,
        tournament: Address,
        match_id: MatchID,
    ) -> Result<(), Box<dyn Error>> {
        let tournament = tournament::Tournament::new(tournament, self.client.clone());
        let match_id = tournament::Id {
            commitment_one: match_id.commitment_one.into(),
            commitment_two: match_id.commitment_two.into(),
        };
        tournament
            .eliminate_match_by_timeout(match_id)
            .send()
            .await?
            .await?;
        Ok(())
    }
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

impl ClockState {
    pub fn has_time(&self) -> bool {
        if self.start_instant == 0 {
            true
        } else {
            self.deadline() > self.block_time.as_u64()
        }
    }

    pub fn time_since_timeout(&self) -> u64 {
        if self.start_instant == 0 {
            0
        } else {
            self.block_time.as_u64() - self.deadline()
        }
    }

    // deadline of clock if it's ticking
    fn deadline(&self) -> u64 {
        self.start_instant + self.allowance
    }
}

impl std::fmt::Display for ClockState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.start_instant == 0 {
            write!(f, "clock paused, {} seconds left", self.allowance)
        } else {
            let time_elapsed = self.block_time.as_u64() - self.start_instant;
            if self.allowance >= time_elapsed {
                write!(
                    f,
                    "clock ticking, {} seconds left",
                    self.allowance - time_elapsed
                )
            } else {
                write!(
                    f,
                    "clock ticking, {} seconds overdue",
                    time_elapsed - self.allowance
                )
            }
        }
    }
}

/// Enum used to represent the winner of a tournament.
#[derive(Clone, PartialEq)]
pub enum TournamentWinner {
    Root(Digest, Digest),
    Inner(Digest, Digest),
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
    pub tournament_address: Address,
    pub inner_tournament: Option<Address>,
}
