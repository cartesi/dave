use ::log::debug;
use alloy::primitives::Address;
use async_recursion::async_recursion;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::strategy::error::Result;
use crate::tournament::{ArenaSender, MatchState, TournamentStateMap};

pub struct GarbageCollector<AS: ArenaSender> {
    arena_sender: Arc<Mutex<AS>>,
    root_tournamet: Address,
}

impl<AS: ArenaSender> GarbageCollector<AS> {
    pub fn new(arena_sender: Arc<Mutex<AS>>, root_tournamet: Address) -> Self {
        Self {
            arena_sender,
            root_tournamet,
        }
    }

    pub async fn react(&self, tournament_states: &TournamentStateMap) -> Result<()> {
        self.react_tournament(self.root_tournamet, tournament_states)
            .await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &self,
        tournament_address: Address,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        let tournament_state = tournament_states
            .get(&tournament_address)
            .expect("tournament state not found");

        for m in tournament_state.matches.iter() {
            self.react_match(m, tournament_states, tournament_address)
                .await?;

            let status_1 = tournament_state
                .commitment_states
                .get(&m.id.commitment_one)
                .expect("status of commitment 1 not found");
            let status_2 = tournament_state
                .commitment_states
                .get(&m.id.commitment_two)
                .expect("status of commitment 2 not found");
            if (!status_1.clock.has_time()
                && (status_1.clock.time_since_timeout() > status_2.clock.allowance))
                || (!status_2.clock.has_time()
                    && (status_2.clock.time_since_timeout() > status_1.clock.allowance))
            {
                debug!(
                    "eliminate match for commitment {} and {} at tournament {} of level {}",
                    m.id.commitment_one,
                    m.id.commitment_two,
                    tournament_address,
                    tournament_state.level
                );

                self.arena_sender
                    .lock()
                    .await
                    .eliminate_match(tournament_address, m.id)
                    .await?;
            }
        }
        Ok(())
    }

    #[async_recursion]
    async fn react_match<'a>(
        &self,
        match_state: &MatchState,
        tournament_states: &TournamentStateMap,
        tournament_address: Address,
    ) -> Result<()> {
        if let Some(inner_tournament_address) = match_state.inner_tournament {
            let inner_tournament_state = tournament_states
                .get(&inner_tournament_address)
                .expect("tournament state not found");

            if inner_tournament_state.can_be_eliminated {
                debug!(
                    "eliminate inner tournament {inner_tournament_address} of level {}, child of tournament {tournament_address}",
                    inner_tournament_state.level
                );
                self.arena_sender
                    .lock()
                    .await
                    .eliminate_inner_tournament(tournament_address, inner_tournament_address)
                    .await?;
            } else {
                self.react_tournament(inner_tournament_address, tournament_states)
                    .await?;
            }
        }
        Ok(())
    }
}
