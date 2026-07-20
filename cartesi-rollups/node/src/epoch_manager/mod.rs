// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;

use self::error::Result;
use alloy::primitives::{Address, B256};
use alloy::providers::DynProvider;
use log::{debug, info, trace};
use std::{sync::Arc, time::Duration};

use crate::chain::Chain;
use crate::storage::{Epoch, Proof, Storage};
use crate::sync::ShutdownSignal;
use crate::{
    hero::Hero,
    tournament::{ArenaSender, allow_revert_rethrow_others},
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;

pub struct EpochManager<AS: ArenaSender> {
    arena_sender: Arc<AS>,
    consensus: Address,
    signer_address: Address,
    sleep_duration: Duration,
    storage: Storage,
    epoch_hero: (Option<Hero<AS>>, u64),
}

impl<AS: ArenaSender> EpochManager<AS> {
    pub fn new(
        arena_sender: Arc<AS>,
        consensus_address: Address,
        signer_address: Address,
        storage: Storage,
        sleep_duration: Duration,
    ) -> Self {
        Self {
            arena_sender,
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
            if let Err(e) = self.try_settle_epoch(&dave_consensus).await {
                log::warn!("settle attempt failed, retrying next tick: {e}");
            }
            if let Err(e) = self.try_react_epoch(&chain).await {
                log::warn!("dispute tick failed, retrying next tick: {e}");
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
    /// guarded and idempotent, so one tick can advance whichever
    /// step the chain is ready for.
    pub async fn try_settle_epoch(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<()> {
        self.try_submit_sentry_claim(dave_consensus).await?;
        self.try_stage_tournament_result(dave_consensus).await?;
        self.try_accept_tournament_result(dave_consensus).await?;
        Ok(())
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
    ) -> Result<()> {
        let sentry_id = dave_consensus
            .getSentryId(self.signer_address)
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;

        if sentry_id.is_zero() {
            trace!(
                "signer {} is not a sentry of DaveConsensus@{}",
                self.signer_address,
                dave_consensus.address()
            );
            return Ok(());
        }

        let current_sealed_epoch = dave_consensus
            .getCurrentSealedEpoch()
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;
        let epoch_number = current_sealed_epoch.epochNumber;

        let has_claimed = dave_consensus
            .hasSentryClaimedInEpoch(epoch_number, sentry_id)
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;

        if has_claimed {
            trace!(
                "sentry {} (id {}) has already claimed for epoch {}",
                self.signer_address, sentry_id, epoch_number
            );
            return Ok(());
        }

        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;

        if can_accept.isTournamentResultStaged && can_accept.isClaimStagingPeriodOver {
            trace!(
                "epoch {} already has a staged result past its staging period; a claim buys nothing",
                epoch_number
            );
            return Ok(());
        }

        match self.storage.settlement_info(
            u64::try_from(epoch_number).expect("fail to convert epoch number to u64"),
        )? {
            Some(settlement) => {
                let claim = vec_u8_to_bytes_32(settlement.final_state.into());
                info!("submit sentry claim {} for epoch {}", claim, epoch_number);
                let tx_result = dave_consensus
                    .submitSentryClaim(epoch_number, claim)
                    .send()
                    .await;
                allow_revert_rethrow_others("submitSentryClaim", tx_result).await?;
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(())
    }

    async fn try_stage_tournament_result(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<()> {
        let can_stage = dave_consensus
            .canStageTournamentResult()
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;

        if !can_stage.isFinished || can_stage.isTournamentResultStaged {
            trace!("tournament result not ready to be staged");
            return Ok(());
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
                let tx_result = dave_consensus
                    .stageTournamentResult(
                        can_stage.epochNumber,
                        vec_u8_to_bytes_32(settlement.output_merkle.into()),
                        to_bytes_32_vec(settlement.output_proof),
                    )
                    .send()
                    .await;
                allow_revert_rethrow_others("stageTournamentResult", tx_result).await?;
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(())
    }

    async fn try_accept_tournament_result(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<()> {
        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(alloy::eips::BlockId::pending())
            .call()
            .await?;

        if !can_accept.isTournamentResultStaged {
            trace!("staged tournament result not ready to be accepted");
            return Ok(());
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
                    vec_u8_to_bytes_32(settlement.output_merkle.into()),
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
                    let tx_result = dave_consensus
                        .acceptStagedTournamentResult(can_accept.epochNumber)
                        .send()
                        .await;
                    allow_revert_rethrow_others("acceptStagedTournamentResult", tx_result).await?;
                }
            }
            None => {
                trace!("wait for the `machine-runner` to insert the value");
            }
        }
        Ok(())
    }

    async fn try_react_epoch(&mut self, chain: &Chain) -> Result<()> {
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
                    self.react_dispute(chain, &last_sealed_epoch).await?
                }
                None => {
                    debug!(
                        "wait for `machine-runner` to insert settlement values for epoch {}",
                        last_sealed_epoch.epoch_number
                    );
                }
            }
        }
        Ok(())
    }

    async fn react_dispute(&mut self, chain: &Chain, last_sealed_epoch: &Epoch) -> Result<()> {
        self.get_latest_hero(last_sealed_epoch, chain)?;
        self.epoch_hero
            .0
            .as_mut()
            .expect("hero should be instantiated")
            .tick()
            .await?;

        Ok(())
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
