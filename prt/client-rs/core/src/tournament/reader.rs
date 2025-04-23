//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments

use anyhow::Result;
use async_recursion::async_recursion;
use std::collections::HashMap;

use alloy::{
    eips::BlockNumberOrTag::Latest,
    providers::{DynProvider, Provider},
    sol_types::private::{Address, B256},
};
use num_traits::cast::ToPrimitive;

use crate::{
    machine::constants,
    tournament::{
        ClockState, CommitmentState, MatchID, MatchState, TournamentState, TournamentStateMap,
        TournamentWinner,
    },
};
use cartesi_dave_merkle::Digest;
use cartesi_prt_contracts::{nonleaftournament, nonroottournament, roottournament, tournament};

#[derive(Clone)]
pub struct StateReader {
    client: DynProvider,
    block_created_number: u64,
}

impl StateReader {
    pub fn new(client: DynProvider, block_created_number: u64) -> Result<Self> {
        Ok(Self {
            client,
            block_created_number,
        })
    }

    async fn created_tournament(
        &self,
        tournament_address: Address,
        match_id: MatchID,
    ) -> Result<Option<TournamentCreatedEvent>> {
        let tournament =
            nonleaftournament::NonLeafTournament::new(tournament_address, &self.client);
        let events = tournament
            .newInnerTournament_filter()
            .address(tournament_address)
            .topic1::<B256>(match_id.hash().into())
            .from_block(self.block_created_number)
            .to_block(Latest)
            .query()
            .await?;
        if let Some(event) = events.last() {
            Ok(Some(TournamentCreatedEvent {
                parent_match_id_hash: match_id.hash(),
                new_tournament_address: event.0._1,
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
            let m = tournament.getMatch(match_id.hash().into()).call().await?._0;

            if !m.otherParent.is_zero() || !m.leftNode.is_zero() || !m.rightNode.is_zero() {
                let leaf_cycle = tournament
                    .getMatchCycle(match_id.hash().into())
                    .call()
                    .await?
                    ._0;
                let base_big_cycle = (leaf_cycle >> constants::LOG2_UARCH_SPAN_TO_BARCH)
                    .to_u64()
                    .expect("fail to convert base big cycle");

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
                    base_big_cycle,
                    inner_tournament: None,
                };
                matches.push(match_state);
            }
        }

        Ok(matches)
    }

    async fn created_matches(&self, tournament_address: Address) -> Result<Vec<MatchCreatedEvent>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let events: Vec<MatchCreatedEvent> = tournament
            .matchCreated_filter()
            .address(tournament_address)
            .from_block(self.block_created_number)
            .to_block(Latest)
            .query()
            .await?
            .iter()
            .map(|event| MatchCreatedEvent {
                id: MatchID {
                    commitment_one: event.0.one.into(),
                    commitment_two: event.0.two.into(),
                },
                left_hash: event.0.leftOfTwo.into(),
            })
            .collect();
        Ok(events)
    }

    async fn joined_commitments(
        &self,
        tournament_address: Address,
    ) -> Result<Vec<CommitmentJoinedEvent>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let events = tournament
            .commitmentJoined_filter()
            .address(tournament_address)
            .from_block(self.block_created_number)
            .to_block(Latest)
            .query()
            .await?
            .iter()
            .map(|c| CommitmentJoinedEvent {
                root: c.0.root.into(),
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
            level_constants_return._max_level,
            level_constants_return._level,
            level_constants_return._log2step,
            level_constants_return._height,
        );

        assert!(state.level < state.max_level, "level out of bounds");

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
                match_state.base_big_cycle,
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
            roottournament::RootTournament::new(root_tournament_address, &self.client);
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
            nonroottournament::NonRootTournament::new(tournament_address, &self.client);
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
