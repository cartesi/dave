//! The bond sweeper: eliminates matches both of whose commitments ran
//! out of clock, and inner tournaments the chain marks eliminable.
//! Pure housekeeping - the Hero wins disputes; the sweep frees bonds.

use ::log::debug;
use alloy::primitives::Address;
use async_recursion::async_recursion;
use std::sync::Arc;

use crate::hero::error::Result;
use crate::tournament::{ArenaSender, DisputeState};

pub struct GarbageCollector<AS: ArenaSender> {
    arena_sender: Arc<AS>,
    root_tournament: Address,
}

impl<AS: ArenaSender> GarbageCollector<AS> {
    pub fn new(arena_sender: Arc<AS>, root_tournament: Address) -> Self {
        Self {
            arena_sender,
            root_tournament,
        }
    }

    pub async fn tick(&self, dispute: &DisputeState) -> Result<()> {
        self.react_tournament(self.root_tournament, dispute).await
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &self,
        tournament_address: Address,
        dispute: &DisputeState,
    ) -> Result<()> {
        let (tournament, overlay) = dispute
            .tournament(&tournament_address)
            .expect("the sweep only descends into reachable tournaments");

        for m in tournament.live_matches() {
            // An eliminable inner tournament dies wholesale; otherwise
            // sweep inside it first, innermost eliminations leading.
            if let Some(inner_address) = m.inner_tournament {
                let (inner, inner_overlay) = dispute
                    .tournament(&inner_address)
                    .expect("a live sealed match's inner tournament is reachable");

                if inner_overlay.can_be_eliminated {
                    debug!(
                        "eliminate inner tournament {inner_address} of level {}, child of tournament {tournament_address}",
                        inner.level
                    );
                    self.arena_sender
                        .eliminate_inner_tournament(tournament_address, inner_address)
                        .await?;
                } else {
                    self.react_tournament(inner_address, dispute).await?;
                }
            }

            let clock_one = overlay
                .clocks
                .get(&m.id.commitment_one)
                .expect("every joined commitment carries a clock");
            let clock_two = overlay
                .clocks
                .get(&m.id.commitment_two)
                .expect("every joined commitment carries a clock");
            if (!clock_one.has_time() && (clock_one.time_since_timeout() > clock_two.allowance))
                || (!clock_two.has_time() && (clock_two.time_since_timeout() > clock_one.allowance))
            {
                debug!(
                    "eliminate match for commitment {} and {} at tournament {} of level {}",
                    m.id.commitment_one, m.id.commitment_two, tournament_address, tournament.level
                );

                self.arena_sender
                    .eliminate_match(tournament_address, m.id)
                    .await?;
            }
        }
        Ok(())
    }
}
