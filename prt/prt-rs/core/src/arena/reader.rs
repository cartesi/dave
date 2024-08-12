//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments

use std::{collections::HashMap, sync::Arc, time::Duration};

use anyhow::Result;
use async_recursion::async_recursion;

use ethers::{
    providers::{Http, Middleware, Provider},
    types::{Address, BlockNumber::Latest, ValueOrArray::Value, H256},
};

use crate::{
    arena::{
        arena::{
            ClockState, CommitmentState, MatchID, MatchState, TournamentState, TournamentStateMap,
            TournamentWinner,
        },
        config::ArenaConfig,
    },
    machine::constants,
};
use cartesi_dave_merkle::Digest;
use cartesi_prt_contracts::{
    non_leaf_tournament, non_root_tournament, root_tournament, tournament,
};

#[derive(Clone)]
pub struct StateReader {
    client: Arc<Provider<Http>>,
}

impl StateReader {
    pub fn new(config: ArenaConfig) -> Result<Self> {
        let provider = Provider::<Http>::try_from(config.web3_rpc_url.clone())?
            .interval(Duration::from_millis(10u64));
        let client = Arc::new(provider);

        Ok(Self { client })
    }

    async fn created_tournament(
        &self,
        tournament_address: Address,
        match_id: MatchID,
    ) -> Result<Option<TournamentCreatedEvent>> {
        let tournament =
            non_leaf_tournament::NonLeafTournament::new(tournament_address, self.client.clone());
        let events = tournament
            .new_inner_tournament_filter()
            .address(Value(tournament_address))
            .topic1(H256::from_slice(match_id.hash().slice()))
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

    async fn created_matches(&self, tournament_address: Address) -> Result<Vec<MatchCreatedEvent>> {
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
    ) -> Result<Vec<CommitmentJoinedEvent>> {
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
    ) -> Result<CommitmentState> {
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

    pub async fn fetch_from_root(&self, root_tournament: Address) -> Result<TournamentStateMap> {
        self.fetch_tournament(TournamentState::new_root(root_tournament), HashMap::new())
            .await
    }

    #[async_recursion]
    async fn fetch_tournament(
        &self,
        tournament_state: TournamentState,
        states: TournamentStateMap,
    ) -> Result<TournamentStateMap> {
        let tournament = tournament::Tournament::new(tournament_state.address, self.client.clone());
        let mut state = tournament_state.clone();

        (
            state.max_level,
            state.level,
            state.log2_stride,
            state.log2_stride_count,
        ) = tournament.tournament_level_constants().await?;

        assert!(state.level < state.max_level, "level out of bounds");

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
            let leaf_cycle = tournament
                .get_match_cycle(match_id.hash().into())
                .call()
                .await?
                .as_u64();
            let base_big_cycle = leaf_cycle >> constants::LOG2_UARCH_SPAN;

            let running_leaf_position = m.running_leaf_position.as_u64();
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
        states: TournamentStateMap,
        tournament_level: u64,
    ) -> Result<(MatchState, TournamentStateMap)> {
        let mut state = match_state.clone();
        let created_tournament = self
            .created_tournament(match_state.tournament_address, match_state.id)
            .await?;
        if let Some(inner) = created_tournament {
            let inner_tournament = TournamentState::new_inner(
                inner.new_tournament_address,
                tournament_level,
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
    ) -> Result<Option<TournamentWinner>> {
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

    async fn tournament_winner(&self, tournament: Address) -> Result<Option<TournamentWinner>> {
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
