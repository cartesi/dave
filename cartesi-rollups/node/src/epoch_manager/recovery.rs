// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Recover one epoch's bonds before its local lifecycle completes.
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
//! Completion uses one coherent finalized snapshot: the event tree
//! ends at that block and every bond classification uses its hash. Latest
//! is consulted only to suppress a transaction already observed as
//! mined. It can never retire an epoch, so a reorg cannot turn a
//! volatile observation into permanent process state.
//!
//! The walked tree is a finalized fact, so it is kept across ticks: each
//! tick walks only the newly finalized blocks. A tournament leaves it once
//! it can no longer owe us a payment (recovered, without a winner, or
//! another claimer's): any of those means it has finished, so it never
//! creates another child. This scan runs before the tick's wave is sent,
//! so its cost must not grow with the dispute's age or with the
//! tournaments an adversary has created and resolved.

use alloy::primitives::Address;
use anyhow::Result;
use futures::{StreamExt, TryStreamExt, stream};
use log::{info, trace};

use crate::chain::{Chain, ChainHead};
use crate::provider::LaneRequest;
use crate::storage::Epoch;
use crate::tournament::observer::POINT_READ_CONCURRENCY;
use cartesi_prt_contracts::tournament;

/// ITournament.BondDisposition, by declaration order.
const TOURNAMENT_RUNNING: u8 = 0;
const NO_WINNER: u8 = 1;
const RECOVERABLE: u8 = 2;
const RECOVERED: u8 = 3;

pub struct RecoveryTick {
    pub wave: Vec<LaneRequest>,
    pub complete: bool,
}

/// One epoch's dispute tree as walked over finalized blocks. Held in
/// memory only: a restart rebuilds it with one full walk.
#[derive(Debug)]
pub struct RecoveryTree {
    epoch_number: u64,
    /// The first block whose NewInnerTournament events are not walked.
    next_block: u64,
    /// The open tournaments, those still running or owing us a payment:
    /// the root first while open, then children in discovery order.
    tournaments: Vec<Address>,
}

impl RecoveryTree {
    fn new(epoch: &Epoch) -> Self {
        Self {
            epoch_number: epoch.epoch_number,
            next_block: epoch.block_created_number,
            tournaments: vec![epoch.root_tournament],
        }
    }

    /// Extends the tree through `to`. A child created in the range may
    /// itself create children in it, so the range is walked again for
    /// each new generation. A failed walk keeps what it found and leaves
    /// the range to the next tick.
    async fn walk_to(&mut self, chain: &Chain, to: u64) -> Result<()> {
        if to < self.next_block {
            return Ok(());
        }
        let mut parents = self.tournaments.clone();
        while !parents.is_empty() {
            let events = chain
                .decoded_logs_from_any::<tournament::Tournament::NewInnerTournament>(
                    &parents,
                    self.next_block,
                    to,
                )
                .await?;
            let mut children = Vec::new();
            for (event, log) in events {
                let child = event.childTournament;
                // Provenance: only a known parent's own event names a child.
                if parents.contains(&log.address()) && !self.tournaments.contains(&child) {
                    self.tournaments.push(child);
                    children.push(child);
                }
            }
            parents = children;
        }
        self.next_block = to + 1;
        Ok(())
    }
}

/// Plan outstanding recoveries from finalized chain state, keeping `tree`
/// for the next tick. Only finalized classifications may complete an
/// epoch; mined payments suppress retries.
pub async fn plan_recovery(
    chain: &Chain,
    tree: &mut Option<RecoveryTree>,
    epoch: &Epoch,
    claimant: Address,
    finalized: ChainHead,
) -> Result<RecoveryTick> {
    if epoch.block_created_number > finalized.number {
        return Ok(RecoveryTick {
            wave: Vec::new(),
            complete: false,
        });
    }

    let tree = match tree {
        Some(tree) if tree.epoch_number == epoch.epoch_number => tree,
        _ => tree.insert(RecoveryTree::new(epoch)),
    };
    tree.walk_to(chain, finalized.number).await?;

    let tournaments = tree.tournaments.clone();
    let recoveries = stream::iter(tournaments.into_iter().map(|address| async move {
        let recovery = tournament::Tournament::new(address, chain.provider())
            .bondRecovery()
            .block(finalized.block_id())
            .call()
            .await?;
        Ok::<_, anyhow::Error>((address, recovery))
    }))
    .buffered(POINT_READ_CONCURRENCY)
    .try_collect::<Vec<_>>()
    .await?;

    let mut candidates = Vec::new();
    let mut open = Vec::new();
    for (tournament, recovery) in recoveries {
        match recovery.disposition {
            RECOVERABLE if recovery.claimer == claimant => {
                candidates.push(tournament);
                open.push(tournament);
            }
            RECOVERABLE | RECOVERED | NO_WINNER => {}
            TOURNAMENT_RUNNING => open.push(tournament),
            other => {
                // Refunds gate the next epoch, so this holds the node out of
                // every later dispute until an operator acts.
                log::error!(
                    "unknown bond disposition {other} for tournament {tournament}; \
                     keeping epoch incomplete, so the next epoch waits for an operator"
                );
                open.push(tournament);
            }
        }
    }
    let mut tick = RecoveryTick {
        wave: Vec::new(),
        complete: open.is_empty(),
    };
    tree.tournaments = open;

    if candidates.is_empty() {
        return Ok(tick);
    }

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
        let request = contract.tryRecoveringBond().into_transaction_request();
        tick.wave.push(("tryRecoveringBond".to_string(), request));
    }

    Ok(tick)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chain::recording::{Requests, log_requests, recording_provider};
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
        (Chain::new(provider), asserter)
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

    /// The generated bindings expose this Solidity enum as a number.
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
        let epoch = epoch(7, root, 5);
        let mut tree = None;

        // At F1 the child does not exist yet and the root is still
        // running. A latest view could already report the root as
        // recovered, but it is intentionally never queried here.
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, TOURNAMENT_RUNNING, Address::ZERO);
        let tick = plan_recovery(&chain, &mut tree, &epoch, us, f1)
            .await
            .unwrap();
        assert!(tick.wave.is_empty());
        assert!(!tick.complete);

        // Once F2 includes the child, the same pinned snapshot sees
        // the terminal root and our recoverable child together.
        asserter.push_success(&vec![child_log(root, child, f2)]);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(latest)));
        push_bond(&asserter, RECOVERABLE, us);

        let tick = plan_recovery(&chain, &mut tree, &epoch, us, f2)
            .await
            .unwrap();
        assert_eq!(tick.wave.len(), 1);
        assert_recovers(&tick.wave[0], child);
        assert!(!tick.complete);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn latest_suppression_is_not_completion_and_recovers_after_a_reorg() {
        let us = address(1);
        let root = address(2);
        let f1 = head(20, 0x20);
        let f2 = head(21, 0x21);
        let h1 = head(22, 0x22);
        let h2 = head(22, 0x32);
        let (chain, asserter) = mocked_chain();
        let epoch = epoch(8, root, 5);
        let mut tree = None;

        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(h1)));
        push_bond(&asserter, RECOVERED, Address::ZERO);
        let tick = plan_recovery(&chain, &mut tree, &epoch, us, f1)
            .await
            .unwrap();
        assert!(tick.wave.is_empty());
        assert!(!tick.complete);

        // Retry immediately when the payment disappears, even while the
        // finalized head has not advanced (so no blocks are walked).
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(h2)));
        push_bond(&asserter, RECOVERABLE, us);

        let tick = plan_recovery(&chain, &mut tree, &epoch, us, f1)
            .await
            .unwrap();
        assert_eq!(tick.wave.len(), 1);
        assert_recovers(&tick.wave[0], root);
        assert!(!tick.complete);

        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        let tick = plan_recovery(&chain, &mut tree, &epoch, us, f2)
            .await
            .unwrap();
        assert!(tick.wave.is_empty());
        assert!(tick.complete);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn every_owned_bond_is_rebuilt_on_the_same_finalized_head() {
        let us = address(1);
        let root = address(2);
        let child = address(3);
        let finalized = head(30, 0x30);
        let latest = head(31, 0x31);
        let (chain, asserter) = mocked_chain();
        let epoch = epoch(9, root, 5);
        let mut tree = None;

        for tick in 0..2 {
            // The tree is walked once; the bonds are read on every tick.
            if tick == 0 {
                asserter.push_success(&vec![child_log(root, child, finalized)]);
                asserter.push_success(&Vec::<Log>::new());
            }
            push_bond(&asserter, RECOVERABLE, us);
            push_bond(&asserter, RECOVERABLE, us);
            asserter.push_success(&Some(block(latest)));
            push_bond(&asserter, RECOVERABLE, us);
            push_bond(&asserter, RECOVERABLE, us);

            let tick = plan_recovery(&chain, &mut tree, &epoch, us, finalized)
                .await
                .unwrap();
            assert_eq!(tick.wave.len(), 2);
            assert_recovers(&tick.wave[0], root);
            assert_recovers(&tick.wave[1], child);
            assert!(!tick.complete);
        }
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn recovered_foreign_and_no_winner_bonds_complete_the_epoch() {
        let us = address(1);
        let root = address(2);
        let child = address(3);
        let grandchild = address(4);
        let finalized = head(30, 0x30);
        let (chain, asserter) = mocked_chain();
        let epoch = epoch(9, root, 5);

        asserter.push_success(&vec![child_log(root, child, head(10, 0x10))]);
        asserter.push_success(&vec![child_log(child, grandchild, head(11, 0x11))]);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        push_bond(&asserter, RECOVERABLE, address(5));
        push_bond(&asserter, NO_WINNER, Address::ZERO);

        let tick = plan_recovery(&chain, &mut None, &epoch, us, finalized)
            .await
            .unwrap();
        assert!(tick.wave.is_empty());
        assert!(tick.complete);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn running_and_undefined_dispositions_keep_the_epoch_incomplete() {
        let (chain, asserter) = mocked_chain();
        let epoch = epoch(9, address(2), 5);

        for disposition in [TOURNAMENT_RUNNING, 9] {
            asserter.push_success(&Vec::<Log>::new());
            push_bond(&asserter, disposition, Address::ZERO);
            let tick = plan_recovery(&chain, &mut None, &epoch, address(1), head(30, 0x30))
                .await
                .unwrap();
            assert!(tick.wave.is_empty());
            assert!(!tick.complete);
        }
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn epoch_created_after_the_snapshot_waits_without_reading_its_tree() {
        let (chain, asserter) = mocked_chain();
        let epoch = epoch(9, address(2), 31);

        let tick = plan_recovery(&chain, &mut None, &epoch, address(1), head(30, 0x30))
            .await
            .unwrap();
        assert!(tick.wave.is_empty());
        assert!(!tick.complete);
        assert!(asserter.read_q().is_empty());
    }

    /// The recorded get_logs requests and the number of point reads.
    fn requested(requests: &Requests) -> (Vec<(u64, u64, usize)>, usize) {
        let calls = requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request["method"] == "eth_call")
            .count();
        (log_requests(requests), calls)
    }

    #[tokio::test]
    async fn a_later_tick_walks_only_new_blocks_from_open_tournaments() {
        let us = address(1);
        let root = address(2);
        let child = address(3);
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        let epoch = epoch(9, root, 5);
        let mut tree = None;

        asserter.push_success(&vec![child_log(root, child, head(10, 0x10))]);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        push_bond(&asserter, TOURNAMENT_RUNNING, Address::ZERO);
        let tick = plan_recovery(&chain, &mut tree, &epoch, us, head(30, 0x30))
            .await
            .unwrap();
        assert!(!tick.complete);

        // The recovered root has left the tree: only the still-running
        // child is walked over the new blocks and read again.
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, NO_WINNER, Address::ZERO);
        let tick = plan_recovery(&chain, &mut tree, &epoch, us, head(40, 0x40))
            .await
            .unwrap();
        assert!(tick.complete);

        let (logs, calls) = requested(&requests);
        assert_eq!(logs, [(5, 30, 1), (5, 30, 1), (31, 40, 1)]);
        assert_eq!(calls, 3);
        assert!(asserter.read_q().is_empty());
    }

    /// A walk that fails in a later generation keeps the child it found and
    /// walks the same blocks again, so a grandchild created there is not
    /// missed; a log from an address outside the tree names no child.
    #[tokio::test]
    async fn a_failed_walk_resumes_over_the_same_blocks() {
        let us = address(1);
        let root = address(2);
        let child = address(3);
        let grandchild = address(4);
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        let epoch = epoch(9, root, 29);
        let mut tree = None;

        // The child's own walk fails over [29, 30] and again at block 29.
        asserter.push_success(&vec![child_log(root, child, head(29, 0x29))]);
        asserter.push_failure_msg("getLogs unavailable");
        asserter.push_failure_msg("getLogs unavailable");
        assert!(
            plan_recovery(&chain, &mut tree, &epoch, us, head(30, 0x30))
                .await
                .is_err()
        );

        asserter.push_success(&vec![
            child_log(root, child, head(29, 0x29)),
            child_log(address(9), address(10), head(29, 0x29)),
            child_log(child, grandchild, head(30, 0x30)),
        ]);
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        push_bond(&asserter, NO_WINNER, Address::ZERO);
        push_bond(&asserter, TOURNAMENT_RUNNING, Address::ZERO);
        let tick = plan_recovery(&chain, &mut tree, &epoch, us, head(30, 0x30))
            .await
            .unwrap();
        assert!(!tick.complete);

        let (logs, calls) = requested(&requests);
        assert_eq!(
            logs,
            [
                (29, 30, 1),
                (29, 30, 1),
                (29, 29, 1),
                (29, 30, 2),
                (29, 30, 1)
            ]
        );
        assert_eq!(calls, 3);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn the_next_epoch_starts_its_own_tree() {
        let us = address(1);
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        let mut tree = None;

        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        let tick = plan_recovery(
            &chain,
            &mut tree,
            &epoch(9, address(2), 5),
            us,
            head(30, 0x30),
        )
        .await
        .unwrap();
        assert!(tick.complete);

        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, TOURNAMENT_RUNNING, Address::ZERO);
        let tick = plan_recovery(
            &chain,
            &mut tree,
            &epoch(10, address(4), 25),
            us,
            head(30, 0x30),
        )
        .await
        .unwrap();
        assert!(!tick.complete);

        let (logs, calls) = requested(&requests);
        assert_eq!(logs, [(5, 30, 1), (25, 30, 1)]);
        assert_eq!(calls, 2);
        assert!(asserter.read_q().is_empty());
    }
}
