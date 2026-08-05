// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The bond recovery planner: stateless over chain reads, riding the
//! wave's tail (docs/plans/bond-recovery-redesign.md).
//!
//! Discovery is one indexed log scan: every CommitmentJoined naming
//! this signer as submitter points at a tournament it posted a bond
//! in, root or inner. Capability is the bondRecovery() view - the
//! same classification tryRecoveringBond acts on, so the planner
//! never re-derives the gate. Termination is a block cursor plus
//! candidates retiring on terminal dispositions; both in memory,
//! rebuilt by a boot rescan, so losing them costs a rescan and never
//! a wrong action.
//!
//! Discovery is permissionless and therefore spoofable: anyone can
//! emit a matching event naming this signer. A spoofed candidate must
//! never be paid a transaction (an attacker contract would burn the
//! whole gas limit every tick), so candidates are verified before any
//! send: a genuine tournament is a cloneWithImmutableArgs proxy whose
//! ERC-1167 prelude - delegate target included - is byte-identical to
//! a trusted root tournament's. View reads cost nothing and need no
//! verification.

use std::collections::BTreeSet;

use alloy::primitives::{Address, Bytes};
use alloy::providers::Provider;
use anyhow::Result;
use log::{info, trace, warn};

use crate::chain::Chain;
use crate::provider::LaneRequest;
use crate::tournament::gas_limit;
use cartesi_prt_contracts::tournament;

/// ITournament.BondDisposition, by declaration order.
const TOURNAMENT_RUNNING: u8 = 0;
const NO_WINNER: u8 = 1;
const RECOVERABLE: u8 = 2;
const RECOVERED: u8 = 3;

/// The ERC-1167 runtime prelude length. OpenZeppelin's
/// cloneWithImmutableArgs appends the args after the standard minimal
/// proxy runtime, so the first 45 bytes - which embed the delegate
/// target - are identical across every clone of one implementation.
const CLONE_PRELUDE_LEN: usize = 45;

pub struct BondRecovery {
    signer_address: Address,
    /// The next unscanned block. Starts at genesis: the boot rescan
    /// re-derives the candidate set, and range bisection bounds the
    /// one historical sweep.
    scan_from: u64,
    /// Verified tournaments this signer joined whose bond disposition
    /// is not yet terminal for it.
    candidates: BTreeSet<Address>,
    /// Log hits awaiting provenance verification (none can be genuine
    /// before a trusted root exists to compare against).
    unverified: BTreeSet<Address>,
    /// The trusted clone prelude, read once from a storage-known root.
    clone_prelude: Option<Bytes>,
}

impl BondRecovery {
    pub fn new(signer_address: Address) -> Self {
        Self {
            signer_address,
            scan_from: 0,
            candidates: BTreeSet::new(),
            unverified: BTreeSet::new(),
            clone_prelude: None,
        }
    }

    /// Extend discovery to the latest block, verify new candidates
    /// against `trusted_root`'s code, and plan one tryRecoveringBond
    /// intent per tournament whose bond is recoverable to this
    /// signer. Terminal dispositions retire candidates, whoever
    /// triggered them; intents repeat every tick until the recovery
    /// is observed, like all wave work.
    pub async fn plan(
        &mut self,
        chain: &Chain,
        trusted_root: Option<Address>,
    ) -> Result<Vec<LaneRequest>> {
        // The cursor is monotone and never rewound, so it must only
        // cross blocks that cannot reorg (the codebase's finalized
        // convention, as in blockchain_reader): a join scanned off a
        // reorged tip would otherwise be dropped until the next boot
        // rescan. Recovery has no urgency; discovery lagging finality
        // costs nothing.
        let finalized = chain.finalized_block_number().await?;
        if finalized >= self.scan_from {
            let joins = chain
                .decoded_logs_by_topic2::<tournament::Tournament::CommitmentJoined>(
                    self.signer_address.into_word(),
                    self.scan_from,
                    finalized,
                )
                .await?;
            for (_, log) in joins {
                let tournament = log.address();
                if !self.candidates.contains(&tournament) {
                    self.unverified.insert(tournament);
                }
            }
            self.scan_from = finalized + 1;
        }

        self.verify_candidates(chain, trusted_root).await?;

        let mut wave = Vec::new();
        let mut retired = Vec::new();
        for address in self.candidates.iter().copied() {
            let contract = tournament::Tournament::new(address, chain.provider());
            let recovery = contract.bondRecovery().call().await?;
            match candidate_action(recovery.disposition, recovery.claimer, self.signer_address) {
                CandidateAction::Recover => {
                    info!("plan bond recovery for tournament {address}");
                    let request = contract
                        .tryRecoveringBond()
                        .gas(gas_limit())
                        .into_transaction_request();
                    wave.push(("tryRecoveringBond".to_string(), request));
                }
                CandidateAction::Keep => {}
                CandidateAction::Retire => retired.push(address),
            }
        }
        for address in retired {
            trace!("bond candidate retired: tournament {address}");
            self.candidates.remove(&address);
        }
        Ok(wave)
    }

    /// Promote unverified log hits whose runtime code is a genuine
    /// tournament clone; drop the rest loudly. Without a trusted root
    /// yet, hits stay parked: nothing genuine can predate the first
    /// sealed epoch.
    async fn verify_candidates(
        &mut self,
        chain: &Chain,
        trusted_root: Option<Address>,
    ) -> Result<()> {
        if self.unverified.is_empty() {
            return Ok(());
        }
        let Some(root) = trusted_root else {
            return Ok(());
        };
        if self.clone_prelude.is_none() {
            let code = chain.provider().get_code_at(root).await?;
            self.clone_prelude = Some(code);
        }
        let prelude = self.clone_prelude.as_ref().expect("initialized above");

        // Remove entries one by one as each verdict lands: a transient
        // provider error mid-loop must leave the unprocessed remainder
        // queued for the next tick, not silently discarded.
        let pending: Vec<Address> = self.unverified.iter().copied().collect();
        for address in pending {
            let code = chain.provider().get_code_at(address).await?;
            self.unverified.remove(&address);
            if genuine_clone(prelude, &code) {
                trace!("bond candidate verified: tournament {address}");
                self.candidates.insert(address);
            } else {
                warn!(
                    "dropping spoofed bond candidate {address}: \
                     CommitmentJoined emitter is not a tournament clone"
                );
            }
        }
        Ok(())
    }
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
/// bond whose winning claimer is someone else (our commitment lost).
fn candidate_action(disposition: u8, claimer: Address, us: Address) -> CandidateAction {
    match disposition {
        RECOVERABLE if claimer == us => CandidateAction::Recover,
        RECOVERABLE | RECOVERED | NO_WINNER => CandidateAction::Retire,
        TOURNAMENT_RUNNING => CandidateAction::Keep,
        other => {
            // A verified clone cannot produce this; stay inert rather
            // than fatal on chain data.
            warn!("undefined bond disposition {other}; keeping candidate inert");
            CandidateAction::Keep
        }
    }
}

/// A genuine tournament clone shares the trusted root's ERC-1167
/// prelude byte for byte, delegate target included; the immutable
/// args that follow differ per instance.
fn genuine_clone(trusted_prelude: &Bytes, candidate_code: &Bytes) -> bool {
    trusted_prelude.len() >= CLONE_PRELUDE_LEN
        && candidate_code.len() >= CLONE_PRELUDE_LEN
        && trusted_prelude[..CLONE_PRELUDE_LEN] == candidate_code[..CLONE_PRELUDE_LEN]
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

    #[test]
    fn clone_verification_compares_the_prelude_only() {
        let mut trusted = vec![0xAA; CLONE_PRELUDE_LEN];
        trusted.extend_from_slice(b"root args");
        let trusted = Bytes::from(trusted);

        let mut sibling = vec![0xAA; CLONE_PRELUDE_LEN];
        sibling.extend_from_slice(b"different inner args");
        assert!(genuine_clone(&trusted, &Bytes::from(sibling)));

        let mut impostor = vec![0xAA; CLONE_PRELUDE_LEN];
        impostor[20] = 0xBB;
        assert!(
            !genuine_clone(&trusted, &Bytes::from(impostor)),
            "a different delegate target must fail verification"
        );
        assert!(
            !genuine_clone(&trusted, &Bytes::from(vec![0xAA; 10])),
            "short code cannot be a clone"
        );
    }
}
