// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

mod recovery;

use self::recovery::{RecoveryTree, plan_recovery};
use alloy::primitives::{Address, B256, TxKind, U256, keccak256};
use alloy::providers::DynProvider;
use anyhow::Result;
use log::{Level, debug, error, info, trace};
use std::time::{Duration, Instant};

use crate::chain::{Chain, ChainHead};
use crate::escalation::{PAGE_AFTER, Persistence};
use crate::fatal::Fatal;
use crate::provider::{LaneRequest, SendReport, TransactionLane};
use crate::storage::{
    Epoch, LeafProof as StoredLeafProof, MachineValidityProof as StoredMachineValidityProof,
    Settlement, Storage,
};
use crate::sync::ShutdownSignal;
use crate::{
    hero::{
        Hero, HeroTick,
        planner::{HeroTerminal, Loss},
    },
    merkle::Digest,
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;

pub struct EpochManager {
    transaction_lane: TransactionLane,
    consensus: Address,
    application: Address,
    signer_address: Address,
    sleep_duration: Duration,
    storage: Storage,
    epoch_hero: Option<Hero>,
    shutdown: ShutdownSignal,
    /// The previous tick's calls, each with the instant it was first
    /// planned on consecutive ticks (`track_planned`).
    planned: Vec<(CallKey, Instant)>,
    /// How long the unfinished epoch has failed to plan or advance.
    stall: Persistence,
    /// Whether this tick recorded a stall; a tick without one clears it.
    stalled_now: bool,
    /// The unfinished epoch's dispute tree, walked over finalized blocks.
    recovery: Option<RecoveryTree>,
}

/// A call's identity across ticks: its verb, target and calldata.
type CallKey = (String, Option<TxKind>, B256);

/// A call planned for PAGE_AFTER or longer, its latest report and how long.
type Overdue<'r> = (CallKey, &'r SendReport, Duration);

type Consensus = DaveConsensus::DaveConsensusInstance<DynProvider, alloy::network::Ethereum>;

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

impl EpochManager {
    pub fn new(
        transaction_lane: TransactionLane,
        consensus_address: Address,
        application: Address,
        signer_address: Address,
        storage: Storage,
        sleep_duration: Duration,
        shutdown: ShutdownSignal,
    ) -> Self {
        Self {
            transaction_lane,
            consensus: consensus_address,
            application,
            signer_address,
            sleep_duration,
            storage,
            epoch_hero: None,
            shutdown,
            planned: Vec::new(),
            stall: Persistence::default(),
            stalled_now: false,
            recovery: None,
        }
    }

    /// A stop lets the tick in flight finish, so an action whose
    /// preparation completed still goes out; only the Hero's machine
    /// work stops early.
    pub async fn execution_loop(mut self, chain: Chain) -> Result<()> {
        let shutdown = self.shutdown.clone();
        while !shutdown.is_requested() {
            match self.tick(&chain).await {
                Ok(ticked) => {
                    if !self.stalled_now {
                        self.stall.cleared();
                    }
                    // Catch up completed historical epochs without a polling sleep.
                    if ticked.done {
                        continue;
                    }
                }
                Err(e) if Fatal::of(&e).is_some() => return Err(e),
                Err(e) => self.stalled(
                    Level::Warn,
                    format_args!("epoch tick failed, retrying next tick: {e:#}"),
                ),
            }
            tokio::select! { biased;
                _ = shutdown.requested() => break,
                _ = tokio::time::sleep(self.sleep_duration) => {}
            }
        }
        Ok(())
    }

    pub(crate) async fn tick(&mut self, chain: &Chain) -> Result<Ticked> {
        self.stalled_now = false;
        let Some(tick) = self.plan_tick(chain).await? else {
            self.planned.clear();
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
            reports = self.transaction_lane.submit_wave(tick.wave).await?;
            let overdue;
            (self.planned, overdue) = track_planned(&self.planned, calls, &reports, Instant::now());
            for ((label, to, _), report, lasted) in overdue {
                let to = to.and_then(|kind| kind.to().copied()).unwrap_or_default();
                let why = match &report.revert {
                    Some(reason) => format!("it reverts at latest: {reason}"),
                    // The newest send at the stuck nonce; a relay holds an
                    // earlier one there (docs/runbooks/submit-relay.md).
                    None => format!(
                        "last verdict {:?} for transaction {} at nonce {}",
                        report.verdict, report.tx_hash, report.nonce
                    ),
                };
                error!(
                    "{label} to {to} has been planned for {} min without landing ({why}): \
                     the node keeps planning a step that does not land, and a dispute clock \
                     may be running",
                    lasted.as_secs() / 60
                );
            }
        }
        if reports.is_empty() {
            self.planned.clear();
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
        let finalized = chain.finalized_head().await?;
        // Ingestion is finalized-only. A later sealed epoch proves this one's
        // settlement, but it must not outrun the refund observation's head.
        let settled = self.storage.last_sealed_epoch()?.is_some_and(|last| {
            last.epoch_number > epoch.epoch_number && last.block_created_number <= finalized.number
        });
        let mut wave = Vec::new();
        let mut foreclosed = false;
        let application = cartesi_rollups_contracts::i_application::IApplication::new(
            self.application,
            chain.provider().clone(),
        );
        if !settled {
            if let Some(settlement) = self.storage.settlement_info(epoch.epoch_number)? {
                match self.react_dispute(chain, &epoch, &settlement).await {
                    Ok(tick) => {
                        let result = tick.result();
                        let head = tick.head();
                        wave.extend(tick.into_request());
                        if result.is_some() {
                            foreclosed = application
                                .isForeclosed()
                                .block(head.block_id())
                                .call()
                                .await?;
                        }
                        // A sentry votes the state it computed once the root
                        // has a winner, its own or not: after a loss its claim
                        // is the dissent a guardian reads. Staging and
                        // acceptance follow only its own win.
                        if !foreclosed
                            && matches!(
                                result,
                                Some(HeroTerminal::Won | HeroTerminal::Lost(Loss::Root { .. }))
                            )
                        {
                            let consensus =
                                DaveConsensus::new(self.consensus, chain.provider().clone());
                            let step = if result == Some(HeroTerminal::Won) {
                                self.plan_settlement(
                                    &consensus,
                                    epoch.epoch_number,
                                    &settlement,
                                    head,
                                )
                                .await
                            } else {
                                self.plan_sentry_claim(
                                    &consensus,
                                    epoch.epoch_number,
                                    &settlement,
                                    head,
                                )
                                .await
                            };
                            match step {
                                Ok(step) => wave.extend(step),
                                Err(e) => self.stalled(
                                    Level::Warn,
                                    format_args!(
                                        "settlement planning failed, retrying next tick: {e:#}"
                                    ),
                                ),
                            }
                        }
                    }
                    Err(e) if Fatal::of(&e).is_some() => return Err(e),
                    Err(e) if self.shutdown.is_requested() => {
                        info!("dispute planning stopped by shutdown: {e:#}")
                    }
                    Err(e) => self.stalled(
                        Level::Warn,
                        format_args!("dispute planning failed, retrying next tick: {e:#}"),
                    ),
                }
            } else if self
                .storage
                .next_input_id()
                .is_ok_and(|next| next.epoch_number == epoch.epoch_number)
            {
                // Routine while the runner finishes a sealed epoch's tail; the
                // root join waits for it.
                self.stalled(
                    Level::Debug,
                    format_args!(
                        "wait for machine-runner to prepare sealed epoch {}",
                        epoch.epoch_number
                    ),
                );
            } else {
                // Still replaying earlier epochs (a fresh data directory):
                // the replay is the operator's expected wait, not a stall.
                debug!(
                    "wait for machine-runner to reach sealed epoch {}",
                    epoch.epoch_number
                );
            }
        }

        // Every applicable refund joins the same batch, including while the
        // root is running. A failed scan cannot discard already prepared work.
        let refunds_complete = match plan_recovery(
            chain,
            &mut self.recovery,
            &epoch,
            self.signer_address,
            finalized,
        )
        .await
        {
            Ok(recovery) => {
                wave.extend(recovery.wave);
                recovery.complete
            }
            Err(e) => {
                self.stalled(
                    Level::Warn,
                    format_args!("bond recovery planning failed, retrying next tick: {e:#}"),
                );
                false
            }
        };
        if foreclosed
            && refunds_complete
            && application
                .isForeclosed()
                .block(finalized.block_id())
                .call()
                .await?
        {
            return Err(Fatal::terminal(
                "application is foreclosed; dispute defense and bond recovery are complete",
            )
            .into());
        }
        Ok(Some(EpochTick {
            epoch: epoch.epoch_number,
            wave,
            done: settled && refunds_complete,
        }))
    }

    /// Logs why this tick could not advance its epoch: at `quiet` until the
    /// stall has lasted PAGE_AFTER, then at ERROR. A tick that records no
    /// stall clears it.
    fn stalled(&mut self, quiet: Level, message: std::fmt::Arguments<'_>) {
        self.stalled_now = true;
        match self.stall.failed() {
            Level::Error => error!(
                "{message} (the epoch has not advanced for {} min; a dispute clock may be running)",
                self.stall.minutes()
            ),
            _ => log::log!(quiet, "{message}"),
        }
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
        dave_consensus: &Consensus,
        epoch_number: u64,
        settlement: &Settlement,
        head: ChainHead,
    ) -> Result<Option<LaneRequest>> {
        if let Some(step) = self
            .plan_sentry_claim(dave_consensus, epoch_number, settlement, head)
            .await?
        {
            return Ok(Some(step));
        }
        if let Some(step) = self
            .plan_stage_tournament_result(dave_consensus, epoch_number, settlement, head)
            .await?
        {
            return Ok(Some(step));
        }
        self.plan_accept_tournament_result(dave_consensus, epoch_number, settlement, head)
            .await
    }

    /// A sentry claims the post-epoch state it computed itself -
    /// never the staged value - so claims stay an independent check
    /// on the tournament result.
    async fn plan_sentry_claim(
        &mut self,
        dave_consensus: &Consensus,
        epoch_number: u64,
        settlement: &Settlement,
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

        // Its epoch number is the current sealed epoch's.
        let can_accept = dave_consensus
            .canAcceptStagedTournamentResult()
            .block(head.block_id())
            .call()
            .await?;
        if can_accept.epochNumber != U256::from(epoch_number) {
            return Ok(None);
        }
        if can_accept.isTournamentResultStaged && can_accept.isClaimStagingPeriodOver {
            trace!(
                "epoch {epoch_number} already has a staged result past its staging period; a claim buys nothing"
            );
            return Ok(None);
        }

        let has_claimed = dave_consensus
            .hasSentryClaimedInEpoch(can_accept.epochNumber, sentry_id)
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

        let claim = B256::from(settlement.final_state);
        info!("submit sentry claim {claim} for epoch {epoch_number}");
        let request = dave_consensus
            .submitSentryClaim(can_accept.epochNumber, claim)
            .into_transaction_request();
        Ok(Some(("submitSentryClaim".to_string(), request)))
    }

    async fn plan_stage_tournament_result(
        &mut self,
        dave_consensus: &Consensus,
        epoch_number: u64,
        settlement: &Settlement,
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

        // Staging follows the Hero's win, read at this block, where a root
        // without a winner cannot occur (the Hero logs that case). The flag
        // still keeps a failed root, which the contracts can produce, away
        // from the asserts below.
        if !can_stage.isFinished
            || can_stage.isTournamentFailed
            || can_stage.isTournamentResultStaged
        {
            trace!("tournament result not ready to be staged");
            return Ok(None);
        }

        assert_eq!(
            settlement.computation_hash.data(),
            can_stage.winnerCommitment,
            "Winner commitment mismatch, notify all users!"
        );
        assert_eq!(
            B256::from(settlement.final_state),
            can_stage.winnerPostEpochMachineStateHash,
            "Winner final state mismatch, notify all users!"
        );
        // The node defended a terminal app's true state, which no
        // validity proof accepts, so it holds the epoch for the
        // application's guardian.
        if !settlement.machine_validity_proof.settles() {
            log::error!(
                "epoch {epoch_number} ended with the application in a terminal state; \
                 it won the dispute but cannot settle, notify all users!"
            );
            return Ok(None);
        }
        info!(
            "stage tournament result of epoch {epoch_number} with claim {}",
            settlement.computation_hash.to_hex()
        );
        let request = dave_consensus
            .stageTournamentResult(
                can_stage.epochNumber,
                to_machine_validity_proof(&settlement.machine_validity_proof),
            )
            .into_transaction_request();
        Ok(Some(("stageTournamentResult".to_string(), request)))
    }

    async fn plan_accept_tournament_result(
        &mut self,
        dave_consensus: &Consensus,
        epoch_number: u64,
        settlement: &Settlement,
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

        assert_eq!(
            B256::from(settlement.final_state),
            can_accept.stagedPostEpochMachineStateHash,
            "Staged final state mismatch, notify all users!"
        );
        assert_eq!(
            B256::from(settlement.outputs_merkle_root()),
            can_accept.stagedPostEpochOutputsMerkleRoot,
            "Staged outputs Merkle root mismatch, notify all users!"
        );
        if !can_accept.doAllSentriesAgreeWithStagedTournamentResult
            && !can_accept.isClaimStagingPeriodOver
        {
            return Ok(None);
        }
        info!("settle epoch {epoch_number}: accept staged tournament result");
        let request = dave_consensus
            .acceptStagedTournamentResult(can_accept.epochNumber)
            .into_transaction_request();
        Ok(Some(("acceptStagedTournamentResult".to_string(), request)))
    }

    /// The current Hero's repeated observations (Hero::tick).
    #[cfg(test)]
    pub(crate) fn reobservations(&self) -> usize {
        self.epoch_hero
            .as_ref()
            .map_or(0, |hero| hero.reobservations())
    }

    async fn react_dispute(
        &mut self,
        chain: &Chain,
        epoch: &Epoch,
        settlement: &Settlement,
    ) -> Result<HeroTick> {
        if self.epoch_hero.is_none() {
            let storage = Storage::new(self.storage.state_dir())?;
            self.epoch_hero = Some(Hero::new(
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
            None => {}
            Some(HeroTerminal::Won) => info!(
                "local commitment won dispute tournament {} for epoch {}",
                epoch.root_tournament, epoch.epoch_number
            ),
            Some(HeroTerminal::Lost(loss)) => report_loss(epoch, settlement, loss),
            Some(HeroTerminal::FailedNoWinner) => log::error!(
                "dispute tournament {} for epoch {} finished without a winner",
                epoch.root_tournament,
                epoch.epoch_number
            ),
        }
        Ok(tick)
    }
}

/// Names how the epoch's dispute was lost, once per tick. Every case
/// means the honest commitment was not defended in time; a root won
/// with another final state also means the chain will settle a state
/// this node did not compute.
fn report_loss(epoch: &Epoch, settlement: &Settlement, loss: Loss) {
    let e = epoch.epoch_number;
    match loss {
        Loss::Root { final_state } => {
            let ours = Digest::from(settlement.final_state);
            if ours == final_state {
                error!(
                    "epoch {e}: root tournament {} went to another commitment with this \
                     node's final state {final_state}: the correct state settles once anyone \
                     stages it (this node stages only its own win), but this node's \
                     commitment was not defended in time",
                    epoch.root_tournament
                );
            } else {
                error!(
                    "epoch {e} DIVERGED: root tournament {} went to a commitment ending in \
                     {final_state}, but this node computed {ours}. The application's guardian \
                     can still foreclose before the staged result is accepted; a sentry \
                     node votes its own state, and the node stops (exit 30) at the next \
                     epoch, which starts from the settled state",
                    epoch.root_tournament,
                );
            }
        }
        Loss::Eliminated { tournament, reason } => error!(
            "epoch {e}: the local commitment was eliminated in tournament {tournament} \
             ({reason:?}); root tournament {}",
            epoch.root_tournament
        ),
        Loss::Child { tournament } => error!(
            "epoch {e}: another commitment class won child tournament {tournament} of the \
             local commitment's match; root tournament {}",
            epoch.root_tournament
        ),
    }
}

fn call_key((label, request): &LaneRequest) -> CallKey {
    let input = request.input.input().map(keccak256).unwrap_or_default();
    (label.clone(), request.to, input)
}

/// This tick's calls (one report per call, in order), each with the instant
/// it was first planned on consecutive ticks, and those planned for
/// PAGE_AFTER or longer. Planning reads latest and drops a call once it
/// lands, so a call planned tick after tick has not landed: it reverts at
/// estimation, the submit endpoint does not answer, a relay holds or dropped
/// it, it is outbid, or it mines without effect. A repeat or two is routine:
/// inclusion takes a block or two, and another honest node's copy of a step
/// can land first.
fn track_planned<'r>(
    previous: &[(CallKey, Instant)],
    calls: Vec<CallKey>,
    reports: &'r [SendReport],
    now: Instant,
) -> (Vec<(CallKey, Instant)>, Vec<Overdue<'r>>) {
    let mut overdue = Vec::new();
    let planned = calls
        .into_iter()
        .zip(reports)
        .map(|(call, report)| {
            let since = previous
                .iter()
                .find(|(planned, _)| *planned == call)
                .map_or(now, |(_, since)| *since);
            let lasted = now.saturating_duration_since(since);
            if lasted >= PAGE_AFTER {
                overdue.push((call.clone(), report, lasted));
            }
            (call, since)
        })
        .collect();
    (planned, overdue)
}

fn to_leaf_proof(proof: &StoredLeafProof) -> DaveConsensus::LeafProof {
    DaveConsensus::LeafProof {
        dataBlock: B256::from(proof.data_block),
        siblings: proof.siblings.inner().iter().map(B256::from).collect(),
    }
}

fn to_machine_validity_proof(
    proof: &StoredMachineValidityProof,
) -> DaveConsensus::MachineValidityProof {
    DaveConsensus::MachineValidityProof {
        iflagsYProof: to_leaf_proof(&proof.iflags_y_proof),
        htifTohostProof: to_leaf_proof(&proof.htif_tohost_proof),
        txBufferProof: to_leaf_proof(&proof.tx_buffer_proof),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::SendVerdict;
    use crate::storage::{
        LeafProof, MACHINE_MEMORY_PROOF_SIBLING_COUNT, MachineValidityProof, Proof,
    };
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
    fn a_call_pages_once_it_has_been_planned_for_the_response_window() {
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
            revert: None,
        };
        let reports = [report(SendVerdict::Submitted), report(SendVerdict::Reverts)];
        let start = Instant::now();
        let tick = |previous: &[(CallKey, Instant)], calls: Vec<CallKey>, at: Duration| {
            let count = calls.len();
            let (planned, overdue) = track_planned(previous, calls, &reports[..count], start + at);
            let overdue: Vec<_> = overdue.into_iter().map(|(call, _, _)| call).collect();
            (planned, overdue)
        };
        let advance = call("advanceMatch", 1);

        // Planned again and again, whatever the verdict, it pages once it
        // has been planned for the response window.
        let (first, overdue) = tick(&[], vec![advance.clone()], Duration::ZERO);
        assert!(overdue.is_empty());
        let (second, overdue) = tick(&first, vec![advance.clone()], PAGE_AFTER / 2);
        assert!(overdue.is_empty());
        let (_, overdue) = tick(&second, vec![advance.clone()], PAGE_AFTER);
        assert_eq!(overdue, vec![advance.clone()]);
        // A tick without it restarts its clock, and the next step of the
        // same verb is another call.
        let (none, _) = tick(&second, vec![], PAGE_AFTER);
        assert!(
            tick(&none, vec![advance.clone()], 2 * PAGE_AFTER)
                .1
                .is_empty()
        );
        assert!(
            tick(&second, vec![call("advanceMatch", 3)], PAGE_AFTER)
                .1
                .is_empty()
        );
        // Recoveries share verb and calldata; another tournament is another
        // call.
        let (recovery, _) = tick(
            &[],
            vec![call_to("tryRecoveringBond", 0x20, 0)],
            Duration::ZERO,
        );
        let other = vec![call_to("tryRecoveringBond", 0x21, 0)];
        assert!(tick(&recovery, other, PAGE_AFTER).1.is_empty());
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
            proof: to_machine_validity_proof(&proof),
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

    fn manager(path: &Path) -> (EpochManager, Chain, Asserter) {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        let (manager, chain) = manager_on(path, provider);
        (manager, chain, asserter)
    }

    fn manager_on(path: &Path, provider: DynProvider) -> (EpochManager, Chain) {
        let signer = PrivateKeySigner::from_bytes(&B256::repeat_byte(0x11)).unwrap();
        let address = signer.address();
        let lane = TransactionLane::new(
            provider.clone(),
            provider.clone(),
            31337,
            EthereumWallet::from(signer),
        );
        let manager = EpochManager::new(
            lane,
            Address::repeat_byte(0xCC),
            Address::repeat_byte(0xAA),
            address,
            Storage::new(path).unwrap(),
            Duration::ZERO,
            ShutdownSignal::default(),
        );
        (manager, Chain::new(provider))
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
        // The tree is already walked through 30: no logs, only the bond read.
        push_head(&rpc, 30);
        push_bond(&rpc, 2, us);
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
        let ours = storage.settlement_info(0).unwrap().unwrap();
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
                .plan_stage_tournament_result(&consensus, 0, &ours, won_at())
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
                .plan_accept_tournament_result(&consensus, 0, &ours, won_at())
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
        let mut storage = crate::storage::sql::test_helper::seed_storage(
            dir.path(),
            &template,
            0,
            &crate::engine::TournamentGeometry::two_level(),
        );
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

        let sentry = U256::from(1);

        // A sentry that already claimed stages the result.
        push_call::<DaveConsensus::getSentryIdCall>(&rpc, &sentry);
        push_call::<DaveConsensus::canAcceptStagedTournamentResultCall>(&rpc, &staged(false));
        push_call::<DaveConsensus::hasSentryClaimedInEpochCall>(&rpc, &true);
        push_call::<DaveConsensus::canStageTournamentResultCall>(&rpc, &can_stage(false));
        let (label, _) = manager
            .plan_settlement(&consensus, 0, &settlement, won_at())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(label, "stageTournamentResult");

        // Once it is staged past its period, nobody claims or stages again.
        push_call::<DaveConsensus::getSentryIdCall>(&rpc, &sentry);
        push_call::<DaveConsensus::canAcceptStagedTournamentResultCall>(&rpc, &staged(true));
        push_call::<DaveConsensus::canStageTournamentResultCall>(&rpc, &can_stage(true));
        push_call::<DaveConsensus::canAcceptStagedTournamentResultCall>(&rpc, &staged(true));
        let (label, _) = manager
            .plan_settlement(&consensus, 0, &settlement, won_at())
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
        assert_eq!(calls.len(), 8);
        for call in calls {
            assert_eq!(
                call["params"][1],
                serde_json::json!(format!("{:#x}", won_at().hash))
            );
        }
    }

    /// A rolled epoch 0 whose template is yielded with an exception, the
    /// ordinary terminal application.
    fn rolled_terminal_epoch_zero() -> (tempfile::TempDir, Storage) {
        rolled_epoch_zero(crate::storage::sql::test_helper::yield_exception)
    }

    #[tokio::test]
    async fn unstageable_roots_never_reach_a_stage_request() {
        let (dir, mut storage) = rolled_terminal_epoch_zero();
        let settlement = storage.settlement_info(0).unwrap().unwrap();
        assert!(!settlement.machine_validity_proof.settles());
        let (mut manager, chain, rpc) = manager(dir.path());
        let consensus = DaveConsensus::new(manager.consensus, chain.provider().clone());

        // The node won its terminal state's root: the views agree with the
        // local row, and no validity proof accepts it, so the epoch is held.
        push_call::<DaveConsensus::canStageTournamentResultCall>(
            &rpc,
            &DaveConsensus::canStageTournamentResultReturn {
                isFinished: true,
                isTournamentFailed: false,
                isTournamentResultStaged: false,
                epochNumber: U256::ZERO,
                winnerCommitment: B256::from(settlement.computation_hash.data()),
                winnerPostEpochMachineStateHash: B256::from(settlement.final_state),
            },
        );
        assert!(
            manager
                .plan_stage_tournament_result(&consensus, 0, &settlement, won_at())
                .await
                .unwrap()
                .is_none()
        );

        // A root that finished without a winner reports zero winner values,
        // which the local row contradicts: the flag must stop it before
        // the settle asserts.
        push_call::<DaveConsensus::canStageTournamentResultCall>(
            &rpc,
            &DaveConsensus::canStageTournamentResultReturn {
                isFinished: true,
                isTournamentFailed: true,
                isTournamentResultStaged: false,
                epochNumber: U256::ZERO,
                winnerCommitment: B256::ZERO,
                winnerPostEpochMachineStateHash: B256::ZERO,
            },
        );
        assert!(
            manager
                .plan_stage_tournament_result(&consensus, 0, &settlement, won_at())
                .await
                .unwrap()
                .is_none()
        );
        assert!(rpc.read_q().is_empty());
    }
}
