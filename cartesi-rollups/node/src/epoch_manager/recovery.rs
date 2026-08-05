// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The bond recovery planner: stateless over chain reads, riding the
//! wave's tail (docs/plans/bond-recovery-redesign.md).
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
//! Termination is the only state: an epoch retires when every
//! tournament in its tree reports a terminal disposition. It is held
//! in memory and rebuilt by a boot re-walk, so losing it costs a
//! re-walk and never a wrong action.

use std::collections::BTreeSet;

use alloy::primitives::Address;
use anyhow::Result;
use log::{info, trace};

use crate::chain::Chain;
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
}

impl BondRecovery {
    pub fn new(signer_address: Address) -> Self {
        Self {
            signer_address,
            completed_epochs: BTreeSet::new(),
        }
    }

    /// Plan one tryRecoveringBond intent per tournament whose bond is
    /// recoverable to this signer, across every sealed epoch not yet
    /// retired. Terminal dispositions retire tournaments (whoever
    /// triggered them), full trees retire epochs; intents repeat every
    /// tick until the recovery is observed, like all wave work.
    pub async fn plan(&mut self, chain: &Chain, epochs: &[Epoch]) -> Result<Vec<LaneRequest>> {
        let mut wave = Vec::new();
        let finalized = chain.finalized_block_number().await?;

        for epoch in epochs {
            if self.completed_epochs.contains(&epoch.epoch_number) {
                continue;
            }
            let tree = tournament_tree(
                chain,
                epoch.root_tournament,
                epoch.block_created_number,
                finalized,
            )
            .await?;

            let mut all_terminal = true;
            for tournament in tree {
                let contract = tournament::Tournament::new(tournament, chain.provider());
                let recovery = contract.bondRecovery().call().await?;
                match candidate_action(recovery.disposition, recovery.claimer, self.signer_address)
                {
                    CandidateAction::Recover => {
                        info!("plan bond recovery for tournament {tournament}");
                        let request = contract
                            .tryRecoveringBond()
                            .gas(gas_limit())
                            .into_transaction_request();
                        wave.push(("tryRecoveringBond".to_string(), request));
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
        Ok(wave)
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

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
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
}
