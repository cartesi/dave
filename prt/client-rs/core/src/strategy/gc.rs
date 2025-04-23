use ::log::debug;
use alloy::primitives::Address;
use async_recursion::async_recursion;

use crate::strategy::error::Result;
use crate::tournament::{ArenaSender, MatchState, TournamentStateMap};

pub struct GarbageCollector {
    root_tournamet: Address,
}

impl GarbageCollector {
    pub fn new(root_tournamet: Address) -> Self {
        Self { root_tournamet }
    }

    pub async fn react_once<'a>(
        &self,
        arena_sender: &'a impl ArenaSender,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        self.react_tournament(arena_sender, self.root_tournamet, tournament_states)
            .await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &self,
        arena_sender: &'a impl ArenaSender,
        tournament_address: Address,
        tournament_states: &TournamentStateMap,
    ) -> Result<()> {
        let tournament_state = tournament_states
            .get(&tournament_address)
            .expect("tournament state not found");

        for m in tournament_state.matches.iter() {
            self.react_match(arena_sender, m, tournament_states, tournament_address)
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

                arena_sender
                    .eliminate_match(tournament_address, m.id)
                    .await?;
            }
        }
        Ok(())
    }

    #[async_recursion]
    async fn react_match<'a>(
        &self,
        arena_sender: &'a impl ArenaSender,
        match_state: &MatchState,
        tournament_states: &TournamentStateMap,
        tournament_address: Address,
    ) -> Result<()> {
        debug!(
            "Garbage collect match at HEIGHT: {}, of tournament: {}",
            match_state.current_height, tournament_address
        );
        if let Some(inner_tournament) = match_state.inner_tournament {
            self.react_tournament(arena_sender, inner_tournament, tournament_states)
                .await?;
        }
        Ok(())
    }
}
