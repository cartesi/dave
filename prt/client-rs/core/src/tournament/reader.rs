//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments

use anyhow::Result;
use async_recursion::async_recursion;
use cartesi_machine::types::Hash;
use std::{collections::HashMap, sync::Arc};

use alloy::{
    eips::BlockNumberOrTag::Latest, primitives::U256, providers::DynProvider,
    sol_types::private::Address,
};

use crate::tournament::{ClockState, CommitmentState, MatchState, TournamentArgs, TournamentState};
use cartesi_dave_merkle::Digest;
use cartesi_prt_contracts::{
    nonroottournament, roottournament,
    tournament::{self},
};

use super::{Divergence, MatchStatus, Matchup, TournamentStatus};

#[derive(Clone)]
pub struct StateReader {
    client: DynProvider,
    root_tournament_address: Address,
    levels: u8,
    latest: u64,
    genesis: u64,
}

impl StateReader {
    pub fn new(client: DynProvider, root_tournament_address: Address, genesis: u64) -> Self {
        Self {
            client,
            root_tournament_address,
            levels: 3, // TODO hardcoded
            latest: 0,
            genesis,
        }
    }

    pub async fn read_state(&self) -> Result<TournamentState> {
        self.read_tournament(self.root_tournament_address).await
    }
}

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
    #[async_recursion]
    async fn read_tournament(&self, tournament_address: Address) -> Result<TournamentState> {
        let tournament_args = {
            let tournament = tournament::Tournament::new(tournament_address, &self.client);
            let level_constants_return = tournament.tournamentLevelConstants().call().await?;
            TournamentArgs {
                max_level: level_constants_return._maxLevel as u8,
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

        let matches = self
            .read_matches(
                tournament_address,
                tournament_args.level,
                &commitments_joined,
            )
            .await?;

        Ok(TournamentState {
            address: tournament_address,
            args: tournament_args,
            commitments_joined,
            status: TournamentStatus::Ongoing { matches },
        })
    }

    // #[async_recursion]
    async fn read_matches(
        &self,
        tournament_address: Address,
        level: u8,
        commitments_joined: &HashMap<Digest, Arc<CommitmentState>>,
    ) -> Result<Vec<MatchState>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let created_matches = self.matches_created(tournament_address).await?;

        let mut matches = vec![];
        for pair in created_matches {
            let matchup = Matchup {
                commitment_one: commitments_joined
                    .get(&pair.0)
                    .expect("commitment should always exist")
                    .clone(),
                commitment_two: commitments_joined
                    .get(&pair.1)
                    .expect("commitment should always exist")
                    .clone(),
            };

            let id = matchup.id().into();
            let m = tournament.getMatch(id).call().await?._0;

            if m.otherParent.is_zero() {
                continue;
            }

            let match_state = if level == self.levels {
                // leaf
                MatchState {
                    matchup,
                    status: if m.height == 0 {
                        let divergence = build_divergence!(id, m, tournament);
                        MatchStatus::FinishedLeaf { divergence }
                    } else {
                        MatchStatus::Ongoing {
                            other_parent: m.otherParent.into(),
                            left_node: m.leftNode.into(),
                            right_node: m.rightNode.into(),
                            current_height: m.height,
                        }
                    },
                }
            } else {
                // non leaf
                MatchState {
                    matchup,
                    status: if m.height == 0 {
                        let divergence = build_divergence!(id, m, tournament);
                        MatchStatus::FinishedNonLeaf {
                            divergence,
                            inner_tournament: Box::new(
                                self.read_tournament(tournament_address).await?,
                            ),
                        }
                    } else {
                        MatchStatus::Ongoing {
                            other_parent: m.otherParent.into(),
                            left_node: m.leftNode.into(),
                            right_node: m.rightNode.into(),
                            current_height: m.height,
                        }
                    },
                }
            };

            matches.push(match_state);
        }

        Ok(matches)
    }

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

    async fn matches_created(&self, tournament_address: Address) -> Result<Vec<(Digest, Digest)>> {
        let tournament = tournament::Tournament::new(tournament_address, &self.client);
        let pairs = tournament
            .matchCreated_filter()
            .address(tournament_address)
            .from_block(self.genesis)
            .to_block(self.latest)
            .query()
            .await?
            .iter()
            .map(|event| (event.0.one.into(), event.0.two.into()))
            .collect();
        Ok(pairs)
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
