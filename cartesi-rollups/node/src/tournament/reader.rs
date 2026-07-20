//! The tournament reader: structure from the event fold, volatile
//! state from per-tick point reads (docs/plans/node-refactor.md,
//! workstream 5, phase 2).
//!
//! Every tick folds from genesis, but only the tail is fetched live:
//! events at or below the chain's finalized block are persisted into
//! storage (the dispute role's tournament_events log) as they
//! finalize, and each tick replays the stored prefix, fetches
//! watermark+1..latest for every discovered tournament, and persists
//! the newly finalized slice. The fold itself is unchanged from
//! phase 1 - still pure, still fed every event in order, and cold
//! start still equals tick (a respawned node replays its stored
//! prefix instead of refetching hundreds of blocks of logs).
//!
//! Reorg stance, unchanged: persisted events are finalized by
//! definition; the tail past the watermark is scratch, refetched
//! every tick, and acting on tail-derived state is safe because the
//! arena sender is revert-tolerant.
//!
//! The overlay reads what events cannot determine (see the fold
//! module doc): live match positions (getMatch, getMatchCycle),
//! clocks (getCommitment), winners (arbitrationResult,
//! innerTournamentWinner), elimination readiness, and the level
//! constants. The whole tick observes ONE block: events are fetched
//! to the tick's head and every point read is pinned at that same
//! height. Unpinned reads raced the advancing chain - a clock could
//! start ticking after the head was sampled and carry a start
//! instant beyond the tick's block stamp (crashed a kill_mid_match
//! run, 2026-07-09). The tail between ticks is scratch, re-derived
//! next tick, and acting on tip-derived state is safe because the
//! arena sender is revert-tolerant.
//!
//! Pinning's residual trade-off: the provider must serve state at a
//! block a few seconds old. Gateways prune (full nodes typically
//! keep 128 blocks; anvil under aggressive fast-forward sometimes
//! less), so a pinned read can transiently miss - the epoch manager
//! retries the whole tick on error rather than dying. A provider
//! that never serves non-latest state would starve the tick
//! entirely; revisit the pin if a real gateway shows that.

use anyhow::{Result, ensure};
use std::collections::HashMap;

use alloy::{
    primitives::{Address, U256},
    rpc::types::Log,
};

use crate::chain::Chain;
use crate::storage::Storage;
use crate::tournament::{
    ClockState, DisputeState, MatchLive, TournamentOverlay, TournamentWinner,
    fold::{Fold, decode_event},
};
use cartesi_prt_contracts::tournament;

pub struct StateReader {
    chain: Chain,
    block_created_number: u64,
    storage: Storage,
}

impl StateReader {
    pub fn new(chain: Chain, block_created_number: u64, storage: Storage) -> Result<Self> {
        Ok(Self {
            chain,
            block_created_number,
            storage,
        })
    }

    pub async fn fetch_from_root(
        &mut self,
        root_tournament_address: Address,
    ) -> Result<DisputeState> {
        let latest_block = self.chain.latest_block_number().await?;
        // Clamped to the tick's head: the tail fetch stops at latest,
        // so nothing past it may be declared persisted.
        let finalized_block = self.chain.finalized_block_number().await?.min(latest_block);

        let fold = self
            .fold_dispute(root_tournament_address, finalized_block, latest_block)
            .await?;
        let overlay = self.overlay(&fold, latest_block).await?;
        Ok(DisputeState { fold, overlay })
    }

    /// Replays the persisted prefix, fetches every discovered
    /// tournament's live tail, and persists the newly finalized
    /// slice. Discovery grows the fetch set (an inner tournament's
    /// stream only matters once its creation event names it), so the
    /// loop runs until no new address appears - bounded by the level
    /// count. Coverage induction: a tournament discovered in the tail
    /// has its whole stream inside the tail range (its creation event
    /// is there), so stored events always cover every discovered
    /// stream up to the watermark.
    async fn fold_dispute(
        &mut self,
        root: Address,
        finalized_block: u64,
        latest_block: u64,
    ) -> Result<Fold> {
        let mut fold = Fold::new(root);

        // The persisted prefix, all tournaments in chain order; the
        // fold discovers inner tournaments as their creations replay.
        for log in &self.storage.tournament_events(root)? {
            if let Some(event) = decode_event(log)? {
                fold.apply(&event)?;
            }
        }
        let watermark = self.storage.tournament_events_watermark(root)?;
        let tail_from = match watermark {
            Some(w) => w + 1,
            None => self.block_created_number,
        };

        let mut fetched = std::collections::HashSet::new();
        let mut harvest: Vec<Log> = Vec::new();
        loop {
            let pending: Vec<Address> = fold
                .addresses()
                .into_iter()
                .filter(|address| !fetched.contains(address))
                .collect();
            if pending.is_empty() {
                break;
            }

            for address in pending {
                if latest_block >= tail_from {
                    let logs = self
                        .chain
                        .raw_logs(address, tail_from, latest_block)
                        .await?;

                    for log in &logs {
                        if let Some(event) = decode_event(log)? {
                            fold.apply(&event)?;
                            if event.block <= finalized_block {
                                harvest.push(log.clone());
                            }
                        }
                    }
                }
                fetched.insert(address);
            }
        }

        // Persist the finalized harvest; the watermark advances even
        // when the harvest is empty, keeping the tail bounded. A
        // crash before this line re-fetches the same range next tick
        // and the append absorbs the replay.
        if watermark.is_none_or(|w| finalized_block > w) {
            let refs: Vec<&Log> = harvest.iter().collect();
            self.storage
                .append_tournament_events(root, finalized_block, &refs)?;
        }

        Ok(fold)
    }

    /// The point-read overlay over the fold's structure: what the
    /// chain owns and events cannot determine (see the fold module
    /// doc). Covers reachable tournaments only - the root plus inners
    /// whose parent match is still live (a settled inner disappears
    /// with its match, exactly as the old recursive walk never
    /// reached it).
    async fn overlay(
        &mut self,
        fold: &Fold,
        latest_block: u64,
    ) -> Result<HashMap<Address, TournamentOverlay>> {
        let mut overlay: HashMap<Address, TournamentOverlay> = HashMap::new();

        for tf in fold.tournaments() {
            // Discovery order guarantees the parent's overlay is
            // already in when its children come up.
            let Some(base_cycle) = reachable_base_cycle(tf, &overlay) else {
                continue;
            };

            let contract = tournament::Tournament::new(tf.address, self.chain.provider());
            let at = alloy::eips::BlockId::from(latest_block);

            let level_constants = contract.tournamentLevelConstants().block(at).call().await?;
            ensure!(
                level_constants._level == tf.level,
                "chain and fold disagree on tournament level: {} vs {}",
                level_constants._level,
                tf.level
            );

            let can_be_eliminated = if tf.level > 0 {
                contract.canBeEliminated().block(at).call().await?
            } else {
                false
            };

            // Live matches only, in creation order; the fold knows
            // which without a per-match existence probe.
            let mut live_matches = HashMap::new();
            for m in tf.live_matches() {
                let id_hash = m.id.hash();
                let chain_match = contract.getMatch(id_hash.into()).block(at).call().await?;
                ensure!(
                    chain_match.isInit,
                    "fold sees live match {id_hash} but the chain does not"
                );
                let leaf_cycle = contract
                    .getMatchCycle(id_hash.into())
                    .block(at)
                    .call()
                    .await?;

                live_matches.insert(
                    id_hash,
                    MatchLive {
                        other_parent: chain_match.otherParent.into(),
                        left_node: chain_match.leftNode.into(),
                        right_node: chain_match.rightNode.into(),
                        running_leaf_position: chain_match.runningLeafPosition,
                        current_height: chain_match.currentHeight,
                        leaf_cycle,
                    },
                );
            }

            let mut clocks = HashMap::new();
            for c in tf.commitments.values() {
                let commitment_return = contract
                    .getCommitment(c.root.into())
                    .block(at)
                    .call()
                    .await?;
                ensure!(
                    crate::merkle::Digest::from(commitment_return._1) == c.final_state,
                    "chain and fold disagree on commitment {}'s final state",
                    c.root
                );

                clocks.insert(
                    c.root,
                    ClockState {
                        allowance: commitment_return._0.allowance,
                        start_instant: commitment_return._0.startInstant,
                        block_number: latest_block,
                    },
                );
            }

            let winner = match tf.parent {
                Some(_) => self.tournament_winner(tf.address, at).await?,
                None => self.root_tournament_winner(tf.address, at).await?,
            };

            overlay.insert(
                tf.address,
                TournamentOverlay {
                    max_level: level_constants._maxLevel,
                    log2_stride: level_constants._log2step,
                    log2_stride_count: level_constants._height,
                    base_cycle,
                    winner,
                    can_be_eliminated,
                    clocks,
                    live_matches,
                },
            );
        }

        Ok(overlay)
    }

    async fn root_tournament_winner(
        &mut self,
        root_tournament_address: Address,
        at: alloy::eips::BlockId,
    ) -> Result<Option<TournamentWinner>> {
        let root_tournament =
            tournament::Tournament::new(root_tournament_address, self.chain.provider());
        let arbitration_result_return =
            root_tournament.arbitrationResult().block(at).call().await?;
        let (finished, commitment, state) = (
            arbitration_result_return._0,
            arbitration_result_return._1,
            arbitration_result_return._2,
        );

        if finished {
            Ok(Some(TournamentWinner::Root(
                commitment.into(),
                state.into(),
            )))
        } else {
            Ok(None)
        }
    }

    async fn tournament_winner(
        &mut self,
        tournament_address: Address,
        at: alloy::eips::BlockId,
    ) -> Result<Option<TournamentWinner>> {
        let tournament = tournament::Tournament::new(tournament_address, self.chain.provider());
        let inner_tournament_winner_return =
            tournament.innerTournamentWinner().block(at).call().await?;
        let (finished, parent_commitment, dangling_commitment) = (
            inner_tournament_winner_return._0,
            inner_tournament_winner_return._1,
            inner_tournament_winner_return._2,
        );

        if finished {
            Ok(Some(TournamentWinner::Inner(
                parent_commitment.into(),
                dangling_commitment.into(),
            )))
        } else {
            Ok(None)
        }
    }
}

/// The overlay's reachability gate, pure: a tournament is reachable
/// iff it is the root (base cycle zero) or its parent is overlaid
/// with the sealing match still live, in which case the inner level
/// arbitrates that match's leaf cycle. A settled parent match makes
/// the inner history, exactly as the pre-fold recursive walk never
/// descended into it.
fn reachable_base_cycle(
    tf: &crate::tournament::fold::TournamentFold,
    overlay: &HashMap<Address, TournamentOverlay>,
) -> Option<U256> {
    match tf.parent {
        None => Some(U256::ZERO),
        Some((parent_address, match_id_hash)) => {
            let parent_overlay = overlay.get(&parent_address)?;
            let parent_match = parent_overlay.live_matches.get(&match_id_hash)?;
            Some(parent_match.leaf_cycle)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::merkle::Digest;
    use crate::tournament::fold::{EventKind, TournamentEvent};
    use crate::tournament::{MatchID, MatchLive};

    fn digest(byte: u8) -> Digest {
        Digest::from_digest(&[byte; 32]).unwrap()
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn apply(fold: &mut Fold, tournament: Address, kind: EventKind) {
        fold.apply(&TournamentEvent {
            tournament,
            block: 1,
            kind,
        })
        .unwrap();
    }

    /// Joins two commitments, matches them, seals the match into an
    /// inner tournament; returns the sealing match's id hash.
    fn seal_inner(fold: &mut Fold, at: Address, child: Address, seed: u8) -> Digest {
        let (one, two) = (digest(seed), digest(seed + 1));
        apply(
            fold,
            at,
            EventKind::CommitmentJoined {
                root: one,
                final_state: digest(seed + 100),
            },
        );
        apply(
            fold,
            at,
            EventKind::CommitmentJoined {
                root: two,
                final_state: digest(seed + 101),
            },
        );
        apply(
            fold,
            at,
            EventKind::MatchCreated {
                one,
                two,
                left_of_two: digest(seed + 102),
            },
        );
        let id_hash = MatchID {
            commitment_one: one,
            commitment_two: two,
        }
        .hash();
        apply(
            fold,
            at,
            EventKind::NewInnerTournament {
                match_id_hash: id_hash,
                child,
            },
        );
        id_hash
    }

    fn overlay_with_live(live: &[(Digest, U256)]) -> TournamentOverlay {
        TournamentOverlay {
            max_level: 3,
            log2_stride: 44,
            log2_stride_count: 48,
            base_cycle: U256::ZERO,
            winner: None,
            can_be_eliminated: false,
            clocks: HashMap::new(),
            live_matches: live
                .iter()
                .map(|(id_hash, leaf_cycle)| {
                    (
                        *id_hash,
                        MatchLive {
                            other_parent: digest(0),
                            left_node: digest(0),
                            right_node: digest(0),
                            running_leaf_position: U256::ZERO,
                            current_height: 0,
                            leaf_cycle: *leaf_cycle,
                        },
                    )
                })
                .collect(),
        }
    }

    #[test]
    fn root_is_always_reachable_at_cycle_zero() {
        let fold = Fold::new(address(1));
        let overlay = HashMap::new();
        let root = fold.tournament(&address(1)).unwrap();
        assert_eq!(reachable_base_cycle(root, &overlay), Some(U256::ZERO));
    }

    #[test]
    fn inner_reads_its_base_cycle_off_the_parents_live_match() {
        let (root, inner) = (address(1), address(2));
        let mut fold = Fold::new(root);
        let id_hash = seal_inner(&mut fold, root, inner, 10);

        let mut overlay = HashMap::new();
        overlay.insert(root, overlay_with_live(&[(id_hash, U256::from(0x4400))]));

        let tf = fold.tournament(&inner).unwrap();
        assert_eq!(reachable_base_cycle(tf, &overlay), Some(U256::from(0x4400)));
    }

    #[test]
    fn inner_of_a_settled_match_is_history() {
        let (root, inner) = (address(1), address(2));
        let mut fold = Fold::new(root);
        let _ = seal_inner(&mut fold, root, inner, 10);

        // The parent is overlaid, but the sealing match is no longer
        // among its live matches: the inner disappeared with it.
        let mut overlay = HashMap::new();
        overlay.insert(root, overlay_with_live(&[]));

        let tf = fold.tournament(&inner).unwrap();
        assert_eq!(reachable_base_cycle(tf, &overlay), None);
    }

    #[test]
    fn grandchild_of_an_unreachable_parent_stays_unreachable() {
        let (root, mid, leaf) = (address(1), address(2), address(3));
        let mut fold = Fold::new(root);
        let _ = seal_inner(&mut fold, root, mid, 10);
        let leaf_id_hash = seal_inner(&mut fold, mid, leaf, 30);

        // Root settled mid's match, so mid never got an overlay; the
        // grandchild must not resurrect through its own (live) match.
        let mut overlay = HashMap::new();
        overlay.insert(root, overlay_with_live(&[]));
        let _ = leaf_id_hash;

        let tf = fold.tournament(&leaf).unwrap();
        assert_eq!(reachable_base_cycle(tf, &overlay), None);
    }
}

/// Fold phase 2's equivalence oracle, against the chain recordings:
/// persisting a finalized prefix through the real storage path and
/// folding stored-plus-tail must reproduce the all-at-once fold
/// EXACTLY, at every block boundary of the recorded dispute. No
/// split point may change what the Hero sees; this is what makes the
/// persisted log safe to trust across restarts.
#[cfg(test)]
mod phase2_tests {
    use super::*;
    use crate::storage::Storage;
    use alloy::sol_types::SolEvent;
    use cartesi_dave_contracts::dave_consensus::DaveConsensus;

    fn recorded_logs(name: &str) -> Vec<Log> {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/chain-recordings")
            .join(name);
        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        raw["logs"]
            .as_array()
            .expect("recording carries a log array")
            .iter()
            .map(|log| serde_json::from_value(log.clone()).expect("log decodes"))
            .collect()
    }

    fn migrated_storage() -> (tempfile::TempDir, Storage) {
        let dir = tempfile::tempdir().unwrap();
        let mut conn = rusqlite::Connection::open(dir.path().join("db.sqlite3")).unwrap();
        crate::storage::sql::migrations::migrate_to_latest(&mut conn).unwrap();
        drop(conn);
        let storage = Storage::new(dir.path()).unwrap();
        (dir, storage)
    }

    #[test]
    fn stored_prefix_plus_live_tail_equals_the_whole_stream() {
        let logs = recorded_logs("echo_simple.json");
        let root = logs
            .iter()
            .filter_map(|log| DaveConsensus::EpochSealed::decode_log(&log.inner).ok())
            .find(|e| e.epochNumber == U256::from(1))
            .expect("epoch 1 is the disputed epoch")
            .tournament;

        // The whole-stream fold, discovery inline (chain order makes
        // one pass sufficient), keeping the applied raw logs.
        let mut full_fold = Fold::new(root);
        let mut dispute_logs: Vec<&Log> = Vec::new();
        for log in &logs {
            let Some(event) = decode_event(log).unwrap() else {
                continue;
            };
            if full_fold.tournament(&event.tournament).is_none() {
                continue; // another epoch's tournament or foreign contract
            }
            full_fold.apply(&event).unwrap();
            dispute_logs.push(log);
        }
        assert!(!dispute_logs.is_empty());

        let mut split_points: Vec<u64> = dispute_logs
            .iter()
            .map(|log| log.block_number.expect("recorded log has a block"))
            .collect();
        split_points.dedup();

        for split in split_points {
            let (_dir, mut storage) = migrated_storage();

            let prefix: Vec<&Log> = dispute_logs
                .iter()
                .filter(|log| log.block_number.unwrap() <= split)
                .copied()
                .collect();
            storage
                .append_tournament_events(root, split, &prefix)
                .unwrap();
            assert_eq!(
                storage.tournament_events_watermark(root).unwrap(),
                Some(split)
            );

            // The round trip: stored prefix replayed, live tail applied.
            let mut fold = Fold::new(root);
            for log in &storage.tournament_events(root).unwrap() {
                if let Some(event) = decode_event(log).unwrap() {
                    fold.apply(&event).unwrap();
                }
            }
            for log in dispute_logs
                .iter()
                .filter(|log| log.block_number.unwrap() > split)
            {
                let event = decode_event(log).unwrap().expect("dispute log decodes");
                fold.apply(&event).unwrap();
            }

            assert_eq!(fold, full_fold, "fold diverges when split at block {split}");
        }
    }
}
