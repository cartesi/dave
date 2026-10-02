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

use alloy::primitives::Address;
use anyhow::Result;
use log::{info, trace};

use crate::chain::{Chain, ChainHead};
use crate::provider::LaneRequest;
use crate::storage::Epoch;
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

/// Rebuild every outstanding recovery from chain state. Only finalized
/// classifications may complete an epoch; mined payments suppress retries.
pub async fn plan_recovery(
    chain: &Chain,
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

    let tree = tournament_tree(
        chain,
        epoch.root_tournament,
        epoch.block_created_number,
        finalized.number,
    )
    .await?;
    let mut candidates = Vec::new();
    let mut tick = RecoveryTick {
        wave: Vec::new(),
        complete: true,
    };
    for tournament in tree {
        let contract = tournament::Tournament::new(tournament, chain.provider());
        let recovery = contract
            .bondRecovery()
            .block(finalized.block_id())
            .call()
            .await?;
        match recovery.disposition {
            RECOVERABLE if recovery.claimer == claimant => {
                candidates.push(tournament);
                tick.complete = false;
            }
            RECOVERABLE | RECOVERED | NO_WINNER => {}
            TOURNAMENT_RUNNING => tick.complete = false,
            other => {
                log::warn!(
                    "unknown bond disposition {other} for tournament {tournament}; \
                     keeping epoch incomplete"
                );
                tick.complete = false;
            }
        }
    }

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

        // At F1 the child does not exist yet and the root is still
        // running. A latest view could already report the root as
        // recovered, but it is intentionally never queried here.
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, TOURNAMENT_RUNNING, Address::ZERO);
        let tick = plan_recovery(&chain, &epoch, us, f1).await.unwrap();
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

        let tick = plan_recovery(&chain, &epoch, us, f2).await.unwrap();
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

        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(h1)));
        push_bond(&asserter, RECOVERED, Address::ZERO);
        let tick = plan_recovery(&chain, &epoch, us, f1).await.unwrap();
        assert!(tick.wave.is_empty());
        assert!(!tick.complete);

        // Retry immediately when the payment disappears, even while the
        // finalized head has not advanced.
        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERABLE, us);
        asserter.push_success(&Some(block(h2)));
        push_bond(&asserter, RECOVERABLE, us);

        let tick = plan_recovery(&chain, &epoch, us, f1).await.unwrap();
        assert_eq!(tick.wave.len(), 1);
        assert_recovers(&tick.wave[0], root);
        assert!(!tick.complete);

        asserter.push_success(&Vec::<Log>::new());
        push_bond(&asserter, RECOVERED, Address::ZERO);
        let tick = plan_recovery(&chain, &epoch, us, f2).await.unwrap();
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

        for _ in 0..2 {
            asserter.push_success(&vec![child_log(root, child, finalized)]);
            asserter.push_success(&Vec::<Log>::new());
            push_bond(&asserter, RECOVERABLE, us);
            push_bond(&asserter, RECOVERABLE, us);
            asserter.push_success(&Some(block(latest)));
            push_bond(&asserter, RECOVERABLE, us);
            push_bond(&asserter, RECOVERABLE, us);

            let tick = plan_recovery(&chain, &epoch, us, finalized).await.unwrap();
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

        let tick = plan_recovery(&chain, &epoch, us, finalized).await.unwrap();
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
            let tick = plan_recovery(&chain, &epoch, address(1), head(30, 0x30))
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

        let tick = plan_recovery(&chain, &epoch, address(1), head(30, 0x30))
            .await
            .unwrap();
        assert!(tick.wave.is_empty());
        assert!(!tick.complete);
        assert!(asserter.read_q().is_empty());
    }
}
