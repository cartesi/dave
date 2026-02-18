//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments

use anyhow::{Result, anyhow};
use async_recursion::async_recursion;
use std::collections::HashMap;

use alloy::{
    contract::{Error, Event},
    eips::BlockNumberOrTag::Latest,
    providers::{DynProvider, Provider},
    rpc::types::{Log, Topic},
    sol_types::SolEvent,
    sol_types::private::{Address, B256},
};

use crate::tournament::{
    ClockState, CommitmentState, MatchID, MatchState, TournamentState, TournamentStateMap,
    TournamentWinner,
};
use cartesi_dave_merkle::Digest;
use cartesi_prt_contracts::{
    non_leaf_tournament, non_root_tournament, root_tournament, tournament,
};

#[derive(Clone)]
pub struct StateReader {
    client: DynProvider,
    block_created_number: u64,
    long_block_range_error_codes: Vec<String>,
}

impl StateReader {
    pub fn new(
        client: DynProvider,
        block_created_number: u64,
        long_block_range_error_codes: Vec<String>,
    ) -> Result<Self> {
        Ok(Self {
            client,
            block_created_number,
            long_block_range_error_codes,
        })
    }

    async fn latest_block_number(&self) -> Result<u64> {
        let block_number = self
            .client
            .get_block(Latest.into())
            .await?
            .expect("cannot get last block")
            .header
            .number;

        Ok(block_number)
    }

    async fn query_events<E: SolEvent + Send + Sync>(
        &self,
        topic1: Option<&Topic>,
        read_from: &Address,
    ) -> Result<Vec<(E, Log)>> {
        let latest_block = self.latest_block_number().await?;

        if latest_block < self.block_created_number {
            return Ok(vec![]);
        }

        get_events(
            &self.client,
            topic1,
            read_from,
            self.block_created_number,
            latest_block,
            &self.long_block_range_error_codes,
        )
        .await
        .map_err(|errors| anyhow!("{errors:?}"))
    }

    async fn created_tournament(
        &self,
        tournament_address: Address,
        match_id: MatchID,
    ) -> Result<Option<TournamentCreatedEvent>> {
        let topic1: Topic = B256::from(match_id.hash()).into();
        let events = self
            .query_events::<non_leaf_tournament::NonLeafTournament::NewInnerTournament>(
                Some(&topic1),
                &tournament_address,
            )
            .await?;

        if let Some((event, _)) = events.last() {
            Ok(Some(TournamentCreatedEvent {
                parent_match_id_hash: match_id.hash(),
                new_tournament_address: event.childTournament,
            }))
        } else {
            Ok(None)
        }
    }

    async fn capture_matches(&self, tournament_address: Address) -> Result<Vec<MatchState>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let created_matches = self.created_matches(tournament_address).await?;

        let mut matches = vec![];
        for match_event in created_matches {
            let match_id = match_event.id;
            let m = tournament.getMatch(match_id.hash().into()).call().await?;

            if m.isInit {
                let leaf_cycle = tournament
                    .getMatchCycle(match_id.hash().into())
                    .call()
                    .await?;
                let running_leaf_position = m.runningLeafPosition;

                let match_state = MatchState {
                    id: match_id,
                    other_parent: m.otherParent.into(),
                    left_node: m.leftNode.into(),
                    right_node: m.rightNode.into(),
                    running_leaf_position,
                    current_height: m.currentHeight,
                    tournament_address,
                    leaf_cycle,
                    inner_tournament: None,
                };
                matches.push(match_state);
            }
        }

        Ok(matches)
    }

    async fn created_matches(&self, tournament_address: Address) -> Result<Vec<MatchCreatedEvent>> {
        let events: Vec<MatchCreatedEvent> = self
            .query_events::<tournament::Tournament::MatchCreated>(None, &tournament_address)
            .await?
            .iter()
            .map(|(event, _)| MatchCreatedEvent {
                id: MatchID {
                    commitment_one: event.one.into(),
                    commitment_two: event.two.into(),
                },
                left_hash: event.leftOfTwo.into(),
            })
            .collect();
        Ok(events)
    }

    async fn joined_commitments(
        &self,
        tournament_address: Address,
    ) -> Result<Vec<CommitmentJoinedEvent>> {
        let events = self
            .query_events::<tournament::Tournament::CommitmentJoined>(None, &tournament_address)
            .await?
            .iter()
            .map(|(event, _)| CommitmentJoinedEvent {
                root: event.commitment.into(),
            })
            .collect();
        Ok(events)
    }

    async fn get_commitment(
        &self,
        tournament_address: Address,
        commitment_hash: Digest,
    ) -> Result<CommitmentState> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let commitment_return = tournament
            .getCommitment(commitment_hash.into())
            .call()
            .await?;

        let block_number = self
            .client
            .get_block(Latest.into())
            .await?
            .expect("cannot get last block")
            .header
            .number;
        let clock_state = ClockState {
            allowance: commitment_return._0.allowance,
            start_instant: commitment_return._0.startInstant,
            block_number,
        };
        Ok(CommitmentState {
            clock: clock_state,
            final_state: commitment_return._1.into(),
            latest_match: None,
        })
    }

    pub async fn fetch_from_root(
        &self,
        root_tournament_address: Address,
    ) -> Result<TournamentStateMap> {
        let mut states = HashMap::new();
        self.fetch_tournament(
            TournamentState::new_root(root_tournament_address),
            &mut states,
        )
        .await?;

        Ok(states)
    }

    #[async_recursion]
    async fn fetch_tournament(
        &self,
        mut state: TournamentState,
        states: &mut TournamentStateMap,
    ) -> Result<()> {
        let tournament_address = state.address;
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let level_constants_return = tournament.tournamentLevelConstants().call().await?;
        (
            state.max_level,
            state.level,
            state.log2_stride,
            state.log2_stride_count,
        ) = (
            level_constants_return._maxLevel,
            level_constants_return._level,
            level_constants_return._log2step,
            level_constants_return._height,
        );

        assert!(state.level < state.max_level, "level out of bounds");

        if state.level > 0 {
            let tournament =
                non_root_tournament::NonRootTournament::new(tournament_address, &self.client);
            state.can_be_eliminated = tournament.canBeEliminated().call().await?;
        }

        let mut captured_matches = self.capture_matches(tournament_address).await?;
        let commitments_joined = self.joined_commitments(tournament_address).await?;

        let mut commitment_states = HashMap::new();
        for commitment in commitments_joined {
            let commitment_state = self
                .get_commitment(tournament_address, commitment.root)
                .await?;
            commitment_states.insert(commitment.root, commitment_state);
        }

        for (i, captured_match) in captured_matches.iter_mut().enumerate() {
            self.fetch_match(captured_match, states, state.level)
                .await?;

            commitment_states
                .get_mut(&captured_match.id.commitment_one)
                .expect("cannot find commitment one state")
                .latest_match = Some(i);
            commitment_states
                .get_mut(&captured_match.id.commitment_two)
                .expect("cannot find commitment two state")
                .latest_match = Some(i);
        }

        let winner = match state.parent {
            Some(_) => self.tournament_winner(tournament_address).await?,
            None => self.root_tournament_winner(tournament_address).await?,
        };

        state.winner = winner;
        state.matches = captured_matches;
        state.commitment_states = commitment_states;

        states.insert(tournament_address, state);

        Ok(())
    }

    #[async_recursion]
    async fn fetch_match(
        &self,
        match_state: &mut MatchState,
        states: &mut TournamentStateMap,
        tournament_level: u64,
    ) -> Result<()> {
        let created_tournament = self
            .created_tournament(match_state.tournament_address, match_state.id)
            .await?;
        if let Some(inner) = created_tournament {
            let inner_tournament = TournamentState::new_inner(
                inner.new_tournament_address,
                tournament_level,
                match_state.leaf_cycle,
                match_state.tournament_address,
            );
            self.fetch_tournament(inner_tournament, states).await?;
            match_state.inner_tournament = Some(inner.new_tournament_address);

            return Ok(());
        }

        Ok(())
    }

    async fn root_tournament_winner(
        &self,
        root_tournament_address: Address,
    ) -> Result<Option<TournamentWinner>> {
        let root_tournament =
            root_tournament::RootTournament::new(root_tournament_address, &self.client);
        let arbitration_result_return = root_tournament.arbitrationResult().call().await?;
        let (finished, commitment, state) = (
            arbitration_result_return._0,
            arbitration_result_return._1,
            arbitration_result_return._2,
        );

        if finished {
            Ok(Some(TournamentWinner::Root(
                commitment.into(),
                state.into(),
            )))
        } else {
            Ok(None)
        }
    }

    async fn tournament_winner(
        &self,
        tournament_address: Address,
    ) -> Result<Option<TournamentWinner>> {
        let tournament =
            non_root_tournament::NonRootTournament::new(tournament_address, &self.client);
        let inner_tournament_winner_return = tournament.innerTournamentWinner().call().await?;
        let (finished, parent_commitment, dangling_commitment) = (
            inner_tournament_winner_return._0,
            inner_tournament_winner_return._1,
            inner_tournament_winner_return._2,
        );

        if finished {
            Ok(Some(TournamentWinner::Inner(
                parent_commitment.into(),
                dangling_commitment.into(),
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

// Below is a simplified version originated from https://github.com/cartesi/state-fold
// ParitionProvider will attempt to fetch events in smaller partition if the original request is too large
#[async_recursion]
async fn get_events<E: SolEvent + Send + Sync>(
    provider: &impl Provider,
    topic1: Option<&Topic>,
    read_from: &Address,
    start_block: u64,
    end_block: u64,
    long_block_range_error_codes: &Vec<String>,
) -> std::result::Result<Vec<(E, Log)>, Vec<Error>> {
    let event: Event<_, _, _> = {
        let mut e = Event::new_sol(provider, read_from)
            .from_block(start_block)
            .to_block(end_block)
            .event(E::SIGNATURE);

        if let Some(t) = topic1 {
            e = e.topic1(t.clone());
        }

        e
    };

    match event.query().await {
        Ok(l) => Ok(l),
        Err(e) => {
            if should_retry_with_partition(&e, long_block_range_error_codes) {
                let middle = {
                    let blocks = 1 + end_block - start_block;
                    let half = blocks / 2;
                    start_block + half - 1
                };

                let first_res = get_events(
                    provider,
                    topic1,
                    read_from,
                    start_block,
                    middle,
                    long_block_range_error_codes,
                )
                .await;

                let second_res = get_events(
                    provider,
                    topic1,
                    read_from,
                    middle + 1,
                    end_block,
                    long_block_range_error_codes,
                )
                .await;

                match (first_res, second_res) {
                    (Ok(mut first), Ok(second)) => {
                        first.extend(second);
                        Ok(first)
                    }

                    (Err(mut first), Err(second)) => {
                        first.extend(second);
                        Err(first)
                    }

                    (Err(err), _) | (_, Err(err)) => Err(err),
                }
            } else {
                Err(vec![e])
            }
        }
    }
}

fn should_retry_with_partition(
    err: &impl std::error::Error,
    long_block_range_error_codes: &Vec<String>,
) -> bool {
    for code in long_block_range_error_codes {
        let s = format!("{:?}", err);
        if s.contains(&code.to_string()) {
            return true;
        }
    }

    false
}
