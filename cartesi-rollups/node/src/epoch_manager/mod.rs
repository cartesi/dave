// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;
mod recovery;

use self::error::Result;
use self::recovery::BondRecovery;
use alloy::primitives::{Address, B256, U256};
use alloy::providers::DynProvider;
use log::{debug, info, trace};
use std::{sync::Arc, time::Duration};

use crate::chain::Chain;
use crate::provider::{LaneRequest, TransactionLane};
use crate::storage::{
    Epoch, LeafProof as StoredLeafProof, MachineValidityProof as StoredMachineValidityProof,
    Storage,
};
use crate::sync::ShutdownSignal;
use crate::{
    hero::{Hero, HeroTick, TournamentResult},
    tournament::{ArenaSender, gas_limit},
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;

pub struct EpochManager<AS: ArenaSender> {
    arena_sender: Arc<AS>,
    transaction_lane: TransactionLane,
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

    /// Recovery is maintenance: it runs only when the current epoch
    /// has no clock-bearing work and its state was observed without an
    /// error. A non-empty settlement or hero wave adds a second fence
    /// in the execution loop.
    fn allows_recovery(&self) -> bool {
        match self {
            Self::Absent => true,
            Self::Preparing => false,
            Self::Ticked(tick) => tick.result() != TournamentResult::Running,
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
        transaction_lane: TransactionLane,
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
            let (wave, recovery_allowed) = match self.try_react_epoch(&chain).await {
                Ok(reaction) => {
                    let mut recovery_allowed = reaction.allows_recovery();
                    let settlement = if reaction.wants_settlement() {
                        match self.plan_settlement(&dave_consensus).await {
                            Ok(step) => {
                                if step.is_some() {
                                    recovery_allowed = false;
                                }
                                step
                            }
                            Err(e) => {
                                recovery_allowed = false;
                                log::warn!("settlement planning failed, retrying next tick: {e}");
                                None
                            }
                        }
                    } else {
                        None
                    };
                    (
                        settlement
                            .into_iter()
                            .chain(reaction.into_wave())
                            .collect::<Vec<_>>(),
                        recovery_allowed,
                    )
                }
                Err(e) => {
                    log::warn!("dispute tick failed, retrying next tick: {e}");
                    (Vec::new(), false)
                }
            };

            if !wave.is_empty() {
                // Submit clock-bearing and settlement work before any
                // recovery RPC scan can delay it.
                if let Err(e) = self.transaction_lane.submit_wave(wave).await {
                    log::warn!("wave submission failed, retrying next tick: {e}");
                }
            } else if recovery_allowed {
                match self.latest_epoch_is_finalized(&dave_consensus).await {
                    Ok(true) => match self.plan_bond_recovery(&chain).await {
                        Ok(Some(recovery)) => {
                            if let Err(e) = self.transaction_lane.submit_wave(vec![recovery]).await
                            {
                                log::warn!("bond recovery submission failed, retrying later: {e}");
                            }
                        }
                        Ok(None) => {}
                        Err(e) => {
                            log::warn!("bond recovery planning failed, retrying next tick: {e}");
                        }
                    },
                    Ok(false) => {
                        trace!("defer bond recovery until the latest sealed epoch is finalized");
                    }
                    Err(e) => {
                        log::warn!("bond recovery epoch fence failed, retrying next tick: {e}");
                    }
                }
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

        // A failed root is a documented terminal state, not a local
        // contradiction: the ticked Hero path already logs and idles on
        // FailedNoWinner, and this path also runs with no Hero (Absent),
        // where crashing would loop on restart. stageTournamentResult's
        // TournamentFailedNoWinner revert remains the write-side guard.
        if can_stage.isTournamentFailed {
            log::error!(
                "dispute tournament for epoch {} finished without a winner; settlement is impossible, notify all users!",
                can_stage.epochNumber
            );
            return Ok(None);
        }

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
                        to_machine_validity_proof(settlement.machine_validity_proof),
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
                    vec_u8_to_bytes_32(settlement.outputs_merkle_root().into()),
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

    async fn plan_bond_recovery(&mut self, chain: &Chain) -> Result<Option<LaneRequest>> {
        let epochs = self.storage.sealed_epochs()?;
        self.bond_recovery
            .plan_due(chain, &epochs)
            .await
            .map_err(crate::hero::error::ReactError::from)
            .map_err(Into::into)
    }

    /// Keep maintenance out of the nonce lane while a newly sealed
    /// epoch is visible at Latest but not yet in the finalized DB.
    async fn latest_epoch_is_finalized(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
    ) -> Result<bool> {
        let latest = dave_consensus
            .getCurrentSealedEpoch()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;
        let finalized = self
            .storage
            .last_sealed_epoch()?
            .map(|epoch| epoch.epoch_number);
        Ok(finalized_epoch_matches_latest(
            finalized,
            latest.epochNumber,
        ))
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

fn to_leaf_proof(proof: StoredLeafProof) -> DaveConsensus::LeafProof {
    DaveConsensus::LeafProof {
        dataBlock: B256::from(proof.data_block),
        siblings: proof.siblings.inner().iter().map(B256::from).collect(),
    }
}

fn to_machine_validity_proof(
    proof: StoredMachineValidityProof,
) -> DaveConsensus::MachineValidityProof {
    DaveConsensus::MachineValidityProof {
        iflagsYProof: to_leaf_proof(proof.iflags_y_proof),
        htifTohostProof: to_leaf_proof(proof.htif_tohost_proof),
        txBufferProof: to_leaf_proof(proof.tx_buffer_proof),
    }
}

fn vec_u8_to_bytes_32(hash: Vec<u8>) -> B256 {
    B256::from_slice(&hash)
}

fn finalized_epoch_matches_latest(finalized: Option<u64>, latest: U256) -> bool {
    finalized.is_some_and(|epoch| U256::from(epoch) == latest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{
        LeafProof, MACHINE_MEMORY_PROOF_SIBLING_COUNT, MachineValidityProof, Proof,
    };
    use alloy::rpc::types::TransactionRequest;
    use alloy::sol_types::SolCall;

    fn proof_leaf(data_byte: u8, sibling_byte: u8) -> LeafProof {
        LeafProof {
            data_block: [data_byte; 32],
            siblings: Proof::new(vec![[sibling_byte; 32]; MACHINE_MEMORY_PROOF_SIBLING_COUNT])
                .unwrap(),
        }
    }

    #[test]
    fn stage_tournament_result_encodes_machine_validity_proof() {
        let proof = MachineValidityProof {
            iflags_y_proof: proof_leaf(0x11, 0xA1),
            htif_tohost_proof: proof_leaf(0x22, 0xA2),
            tx_buffer_proof: proof_leaf(0x33, 0xA3),
        };
        let call = DaveConsensus::stageTournamentResultCall {
            epochNumber: U256::from(7),
            proof: to_machine_validity_proof(proof),
        };

        let encoded = call.abi_encode();
        let decoded = DaveConsensus::stageTournamentResultCall::abi_decode(&encoded).unwrap();

        assert_eq!(decoded.epochNumber, U256::from(7));
        assert_eq!(
            decoded.proof.iflagsYProof.dataBlock,
            B256::repeat_byte(0x11)
        );
        assert_eq!(
            decoded.proof.htifTohostProof.dataBlock,
            B256::repeat_byte(0x22)
        );
        assert_eq!(
            decoded.proof.txBufferProof.dataBlock,
            B256::repeat_byte(0x33)
        );
        assert_eq!(
            decoded.proof.iflagsYProof.siblings,
            vec![B256::repeat_byte(0xA1); MACHINE_MEMORY_PROOF_SIBLING_COUNT]
        );
        assert_eq!(
            decoded.proof.htifTohostProof.siblings,
            vec![B256::repeat_byte(0xA2); MACHINE_MEMORY_PROOF_SIBLING_COUNT]
        );
        assert_eq!(
            decoded.proof.txBufferProof.siblings,
            vec![B256::repeat_byte(0xA3); MACHINE_MEMORY_PROOF_SIBLING_COUNT]
        );
    }

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

    #[test]
    fn recovery_runs_only_in_idle_or_terminal_phases() {
        assert!(EpochReaction::Absent.allows_recovery());
        assert!(!EpochReaction::Preparing.allows_recovery());
        for (result, allows) in [
            (TournamentResult::Running, false),
            (TournamentResult::Won, true),
            (TournamentResult::Lost, true),
            (TournamentResult::FailedNoWinner, true),
        ] {
            assert_eq!(
                ticked(result, &[]).allows_recovery(),
                allows,
                "recovery gating for {result:?}"
            );
        }
    }

    #[test]
    fn recovery_waits_for_the_latest_epoch_to_reach_finalized_storage() {
        assert!(!finalized_epoch_matches_latest(None, U256::ZERO));
        assert!(finalized_epoch_matches_latest(Some(7), U256::from(7)));
        assert!(!finalized_epoch_matches_latest(Some(7), U256::from(8)));
        assert!(!finalized_epoch_matches_latest(Some(8), U256::from(7)));
    }
}
