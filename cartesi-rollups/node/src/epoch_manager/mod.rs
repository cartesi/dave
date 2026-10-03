// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod error;
mod recovery;

use self::error::Result;
use self::recovery::plan_recovery;
use alloy::primitives::{Address, B256, TxKind, U256, keccak256};
use alloy::providers::DynProvider;
use log::{debug, error, info, trace};
use std::{sync::Arc, time::Duration};

use crate::chain::{Chain, ChainHead};
use crate::provider::{LaneRequest, SendReport, SendVerdict, TransactionLane};
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
    shutdown: ShutdownSignal,
    /// The calls the previous tick skipped as reverting at latest.
    reverted: Vec<CallKey>,
}

/// A call's identity across ticks: its verb, target and calldata.
type CallKey = (String, Option<TxKind>, B256);

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
        shutdown: ShutdownSignal,
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
            shutdown,
            reverted: Vec::new(),
        })
    }

    /// A stop lets the tick in flight finish, so an action whose
    /// preparation completed still goes out; only the Hero's machine
    /// work stops early.
    pub async fn execution_loop(mut self, chain: Chain) -> Result<()> {
        let shutdown = self.shutdown.clone();
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
            self.reverted.clear();
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
            let calls = tick.wave.iter().map(call_key).collect();
            reports = self
                .transaction_lane
                .submit_wave(tick.wave)
                .await
                .map_err(crate::hero::error::ReactError::from)?;
            let (reverted, repeated) = repeated_reverts(&self.reverted, calls, &reports);
            // The lane warns of each skip with its reason. Once is routine
            // with several honest nodes on one commitment: another node's
            // copy of the step mined between this node's read and its
            // estimate. The same call again on the next tick is not.
            for (label, to, _) in repeated {
                let to = to.and_then(|kind| kind.to().copied()).unwrap_or_default();
                error!(
                    "{label} to {to} reverts at latest on consecutive ticks: the node \
                     keeps planning a step it cannot take, and a dispute clock may be running"
                );
            }
            self.reverted = reverted;
        }
        if reports.is_empty() {
            self.reverted.clear();
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
                        let head = tick.head();
                        wave.extend(tick.into_wave());
                        if won {
                            let consensus =
                                DaveConsensus::new(self.consensus, chain.provider().clone());
                            match self
                                .plan_settlement(&consensus, epoch.epoch_number, head)
                                .await
                            {
                                Ok(step) => wave.extend(step),
                                Err(e) => log::warn!(
                                    "settlement planning failed, retrying next tick: {e:#}"
                                ),
                            }
                        }
                    }
                    Err(e) if self.shutdown.is_requested() => {
                        info!("dispute planning stopped by shutdown: {e:#}")
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
    /// ingestion while the whether-still-needed guards read `head`,
    /// where the Hero observed its win. That is this tick's latest, so
    /// a step mined in an earlier tick is still seen; and the settle
    /// asserts compare local data with the block the win was read at,
    /// where the winner cannot differ without a node bug.
    /// At most one step is planned so a later settlement step never
    /// queues behind an earlier step from stale state.
    async fn plan_settlement(
        &mut self,
        dave_consensus: &DaveConsensus::DaveConsensusInstance<
            DynProvider,
            alloy::network::Ethereum,
        >,
        epoch_number: u64,
        head: ChainHead,
    ) -> Result<Option<LaneRequest>> {
        if let Some(step) = self
            .plan_sentry_claim(dave_consensus, epoch_number, head)
            .await?
        {
            return Ok(Some(step));
        }
        if let Some(step) = self
            .plan_stage_tournament_result(dave_consensus, epoch_number, head)
            .await?
        {
            return Ok(Some(step));
        }
        self.plan_accept_tournament_result(dave_consensus, epoch_number, head)
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
        head: ChainHead,
    ) -> Result<Option<LaneRequest>> {
        let sentry_id = dave_consensus
            .getSentryId(self.signer_address)
            .block(head.block_id())
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
            .block(head.block_id())
            .call()
            .await?;
        if current_sealed_epoch.epochNumber != U256::from(epoch_number) {
            return Ok(None);
        }
        let epoch_number = current_sealed_epoch.epochNumber;

        let has_claimed = dave_consensus
            .hasSentryClaimedInEpoch(epoch_number, sentry_id)
            .block(head.block_id())
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
            .block(head.block_id())
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
        head: ChainHead,
    ) -> Result<Option<LaneRequest>> {
        let can_stage = dave_consensus
            .canStageTournamentResult()
            .block(head.block_id())
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
        head: ChainHead,
    ) -> Result<Option<LaneRequest>> {
        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(head.block_id())
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

    /// The current Hero's repeated observations (Hero::tick).
    #[cfg(test)]
    pub(crate) fn reobservations(&self) -> usize {
        self.epoch_hero
            .as_ref()
            .map_or(0, |hero| hero.reobservations())
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
                self.shutdown.clone(),
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

fn call_key((label, request): &LaneRequest) -> CallKey {
    let input = request.input.input().map(keccak256).unwrap_or_default();
    (label.clone(), request.to, input)
}

/// The calls this tick skipped as reverting at latest (one report per call,
/// in order), and those of them the previous tick skipped too.
fn repeated_reverts(
    previous: &[CallKey],
    calls: Vec<CallKey>,
    reports: &[SendReport],
) -> (Vec<CallKey>, Vec<CallKey>) {
    let reverted: Vec<_> = calls
        .into_iter()
        .zip(reports)
        .filter(|(_, report)| report.verdict == SendVerdict::Reverts)
        .map(|(call, _)| call)
        .collect();
    let repeated = reverted
        .iter()
        .filter(|call| previous.contains(call))
        .cloned()
        .collect();
    (reverted, repeated)
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
        network::{EthereumWallet, TransactionBuilder},
        primitives::{Bytes, TxKind},
        providers::{Provider, ProviderBuilder},
        rpc::types::{Block, Log, TransactionRequest},
        signers::local::PrivateKeySigner,
        sol_types::SolCall,
        transports::mock::Asserter,
    };
    use cartesi_prt_contracts::tournament::Tournament;
    use std::path::Path;

    #[test]
    fn repeated_reverts_escalate_only_on_consecutive_ticks() {
        let call_to = |label: &str, to: u8, input: u8| {
            call_key(&(
                label.to_string(),
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(to))
                    .with_input(vec![input]),
            ))
        };
        let call = |label: &str, input: u8| call_to(label, 0x10, input);
        let report = |verdict| SendReport {
            label: String::new(),
            nonce: 0,
            tx_hash: B256::ZERO,
            verdict,
        };
        let skipped = [report(SendVerdict::Reverts), report(SendVerdict::Submitted)];
        let tick = |previous: &[CallKey], calls: Vec<CallKey>| {
            let count = calls.len();
            repeated_reverts(previous, calls, &skipped[..count])
        };
        let advance = call("advanceMatch", 1);

        // The first skip is a warning only; the same call next tick is not.
        let (first, repeated) = tick(&[], vec![advance.clone()]);
        assert!(repeated.is_empty());
        let (second, repeated) = tick(&first, vec![advance.clone()]);
        assert_eq!(repeated, vec![advance.clone()]);
        // A sent call is not a skip.
        let (sent, repeated) = repeated_reverts(
            &second,
            vec![call("joinTournament", 2), advance.clone()],
            &skipped,
        );
        assert!(repeated.is_empty());
        assert_eq!(sent, vec![call("joinTournament", 2)]);
        // A tick without it resets, and a lost race on the next step of the
        // same verb is another call.
        let (none, _) = tick(&second, vec![]);
        assert!(tick(&none, vec![advance.clone()]).1.is_empty());
        assert!(tick(&second, vec![call("advanceMatch", 3)]).1.is_empty());
        // Recoveries share verb and calldata; another tournament is another
        // call.
        let (recovery, _) = tick(&[], vec![call_to("tryRecoveringBond", 0x20, 0)]);
        let other = vec![call_to("tryRecoveringBond", 0x21, 0)];
        assert!(tick(&recovery, other).1.is_empty());
    }

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
        let (manager, chain) = manager_on(path, provider);
        (manager, chain, asserter)
    }

    fn manager_on(path: &Path, provider: DynProvider) -> (EpochManager<EthArenaSender>, Chain) {
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
            ShutdownSignal::default(),
        )
        .unwrap();
        (manager, Chain::new(provider, Vec::new()))
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
                .plan_stage_tournament_result(&consensus, 0, won_at())
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
                .plan_accept_tournament_result(&consensus, 0, won_at())
                .await
                .unwrap()
                .is_none()
        );
        assert!(rpc.read_q().is_empty());
    }

    /// The head a Hero tick observed its win at.
    fn won_at() -> ChainHead {
        ChainHead {
            number: 7,
            hash: B256::repeat_byte(0x77),
        }
    }

    /// Storage whose epoch 0 is sealed without inputs and rolled, so its
    /// settlement row exists; `adjust` edits the template first.
    fn rolled_epoch_zero(
        adjust: impl FnOnce(&mut cartesi_machine::Machine),
    ) -> (tempfile::TempDir, Storage) {
        let dir = tempfile::tempdir().unwrap();
        let template = dir.path().join("_template");
        crate::storage::sql::test_helper::store_template(&template, adjust);
        let mut storage = Storage::initialize(
            dir.path(),
            &crate::storage::Template::inspect(&template).unwrap(),
            0,
            Address::ZERO,
            Address::ZERO,
            0,
            &crate::engine::TournamentGeometry::two_level(),
        )
        .unwrap();
        let epoch = Epoch {
            epoch_number: 0,
            input_index_boundary: 0,
            root_tournament: Address::repeat_byte(1),
            block_created_number: 1,
        };
        storage
            .insert_consensus_data(1, [].iter(), [&epoch].into_iter())
            .unwrap();
        storage.roll_epoch().unwrap();
        (dir, storage)
    }

    fn push_sentry_views(asserter: &Asserter, claimed: bool) {
        push_call::<DaveConsensus::getSentryIdCall>(asserter, &U256::from(1));
        push_call::<DaveConsensus::getCurrentSealedEpochCall>(
            asserter,
            &DaveConsensus::getCurrentSealedEpochReturn {
                epochNumber: U256::ZERO,
                inputIndexLowerBound: U256::ZERO,
                inputIndexUpperBound: U256::ZERO,
                tournament: Address::repeat_byte(1),
                isTournamentResultStaged: false,
                stagingBlockNumber: U256::ZERO,
                stagedPostEpochMachineStateHash: B256::ZERO,
                stagedPostEpochOutputsMerkleRoot: B256::ZERO,
            },
        );
        push_call::<DaveConsensus::hasSentryClaimedInEpochCall>(asserter, &claimed);
    }

    #[tokio::test]
    async fn settlement_reads_the_block_the_hero_won_at() {
        let (dir, mut storage) = rolled_epoch_zero(|_| {});
        let settlement = storage.settlement_info(0).unwrap().unwrap();
        let (provider, rpc, requests) = crate::chain::recording::recording_provider();
        let (mut manager, chain) = manager_on(dir.path(), provider);
        let consensus = DaveConsensus::new(manager.consensus, chain.provider().clone());
        let staged = |staged: bool| DaveConsensus::canAcceptStagedTournamentResultReturn {
            isTournamentResultStaged: staged,
            doAllSentriesAgreeWithStagedTournamentResult: true,
            isClaimStagingPeriodOver: true,
            epochNumber: U256::ZERO,
            stagedPostEpochMachineStateHash: B256::from(settlement.final_state),
            stagedPostEpochOutputsMerkleRoot: B256::from(settlement.outputs_merkle_root()),
        };
        let can_stage = |staged: bool| DaveConsensus::canStageTournamentResultReturn {
            isFinished: true,
            isTournamentFailed: false,
            isTournamentResultStaged: staged,
            epochNumber: U256::ZERO,
            winnerCommitment: B256::from(settlement.computation_hash.data()),
            winnerPostEpochMachineStateHash: B256::from(settlement.final_state),
        };

        // A sentry that already claimed stages the result.
        push_sentry_views(&rpc, true);
        push_call::<DaveConsensus::canStageTournamentResultCall>(&rpc, &can_stage(false));
        let (label, _) = manager
            .plan_settlement(&consensus, 0, won_at())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(label, "stageTournamentResult");

        // Once it is staged past its period, nobody claims or stages again.
        push_sentry_views(&rpc, false);
        push_call::<DaveConsensus::canAcceptStagedTournamentResultCall>(&rpc, &staged(true));
        push_call::<DaveConsensus::canStageTournamentResultCall>(&rpc, &can_stage(true));
        push_call::<DaveConsensus::canAcceptStagedTournamentResultCall>(&rpc, &staged(true));
        let (label, _) = manager
            .plan_settlement(&consensus, 0, won_at())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(label, "acceptStagedTournamentResult");
        assert!(rpc.read_q().is_empty());

        // Every view is pinned to the won head's hash, a bare EIP-1898 hash
        // as the reader's pinned reads send it, so a reorg between the
        // Hero's read and these cannot fire a settle assert.
        let requests = requests.lock().unwrap();
        let calls: Vec<_> = requests
            .iter()
            .filter(|request| request["method"] == "eth_call")
            .collect();
        assert_eq!(calls.len(), 10);
        for call in calls {
            assert_eq!(
                call["params"][1],
                serde_json::json!(format!("{:#x}", won_at().hash))
            );
        }
    }
}
