// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;
mod recovery;

use self::error::Result;
use self::recovery::BondRecovery;
use alloy::primitives::{Address, B256};
use alloy::providers::DynProvider;
use log::{debug, info, trace};
use std::{sync::Arc, time::Duration};

use crate::chain::Chain;
use crate::provider::{LaneRequest, TransactionLane};
use crate::storage::{Epoch, Proof, Storage};
use crate::sync::ShutdownSignal;
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
    bond_recovery: BondRecovery,
}

enum EpochReaction {
    Absent,
    Preparing,
    Ticked(HeroTick),
}

impl EpochReaction {
    /// Settlement steps run only while no dispute is being contested:
    /// before this epoch has local material (an earlier epoch may
    /// still be settling) or once the tournament is won. The step, if
    /// any, takes the wave's base nonce; the tick's own wave fills
    /// strictly above it, so settlement never queues behind dispute
    /// work.
    fn wants_settlement(&self) -> bool {
        match self {
            Self::Absent => true,
            Self::Preparing => false,
            Self::Ticked(tick) => tick.result() == TournamentResult::Won,
        }
    }

    fn into_wave(self) -> Vec<LaneRequest> {
        match self {
            Self::Ticked(tick) => tick.into_wave(),
            Self::Absent | Self::Preparing => Vec::new(),
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
            bond_recovery: BondRecovery::new(signer_address),
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
            let mut wave = match self.try_react_epoch(&chain).await {
                Ok(reaction) => {
                    let settlement = if reaction.wants_settlement() {
                        match self.plan_settlement(&dave_consensus).await {
                            Ok(step) => step,
                            Err(e) => {
                                log::warn!("settlement planning failed, retrying next tick: {e}");
                                None
                            }
                        }
                    } else {
                        None
                    };
                    settlement
                        .into_iter()
                        .chain(reaction.into_wave())
                        .collect::<Vec<_>>()
                }
                Err(e) => {
                    log::warn!("dispute tick failed, retrying next tick: {e}");
                    Vec::new()
                }
            };

            // Bond recovery rides the tail of every wave: nothing in
            // the protocol waits on it, and it spans epochs, so it
            // plans independently of the dispute phases above. Any
            // sealed epoch's root anchors clone verification.
            match self.plan_bond_recovery(&chain).await {
                Ok(recovery) => wave.extend(recovery),
                Err(e) => {
                    log::warn!("bond recovery planning failed, retrying next tick: {e}");
                }
            }

            if !wave.is_empty()
                && let Err(e) = self.transaction_lane.submit_wave(wave).await
            {
                log::warn!("wave submission failed, retrying next tick: {e}");
            }

            tokio::select! { biased;
                _ = shutdown.requested() => break Ok(()),
                _ = tokio::time::sleep(self.sleep_duration) => {}
            }
        }
    }

    /// Plans the next staged-settlement step: a sentry claim when
    /// this signer is a sentry, then staging the finished
    /// tournament's result, then accepting it once every sentry
    /// agrees or the claim staging period elapses. Each step is
    /// guarded and idempotent; its content derives from finalized
    /// ingestion while the whether-still-needed guards read latest,
    /// which is what stops resubmission within a block of inclusion.
    /// At most one step is planned so a later settlement step never
    /// queues behind an earlier step from stale state.
    pub async fn plan_settlement(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<Option<LaneRequest>> {
        if let Some(step) = self.plan_sentry_claim(dave_consensus).await? {
            return Ok(Some(step));
        }
        if let Some(step) = self.plan_stage_tournament_result(dave_consensus).await? {
            return Ok(Some(step));
        }
        self.plan_accept_tournament_result(dave_consensus).await
    }

    /// A sentry claims the post-epoch state it computed itself -
    /// never the staged value - so claims stay an independent check
    /// on the tournament result.
    async fn plan_sentry_claim(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<Option<LaneRequest>> {
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
            return Ok(None);
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
            return Ok(None);
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
            return Ok(None);
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
                return Ok(Some(("submitSentryClaim".to_string(), request)));
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(None)
    }

    async fn plan_stage_tournament_result(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<Option<LaneRequest>> {
        let can_stage = dave_consensus
            .canStageTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if !can_stage.isFinished || can_stage.isTournamentResultStaged {
            trace!("tournament result not ready to be staged");
            return Ok(None);
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
                return Ok(Some(("stageTournamentResult".to_string(), request)));
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(None)
    }

    async fn plan_accept_tournament_result(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<Option<LaneRequest>> {
        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if !can_accept.isTournamentResultStaged {
            trace!("staged tournament result not ready to be accepted");
            return Ok(None);
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
                    return Ok(Some(("acceptStagedTournamentResult".to_string(), request)));
                }
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(None)
    }

    async fn plan_bond_recovery(&mut self, chain: &Chain) -> Result<Vec<LaneRequest>> {
        let trusted_root = self
            .storage
            .last_sealed_epoch()?
            .map(|epoch| epoch.root_tournament);
        self.bond_recovery
            .plan(chain, trusted_root)
            .await
            .map_err(crate::hero::error::ReactError::from)
            .map_err(Into::into)
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
    use alloy::rpc::types::TransactionRequest;

    fn tick_wave(labels: &[&str]) -> Vec<LaneRequest> {
        labels
            .iter()
            .map(|label| (label.to_string(), TransactionRequest::default()))
            .collect()
    }

    fn ticked(result: TournamentResult, labels: &[&str]) -> EpochReaction {
        EpochReaction::Ticked(HeroTick::new(result, tick_wave(labels)))
    }

    #[test]
    fn settlement_rides_only_undisputed_phases_and_tick_waves_pass_through() {
        assert!(EpochReaction::Absent.wants_settlement());
        assert!(!EpochReaction::Preparing.wants_settlement());
        for (result, wants) in [
            (TournamentResult::Running, false),
            (TournamentResult::Won, true),
            (TournamentResult::Lost, false),
            (TournamentResult::FailedNoWinner, false),
        ] {
            assert_eq!(
                ticked(result, &["heroAction", "eliminateMatchByTimeout"]).wants_settlement(),
                wants,
                "settlement gating for {result:?}"
            );
        }

        assert!(EpochReaction::Absent.into_wave().is_empty());
        assert!(EpochReaction::Preparing.into_wave().is_empty());
        let labels: Vec<String> = ticked(
            TournamentResult::Running,
            &["heroAction", "eliminateMatchByTimeout"],
        )
        .into_wave()
        .into_iter()
        .map(|(label, _)| label)
        .collect();
        assert_eq!(
            labels,
            vec!["heroAction", "eliminateMatchByTimeout"],
            "the tick's wave order is preserved"
        );
    }
}
