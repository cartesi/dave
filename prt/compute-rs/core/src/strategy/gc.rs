use ::log::info;
use anyhow::Result;
use async_recursion::async_recursion;
use ethers::types::Address;

use crate::arena::{ArenaSender, MatchState, TournamentStateMap};

pub struct GarbageCollector {
    root_tournamet: Address,
}

impl GarbageCollector {
    pub fn new(root_tournamet: Address) -> Self {
        Self { root_tournamet }
    }

    pub async fn react<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        tournament_states: TournamentStateMap,
    ) -> Result<()> {
        self.react_tournament(arena_sender, self.root_tournamet, tournament_states)
            .await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        tournament_address: Address,
        tournament_states: TournamentStateMap,
    ) -> Result<()> {
        info!("Enter tournament at address: {}", tournament_address);
        let tournament_state = tournament_states
            .get(&tournament_address)
            .expect("tournament state not found");

        for m in tournament_state.matches.clone() {
            self.react_match(arena_sender, &m, tournament_states.clone())
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
                info!(
                    "eliminate match for commitment {} and {} at tournament {} of level {}",
                    m.id.commitment_one,
                    m.id.commitment_two,
                    tournament_address,
                    tournament_state.level
                );

                arena_sender
                    .eliminate_match(tournament_address, m.id)
                    .await
                    .expect("fail to eliminate match");
            }
        }
        Ok(())
    }

    #[async_recursion]
    async fn react_match<'a>(
        &mut self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        tournament_states: TournamentStateMap,
    ) -> Result<()> {
        info!("Enter match at HEIGHT: {}", match_state.current_height);
        if let Some(inner_tournament) = match_state.inner_tournament {
            return self
                .react_tournament(arena_sender, inner_tournament, tournament_states)
                .await;
        }

        Ok(())
    }
}
