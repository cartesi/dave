// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The executable leaf-convention specification.
//!
//! `oracle_counters` enumerates the whole ruler by brute force, written
//! directly from the documented conventions with none of the engine's
//! machinery. Every test compares engine and cache outputs against it.
//! If the engine and the oracle ever disagree, the conventions are
//! ambiguous or one of them is wrong; either way the spec is doing its
//! job.

use super::cache::{PRECOMPUTE_LEVELS, get_or_compute};
use super::config::EngineConfig;
use super::dispute::{DisputeSource, LevelCoords, fold_runs};
use super::ruler::{RulerFactory, Run, ToyFactory};
use super::stf::{IDLE_CHURN_TICKS, ToyInput, ToyOutcome, ToyStf};
use super::structure::{Quartet, Structure};
use crate::merkle::{Digest, MerkleBuilder, MerkleTree};
use crate::storage::Storage;
use alloy::primitives::U256;
use anyhow::Result;
use rusqlite::Connection;
use std::sync::Arc;

// Tiny structures: (a, b, c) as in docs/computation-hash.md.
const S_DIAGRAM: Structure = Structure {
    log2_input_span: 1,
    log2_barch_span: 1,
    log2_uarch_span: 2,
}; // 16 positions: the toy picture in the docs

pub(crate) const S_SMALL: Structure = Structure {
    log2_input_span: 2,
    log2_barch_span: 2,
    log2_uarch_span: 3,
}; // 128 positions

const S_MEDIUM: Structure = Structure {
    log2_input_span: 2,
    log2_barch_span: 3,
    log2_uarch_span: 4,
}; // 512 positions

fn accept(big_cycles: &[u64]) -> ToyInput {
    ToyInput {
        big_cycles: big_cycles.to_vec(),
        outcome: ToyOutcome::Accept,
    }
}

fn reject(big_cycles: &[u64]) -> ToyInput {
    ToyInput {
        big_cycles: big_cycles.to_vec(),
        outcome: ToyOutcome::Reject,
    }
}

fn halt(big_cycles: &[u64]) -> ToyInput {
    ToyInput {
        big_cycles: big_cycles.to_vec(),
        outcome: ToyOutcome::Halt,
    }
}

/// Scripts covering every geometry case: full activity, early uarch
/// halts, early yields, rejection (revert), machine halt, empty epoch.
fn scripts_for(structure: &Structure) -> Vec<(&'static str, Vec<ToyInput>)> {
    let max_usteps = structure.big_span() - 1;
    let window_bigs = 1u64 << structure.log2_barch_span;
    let fully_active = vec![max_usteps; window_bigs as usize];

    vec![
        ("empty", vec![]),
        ("one_full", vec![accept(&fully_active)]),
        ("one_short", vec![accept(&[1])]),
        (
            "mixed",
            vec![
                accept(&[2, max_usteps, 1]),
                reject(&[max_usteps, 2]),
                accept(&[1]),
            ],
        ),
        ("halting", vec![accept(&[2, 2]), halt(&[1])]),
        ("reject_first", vec![reject(&[1]), accept(&[2])]),
    ]
    .into_iter()
    .map(|(name, script)| {
        // Clamp scripts that do not fit tiny structures.
        let script = script
            .into_iter()
            .take(structure.max_inputs() as usize)
            .map(|mut input| {
                input.big_cycles.truncate(window_bigs as usize);
                input
            })
            .collect();
        (name, script)
    })
    .collect()
}

/// The brute-force spec: the state digest at every ruler position,
/// written as literal nested loops over windows, big cycles, and
/// slots, including the idle churn pattern (see the ruler module doc:
/// idle big cycles repeat churned slots and close back on the base
/// state).
fn oracle_digests(structure: &Structure, script: &[ToyInput]) -> Vec<Digest> {
    let big_span = structure.big_span();
    let window_bigs = 1u64 << structure.log2_barch_span;
    let mut leaves = Vec::new();
    let mut state = 0u64;
    let mut halted = false;

    // One idle big cycle: the churn ticks color every slot before the
    // closing ureset restores the base state.
    let idle_cycle = |leaves: &mut Vec<Digest>, state: u64| {
        for _ in 0..big_span - 1 {
            leaves.push(ToyStf::churned_hash_of(state, IDLE_CHURN_TICKS));
        }
        leaves.push(ToyStf::hash_of(state));
    };

    for window in 0..structure.max_inputs() {
        let scripted = if halted {
            None
        } else {
            script.get(window as usize)
        };
        match scripted {
            None => {
                // No input (or halted): the whole window idles.
                for _ in 0..window_bigs {
                    idle_cycle(&mut leaves, state);
                }
            }
            Some(input) => {
                let checkpoint = state;
                for (index, &active_usteps) in input.big_cycles.iter().enumerate() {
                    let last = index + 1 == input.big_cycles.len();
                    // Ustep slots: active ones advance, the rest repeat.
                    for slot in 0..big_span - 1 {
                        if slot < active_usteps {
                            state += 1;
                        }
                        leaves.push(ToyStf::hash_of(state));
                    }
                    // The ureset slot; the revert lands here when the
                    // yield rejects.
                    state += 1;
                    if last && input.outcome == ToyOutcome::Reject {
                        state = checkpoint;
                    }
                    leaves.push(ToyStf::hash_of(state));
                    if last && input.outcome == ToyOutcome::Halt {
                        halted = true;
                    }
                }
                // Window padding after the yield (or halt).
                let used = input.big_cycles.len() as u64;
                for _ in used..window_bigs {
                    idle_cycle(&mut leaves, state);
                }
            }
        }
    }
    leaves
}

fn expand(runs: &[Run]) -> Vec<Digest> {
    let mut out = vec![];
    for run in runs {
        let n = u64::try_from(run.repetitions).expect("test sizes fit u64");
        out.extend(std::iter::repeat_n(run.hash, n as usize));
    }
    out
}

pub(crate) fn toy_storage(structure: Structure) -> Storage {
    let config = EngineConfig {
        structure,
        app: vec![0xda; 20],
        template_hash: ToyStf::hash_of(0),
        emulator_version: "toy".into(),
    };
    let dir = tempfile::tempdir().unwrap().keep();
    let mut connection = Connection::open(dir.join("db.sqlite3")).unwrap();
    crate::storage::sql::migrations::migrate_to_latest(&mut connection).unwrap();
    super::config::pin(&connection, &config).unwrap();
    Storage::new(&dir).unwrap()
}

#[test]
fn full_ruler_matches_oracle() {
    for structure in [S_DIAGRAM, S_SMALL, S_MEDIUM] {
        for (name, script) in scripts_for(&structure) {
            let expected = oracle_digests(&structure, &script);
            let mut factory = ToyFactory {
                structure,
                script: script.clone(),
            };
            let mut ruler = factory.ruler_at(U256::ZERO).unwrap();
            let runs = ruler.collect(structure.ruler_span(), 0).unwrap();
            assert_eq!(expand(&runs), expected, "script {name} on {structure:?}");
        }
    }
}

#[test]
fn stride_sampling_matches_oracle() {
    for structure in [S_DIAGRAM, S_SMALL] {
        let total = structure.log2_ruler_span();
        for (name, script) in scripts_for(&structure) {
            let oracle = oracle_digests(&structure, &script);
            for log2_stride in 1..=total {
                let stride = 1usize << log2_stride;
                let expected: Vec<Digest> = oracle
                    .iter()
                    .skip(stride - 1)
                    .step_by(stride)
                    .copied()
                    .collect();
                let mut factory = ToyFactory {
                    structure,
                    script: script.clone(),
                };
                let mut ruler = factory.ruler_at(U256::ZERO).unwrap();
                let runs = ruler.collect(structure.ruler_span(), log2_stride).unwrap();
                assert_eq!(
                    expand(&runs),
                    expected,
                    "script {name}, stride 2^{log2_stride}"
                );
            }
        }
    }
}

#[test]
fn fully_active_state_is_position_plus_one() {
    // The property the toy is named for: with no padding, the state
    // after transition N is N + 1.
    let structure = S_SMALL;
    let window_bigs = 1usize << structure.log2_barch_span;
    let script = vec![accept(&vec![structure.big_span() - 1; window_bigs])];
    let oracle = oracle_digests(&structure, &script);
    let window_span = u64::try_from(structure.window_span()).unwrap();
    for (position, digest) in oracle.iter().enumerate().take(window_span as usize) {
        assert_eq!(*digest, ToyStf::hash_of(position as u64 + 1));
    }
}

#[test]
fn mid_span_positioning_matches_oracle() {
    // A ruler positioned mid-epoch by replay must continue exactly
    // where the oracle says it should.
    let structure = S_SMALL;
    for (name, script) in scripts_for(&structure) {
        let oracle = oracle_digests(&structure, &script);
        let quarter = structure.ruler_span() >> 2;
        let mut factory = ToyFactory {
            structure,
            script: script.clone(),
        };
        let mut ruler = factory.ruler_at(quarter).unwrap();
        let runs = ruler.collect(quarter * U256::from(3), 0).unwrap();
        let lo = u64::try_from(quarter).unwrap() as usize;
        let hi = lo * 3;
        assert_eq!(expand(&runs), oracle[lo..hi], "script {name}");
    }
}

#[test]
fn cache_root_matches_oracle_tree() -> Result<()> {
    for structure in [S_DIAGRAM, S_SMALL] {
        for (name, script) in scripts_for(&structure) {
            let mut cache = toy_storage(structure);
            let mut factory = ToyFactory {
                structure,
                script: script.clone(),
            };

            let root = Quartet::level_root(0, 0, structure.log2_ruler_span());
            let computed = get_or_compute(&mut cache, &structure, &mut factory, &root)?;

            let mut builder = MerkleBuilder::default();
            for digest in oracle_digests(&structure, &script) {
                builder.append(digest);
            }
            assert_eq!(
                computed,
                builder.build().root_hash(),
                "script {name} on {structure:?}"
            );
        }
    }
    Ok(())
}

#[test]
fn coarse_root_equals_sampled_oracle_tree() -> Result<()> {
    // A commitment at a coarse stride is the tree over the sampled
    // oracle leaves, matching how tournament levels see the epoch.
    let structure = S_MEDIUM;
    let (_, script) = scripts_for(&structure).remove(3); // mixed
    let log2_stride = structure.log2_uarch_span; // big-cycle stride
    let height = structure.log2_ruler_span() - log2_stride;

    let mut cache = toy_storage(structure);
    let mut factory = ToyFactory {
        structure,
        script: script.clone(),
    };
    let root = Quartet::level_root(0, log2_stride, height);
    let computed = get_or_compute(&mut cache, &structure, &mut factory, &root)?;

    let stride = 1usize << log2_stride;
    let mut builder = MerkleBuilder::default();
    for digest in oracle_digests(&structure, &script)
        .into_iter()
        .skip(stride - 1)
        .step_by(stride)
    {
        builder.append(digest);
    }
    assert_eq!(computed, builder.build().root_hash());
    Ok(())
}

#[test]
fn children_join_to_parent() -> Result<()> {
    let structure = S_SMALL;
    let (_, script) = scripts_for(&structure).remove(3); // mixed
    let mut cache = toy_storage(structure);
    let mut factory = ToyFactory { structure, script };

    let mut quartet = Quartet::level_root(0, 0, structure.log2_ruler_span());
    while let Some((left, right)) = quartet.children() {
        let parent = get_or_compute(&mut cache, &structure, &mut factory, &quartet)?;
        let l = get_or_compute(&mut cache, &structure, &mut factory, &left)?;
        let r = get_or_compute(&mut cache, &structure, &mut factory, &right)?;
        assert_eq!(parent, l.join(&r), "at {quartet:?}");
        // Descend along the right edge, crossing fanout strata.
        quartet = right;
    }
    Ok(())
}

/// Counts how often the cache had to touch the (toy) machine.
struct Counting {
    inner: ToyFactory,
    calls: usize,
}

impl RulerFactory for Counting {
    type S = ToyStf;
    fn ruler_at(&mut self, position: U256) -> Result<super::ruler::Ruler<ToyStf>> {
        self.calls += 1;
        self.inner.ruler_at(position)
    }
}

#[test]
fn fanout_amortizes_descent() -> Result<()> {
    let structure = S_MEDIUM; // ruler height 9 crosses one fanout stratum
    let (_, script) = scripts_for(&structure).remove(3);
    let mut cache = toy_storage(structure);
    let mut factory = Counting {
        inner: ToyFactory { structure, script },
        calls: 0,
    };

    let root = Quartet::level_root(0, 0, structure.log2_ruler_span());
    get_or_compute(&mut cache, &structure, &mut factory, &root)?;
    assert_eq!(factory.calls, 1);

    // Everything within PRECOMPUTE_LEVELS of the root is already there.
    let mut quartet = root.clone();
    for _ in 0..PRECOMPUTE_LEVELS {
        let (left, _) = quartet.children().unwrap();
        get_or_compute(&mut cache, &structure, &mut factory, &left)?;
        quartet = left;
    }
    assert_eq!(factory.calls, 1, "descent within the fanout hit the cache");

    // One level further misses and costs exactly one more machine trip.
    let (left, _) = quartet.children().unwrap();
    get_or_compute(&mut cache, &structure, &mut factory, &left)?;
    assert_eq!(factory.calls, 2);

    // Repeating any of it stays cached.
    get_or_compute(&mut cache, &structure, &mut factory, &root)?;
    get_or_compute(&mut cache, &structure, &mut factory, &left)?;
    assert_eq!(factory.calls, 2);
    Ok(())
}

#[test]
fn empty_epoch_is_iterated_initial_state_at_big_stride() -> Result<()> {
    // At big-cycle strides an empty epoch samples only big boundaries,
    // which all carry the initial state - the iterated tree the
    // settlement layer builds. At uarch stride the same epoch carries
    // the idle churn pattern, covered by the oracle tests.
    let structure = S_SMALL;
    let mut cache = toy_storage(structure);
    let mut factory = ToyFactory {
        structure,
        script: vec![],
    };
    let log2_stride = structure.log2_uarch_span;
    let height = structure.log2_ruler_span() - log2_stride;
    let root = Quartet::level_root(0, log2_stride, height);
    let computed = get_or_compute(&mut cache, &structure, &mut factory, &root)?;

    let expected = MerkleTree::leaf(ToyStf::hash_of(0))
        .iterated(height as usize)
        .root_hash();
    assert_eq!(computed, expected);
    Ok(())
}

#[test]
fn reject_restores_the_checkpoint() {
    // After a rejected input, the window tail idles over the pre-window
    // state, and the next window builds on it.
    let structure = S_SMALL;
    let script = vec![reject(&[3]), accept(&[2])];
    let oracle = oracle_digests(&structure, &script);
    let window = u64::try_from(structure.window_span()).unwrap() as usize;
    let big = structure.big_span() as usize;

    // Window 0 processes and reverts: its last leaf is the checkpoint.
    assert_eq!(
        oracle[big - 1],
        ToyStf::hash_of(0),
        "revert lands on the closing slot"
    );
    // The tail idles over the checkpoint: churn inside each big cycle,
    // the checkpoint itself at each big boundary.
    assert_eq!(
        oracle[window - 2],
        ToyStf::churned_hash_of(0, IDLE_CHURN_TICKS),
        "tail slots churn over the checkpoint"
    );
    assert_eq!(
        oracle[window - 1],
        ToyStf::hash_of(0),
        "tail boundaries repeat the checkpoint"
    );
    // Window 1 resumes counting from the restored state.
    assert_eq!(
        oracle[window],
        ToyStf::hash_of(1),
        "next input builds on restored state"
    );
}

//
// Dispute-source spec: the hero-facing queries must agree with an
// in-memory reference tree built from the (oracle-checked) ruler runs.
//

/// The reference: a whole level materialized as one in-memory tree.
fn reference_tree(
    structure: Structure,
    script: &[ToyInput],
    level: &LevelCoords,
) -> Arc<MerkleTree> {
    let mut factory = ToyFactory {
        structure,
        script: script.to_vec(),
    };
    let mut ruler = factory.ruler_at(level.base_cycle).unwrap();
    let span = U256::from(1) << (level.log2_stride + level.height);
    let runs = ruler
        .collect(level.base_cycle + span, level.log2_stride)
        .unwrap();
    let mut builder = MerkleBuilder::default();
    for run in &runs {
        builder.append_repeated(run.hash, run.repetitions);
    }
    builder.build()
}

fn reference_node(tree: &Arc<MerkleTree>, depth: u64, index: U256) -> Arc<MerkleTree> {
    let mut node = Arc::clone(tree);
    for i in (0..depth).rev() {
        let (left, right) = node.subtrees().expect("depth bounded by height");
        node = if ((index >> i) & U256::from(1)).is_zero() {
            left
        } else {
            right
        };
    }
    node
}

pub(crate) fn toy_source(structure: Structure, script: &[ToyInput]) -> DisputeSource<ToyFactory> {
    toy_source_over(
        toy_storage(structure),
        structure,
        script,
        structure.log2_uarch_span,
    )
}

pub(crate) fn toy_source_over(
    storage: Storage,
    structure: Structure,
    script: &[ToyInput],
    log2_run_stride: u64,
) -> DisputeSource<ToyFactory> {
    let factory = ToyFactory {
        structure,
        script: script.to_vec(),
    };
    DisputeSource::new(storage, factory, 0, log2_run_stride).unwrap()
}

/// Records what the open regime leaves behind for a closed toy
/// epoch, through the production shapes: the input rows (the
/// frontier count), one window-root quartet row per input (folded
/// from a window-sized collect, exactly as the advance commit does),
/// and the final boundary row (the padding value).
fn record_toy_material(
    storage: &mut Storage,
    structure: &Structure,
    script: &[ToyInput],
    log2_stride: u64,
) -> Result<()> {
    use crate::storage::{Epoch, Input, InputId};
    use alloy::primitives::Address;

    let interior_height = structure.log2_window_span() - log2_stride;
    let count = script.len() as u64;

    let inputs: Vec<Input> = (0..count)
        .map(|i| Input {
            id: InputId {
                epoch_number: 0,
                input_index_in_epoch: i,
            },
            data: vec![],
        })
        .collect();
    storage.insert_consensus_data(
        0,
        inputs.iter(),
        [&Epoch {
            epoch_number: 0,
            input_index_boundary: count,
            root_tournament: Address::ZERO,
            block_created_number: 0,
        }]
        .into_iter(),
    )?;

    let mut factory = ToyFactory {
        structure: *structure,
        script: script.to_vec(),
    };
    let mut ruler = factory.ruler_at(U256::ZERO)?;
    for window in 0..count {
        let runs = ruler.collect(structure.window_start(window + 1), log2_stride)?;
        let root = fold_runs(
            runs.iter().map(|run| {
                (
                    run.hash,
                    u64::try_from(run.repetitions).expect("window-sized"),
                )
            }),
            interior_height,
        )?
        .root_hash();
        storage.insert_quartet_nodes(&[(
            Quartet {
                epoch: 0,
                log2_stride,
                height: interior_height,
                shift: U256::from(window),
            },
            root,
        )])?;
    }

    // The final boundary row: the toy's state at the frontier (the
    // path is never loaded by these tests).
    let final_hash = ruler.state_hash()?;
    storage.insert_boundary(0, count, &final_hash.data(), std::path::Path::new("/toy"))?;
    Ok(())
}

#[test]
fn dispute_nodes_match_reference_everywhere() -> Result<()> {
    // Every positional node of a level, at every height, against the
    // reference subtree; exercises cache hits, misses, and fanout
    // stratum crossings alike.
    let structure = S_MEDIUM;
    for (name, script) in scripts_for(&structure) {
        let level = LevelCoords::new(0, U256::ZERO, 0, structure.log2_ruler_span());
        let reference = reference_tree(structure, &script, &level);
        let mut source = toy_source(structure, &script);

        for height in (0..=level.height).rev() {
            let count = 1u64 << (level.height - height);
            for i in 0..count {
                let offset = U256::from(i) << height;
                let quartet = level.node(height, offset);
                let expected = reference_node(&reference, level.height - height, U256::from(i));
                assert_eq!(
                    source.node(&quartet)?,
                    expected.root_hash(),
                    "script {name}, height {height}, offset {offset}"
                );
                if height > 0 {
                    let (l, r) = source.children(&quartet)?;
                    let (el, er) = expected.subtrees().unwrap();
                    assert_eq!((l, r), (el.root_hash(), er.root_hash()));
                }
            }
        }
    }
    Ok(())
}

#[test]
fn dispute_proofs_match_reference_at_every_index() -> Result<()> {
    let structure = S_SMALL;
    for (name, script) in scripts_for(&structure) {
        let level = LevelCoords::new(0, U256::ZERO, 0, structure.log2_ruler_span());
        let reference = reference_tree(structure, &script, &level);
        let mut source = toy_source(structure, &script);

        let leaves = 1u64 << level.height;
        for i in 0..leaves {
            let proof = source.prove_leaf(&level, U256::from(i))?;
            let expected = reference.prove_leaf(U256::from(i));
            assert_eq!(proof.position, expected.position, "script {name}, leaf {i}");
            assert_eq!(proof.node, expected.node, "script {name}, leaf {i}");
            assert_eq!(proof.siblings, expected.siblings, "script {name}, leaf {i}");
            assert!(proof.verify_root(reference.root_hash()));
        }
        let last = source.prove_last(&level)?;
        assert_eq!(last.position, U256::from(leaves - 1));
        assert!(last.verify_root(reference.root_hash()));
    }
    Ok(())
}

#[test]
fn sub_level_at_nonzero_base_matches_reference() -> Result<()> {
    // An inner tournament's level: window 1 of the epoch at uarch
    // stride, pinning the base-cycle shift arithmetic on quartets.
    let structure = S_MEDIUM;
    let (_, script) = scripts_for(&structure).remove(3); // mixed
    let base = structure.window_span();
    let level = LevelCoords::new(0, base, 0, structure.log2_window_span());
    let reference = reference_tree(structure, &script, &level);
    let mut source = toy_source(structure, &script);

    assert_eq!(source.node(&level.root())?, reference.root_hash());
    let leaves = 1u64 << level.height;
    for i in 0..leaves {
        let proof = source.prove_leaf(&level, U256::from(i))?;
        let expected = reference.prove_leaf(U256::from(i));
        assert_eq!(proof.node, expected.node, "leaf {i}");
        assert_eq!(proof.siblings, expected.siblings, "leaf {i}");
    }
    Ok(())
}

#[test]
fn frontier_fold_serves_window_granularity_without_the_machine() -> Result<()> {
    // Everything at or above window granularity - the recorded
    // prefix, the padding suffix (mixed records 3 of S_MEDIUM's 4),
    // and every node whose span crosses the frontier - comes from the
    // prepaid window-root rows plus fixed-point arithmetic: same
    // answers as the reference, zero machine trips. Below window
    // granularity the machine regime takes over (like any nested
    // level), so full proof descents stay correct but are allowed to
    // replay.
    let structure = S_MEDIUM;
    let (_, script) = scripts_for(&structure).remove(3); // mixed
    let log2_stride = structure.log2_uarch_span;
    let interior_height = structure.log2_window_span() - log2_stride;
    let level = LevelCoords::new(
        0,
        U256::ZERO,
        log2_stride,
        structure.log2_ruler_span() - log2_stride,
    );

    let mut storage = toy_storage(structure);
    record_toy_material(&mut storage, &structure, &script, log2_stride)?;
    let state_dir = storage.state_dir().to_path_buf();

    let reference = reference_tree(structure, &script, &level);
    let mut counting = DisputeSource::new(
        storage,
        Counting {
            inner: ToyFactory {
                structure,
                script: script.clone(),
            },
            calls: 0,
        },
        0,
        log2_stride,
    )?;

    // The frontier fold's whole domain: every node at or above window
    // granularity, checked against the reference with the machine
    // forbidden.
    for height in (interior_height..=level.height).rev() {
        let count = 1u64 << (level.height - height);
        for i in 0..count {
            let quartet = level.node(height, U256::from(i) << height);
            let expected = reference_node(&reference, level.height - height, U256::from(i));
            assert_eq!(
                counting.node(&quartet)?,
                expected.root_hash(),
                "height {height}, index {i}"
            );
        }
    }
    assert_eq!(
        counting.factory().calls,
        0,
        "window granularity and above must not touch the machine"
    );

    // Below the window roots the machine regime serves; proofs cross
    // both domains and must still match the reference exactly.
    let leaves = 1u64 << level.height;
    for i in 0..leaves {
        let proof = counting.prove_leaf(&level, U256::from(i))?;
        let expected = reference.prove_leaf(U256::from(i));
        assert_eq!(proof.node, expected.node, "leaf {i}");
        assert_eq!(proof.siblings, expected.siblings, "leaf {i}");
    }

    // Those descents bought padding-window roots from the machine and
    // stored them AT the window-root coordinate - legitimate final
    // rows beyond the recorded prefix. A fresh source over the same
    // store must still construct and agree: counting them once
    // bricked every reconstruction after the hero's own join (the
    // prove_last descent crosses the last padding window).
    let mut rebuilt = toy_source_over(
        Storage::new(&state_dir).unwrap(),
        structure,
        &script,
        log2_stride,
    );
    assert_eq!(rebuilt.node(&level.root())?, reference.root_hash());
    Ok(())
}

#[test]
fn full_capacity_frontier_serves_without_padding() -> Result<()> {
    // Every window recorded (4 of S_MEDIUM's 4): the frontier fold's
    // no-padding branch, against the reference, machine forbidden at
    // window granularity and above.
    let structure = S_MEDIUM;
    let script = vec![accept(&[2, 1]), reject(&[1]), accept(&[3]), accept(&[1, 1])];
    let log2_stride = structure.log2_uarch_span;
    let interior_height = structure.log2_window_span() - log2_stride;
    let level = LevelCoords::new(
        0,
        U256::ZERO,
        log2_stride,
        structure.log2_ruler_span() - log2_stride,
    );

    let mut storage = toy_storage(structure);
    record_toy_material(&mut storage, &structure, &script, log2_stride)?;

    let reference = reference_tree(structure, &script, &level);
    let mut counting = DisputeSource::new(
        storage,
        Counting {
            inner: ToyFactory {
                structure,
                script: script.clone(),
            },
            calls: 0,
        },
        0,
        log2_stride,
    )?;

    assert_eq!(counting.node(&level.root())?, reference.root_hash());
    for window in 0..script.len() as u64 {
        let quartet = level.node(interior_height, U256::from(window) << interior_height);
        let expected = reference_node(
            &reference,
            level.height - interior_height,
            U256::from(window),
        );
        assert_eq!(
            counting.node(&quartet)?,
            expected.root_hash(),
            "window {window}"
        );
    }
    assert_eq!(
        counting.factory().calls,
        0,
        "no machine at window granularity"
    );

    let last = counting.prove_last(&level)?;
    assert!(last.verify_root(reference.root_hash()));
    Ok(())
}

#[test]
#[should_panic(expected = "corruption or version drift")]
fn missing_window_root_fails_loudly() {
    // Strict rows: a recorded epoch whose window-root row is absent
    // is corruption or version drift, and serving must PANIC - the
    // tick loops retry errors forever, so only a panic reaches the
    // node's loud exit path (lib.rs worker_failure).
    let structure = S_MEDIUM;
    let (_, script) = scripts_for(&structure).remove(3); // mixed
    let log2_stride = structure.log2_uarch_span;

    let mut storage = toy_storage(structure);
    record_toy_material(&mut storage, &structure, &script, log2_stride).unwrap();

    // A hole: delete one prepaid row through a raw connection (the
    // settled-epoch prune is the only blessed delete, so borrow its
    // shape).
    let raw =
        rusqlite::Connection::open(crate::storage::open::db_path(storage.state_dir())).unwrap();
    raw.execute(
        "DELETE FROM sling_nodes WHERE epoch <= 0 AND shift = ?1",
        [U256::from(1).to_be_bytes::<32>().to_vec()],
    )
    .unwrap();

    let factory = ToyFactory {
        structure,
        script: script.to_vec(),
    };
    let _ = DisputeSource::new(storage, factory, 0, log2_stride);
}

#[test]
fn no_material_serves_through_the_machine() -> Result<()> {
    // An epoch that recorded nothing (the empty epoch) has no level-0
    // material: the tiers stand down and the machine serves every
    // span as a fixed point of the initial state.
    let structure = S_SMALL;
    let log2_stride = structure.log2_uarch_span;
    let level = LevelCoords::new(
        0,
        U256::ZERO,
        log2_stride,
        structure.log2_ruler_span() - log2_stride,
    );
    let reference = reference_tree(structure, &[], &level);
    let mut counting = DisputeSource::new(
        toy_storage(structure),
        Counting {
            inner: ToyFactory {
                structure,
                script: vec![],
            },
            calls: 0,
        },
        0,
        log2_stride,
    )?;

    assert_eq!(counting.node(&level.root())?, reference.root_hash());
    assert!(
        counting.factory().calls > 0,
        "no material means machine trips"
    );
    Ok(())
}

#[test]
#[should_panic(expected = "node cache collision")]
fn collision_fails_loudly() {
    // Two different computations (scripts) sharing one cache model
    // nondeterminism: the second must not overwrite the first, and
    // the disagreement must PANIC - the tick loops retry errors
    // forever, so only a panic reaches the node's loud exit path.
    let structure = S_DIAGRAM;
    let mut cache = toy_storage(structure);
    let root = Quartet::level_root(0, 0, structure.log2_ruler_span());
    let (left, _) = root.children().unwrap();

    let mut factory_a = ToyFactory {
        structure,
        script: vec![accept(&[1])],
    };
    get_or_compute(&mut cache, &structure, &mut factory_a, &left).unwrap();

    let mut factory_b = ToyFactory {
        structure,
        script: vec![accept(&[2, 2])],
    };
    let _ = get_or_compute(&mut cache, &structure, &mut factory_b, &root);
}
