// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;

use self::error::Result;
use alloy::primitives::{Address, B256};
use alloy::providers::DynProvider;
use log::{debug, info, trace};
use std::{sync::Arc, time::Duration};

use crate::chain::Chain;
use crate::provider::TransactionLane;
use crate::storage::{Epoch, Proof, Storage};
use crate::sync::ShutdownSignal;
use crate::tournament::domain::GcIntent;
use crate::{
    hero::{Hero, HeroTick, TournamentResult},
    tournament::{ArenaSender, gas_limit},
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;

pub struct EpochManager<AS: ArenaSender> {
    arena_sender: Arc<AS>,
    transaction_lane: Arc<TransactionLane>,
    consensus: Address,
    signer_address: Address,
    sleep_duration: Duration,
    storage: Storage,
    epoch_hero: (Option<Hero<AS>>, u64),
}

enum EpochReaction {
    Absent,
    Preparing,
    Ticked(HeroTick),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EpochWritePlan {
    None,
    GarbageCollect(GcIntent),
    Settle {
        garbage_collect_if_idle: Option<GcIntent>,
    },
}

impl EpochReaction {
    /// Selects at most one write lane from one observation. Settlement stays
    /// off the active-dispute lane, including while local dispute material is
    /// still being prepared. The shared transaction lane preserves this
    /// priority across ticks by replacing the same mined nonce.
    fn write_plan(self) -> EpochWritePlan {
        match self {
            Self::Absent => EpochWritePlan::Settle {
                garbage_collect_if_idle: None,
            },
            Self::Preparing => EpochWritePlan::None,
            Self::Ticked(tick) if tick.action_attempted() => EpochWritePlan::None,
            Self::Ticked(tick) if tick.result() == TournamentResult::Running => tick
                .gc_intent()
                .map_or(EpochWritePlan::None, EpochWritePlan::GarbageCollect),
            Self::Ticked(tick) if tick.result() == TournamentResult::Won => {
                EpochWritePlan::Settle {
                    garbage_collect_if_idle: tick.gc_intent(),
                }
            }
            Self::Ticked(_) => EpochWritePlan::None,
        }
    }
}

impl<AS: ArenaSender> EpochManager<AS> {
    pub fn new(
        arena_sender: Arc<AS>,
        transaction_lane: Arc<TransactionLane>,
        consensus_address: Address,
        signer_address: Address,
        storage: Storage,
        sleep_duration: Duration,
    ) -> Self {
        Self {
            arena_sender,
            transaction_lane,
            consensus: consensus_address,
            signer_address,
            sleep_duration,
            storage,
            epoch_hero: (None, 0),
        }
    }

    pub async fn execution_loop(mut self, shutdown: ShutdownSignal, chain: Chain) -> Result<()> {
        let dave_consensus = DaveConsensus::new(self.consensus, chain.provider().clone());

        // A failed iteration is retried, not fatal: every tick is
        // re-derived from storage and chain, so transient provider
        // errors (an RPC hiccup, a pinned read landing on a block the
        // gateway no longer serves) cost one polling interval, never
        // the validator. A BlockOutOfRangeError here killed the node
        // mid-dispute on 2026-07-10 and its clocks kept running.
        // Consensus violations stay fatal: they are asserts, not
        // errors.
        loop {
            let write_plan = match self.try_react_epoch(&chain).await {
                Ok(reaction) => reaction.write_plan(),
                Err(e) => {
                    log::warn!("dispute tick failed, retrying next tick: {e}");
                    EpochWritePlan::None
                }
            };

            match write_plan {
                EpochWritePlan::None => {}
                EpochWritePlan::GarbageCollect(intent) => {
                    if let Err(e) = self.try_gc_epoch(intent).await {
                        log::warn!("cleanup tick failed, retrying next tick: {e}");
                    }
                }
                EpochWritePlan::Settle {
                    garbage_collect_if_idle,
                } => match self.try_settle_epoch(&dave_consensus).await {
                    Ok(false) => {
                        if let Some(intent) = garbage_collect_if_idle
                            && let Err(e) = self.try_gc_epoch(intent).await
                        {
                            log::warn!("cleanup tick failed, retrying next tick: {e}");
                        }
                    }
                    Ok(_) => {}
                    Err(e) => {
                        log::warn!("settle attempt failed, retrying next tick: {e}");
                    }
                },
            }

            tokio::select! { biased;
                _ = shutdown.requested() => break Ok(()),
                _ = tokio::time::sleep(self.sleep_duration) => {}
            }
        }
    }

    /// Drives the staged settlement protocol forward: a sentry claim
    /// when this signer is a sentry, then staging the finished
    /// tournament's result, then accepting it once every sentry
    /// agrees or the claim staging period elapses. Each step is
    /// guarded and idempotent. At most one mutation is attempted so a later
    /// settlement step never queues behind an earlier step from stale state.
    pub async fn try_settle_epoch(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<bool> {
        if self.try_submit_sentry_claim(dave_consensus).await? {
            return Ok(true);
        }
        if self.try_stage_tournament_result(dave_consensus).await? {
            return Ok(true);
        }
        self.try_accept_tournament_result(dave_consensus).await
    }

    /// A sentry claims the post-epoch state it computed itself -
    /// never the staged value - so claims stay an independent check
    /// on the tournament result.
    async fn try_submit_sentry_claim(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<bool> {
        let sentry_id = dave_consensus
            .getSentryId(self.signer_address)
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if sentry_id.is_zero() {
            trace!(
                "signer {} is not a sentry of DaveConsensus@{}",
                self.signer_address,
                dave_consensus.address()
            );
            return Ok(false);
        }

        let current_sealed_epoch = dave_consensus
            .getCurrentSealedEpoch()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;
        let epoch_number = current_sealed_epoch.epochNumber;

        let has_claimed = dave_consensus
            .hasSentryClaimedInEpoch(epoch_number, sentry_id)
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if has_claimed {
            trace!(
                "sentry {} (id {}) has already claimed for epoch {}",
                self.signer_address, sentry_id, epoch_number
            );
            return Ok(false);
        }

        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if can_accept.isTournamentResultStaged && can_accept.isClaimStagingPeriodOver {
            trace!(
                "epoch {} already has a staged result past its staging period; a claim buys nothing",
                epoch_number
            );
            return Ok(false);
        }

        match self.storage.settlement_info(
            u64::try_from(epoch_number).expect("fail to convert epoch number to u64"),
        )? {
            Some(settlement) => {
                let claim = vec_u8_to_bytes_32(settlement.final_state.into());
                info!("submit sentry claim {} for epoch {}", claim, epoch_number);
                let request = dave_consensus
                    .submitSentryClaim(epoch_number, claim)
                    .gas(gas_limit())
                    .into_transaction_request();
                self.transaction_lane
                    .submit("submitSentryClaim", request)
                    .await
                    .map_err(crate::hero::error::ReactError::from)?;
                return Ok(true);
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(false)
    }

    async fn try_stage_tournament_result(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<bool> {
        let can_stage = dave_consensus
            .canStageTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if !can_stage.isFinished || can_stage.isTournamentResultStaged {
            trace!("tournament result not ready to be staged");
            return Ok(false);
        }

        match self.storage.settlement_info(
            u64::try_from(can_stage.epochNumber).expect("fail to convert epoch number to u64"),
        )? {
            Some(settlement) => {
                assert_eq!(
                    settlement.computation_hash.data(),
                    can_stage.winnerCommitment,
                    "Winner commitment mismatch, notify all users!"
                );
                assert_eq!(
                    vec_u8_to_bytes_32(settlement.final_state.into()),
                    can_stage.winnerPostEpochMachineStateHash,
                    "Winner final state mismatch, notify all users!"
                );
                info!(
                    "stage tournament result of epoch {} with claim {}",
                    can_stage.epochNumber,
                    settlement.computation_hash.to_hex()
                );
                let request = dave_consensus
                    .stageTournamentResult(
                        can_stage.epochNumber,
                        vec_u8_to_bytes_32(settlement.outputs_merkle_root.into()),
                        to_bytes_32_vec(settlement.outputs_merkle_root_proof),
                    )
                    .gas(gas_limit())
                    .into_transaction_request();
                self.transaction_lane
                    .submit("stageTournamentResult", request)
                    .await
                    .map_err(crate::hero::error::ReactError::from)?;
                return Ok(true);
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(false)
    }

    async fn try_accept_tournament_result(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<bool> {
        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if !can_accept.isTournamentResultStaged {
            trace!("staged tournament result not ready to be accepted");
            return Ok(false);
        }

        match self.storage.settlement_info(
            u64::try_from(can_accept.epochNumber).expect("fail to convert epoch number to u64"),
        )? {
            Some(settlement) => {
                assert_eq!(
                    vec_u8_to_bytes_32(settlement.final_state.into()),
                    can_accept.stagedPostEpochMachineStateHash,
                    "Staged final state mismatch, notify all users!"
                );
                assert_eq!(
                    vec_u8_to_bytes_32(settlement.outputs_merkle_root.into()),
                    can_accept.stagedPostEpochOutputsMerkleRoot,
                    "Staged outputs Merkle root mismatch, notify all users!"
                );
                if can_accept.doAllSentriesAgreeWithStagedTournamentResult
                    || can_accept.isClaimStagingPeriodOver
                {
                    info!(
                        "settle epoch {}: accept staged tournament result",
                        can_accept.epochNumber
                    );
                    let request = dave_consensus
                        .acceptStagedTournamentResult(can_accept.epochNumber)
                        .gas(gas_limit())
                        .into_transaction_request();
                    self.transaction_lane
                        .submit("acceptStagedTournamentResult", request)
                        .await
                        .map_err(crate::hero::error::ReactError::from)?;
                    return Ok(true);
                }
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(false)
    }

    async fn try_react_epoch(&mut self, chain: &Chain) -> Result<EpochReaction> {
        // participate in last sealed epoch tournament
        if let Some(last_sealed_epoch) = self.storage.last_sealed_epoch()? {
            match self
                .storage
                .settlement_info(last_sealed_epoch.epoch_number)?
            {
                Some(_) => {
                    trace!(
                        "dispute tournaments for epoch {}",
                        last_sealed_epoch.epoch_number
                    );
                    return self
                        .react_dispute(chain, &last_sealed_epoch)
                        .await
                        .map(EpochReaction::Ticked);
                }
                None => {
                    debug!(
                        "wait for `machine-runner` to insert settlement values for epoch {}",
                        last_sealed_epoch.epoch_number
                    );
                    return Ok(EpochReaction::Preparing);
                }
            }
        }
        Ok(EpochReaction::Absent)
    }

    async fn react_dispute(
        &mut self,
        chain: &Chain,
        last_sealed_epoch: &Epoch,
    ) -> Result<HeroTick> {
        self.get_latest_hero(last_sealed_epoch, chain)?;
        let tick = self
            .epoch_hero
            .0
            .as_mut()
            .expect("hero should be instantiated")
            .tick()
            .await?;

        match tick.result() {
            TournamentResult::Running => {}
            TournamentResult::Won => info!(
                "local commitment won dispute tournament for epoch {}",
                last_sealed_epoch.epoch_number
            ),
            TournamentResult::Lost => log::error!(
                "local commitment lost dispute tournament for epoch {}",
                last_sealed_epoch.epoch_number
            ),
            TournamentResult::FailedNoWinner => log::error!(
                "dispute tournament for epoch {} finished without a winner",
                last_sealed_epoch.epoch_number
            ),
        }

        Ok(tick)
    }

    async fn try_gc_epoch(&mut self, intent: GcIntent) -> Result<()> {
        match self.epoch_hero.0.as_mut() {
            Some(hero) => hero.submit_gc(intent).await.map_err(Into::into),
            None => Ok(()),
        }
    }

    fn get_latest_hero(&mut self, last_sealed_epoch: &Epoch, chain: &Chain) -> Result<()> {
        // either the hero has never been instantiated, or the sealed epoch has advanced
        // we need to instantiate new epoch hero with appropriate data
        if self.epoch_hero.0.is_none() || self.epoch_hero.1 != last_sealed_epoch.epoch_number {
            // The hero reads the closed epoch's working set through
            // its own storage handle (one connection per thread).
            let storage = Storage::new(self.storage.state_dir())?;

            let hero = Hero::new(
                self.arena_sender.clone(),
                chain.clone(),
                last_sealed_epoch.root_tournament,
                last_sealed_epoch.block_created_number,
                storage,
                last_sealed_epoch.epoch_number,
            )?;

            self.epoch_hero = (Some(hero), last_sealed_epoch.epoch_number);
        }

        Ok(())
    }
}

fn to_bytes_32_vec(proof: Proof) -> Vec<B256> {
    proof.inner().iter().map(B256::from).collect()
}

fn vec_u8_to_bytes_32(hash: Vec<u8>) -> B256 {
    B256::from_slice(&hash)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gc_intent() -> GcIntent {
        GcIntent::EliminateChild {
            parent_tournament: Address::repeat_byte(0x11),
            child_tournament: Address::repeat_byte(0x22),
        }
    }

    fn tick(
        result: TournamentResult,
        action_attempted: bool,
        gc_intent: Option<GcIntent>,
    ) -> EpochReaction {
        EpochReaction::Ticked(HeroTick::new(result, action_attempted, gc_intent))
    }

    #[test]
    fn epoch_write_plan_preserves_hero_priority_and_one_write_lane() {
        assert_eq!(
            EpochReaction::Absent.write_plan(),
            EpochWritePlan::Settle {
                garbage_collect_if_idle: None
            }
        );
        assert_eq!(EpochReaction::Preparing.write_plan(), EpochWritePlan::None);
        for result in [
            TournamentResult::Running,
            TournamentResult::Won,
            TournamentResult::Lost,
            TournamentResult::FailedNoWinner,
        ] {
            assert_eq!(
                tick(result, true, Some(gc_intent())).write_plan(),
                EpochWritePlan::None
            );
        }
        assert_eq!(
            tick(TournamentResult::Running, false, Some(gc_intent())).write_plan(),
            EpochWritePlan::GarbageCollect(gc_intent())
        );
        assert_eq!(
            tick(TournamentResult::Running, false, None).write_plan(),
            EpochWritePlan::None
        );

        assert_eq!(
            tick(TournamentResult::Won, false, Some(gc_intent())).write_plan(),
            EpochWritePlan::Settle {
                garbage_collect_if_idle: Some(gc_intent())
            }
        );
        assert_eq!(
            tick(TournamentResult::Lost, false, Some(gc_intent())).write_plan(),
            EpochWritePlan::None
        );
        assert_eq!(
            tick(TournamentResult::FailedNoWinner, false, Some(gc_intent())).write_plan(),
            EpochWritePlan::None
        );
    }
}
