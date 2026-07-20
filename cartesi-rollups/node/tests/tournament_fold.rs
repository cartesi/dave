// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The fold against the chain recordings (workstream 5, phase 1):
//! raw devnet logs captured after real e2e disputes, decoded through
//! the same bindings the production fetcher uses, folded from
//! genesis. The scenarios' known shapes are the oracle: what
//! tournaments a dispute spawns, how their matches end, and which
//! commitments took part are facts of the recorded run that the fold
//! must reproduce from the log stream alone. No machine image and no
//! chain required.

use alloy::{primitives::Address, rpc::types::Log, sol_types::SolEvent};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;
use cartesi_rollups_prt_node::tournament::fold::{
    EventKind, Fold, MatchDeletionReason, TournamentEvent, WinnerCommitment, decode_event,
};
use std::collections::BTreeMap;
use std::path::PathBuf;

fn recording(name: &str) -> Option<Vec<Log>> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/chain-recordings")
        .join(name);
    if !path.exists() {
        return None;
    }
    let raw: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap())
        .expect("recording must be valid JSON");
    let logs = raw["logs"]
        .as_array()
        .expect("recording must carry a log array")
        .iter()
        .map(|log| serde_json::from_value(log.clone()).expect("log must decode as an RPC log"))
        .collect();
    Some(logs)
}

/// The roots the consensus sealed, in epoch order, straight from the
/// recorded EpochSealed events.
fn sealed_tournaments(logs: &[Log]) -> Vec<(u64, Address)> {
    logs.iter()
        .filter_map(|log| {
            DaveConsensus::EpochSealed::decode_log(&log.inner)
                .ok()
                .map(|e| (u64::try_from(e.epochNumber).unwrap(), e.tournament))
        })
        .collect()
}

/// Folds one root tournament's dispute out of the whole-chain stream.
/// Discovery is inline: logs arrive in block order, and an inner
/// tournament's logs can only follow the NewInnerTournament that
/// names it, so a single chronological pass suffices.
fn fold_dispute(logs: &[Log], root: Address) -> (Fold, Vec<TournamentEvent>) {
    let mut fold = Fold::new(root);
    let mut applied = Vec::new();
    for log in logs {
        let Some(event) = decode_event(log).expect("recorded logs must decode") else {
            continue;
        };
        if fold.tournament(&event.tournament).is_none() {
            continue; // another epoch's tournament, or a foreign contract
        }
        fold.apply(&event).expect("recorded stream must fold");
        applied.push(event);
    }
    (fold, applied)
}

/// echo_simple: one full dispute on epoch 1 - the honest node against
/// one sybil, descending all three levels to a leaf-step elimination.
#[test]
fn fold_reproduces_the_echo_simple_dispute() {
    let Some(logs) = recording("echo_simple.json") else {
        panic!("echo_simple.json is a committed fixture and must exist");
    };

    let sealed = sealed_tournaments(&logs);
    assert!(
        sealed.len() >= 2,
        "the scenario seals epoch 0 and the disputed epoch 1"
    );
    let root = sealed
        .iter()
        .find(|(epoch, _)| *epoch == 1)
        .expect("epoch 1 is the disputed epoch")
        .1;

    let (fold, applied) = fold_dispute(&logs, root);
    assert!(!applied.is_empty(), "the dispute left events to fold");

    // The dispute descends all three levels: the root plus two inner
    // tournaments, each spawned by a sealed match of its parent.
    let tournaments: Vec<_> = fold.tournaments().collect();
    assert_eq!(tournaments.len(), 3, "three levels of tournament");
    let levels: Vec<u64> = tournaments.iter().map(|t| t.level).collect();
    assert_eq!(levels, vec![0, 1, 2]);

    for (i, t) in tournaments.iter().enumerate() {
        assert_eq!(
            t.commitments.len(),
            2,
            "honest and sybil at level {}",
            t.level
        );
        assert_eq!(t.matches.len(), 1, "one match at level {}", t.level);
        let m = &t.matches[0];

        // Parent linkage: each inner tournament hangs off its
        // parent's single match.
        if i > 0 {
            let (parent_address, match_id_hash) = t.parent.expect("inner has a parent");
            assert_eq!(parent_address, tournaments[i - 1].address);
            assert_eq!(match_id_hash, tournaments[i - 1].matches[0].id.hash());
        }

        // Every commitment saw the match.
        for c in t.commitments.values() {
            assert_eq!(c.latest_match, Some(0));
        }

        // Lifecycle: the two non-leaf matches sealed into inner
        // tournaments and were closed by them; the leaf match died by
        // an on-chain step. Every deletion crowned a winner.
        let (reason, winner) = m.deleted.expect("all matches resolve in a settled epoch");
        if t.level < 2 {
            assert_eq!(m.inner_tournament, Some(tournaments[i + 1].address));
            assert_eq!(reason, MatchDeletionReason::ChildTournament);
        } else {
            assert_eq!(m.inner_tournament, None);
            assert_eq!(reason, MatchDeletionReason::Step);
        }
        assert_ne!(winner, WinnerCommitment::Neither);
        assert!(m.advances > 0, "bisection advanced at level {}", t.level);
    }

    // The same commitment pair fights the level-0 match that the
    // epoch's join events introduced, and final states ride the
    // joins: every joined commitment carries one.
    let root_t = fold.tournament(&root).unwrap();
    for c in root_t.commitments.values() {
        assert_ne!(c.final_state.slice(), [0u8; 32]);
    }

    // Event-count audit: everything decodable in the dispute's
    // address set was applied, and the vocabulary saw every kind.
    let mut kinds: BTreeMap<&'static str, usize> = BTreeMap::new();
    for e in &applied {
        *kinds
            .entry(match e.kind {
                EventKind::CommitmentJoined { .. } => "joined",
                EventKind::MatchCreated { .. } => "created",
                EventKind::MatchAdvanced { .. } => "advanced",
                EventKind::MatchDeleted { .. } => "deleted",
                EventKind::NewInnerTournament { .. } => "inner",
            })
            .or_default() += 1;
    }
    assert_eq!(kinds["joined"], 6, "two commitments per level");
    assert_eq!(kinds["created"], 3);
    assert_eq!(kinds["deleted"], 3);
    assert_eq!(kinds["inner"], 2);
    assert!(kinds["advanced"] >= 3);
    println!("echo_simple fold: {kinds:?}");
}

/// The multi-dispute recording (honeypot stf_all): five epochs, each
/// steering its dispute onto a different on-chain transition shape.
/// Every sealed epoch's dispute must fold clean; disputed epochs
/// resolve every match and crown winners at the leaf by steps.
#[test]
fn fold_reproduces_the_stf_all_disputes() {
    let Some(logs) = recording("multilevel_stf.json") else {
        eprintln!("skipping: multilevel_stf.json not recorded yet");
        return;
    };

    let sealed = sealed_tournaments(&logs);
    assert!(sealed.len() >= 4, "stf_all seals several epochs");

    let mut disputed = 0;
    for (epoch, root) in &sealed {
        let (fold, applied) = fold_dispute(&logs, *root);
        if applied.is_empty() {
            continue; // an epoch this recording never disputed or joined
        }

        for t in fold.tournaments() {
            for m in &t.matches {
                if let Some((reason, winner)) = m.deleted {
                    assert_ne!(
                        winner,
                        WinnerCommitment::Neither,
                        "every recorded deletion crowned a winner (epoch {epoch})"
                    );
                    match reason {
                        MatchDeletionReason::ChildTournament => {
                            assert!(m.inner_tournament.is_some())
                        }
                        MatchDeletionReason::Step | MatchDeletionReason::Timeout => {
                            assert!(m.inner_tournament.is_none())
                        }
                    }
                }
            }
        }

        let t: Vec<_> = fold.tournaments().collect();
        if t.len() > 1 {
            disputed += 1;
            // A dispute that spawned inners fought them to the leaf.
            assert_eq!(t.len(), 3, "disputes descend all levels (epoch {epoch})");
            assert!(
                t.last()
                    .unwrap()
                    .matches
                    .iter()
                    .any(|m| m.deleted.is_some()),
                "the leaf level resolved (epoch {epoch})"
            );
        }
        println!(
            "epoch {epoch}: {} tournaments, {} events",
            t.len(),
            applied.len()
        );
    }
    assert!(disputed >= 4, "stf_all disputes at least four epochs");
}

/// multi_sybil: four commitments in one root tournament, two matches
/// live at the same time (the permissionless shape no other fixture
/// carries), and a silent sybil whose match dies by a REAL on-chain
/// timeout - the deletion reason every other test builds
/// synthetically. Captured from the multi_sybil e2e scenario
/// (RECORD_CHAIN_FIXTURE); regeneration is a conscious, reviewable
/// act like every fixture here.
#[test]
fn fold_reproduces_the_multi_sybil_dispute() {
    let Some(logs) = recording("multi_sybil.json") else {
        panic!("multi_sybil.json is a committed fixture and must exist");
    };

    let sealed = sealed_tournaments(&logs);
    let root = sealed
        .iter()
        .find(|(epoch, _)| *epoch == 1)
        .expect("epoch 1 is the disputed epoch")
        .1;

    let (fold, applied) = fold_dispute(&logs, root);
    assert!(!applied.is_empty(), "the dispute left events to fold");

    let root_t = fold.tournament(&root).expect("root tournament folds");
    assert_eq!(
        root_t.commitments.len(),
        4,
        "honest plus three sybils joined the root"
    );
    assert!(
        root_t.matches.len() >= 3,
        "four commitments pair into at least three matches over the bracket"
    );

    // Concurrency, from the event stream itself: a second match is
    // created in the root before the first one is deleted.
    let mut created = 0usize;
    let mut overlapped = false;
    for event in &applied {
        if event.tournament != root {
            continue;
        }
        match &event.kind {
            EventKind::MatchCreated { .. } => {
                created += 1;
                if created >= 2 {
                    overlapped = true;
                }
            }
            EventKind::MatchDeleted { .. } => {
                if created >= 2 {
                    overlapped = true;
                }
                created = created.saturating_sub(1);
            }
            _ => {}
        }
    }
    assert!(
        overlapped,
        "two matches must have been live simultaneously in the root"
    );

    // The silent sybil's match died by a real timeout, decoded from a
    // real chain log (the enum-order pin the synthetic tests bypass).
    let timeout_deletions = applied
        .iter()
        .filter(|e| {
            matches!(
                e.kind,
                EventKind::MatchDeleted {
                    reason: MatchDeletionReason::Timeout,
                    ..
                }
            )
        })
        .count();
    assert!(
        timeout_deletions >= 1,
        "at least one match deletion carries the Timeout reason"
    );

    // The dispute still descended to a leaf resolution somewhere.
    assert!(
        fold.tournaments().count() >= 2,
        "the active matches sealed into inner tournaments"
    );
}
