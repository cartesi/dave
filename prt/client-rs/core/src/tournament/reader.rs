//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments

use anyhow::Result;
use async_recursion::async_recursion;
use cartesi_machine::types::Hash;
use std::{collections::HashMap, sync::Arc};

use alloy::{
    eips::BlockNumberOrTag::Latest,
    primitives::U256,
    providers::{DynProvider, Provider},
    sol_types::private::{Address, B256},
};

use crate::tournament::{
    ClockState, CommitmentState, MatchID, MatchState, TournamentArgs, TournamentState,
    TournamentStateMap,
};
use cartesi_dave_merkle::Digest;
use cartesi_prt_contracts::{
    leaftournament::LeafTournament::LeafTournamentInstance,
    nonleaftournament, nonroottournament, roottournament,
    tournament::{self, Tournament::TournamentInstance},
};

use super::{Divergence, MatchStatus, TournamentStatus};

#[derive(Clone)]
pub struct StateReader {
    client: DynProvider,
    root_tournament_address: Address,
    latest: u64,
    genesis: u64,
}

impl StateReader {
    pub fn new(client: DynProvider, root_tournament_address: Address, genesis: u64) -> Self {
        Self {
            client,
            root_tournament_address,
            genesis,
        }
    }

    pub async fn read_state(&self) -> Result<TournamentState> {
        self.fetch_tournament(
            TournamentState::new_root(self.root_tournament_address),
            &mut states,
        )
        .await?;

        Ok(states)
    }
}

// async fn divergence(
//     match_id: B256,
//     match_state: tournament::Match::State,
//     tournament: TournamentInstance<(), impl Provider>,
// ) -> Result<Divergence> {
//     let leaf_cycle = tournament.getMatchCycle(match_id).call().await?._0;
//     Ok(Divergence {
//         agree: match_state.otherParent.into(),
//         p1_disagree: match_state.leftNode.into(),
//         p2_disagree: match_state.rightNode.into(),
//         agree_metacycle: leaf_cycle,
//     })
// }
//     ($match_id:expr, $match_state:expr, $tournament:expr $(,)?) => {{
//         let leaf_cycle = $tournament.getMatchCycle($match_id).call().await?._0;
//         Divergence {
//             agree: $match_state.otherParent.into(),
//             p1_disagree: $match_state.leftNode.into(),
//             p2_disagree: $match_state.rightNode.into(),
//             agree_metacycle: leaf_cycle,
//         }
//     }};
macro_rules! build_divergence {
    ($match_id:expr, $match_state:expr, $tournament:expr $(,)?) => {{
        let leaf_cycle = $tournament.getMatchCycle($match_id).call().await?._0;
        Divergence {
            agree: $match_state.otherParent.into(),
            p1_disagree: $match_state.leftNode.into(),
            p2_disagree: $match_state.rightNode.into(),
            agree_metacycle: leaf_cycle,
        }
    }};
}

impl StateReader {
    async fn commitments_joined(
        &self,
        tournament_address: Address,
    ) -> Result<HashMap<Digest, Arc<CommitmentState>>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let events = tournament
            .commitmentJoined_filter()
            .address(tournament_address)
            .from_block(self.genesis)
            .to_block(Latest)
            .query()
            .await?;

        let mut joined = HashMap::with_capacity(events.len());
        for (commitment, _) in events {
            let c = self
                .read_commitment(tournament_address, commitment.root.into())
                .await?;

            joined.insert(c.root_hash, Arc::new(c));
        }

        Ok(joined)
    }

    async fn read_commitment(
        &self,
        tournament_address: Address,
        commitment_hash: Digest,
    ) -> Result<CommitmentState> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);

        let commitment = tournament
            .getCommitment(commitment_hash.into())
            .block(self.latest.into())
            .call()
            .await?;

        let clock = ClockState::new(
            self.latest,
            commitment._0.startInstant,
            commitment._0.allowance,
        );

        Ok(CommitmentState {
            root_hash: commitment_hash,
            clock,
        })
    }

    // async fn created_tournament(
    //     &self,
    //     tournament_address: Address,
    //     match_id: MatchID,
    // ) -> Result<Option<TournamentCreatedEvent>> {
    //     let tournament =
    //         nonleaftournament::NonLeafTournament::new(tournament_address, &self.client);
    //     let events = tournament
    //         .newInnerTournament_filter()
    //         .address(tournament_address)
    //         .topic1::<B256>(match_id.hash().into())
    //         .from_block(self.block_created_number)
    //         .to_block(Latest)
    //         .query()
    //         .await?;
    //     if let Some(event) = events.last() {
    //         Ok(Some(TournamentCreatedEvent {
    //             parent_match_id_hash: match_id.hash(),
    //             new_tournament_address: event.0._1,
    //         }))
    //     } else {
    //         Ok(None)
    //     }
    // }

    async fn matches_created(&self, tournament_address: Address) -> Result<Vec<MatchCreatedEvent>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let events: Vec<MatchCreatedEvent> = tournament
            .matchCreated_filter()
            .address(tournament_address)
            .from_block(self.genesis)
            .to_block(self.latest)
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

    async fn read_non_leaf_match(
        &self,
        tournament: LeafTournamentInstance<(), impl Provider>,
        match_id: MatchID,
    ) -> Result<Option<MatchState>> {
        let m = tournament.getMatch(match_id.hash()).call().await?._0;
        if m.otherParent.is_zero() {
            return Ok(None);
        }

        Ok(Some(MatchState {
            id: match_id,
            status: if m.height == 0 {
                let divergence = build_divergence!(match_id.hash().into(), m, tournament);
                MatchStatus::FinishedNonLeaf {
                    divergence,
                    inner_tournament: todo!(),
                }
            } else {
                MatchStatus::Ongoing {
                    other_parent: m.otherParent.into(),
                    left_node: m.leftNode.into(),
                    right_node: m.rightNode.into(),
                    current_height: m.height,
                }
            },
        }))
    }

    async fn read_leaf_match(
        &self,
        tournament: LeafTournamentInstance<(), impl Provider>,
        match_id: MatchID,
    ) -> Result<Option<MatchState>> {
        let m = tournament.getMatch(match_id.hash()).call().await?._0;
        if m.otherParent.is_zero() {
            return Ok(None);
        }

        Ok(Some(MatchState {
            id: match_id,
            status: if m.height == 0 {
                let divergence = build_divergence!(match_id.hash().into(), m, tournament);
                MatchStatus::FinishedLeaf { divergence }
            } else {
                MatchStatus::Ongoing {
                    other_parent: m.otherParent.into(),
                    left_node: m.leftNode.into(),
                    right_node: m.rightNode.into(),
                    current_height: m.height,
                }
            },
        }))
    }

    async fn read_matches(
        &self,
        tournament_address: Address,
    ) -> Result<HashMap<Digest, CommitmentState>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let created_matches = self.matches_created(tournament_address).await?;

        let mut matches = vec![];
        for match_event in created_matches {
            let match_id = match_event.id;
            let m = tournament.getMatch(match_id.hash().into()).call().await?._0;

            if !m.otherParent.is_zero() {
                let leaf_cycle = tournament
                    .getMatchCycle(match_id.hash().into())
                    .call()
                    .await?
                    ._0;
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

    // #[async_recursion]
    async fn read_tournament(&self, tournament_address: Address) -> Result<TournamentState> {
        let tournament_args = {
            let tournament = tournament::Tournament::new(tournament_address, &self.client);
            let level_constants_return = tournament.tournamentLevelConstants().call().await?;
            TournamentArgs {
                level: level_constants_return._level as u8,
                start_metacycle: U256::ZERO, // TODO!!
                log2_stride: level_constants_return._log2step,
                log2_stride_count: level_constants_return._height,
            }
        };

        let commitments_joined = self.commitments_joined(tournament_address).await?;

        if tournament_args.level > 0 {
            let tournament =
                nonroottournament::NonRootTournament::new(tournament_address, &self.client);
            let can_be_eliminated = tournament.canBeEliminated().call().await?._0;

            if can_be_eliminated {
                return Ok(TournamentState {
                    address: tournament_address,
                    args: tournament_args,
                    commitments_joined,
                    status: TournamentStatus::Dead,
                });
            }
        }

        let winner = if tournament_args.level == 0 {
            self.root_tournament_winner(tournament_address).await?
        } else {
            self.tournament_winner(tournament_address).await?
        };

        if let Some((winner_commitment, final_state)) = winner {
            return Ok(TournamentState {
                address: tournament_address,
                args: tournament_args,
                commitments_joined,
                status: TournamentStatus::Finished {
                    winner_commitment,
                    final_state,
                },
            });
        }

        let mut captured_matches = self.capture_matches(tournament_address).await?;

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
    ) -> Result<Option<(Digest, Hash)>> {
        let root_tournament =
            roottournament::RootTournament::new(root_tournament_address, &self.client);
        let arbitration_result_return = root_tournament.arbitrationResult().call().await?;
        let (finished, commitment, state) = (
            arbitration_result_return._0,
            arbitration_result_return._1,
            arbitration_result_return._2,
        );

        if finished {
            Ok(Some((commitment.into(), state.into())))
        } else {
            Ok(None)
        }
    }

    async fn tournament_winner(
        &self,
        tournament_address: Address,
    ) -> Result<Option<(Digest, Hash)>> {
        let tournament =
            nonroottournament::NonRootTournament::new(tournament_address, &self.client);
        let inner_tournament_winner_return = tournament.innerTournamentWinner().call().await?;
        let (finished, parent_commitment, dangling_commitment) = (
            inner_tournament_winner_return._0,
            inner_tournament_winner_return._1,
            inner_tournament_winner_return._2,
        );

        if finished {
            Ok(Some((parent_commitment.into(), dangling_commitment.into())))
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
