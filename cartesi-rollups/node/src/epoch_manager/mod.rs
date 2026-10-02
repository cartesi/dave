// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;
mod recovery;

use self::error::Result;
use self::recovery::plan_recovery;
use alloy::primitives::{Address, B256, U256};
use alloy::providers::DynProvider;
use log::{debug, info, trace};
use std::{sync::Arc, time::Duration};

use crate::chain::Chain;
use crate::provider::{LaneRequest, SendReport, TransactionLane};
use crate::storage::{
    Epoch, LeafProof as StoredLeafProof, MachineValidityProof as StoredMachineValidityProof,
    Storage,
};
use crate::sync::ShutdownSignal;
use crate::{
    hero::{Hero, HeroTick, TournamentResult},
    tournament::ArenaSender,
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;

pub struct EpochManager<AS: ArenaSender> {
    arena_sender: Arc<AS>,
    transaction_lane: TransactionLane,
    consensus: Address,
    signer_address: Address,
    sleep_duration: Duration,
    storage: Storage,
    epoch_hero: Option<Hero<AS>>,
}

struct EpochTick {
    epoch: u64,
    wave: Vec<LaneRequest>,
    done: bool,
}

/// One tick's result: whether it completed an epoch, and the lane's report
/// on each request it sent.
pub(crate) struct Ticked {
    pub done: bool,
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "the harness asserts no honest call reverts")
    )]
    pub reports: Vec<SendReport>,
}

impl<AS: ArenaSender> EpochManager<AS> {
    pub fn new(
        arena_sender: Arc<AS>,
        transaction_lane: TransactionLane,
        consensus_address: Address,
        signer_address: Address,
        mut storage: Storage,
        sleep_duration: Duration,
    ) -> Result<Self> {
        storage.pin_epoch_claimant(signer_address)?;
        Ok(Self {
            arena_sender,
            transaction_lane,
            consensus: consensus_address,
            signer_address,
            sleep_duration,
            storage,
            epoch_hero: None,
        })
    }

    pub async fn execution_loop(mut self, shutdown: ShutdownSignal, chain: Chain) -> Result<()> {
        while !shutdown.is_requested() {
            match self.tick(&chain).await {
                // Catch up completed historical epochs without a polling sleep.
                Ok(Ticked { done: true, .. }) => continue,
                Ok(_) => {}
                Err(e) => log::warn!("epoch tick failed, retrying next tick: {e:#}"),
            }
            tokio::select! { biased;
                _ = shutdown.requested() => break,
                _ = tokio::time::sleep(self.sleep_duration) => {}
            }
        }
        Ok(())
    }

    pub(crate) async fn tick(&mut self, chain: &Chain) -> Result<Ticked> {
        let Some(tick) = self.plan_tick(chain).await? else {
            return Ok(Ticked {
                done: false,
                reports: Vec::new(),
            });
        };
        let mut reports = Vec::new();
        if tick.done {
            assert!(
                tick.wave.is_empty(),
                "a completed epoch has no pending actions"
            );
            // Release the old dispute before advancing the runner's GC boundary.
            self.epoch_hero = None;
            self.storage.complete_epoch(tick.epoch)?;
            info!(
                "epoch {} complete: settlement and bonds finalized",
                tick.epoch
            );
        } else if !tick.wave.is_empty() {
            reports = self
                .transaction_lane
                .submit_wave(tick.wave)
                .await
                .map_err(crate::hero::error::ReactError::from)?;
        }
        Ok(Ticked {
            done: tick.done,
            reports,
        })
    }

    async fn plan_tick(&mut self, chain: &Chain) -> Result<Option<EpochTick>> {
        let Some(epoch) = self.storage.unfinished_epoch()? else {
            return Ok(None);
        };
        let finalized = chain
            .finalized_head()
            .await
            .map_err(crate::hero::error::ReactError::from)?;
        // Ingestion is finalized-only. A later sealed epoch proves this one's
        // settlement, but it must not outrun the refund observation's head.
        let settled = self.storage.last_sealed_epoch()?.is_some_and(|last| {
            last.epoch_number > epoch.epoch_number && last.block_created_number <= finalized.number
        });
        let mut wave = Vec::new();
        if !settled {
            if self.storage.settlement_info(epoch.epoch_number)?.is_some() {
                match self.react_dispute(chain, &epoch).await {
                    Ok(tick) => {
                        let won = tick.result() == TournamentResult::Won;
                        wave.extend(tick.into_wave());
                        if won {
                            let consensus =
                                DaveConsensus::new(self.consensus, chain.provider().clone());
                            match self.plan_settlement(&consensus, epoch.epoch_number).await {
                                Ok(step) => wave.extend(step),
                                Err(e) => log::warn!(
                                    "settlement planning failed, retrying next tick: {e:#}"
                                ),
                            }
                        }
                    }
                    Err(e) => log::warn!("dispute planning failed, retrying next tick: {e:#}"),
                }
            } else {
                debug!(
                    "wait for machine-runner to prepare epoch {}",
                    epoch.epoch_number
                );
            }
        }

        // Every applicable refund joins the same batch, including while the
        // root is running. A failed scan cannot discard already prepared work.
        let refunds_complete =
            match plan_recovery(chain, &epoch, self.signer_address, finalized).await {
                Ok(recovery) => {
                    wave.extend(recovery.wave);
                    recovery.complete
                }
                Err(e) => {
                    log::warn!("bond recovery planning failed, retrying next tick: {e:#}");
                    false
                }
            };
        Ok(Some(EpochTick {
            epoch: epoch.epoch_number,
            wave,
            done: settled && refunds_complete,
        }))
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
    async fn plan_settlement(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
        epoch_number: u64,
    ) -> Result<Option<LaneRequest>> {
        if let Some(step) = self.plan_sentry_claim(dave_consensus, epoch_number).await? {
            return Ok(Some(step));
        }
        if let Some(step) = self
            .plan_stage_tournament_result(dave_consensus, epoch_number)
            .await?
        {
            return Ok(Some(step));
        }
        self.plan_accept_tournament_result(dave_consensus, epoch_number)
            .await
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
        epoch_number: u64,
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
        if current_sealed_epoch.epochNumber != U256::from(epoch_number) {
            return Ok(None);
        }
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
        epoch_number: u64,
    ) -> Result<Option<LaneRequest>> {
        let can_stage = dave_consensus
            .canStageTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if can_stage.epochNumber != U256::from(epoch_number) {
            return Ok(None);
        }

        // A no-winner result cannot settle. Keep the epoch open for operator
        // attention; repeated observation of this state is not a contradiction.
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
                // The node defended a terminal app's true state, which no
                // validity proof accepts. Like a no-winner result, hold
                // the epoch for the consensus's operators.
                if !settlement.machine_validity_proof.settles() {
                    log::error!(
                        "epoch {} ended with the application in a terminal state; \
                         it won the dispute but cannot settle, notify all users!",
                        can_stage.epochNumber
                    );
                    return Ok(None);
                }
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
        epoch_number: u64,
    ) -> Result<Option<LaneRequest>> {
        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(alloy::eips::BlockId::latest())
            .call()
            .await?;

        if can_accept.epochNumber != U256::from(epoch_number) {
            return Ok(None);
        }
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

    async fn react_dispute(&mut self, chain: &Chain, epoch: &Epoch) -> Result<HeroTick> {
        if self.epoch_hero.is_none() {
            let storage = Storage::new(self.storage.state_dir())?;
            self.epoch_hero = Some(Hero::new(
                self.arena_sender.clone(),
                chain.clone(),
                epoch.root_tournament,
                epoch.block_created_number,
                storage,
                epoch.epoch_number,
            )?);
        }
        let tick = self
            .epoch_hero
            .as_mut()
            .expect("hero initialized above")
            .tick()
            .await?;
        match tick.result() {
            TournamentResult::Running => {}
            TournamentResult::Won => info!(
                "local commitment won dispute tournament for epoch {}",
                epoch.epoch_number
            ),
            TournamentResult::Lost => log::error!(
                "local commitment lost dispute tournament for epoch {}",
                epoch.epoch_number
            ),
            TournamentResult::FailedNoWinner => log::error!(
                "dispute tournament for epoch {} finished without a winner",
                epoch.epoch_number
            ),
        }
        Ok(tick)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{
        LeafProof, MACHINE_MEMORY_PROOF_SIBLING_COUNT, MachineValidityProof, Proof,
    };
    use crate::tournament::EthArenaSender;
    use alloy::{
        network::EthereumWallet,
        primitives::{Bytes, TxKind},
        providers::{Provider, ProviderBuilder},
        rpc::types::{Block, Log},
        signers::local::PrivateKeySigner,
        sol_types::SolCall,
        transports::mock::Asserter,
    };
    use cartesi_prt_contracts::tournament::Tournament;
    use std::path::Path;

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

    fn setup_epochs() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let conn = rusqlite::Connection::open(dir.path().join("db.sqlite3")).unwrap();
        crate::storage::sql::schema::initialize(&conn).unwrap();
        drop(conn);
        let mut storage = Storage::new(dir.path()).unwrap();
        let epochs = [
            Epoch {
                epoch_number: 0,
                input_index_boundary: 0,
                root_tournament: Address::repeat_byte(0x10),
                block_created_number: 1,
            },
            Epoch {
                epoch_number: 1,
                input_index_boundary: 0,
                root_tournament: Address::repeat_byte(0x20),
                block_created_number: 20,
            },
        ];
        storage
            .insert_consensus_data(20, [].iter(), epochs.iter())
            .unwrap();
        dir
    }

    fn manager(path: &Path) -> (EpochManager<EthArenaSender>, Chain, Asserter) {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let signer = PrivateKeySigner::from_bytes(&B256::repeat_byte(0x11)).unwrap();
        let address = signer.address();
        let lane = TransactionLane::new(
            provider.clone(),
            provider.clone(),
            31337,
            EthereumWallet::from(signer),
        );
        let manager = EpochManager::new(
            Arc::new(EthArenaSender::new(provider.clone())),
            lane,
            Address::repeat_byte(0xCC),
            address,
            Storage::new(path).unwrap(),
            Duration::ZERO,
        )
        .unwrap();
        (manager, Chain::new(provider, Vec::new()), asserter)
    }

    fn push_head(asserter: &Asserter, number: u64) {
        let mut block: Block = Block::default();
        block.header.inner.number = number;
        block.header.hash = B256::repeat_byte(number as u8);
        asserter.push_success(&Some(block));
    }

    fn push_call<C: SolCall>(asserter: &Asserter, value: &C::Return) {
        asserter.push_success(&Bytes::from(C::abi_encode_returns(value)));
    }

    fn push_bond(asserter: &Asserter, disposition: u8, claimer: Address) {
        push_call::<Tournament::bondRecoveryCall>(
            asserter,
            &Tournament::bondRecoveryReturn {
                disposition,
                claimer,
                payment: U256::ZERO,
            },
        );
    }

    fn push_refund_tick(asserter: &Asserter, finalized: u64, disposition: u8, claimer: Address) {
        push_head(asserter, finalized);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(asserter, disposition, claimer);
    }

    #[tokio::test]
    async fn rotation_and_restart_finish_old_refunds_before_following_the_next_epoch() {
        let dir = setup_epochs();
        let (mut first, chain, rpc) = manager(dir.path());
        let us = first.signer_address;

        // Epoch 1 already exists on the finalized chain, but epoch 0 owns the
        // cursor. Its refund does not need any machine snapshots or Hero.
        push_refund_tick(&rpc, 30, 2, us);
        push_head(&rpc, 31);
        push_bond(&rpc, 2, us);
        let planned = first.plan_tick(&chain).await.unwrap().unwrap();
        assert_eq!(planned.epoch, 0);
        assert!(!planned.done);
        assert_eq!(planned.wave.len(), 1);
        assert_eq!(
            planned.wave[0].1.to,
            Some(TxKind::Call(Address::repeat_byte(0x10)))
        );
        assert!(first.epoch_hero.is_none());
        drop(first);

        // Losing a submission or restarting cannot skip that epoch.
        let (mut restarted, chain, rpc) = manager(dir.path());
        push_refund_tick(&rpc, 30, 2, us);
        push_head(&rpc, 31);
        push_bond(&rpc, 2, us);
        let retried = restarted.plan_tick(&chain).await.unwrap().unwrap();
        assert_eq!(retried.epoch, 0);
        assert_eq!(retried.wave, planned.wave);

        // Mined but unfinalized recovery suppresses the call, not the epoch.
        push_refund_tick(&rpc, 30, 2, us);
        push_head(&rpc, 31);
        push_bond(&rpc, 3, Address::ZERO);
        assert!(!restarted.tick(&chain).await.unwrap().done);
        assert_eq!(
            restarted
                .storage
                .unfinished_epoch()
                .unwrap()
                .unwrap()
                .epoch_number,
            0
        );

        // Once the payment is final the real tick advances the durable cursor.
        push_refund_tick(&rpc, 32, 3, Address::ZERO);
        assert!(restarted.tick(&chain).await.unwrap().done);
        drop(restarted);
        let (mut next, chain, rpc) = manager(dir.path());
        assert_eq!(
            next.storage
                .unfinished_epoch()
                .unwrap()
                .unwrap()
                .epoch_number,
            1
        );
        push_refund_tick(&rpc, 32, 0, Address::ZERO);
        let next_tick = next.plan_tick(&chain).await.unwrap().unwrap();
        assert_eq!(next_tick.epoch, 1);
        assert!(!next_tick.done);
        assert!(rpc.read_q().is_empty());
    }

    #[tokio::test]
    async fn refund_completion_cannot_outrun_finalized_settlement() {
        let dir = setup_epochs();
        let (mut manager, chain, rpc) = manager(dir.path());
        // Ingestion can be ahead of the head sampled by this tick. Even a final
        // refund cannot retire the epoch before this observation sees settlement.
        push_refund_tick(&rpc, 19, 3, Address::ZERO);
        assert!(!manager.tick(&chain).await.unwrap().done);
        assert_eq!(
            manager
                .storage
                .unfinished_epoch()
                .unwrap()
                .unwrap()
                .epoch_number,
            0
        );
        push_refund_tick(&rpc, 20, 3, Address::ZERO);
        assert!(manager.tick(&chain).await.unwrap().done);
        assert_eq!(
            manager
                .storage
                .unfinished_epoch()
                .unwrap()
                .unwrap()
                .epoch_number,
            1
        );
    }

    #[tokio::test]
    async fn settlement_views_for_a_newer_epoch_do_not_stage_or_accept_it() {
        let (dir, mut storage) = crate::storage::sql::test_helper::setup_storage();
        let epochs: Vec<_> = (0..2)
            .map(|epoch_number| Epoch {
                epoch_number,
                input_index_boundary: 0,
                root_tournament: Address::repeat_byte(epoch_number as u8 + 1),
                block_created_number: 1,
            })
            .collect();
        storage
            .insert_consensus_data(1, [].iter(), epochs.iter())
            .unwrap();
        storage.roll_epoch().unwrap();
        storage.roll_epoch().unwrap();
        // The newer epoch has valid, fully prepared settlement material. Only
        // ownership of epoch zero prevents these otherwise applicable actions.
        let newer = storage.settlement_info(1).unwrap().unwrap();
        let (mut manager, chain, rpc) = manager(dir.path());
        let consensus = DaveConsensus::new(manager.consensus, chain.provider().clone());
        push_call::<DaveConsensus::canStageTournamentResultCall>(
            &rpc,
            &DaveConsensus::canStageTournamentResultReturn {
                isFinished: true,
                isTournamentFailed: false,
                isTournamentResultStaged: false,
                epochNumber: U256::from(1),
                winnerCommitment: B256::from(newer.computation_hash.data()),
                winnerPostEpochMachineStateHash: B256::from(newer.final_state),
            },
        );
        assert!(
            manager
                .plan_stage_tournament_result(&consensus, 0)
                .await
                .unwrap()
                .is_none()
        );
        push_call::<DaveConsensus::canAcceptStagedTournamentResultCall>(
            &rpc,
            &DaveConsensus::canAcceptStagedTournamentResultReturn {
                isTournamentResultStaged: true,
                doAllSentriesAgreeWithStagedTournamentResult: true,
                isClaimStagingPeriodOver: true,
                epochNumber: U256::from(1),
                stagedPostEpochMachineStateHash: B256::from(newer.final_state),
                stagedPostEpochOutputsMerkleRoot: B256::from(newer.outputs_merkle_root()),
            },
        );
        assert!(
            manager
                .plan_accept_tournament_result(&consensus, 0)
                .await
                .unwrap()
                .is_none()
        );
        assert!(rpc.read_q().is_empty());
    }
}
