use std::{collections::HashMap, error::Error};

use ::log::info;
use async_recursion::async_recursion;
use ethers::types::Address;

use crate::arena::{Arena, MatchState, TournamentState};

#[derive(Debug)]
pub enum PlayerTournamentResult {
    TournamentWon,
    TournamentLost,
}

pub struct GarbageCollector<A: Arena> {
    arena: A,
    root_tournamet: Address,
}

impl<A: Arena> GarbageCollector<A> {
    pub fn new(arena: A, root_tournamet: Address) -> Self {
        Self {
            arena,
            root_tournamet,
        }
    }

    pub async fn react(&mut self) -> Result<(), Box<dyn Error>> {
        let tournament_states = self.arena.fetch_from_root(self.root_tournamet).await?;
        self.react_tournament(self.root_tournamet, tournament_states)
            .await
    }

    #[async_recursion]
    async fn react_tournament(
        &mut self,
        tournament_address: Address,
        tournament_states: HashMap<Address, TournamentState>,
    ) -> Result<(), Box<dyn Error>> {
        info!("Enter tournament at address: {}", tournament_address);
        let tournament_state = tournament_states
            .get(&tournament_address)
            .expect("tournament state not found");

        for m in tournament_state.matches.clone() {
            self.react_match(&m, tournament_states.clone()).await?;

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
                info!(
                    "eliminate match for commitment {} and {} at tournament {} of level {}",
                    m.id.commitment_one,
                    m.id.commitment_two,
                    tournament_address,
                    tournament_state.level
                );

                self.arena
                    .eliminate_match(tournament_address, m.id)
                    .await
                    .expect("fail to eliminate match");
            }
        }
        Ok(())
    }

    #[async_recursion]
    async fn react_match(
        &mut self,
        match_state: &MatchState,
        tournament_states: HashMap<Address, TournamentState>,
    ) -> Result<(), Box<dyn Error>> {
        info!("Enter match at HEIGHT: {}", match_state.current_height);
        if let Some(inner_tournament) = match_state.inner_tournament {
            return self
                .react_tournament(inner_tournament, tournament_states)
                .await;
        }

        Ok(())
    }
}
