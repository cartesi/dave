// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The bond recovery planner: low-priority maintenance over finalized
//! chain state (docs/plans/bond-recovery-redesign.md).
//!
//! Candidates never come from attacker-writable input. Epoch roots are
//! read from our own storage (written from the trusted DaveConsensus
//! stream), and inner tournaments from each trusted tournament's own
//! NewInnerTournament events - the same provenance-descended tree walk
//! the dispute fold relies on, reusable here after the epoch's hero is
//! gone. One bondRecovery() read per tree node then decides: the view
//! reports the winning claimer from the contract's own classification,
//! so "did we join and win" needs no join history at all.
//!
//! Retirement uses one coherent finalized snapshot: both the event
//! tree and every bond classification are pinned to its hash. Latest
//! is consulted only to suppress a transaction already observed as
//! mined. It can never retire an epoch, so a reorg cannot turn a
//! volatile observation into permanent process state.

use std::collections::BTreeSet;

use alloy::primitives::Address;
use anyhow::Result;
use log::{info, trace};

use crate::chain::{Chain, ChainHead};
use crate::provider::LaneRequest;
use crate::storage::Epoch;
use crate::tournament::gas_limit;
use cartesi_prt_contracts::tournament;

/// ITournament.BondDisposition, by declaration order.
const TOURNAMENT_RUNNING: u8 = 0;
const NO_WINNER: u8 = 1;
const RECOVERABLE: u8 = 2;
const RECOVERED: u8 = 3;

pub struct BondRecovery {
    signer_address: Address,
    /// Epochs whose whole tournament tree reached terminal bond
    /// dispositions; nothing there can ever need recovery again.
    completed_epochs: BTreeSet<u64>,
    /// Recovery is maintenance, not clock-bearing work. Scan at most
    /// once per finalized head after a successful complete attempt.
    last_scanned_finalized: Option<ChainHead>,
}

impl BondRecovery {
    pub fn new(signer_address: Address) -> Self {
        Self {
            signer_address,
            completed_epochs: BTreeSet::new(),
            last_scanned_finalized: None,
        }
    }

    /// Plan at most one recovery for this finalized-head slot. All
    /// sealed epochs participate, so epoch rotation and restart do not
    /// strand an older root.
    pub async fn plan_due(
        &mut self,
        chain: &Chain,
        epochs: &[Epoch],
    ) -> Result<Option<LaneRequest>> {
        let finalized = chain.finalized_head().await?;
        if self.last_scanned_finalized == Some(finalized) {
            return Ok(None);
        }

        let recovery = self.plan_at(chain, epochs, finalized).await?;
        self.last_scanned_finalized = Some(finalized);
        Ok(recovery)
    }

    async fn plan_at(
        &mut self,
        chain: &Chain,
        epochs: &[Epoch],
        finalized: ChainHead,
    ) -> Result<Option<LaneRequest>> {
        let mut candidates = Vec::new();

        for epoch in epochs {
            if self.completed_epochs.contains(&epoch.epoch_number) {
                continue;
            }
            let tree = tournament_tree(
                chain,
                epoch.root_tournament,
                epoch.block_created_number,
                finalized.number,
            )
            .await?;

            let mut all_terminal = true;
            for tournament in tree {
                let contract = tournament::Tournament::new(tournament, chain.provider());
                let recovery = contract
                    .bondRecovery()
                    .block(finalized.block_id())
                    .call()
                    .await?;
                match candidate_action(recovery.disposition, recovery.claimer, self.signer_address)
                {
                    CandidateAction::Recover => {
                        candidates.push(tournament);
                        all_terminal = false;
                    }
                    CandidateAction::Keep => {
                        all_terminal = false;
                    }
                    CandidateAction::Retire => {}
                }
            }
            if all_terminal {
                trace!(
                    "epoch {} retired: every tournament bond is terminal",
                    epoch.epoch_number
                );
                self.completed_epochs.insert(epoch.epoch_number);
            }
        }

        if candidates.is_empty() {
            return Ok(None);
        }

        // A mined recovery need not be resubmitted while it waits for
        // finality. This observation is deliberately not memoized: a
        // reorg merely makes the candidate eligible at the next
        // finalized-head slot.
        let latest = chain.latest_head().await?;
        for tournament in candidates {
            let contract = tournament::Tournament::new(tournament, chain.provider());
            let recovery = contract
                .bondRecovery()
                .block(latest.block_id())
                .call()
                .await?;
            if recovery.disposition == RECOVERED {
                trace!("bond recovery for tournament {tournament} is already mined");
                continue;
            }

            info!("plan bond recovery for tournament {tournament}");
            let request = contract
                .tryRecoveringBond()
                .gas(gas_limit())
                .into_transaction_request();
            return Ok(Some(("tryRecoveringBond".to_string(), request)));
        }

        Ok(None)
    }
}

/// Enumerate one epoch's dispute tree root-down. Every address comes
/// from a trusted parent's own NewInnerTournament events over
/// finalized blocks, so the whole tree inherits the root's provenance.
async fn tournament_tree(chain: &Chain, root: Address, from: u64, to: u64) -> Result<Vec<Address>> {
    let mut tree = vec![root];
    let mut cursor = 0;
    while cursor < tree.len() {
        let parent = tree[cursor];
        cursor += 1;
        let children = chain
            .decoded_logs::<tournament::Tournament::NewInnerTournament>(parent, None, from, to)
            .await?;
        for (event, _) in children {
            tree.push(event.childTournament);
        }
    }
    Ok(tree)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CandidateAction {
    Recover,
    Keep,
    Retire,
}

/// One candidate's fate from its on-chain disposition: recover what
/// is ours, keep watching a running tournament, retire everything
/// terminal - recovered (by anyone), locked without a winner, or a
/// bond whose winning claimer is someone else (our commitment lost,
/// or we never joined this branch of the tree).
fn candidate_action(disposition: u8, claimer: Address, us: Address) -> CandidateAction {
    match disposition {
        RECOVERABLE if claimer == us => CandidateAction::Recover,
        RECOVERABLE | RECOVERED | NO_WINNER => CandidateAction::Retire,
        TOURNAMENT_RUNNING => CandidateAction::Keep,
        other => {
            // A trusted tournament cannot produce this; stay inert
            // rather than fatal on chain data.
            log::warn!("undefined bond disposition {other}; keeping candidate inert");
            CandidateAction::Keep
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        primitives::{B256, Bytes, Log as PrimitiveLog, TxKind, U256},
        providers::{Provider, ProviderBuilder},
        rpc::types::{Block, Log},
        sol_types::{SolCall, SolEvent},
        transports::mock::Asserter,
    };

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn head(number: u64, byte: u8) -> ChainHead {
        ChainHead {
            number,
            hash: B256::repeat_byte(byte),
        }
    }

    fn block(head: ChainHead) -> Block {
        let mut block: Block = Block::default();
        block.header.hash = head.hash;
        block.header.inner.number = head.number;
        block
    }

    fn epoch(epoch_number: u64, root_tournament: Address, created_at: u64) -> Epoch {
        Epoch {
            epoch_number,
            input_index_boundary: 0,
            root_tournament,
            block_created_number: created_at,
        }
    }

    fn mocked_chain() -> (Chain, Asserter) {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        (Chain::new(provider, Vec::new()), asserter)
    }

    fn push_call_response<C: SolCall>(asserter: &Asserter, response: &C::Return) {
        asserter.push_success(&Bytes::from(C::abi_encode_returns(response)));
    }

    fn push_bond(asserter: &Asserter, disposition: u8, claimer: Address) {
        push_call_response::<tournament::Tournament::bondRecoveryCall>(
            asserter,
            &tournament::Tournament::bondRecoveryReturn {
                disposition,
                claimer,
                payment: U256::ZERO,
            },
        );
    }

    fn child_log(parent: Address, child: Address, at: ChainHead) -> Log {
        let event = tournament::Tournament::NewInnerTournament {
            matchIdHash: B256::repeat_byte(0x44),
            childTournament: child,
        };
        Log {
            inner: PrimitiveLog {
                address: parent,
                data: event.encode_log_data(),
            },
            block_hash: Some(at.hash),
            block_number: Some(at.number),
            block_timestamp: None,
            transaction_hash: Some(B256::repeat_byte(0x55)),
            transaction_index: Some(0),
            log_index: Some(0),
            removed: false,
        }
    }

    fn assert_recovers(request: &LaneRequest, tournament: Address) {
        assert_eq!(request.0, "tryRecoveringBond");
        assert_eq!(request.1.to, Some(TxKind::Call(tournament)));
    }

    #[test]
    fn candidate_fate_follows_the_disposition_arms() {
        let us = address(1);
        let them = address(2);
        assert_eq!(
            candidate_action(RECOVERABLE, us, us),
            CandidateAction::Recover
        );
        assert_eq!(
            candidate_action(RECOVERABLE, them, us),
            CandidateAction::Retire,
            "someone else's recoverable bond is not our work"
        );
        assert_eq!(
            candidate_action(RECOVERED, Address::ZERO, us),
            CandidateAction::Retire
        );
        assert_eq!(
            candidate_action(NO_WINNER, Address::ZERO, us),
            CandidateAction::Retire
        );
        assert_eq!(
            candidate_action(TOURNAMENT_RUNNING, Address::ZERO, us),
            CandidateAction::Keep
        );
        assert_eq!(
            candidate_action(9, Address::ZERO, us),
            CandidateAction::Keep,
            "undefined dispositions stay inert, never fatal"
        );
    }

    /// The Round-1 finding-4 class: a hand-maintained numeric mirror
    /// of a Solidity enum needs a drift guard against its source.
    #[test]
    fn bond_disposition_mirror_matches_the_interface() {
        let source = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../prt/contracts/src/ITournament.sol"
        ))
        .expect("ITournament.sol must be readable from the workspace");
        let body = source
            .split("enum BondDisposition {")
            .nth(1)
            .expect("ITournament.sol declares BondDisposition")
            .split('}')
            .next()
            .expect("enum body closes");
        let variants: Vec<&str> = body
            .split(',')
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .collect();
        assert_eq!(variants[TOURNAMENT_RUNNING as usize], "TOURNAMENT_RUNNING");
        assert_eq!(variants[NO_WINNER as usize], "NO_WINNER");
        assert_eq!(variants[RECOVERABLE as usize], "RECOVERABLE");
        assert_eq!(variants[RECOVERED as usize], "RECOVERED");
        assert_eq!(variants.len(), 4, "new arms need mirroring here");
    }

    #[tokio::test]
    async fn finalized_snapshot_cannot_retire_a_child_before_its_event_is_finalized() {
        let us = address(1);
        let root = address(2);
        let child = address(3);
        let f1 = head(10, 0x10);
        let f2 = head(11, 0x11);
        let latest = head(12, 0x12);
        let (chain, asserter) = mocked_chain();
        let mut recovery = BondRecovery::new(us);
        let epochs = [epoch(7, root, 5)];

        // At F1 the child does not exist yet and the root is still
        // running. A latest view could already report the root as
        // recovered, but it is intentionally never queried here.
        asserter.push_success(&Some(block(f1)));
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, TOURNAMENT_RUNNING, Address::ZERO);
        assert!(recovery.plan_due(&chain, &epochs).await.unwrap().is_none());
        assert!(!recovery.completed_epochs.contains(&7));

        // Once F2 includes the child, the same pinned snapshot sees
        // the terminal root and our recoverable child together.
        asserter.push_success(&Some(block(f2)));
        asserter.push_success(&vec![child_log(root, child, f2)]);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(latest)));
        push_bond(&asserter, RECOVERABLE, us);

        let request = recovery
            .plan_due(&chain, &epochs)
            .await
            .unwrap()
            .expect("the finalized child remains recoverable");
        assert_recovers(&request, child);
        assert!(!recovery.completed_epochs.contains(&7));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn latest_suppression_is_not_retirement_and_recovers_after_a_reorg() {
        let us = address(1);
        let root = address(2);
        let f1 = head(20, 0x20);
        let f2 = head(21, 0x21);
        let h1 = head(22, 0x22);
        let h2 = head(22, 0x32);
        let (chain, asserter) = mocked_chain();
        let mut recovery = BondRecovery::new(us);
        let epochs = [epoch(8, root, 5)];

        asserter.push_success(&Some(block(f1)));
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(h1)));
        push_bond(&asserter, RECOVERED, Address::ZERO);
        assert!(recovery.plan_due(&chain, &epochs).await.unwrap().is_none());
        assert!(!recovery.completed_epochs.contains(&8));

        // The same finalized slot performs no tree or point-read scan.
        asserter.push_success(&Some(block(f1)));
        assert!(recovery.plan_due(&chain, &epochs).await.unwrap().is_none());

        // The unfinalized recovery disappears. A new finalized slot
        // recomputes from durable state and makes the bond actionable.
        asserter.push_success(&Some(block(f2)));
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(h2)));
        push_bond(&asserter, RECOVERABLE, us);

        let request = recovery
            .plan_due(&chain, &epochs)
            .await
            .unwrap()
            .expect("latest suppression must not survive a later finalized slot");
        assert_recovers(&request, root);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn epoch_rotation_keeps_older_roots_and_plans_only_one_recovery() {
        let us = address(1);
        let old_root = address(2);
        let new_root = address(3);
        let finalized = head(30, 0x30);
        let latest = head(31, 0x31);
        let (chain, asserter) = mocked_chain();
        let mut recovery = BondRecovery::new(us);
        let epochs = [epoch(8, old_root, 5), epoch(9, new_root, 25)];

        asserter.push_success(&Some(block(finalized)));
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(latest)));
        push_bond(&asserter, RECOVERABLE, us);

        let request = recovery
            .plan_due(&chain, &epochs)
            .await
            .unwrap()
            .expect("the newer epoch is still scanned after the older one retires");
        assert_recovers(&request, new_root);
        assert!(recovery.completed_epochs.contains(&8));
        assert!(!recovery.completed_epochs.contains(&9));
        assert!(asserter.read_q().is_empty());
    }
}
