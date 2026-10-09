// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The executable leaf-convention specification.
//!
//! `oracle_digests` enumerates tiny epochs with literal window, cycle,
//! and slot loops, independently of the ruler's scheduling. The geometry
//! tests compare against that sequence; later cache and proof tests also
//! use reference trees built from the ruler's already-checked runs.

use super::cache::{PRECOMPUTE_LEVELS, get_or_compute};
use super::config::EngineConfig;
use super::dispute::{DisputeSource, LevelCoords, fold_runs};
use super::ruler::{Hashing, Ruler, RulerFactory, Run};
use super::structure::{Quartet, Structure};
use super::toy::{IDLE_CHURN_TICKS, ToyBulk, ToyFactory, ToyInput, ToyOutcome, ToyStf};
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

// Tall enough that stride-0 quartets take the cache's big-cycle-root path
// (height >= c + PRECOMPUTE_LEVELS), at the root and one level below it.
const S_TALL: Structure = Structure {
    log2_input_span: 2,
    log2_barch_span: 7,
    log2_uarch_span: 2,
}; // 2048 positions

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
    // Toy tests hand DisputeSource their run stride; the pin only has
    // to be a valid table for the structure.
    let geometry = super::TournamentGeometry::new(
        vec![
            super::Level {
                log2_stride: structure.log2_uarch_span,
                height: structure.log2_ruler_span() - structure.log2_uarch_span,
            },
            super::Level {
                log2_stride: 0,
                height: structure.log2_uarch_span,
            },
        ],
        &structure,
    )
    .unwrap();
    let config = EngineConfig {
        structure,
        chain_id: 1,
        app: vec![0xda; 20],
        consensus: vec![0xdc; 20],
        template_hash: ToyStf::hash_of(0),
        emulator_version: "toy".into(),
        geometry,
    };
    let dir = tempfile::tempdir().unwrap().keep();
    let connection = Connection::open(dir.join("db.sqlite3")).unwrap();
    crate::storage::sql::schema::initialize(&connection).unwrap();
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
            let mut ruler = factory.ruler_at(U256::ZERO, Hashing::Sampled).unwrap();
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
                let mut ruler = factory.ruler_at(U256::ZERO, Hashing::Sampled).unwrap();
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
fn positioning_at_each_slot_matches_oracle() {
    // Cover partial uarch spans as well as window and big-cycle boundaries.
    let structure = S_SMALL;
    for (name, script) in scripts_for(&structure) {
        let oracle = oracle_digests(&structure, &script);
        let mut factory = ToyFactory {
            structure,
            script: script.clone(),
        };
        for start in 0..oracle.len() {
            let mut ruler = factory
                .ruler_at(U256::from(start), Hashing::Sampled)
                .unwrap();
            let expected = if start == 0 {
                ToyStf::hash_of(0)
            } else {
                oracle[start - 1]
            };
            assert_eq!(
                ruler.state_hash().unwrap(),
                expected,
                "script {name}, position {start}"
            );
            let runs = ruler.collect(structure.ruler_span(), 0).unwrap();
            assert_eq!(
                expand(&runs),
                oracle[start..],
                "script {name}, from {start}"
            );
        }
    }
}

#[test]
fn checked_transition_proofs_match_oracle_at_each_slot() {
    for (name, script) in scripts_for(&S_SMALL) {
        let oracle = oracle_digests(&S_SMALL, &script);
        let mut source = toy_source(S_SMALL, &script);
        let mut pre_state = ToyStf::hash_of(0);
        for (position, &post_state) in oracle.iter().enumerate() {
            let proof = source
                .prove_transition(U256::from(position), pre_state, post_state)
                .unwrap_or_else(|error| panic!("script {name}, position {position}: {error}"));
            assert!(!proof.is_empty());
            pre_state = post_state;
        }
    }
}

#[test]
fn transition_proof_rejects_wrong_expected_states() {
    let script = vec![accept(&[2, 1])];
    let oracle = oracle_digests(&S_SMALL, &script);
    let mut source = toy_source(S_SMALL, &script);
    let position = U256::ONE;
    let wrong = Digest::new([0xff; 32]);

    // A bad pre-state takes precedence when both supplied hashes are wrong.
    for (pre_state, observed, label) in [
        (wrong, oracle[0], "pre-state"),
        (oracle[0], oracle[1], "post-state"),
    ] {
        let error = source
            .prove_transition(position, pre_state, wrong)
            .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("epoch 0 transition 1"));
        assert!(message.contains(label));
        assert!(message.contains(&wrong.to_string()));
        assert!(message.contains(&observed.to_string()));
    }
    // A failed preparation does not poison the next attempt.
    assert!(
        !source
            .prove_transition(position, oracle[0], oracle[1])
            .unwrap()
            .is_empty()
    );
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
fn big_cycle_roots_fold_to_the_transition_tree() {
    // Every big-aligned span, from a fresh or a resumed ruler: the
    // per-cycle roots, folded c levels up, give the tree over the
    // transitions themselves.
    for structure in [S_DIAGRAM, S_SMALL, S_MEDIUM, S_TALL] {
        let c = structure.log2_uarch_span;
        let total = structure.log2_ruler_span();
        for (name, script) in scripts_for(&structure) {
            let oracle = oracle_digests(&structure, &script);
            for height in c..=total {
                let span = 1usize << height;
                for start in (0..oracle.len()).step_by(span) {
                    let mut expected = MerkleBuilder::default();
                    for digest in &oracle[start..start + span] {
                        expected.append(*digest);
                    }

                    let expected = expected.build().root_hash();

                    // Stepped, then through bulk collectors of every shape:
                    // one cycle a call, chunks with declines the ruler
                    // steps, and unbounded calls declining every other time.
                    let collectors = [
                        None,
                        Some(ToyBulk {
                            per_call: 1,
                            decline_every: 0,
                        }),
                        Some(ToyBulk {
                            per_call: 2,
                            decline_every: 3,
                        }),
                        Some(ToyBulk {
                            per_call: u64::MAX,
                            decline_every: 2,
                        }),
                    ];
                    for bulk in collectors {
                        let mut stf = ToyStf::new(structure, script.clone());
                        if let Some(bulk) = bulk {
                            stf = stf.with_bulk(bulk);
                        }
                        let mut ruler = Ruler::new(stf, structure, script.len() as u64);
                        ruler.advance(U256::from(start)).unwrap();
                        let end = U256::from(start + span);
                        let roots = ruler.collect_big_cycle_roots(end).unwrap();
                        assert_eq!(ruler.position(), end);
                        let mut folded = MerkleBuilder::default();
                        for run in &roots {
                            folded.append_repeated(run.hash, run.repetitions);
                        }
                        let folded = folded.build();
                        let context = format!(
                            "script {name}, [{start}, +2^{height}) on {structure:?}, {bulk:?}"
                        );
                        assert_eq!(u64::from(folded.height()), height - c, "{context}");
                        assert_eq!(folded.root_hash(), expected, "{context}");
                        if name == "empty" {
                            // An idle stretch is one root, however long.
                            assert_eq!(roots.len(), 1, "{context}");
                        }
                    }
                }
            }
        }
    }
}

/// The whole epoch's transition-level tree, from the oracle.
fn oracle_tree(structure: &Structure, script: &[ToyInput]) -> Arc<MerkleTree> {
    let mut reference = MerkleBuilder::default();
    for digest in oracle_digests(structure, script) {
        reference.append(digest);
    }
    reference.build()
}

/// Every row one build of `top` stores matches `reference`, in which `top`
/// sits `depth` levels below the root.
fn assert_fanout(
    cache: &Storage,
    reference: &Arc<MerkleTree>,
    top: &Quartet,
    depth: u64,
    name: &str,
) -> Result<()> {
    let mut stratum = vec![(top.clone(), depth)];
    while let Some((quartet, depth)) = stratum.pop() {
        let expected = reference_node(reference, depth, quartet.shift).root_hash();
        assert_eq!(
            cache.quartet_node(&quartet)?,
            Some(expected),
            "script {name}, stored row {quartet:?}"
        );
        if quartet.height > top.height - PRECOMPUTE_LEVELS {
            let (left, right) = quartet.children().unwrap();
            stratum.push((left, depth + 1));
            stratum.push((right, depth + 1));
        }
    }
    Ok(())
}

#[test]
fn tall_leaf_quartets_build_from_big_cycle_roots() -> Result<()> {
    // The cache path for tall stride-0 quartets: every stored fanout row,
    // and every node the descent computes below that stratum, matches the
    // transition-level tree.
    let structure = S_TALL;
    let total = structure.log2_ruler_span();
    assert!(total > structure.log2_uarch_span + PRECOMPUTE_LEVELS);
    for (name, script) in scripts_for(&structure) {
        let reference = oracle_tree(&structure, &script);
        let mut cache = toy_storage(structure);
        let mut factory = Counting {
            inner: ToyFactory {
                structure,
                script: script.clone(),
            },
            calls: 0,
        };

        let root = Quartet::level_root(0, 0, total);
        get_or_compute(&mut cache, &structure, &mut factory, &root)?;
        assert_eq!(factory.calls, 1);
        assert_fanout(&cache, &reference, &root, 0, name)?;
        assert_eq!(factory.calls, 1, "the fanout rows came from one build");

        // Below the stratum, down both edges to single transitions.
        for rightmost in [false, true] {
            let mut quartet = root.clone();
            let mut depth = 0;
            while let Some((left, right)) = quartet.children() {
                quartet = if rightmost { right } else { left };
                depth += 1;
                let expected = reference_node(&reference, depth, quartet.shift).root_hash();
                assert_eq!(
                    get_or_compute(&mut cache, &structure, &mut factory, &quartet)?,
                    expected,
                    "script {name}, descent at {quartet:?}"
                );
            }
        }

        // A quartet away from the epoch's start, exactly at the threshold
        // height: its fanout reaches the reduced tree's leaves.
        let (_, right) = root.children().unwrap();
        assert_eq!(right.height, structure.log2_uarch_span + PRECOMPUTE_LEVELS);
        let mut fresh = toy_storage(structure);
        get_or_compute(&mut fresh, &structure, &mut factory, &right)?;
        assert_fanout(&fresh, &reference, &right, 1, name)?;
    }
    Ok(())
}

/// Reports a stop once `spans` more spans have started, as a shutdown
/// request does to the machine factory mid-build.
struct Stopping<F> {
    inner: F,
    spans: u64,
}

impl<F: RulerFactory> RulerFactory for Stopping<F> {
    type S = F::S;
    fn ruler_at(&mut self, position: U256, hashing: Hashing) -> Result<Ruler<F::S>> {
        self.inner.ruler_at(position, hashing)
    }
    fn interrupted(&mut self) -> bool {
        if self.spans == 0 {
            return true;
        }
        self.spans -= 1;
        false
    }
}

/// The bottom fanout stratum of a level root: the spans a tall build
/// stores one by one.
fn bottom_span(root: &Quartet, index: u64) -> Quartet {
    Quartet {
        height: root.height - PRECOMPUTE_LEVELS,
        shift: (root.shift << PRECOMPUTE_LEVELS) + U256::from(index),
        ..root.clone()
    }
}

#[test]
fn an_interrupted_tall_build_keeps_its_spans_and_resumes() -> Result<()> {
    // A stop between spans fails the build but keeps the spans it
    // finished, and the next build reuses them: one ruler trip, positioned
    // at the first missing span, and the rows a whole build stores.
    let structure = S_TALL;
    let root = Quartet::level_root(0, 0, structure.log2_ruler_span());
    let spans = 1u64 << PRECOMPUTE_LEVELS;
    for (name, script) in scripts_for(&structure) {
        let reference = oracle_tree(&structure, &script);
        let toy = || ToyFactory {
            structure,
            script: script.clone(),
        };
        for stopped_after in [0, 1, spans / 2, spans - 1] {
            let mut cache = toy_storage(structure);
            let mut stopping = Stopping {
                inner: toy(),
                spans: stopped_after,
            };
            assert!(get_or_compute(&mut cache, &structure, &mut stopping, &root).is_err());
            assert_eq!(cache.quartet_node(&root)?, None, "script {name}");
            for index in 0..spans {
                let expected = (index < stopped_after).then(|| {
                    reference_node(&reference, PRECOMPUTE_LEVELS, U256::from(index)).root_hash()
                });
                assert_eq!(
                    cache.quartet_node(&bottom_span(&root, index))?,
                    expected,
                    "script {name}, stopped after {stopped_after}, span {index}"
                );
            }

            let mut resumed = Counting {
                inner: toy(),
                calls: 0,
            };
            assert_eq!(
                get_or_compute(&mut cache, &structure, &mut resumed, &root)?,
                reference.root_hash(),
                "script {name}, stopped after {stopped_after}"
            );
            assert_eq!(
                resumed.calls, 1,
                "script {name}, stopped after {stopped_after}"
            );
            assert_fanout(&cache, &reference, &root, 0, name)?;
        }
    }
    Ok(())
}

#[test]
fn idle_stretches_cost_one_captured_cycle() {
    // One collect steps one big cycle per idle stretch however long it is
    // (a tall build collects span by span, one capture each); replaying
    // every idle cycle would fold to the same roots, so only the step
    // count tells the two apart.
    let structure = S_TALL;
    for (name, script, stepped) in [
        ("empty", vec![], 1),
        // One active cycle, then idle to the epoch's end.
        ("one_short", vec![accept(&[1])], 2),
    ] {
        let mut factory = ToyFactory { structure, script };
        let mut ruler = factory.ruler_at(U256::ZERO, Hashing::Sampled).unwrap();
        ruler
            .collect_big_cycle_roots(structure.ruler_span())
            .unwrap();
        assert_eq!(ruler.into_stf().uresets(), stepped, "script {name}");
    }
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
    fn ruler_at(
        &mut self,
        position: U256,
        hashing: Hashing,
    ) -> Result<super::ruler::Ruler<ToyStf>> {
        self.calls += 1;
        self.inner.ruler_at(position, hashing)
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
    let mut ruler = factory
        .ruler_at(level.base_cycle, Hashing::Sampled)
        .unwrap();
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
    let mut ruler = factory.ruler_at(U256::ZERO, Hashing::Sampled)?;
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
fn coarser_strides_bypass_the_frontier_fold() -> Result<()> {
    // The fold's leaves are run-stride samples; a coarser tree over the
    // same span samples other states, so it is the machine's at every
    // height (a `>=` dispatch would serve fold nodes there instead).
    let structure = S_MEDIUM;
    let script = vec![accept(&[2, 1]), reject(&[1]), accept(&[3]), accept(&[1, 1])];
    let run_stride = structure.log2_uarch_span;
    let coarse = run_stride + 1;
    assert!(coarse <= structure.log2_window_span());
    let level = LevelCoords::new(0, U256::ZERO, coarse, structure.log2_ruler_span() - coarse);

    let mut storage = toy_storage(structure);
    record_toy_material(&mut storage, &structure, &script, run_stride)?;
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
        run_stride,
    )?;

    for height in (0..=level.height).rev() {
        let quartet = level.node(height, U256::ZERO);
        let expected = reference_node(&reference, level.height - height, U256::ZERO);
        assert_eq!(
            counting.node(&quartet)?,
            expected.root_hash(),
            "height {height}"
        );
    }
    assert!(
        counting.factory().calls > 0,
        "the machine served the coarser tree"
    );
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

// Work counts: the node must add no overhead over the emulator, so these
// tests count machine verbs, exactly and at the production structure,
// against the work the emulator cannot avoid. Times, memory and disk
// depend on hardware and workload and are not gated anywhere
// (node-architecture.md, performance stance).

/// Machine work, verb by verb. Hashes are the expensive atom (a root-hash
/// recomputation on the real machine); big cycles run natively.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Work {
    trips: u64,
    feeds: u64,
    big_cycles: u64,
    usteps: u64,
    uresets: u64,
    hashes: u64,
}

/// A toy that tallies its verbs into a tally shared across rulers.
/// Proving verbs are not metered.
struct Metered {
    toy: ToyStf,
    work: std::rc::Rc<std::cell::Cell<Work>>,
}

impl Metered {
    fn tally(&self, count: impl FnOnce(&mut Work)) {
        let mut work = self.work.get();
        count(&mut work);
        self.work.set(work);
    }
}

impl super::stf::Stf for Metered {
    fn state_hash(&mut self) -> Result<Digest> {
        self.tally(|w| w.hashes += 1);
        self.toy.state_hash()
    }
    fn yielded(&mut self) -> Result<bool> {
        self.toy.yielded()
    }
    fn terminal(&mut self) -> Result<bool> {
        self.toy.terminal()
    }
    fn uarch_halted(&mut self) -> Result<bool> {
        self.toy.uarch_halted()
    }
    fn feed(&mut self, window: u64) -> Result<()> {
        self.tally(|w| w.feeds += 1);
        self.toy.feed(window)
    }
    fn ustep(&mut self) -> Result<()> {
        self.tally(|w| w.usteps += 1);
        self.toy.ustep()
    }
    fn ureset(&mut self) -> Result<()> {
        self.tally(|w| w.uresets += 1);
        self.toy.ureset()
    }
    fn run_big(&mut self, big_cycles: u64) -> Result<u64> {
        let ran = self.toy.run_big(big_cycles)?;
        self.tally(|w| w.big_cycles += ran);
        Ok(ran)
    }
    fn log_feed(&mut self, window: u64) -> Result<Vec<u8>> {
        self.toy.log_feed(window)
    }
    fn log_ustep(&mut self) -> Result<Vec<u8>> {
        self.toy.log_ustep()
    }
    fn log_ureset(&mut self) -> Result<Vec<u8>> {
        self.toy.log_ureset()
    }
}

/// Positions like [`ToyFactory`], from the epoch start, so a trip's
/// replay is its whole prefix; production resumes from the nearest
/// stored window boundary, which is the same inside window 0.
struct MeteredFactory {
    structure: Structure,
    script: Vec<ToyInput>,
    work: std::rc::Rc<std::cell::Cell<Work>>,
}

impl MeteredFactory {
    fn new(structure: Structure, script: Vec<ToyInput>) -> Self {
        MeteredFactory {
            structure,
            script,
            work: Default::default(),
        }
    }

    fn stf(&self) -> Metered {
        Metered {
            toy: ToyStf::new(self.structure, self.script.clone()),
            work: self.work.clone(),
        }
    }

    /// Work since the last call.
    fn take(&self) -> Work {
        self.work.take()
    }
}

impl RulerFactory for MeteredFactory {
    type S = Metered;
    fn ruler_at(
        &mut self,
        position: U256,
        _hashing: Hashing,
    ) -> Result<super::ruler::Ruler<Metered>> {
        let stf = self.stf();
        stf.tally(|w| w.trips += 1);
        let mut ruler = super::ruler::Ruler::new(stf, self.structure, self.script.len() as u64);
        ruler.advance(position)?;
        Ok(ruler)
    }
}

/// `n` active big cycles of `usteps` each, accepted.
fn dense(n: usize, usteps: u64) -> ToyInput {
    accept(&vec![usteps; n])
}

#[test]
fn eager_window_runs_its_cycles_once_and_hashes_once_per_sample() {
    // The runner's collect at the two-level root stride: every big cycle
    // runs once on the big machine, nothing steps the uarch, and each
    // sample costs one hash, plus one for the idle tail.
    let structure = Structure::PRODUCTION;
    let log2_stride = 38;
    let spacing = 1usize << (log2_stride - structure.log2_uarch_span);
    for cycles in [1, 2 * spacing, 2 * spacing + 5] {
        let factory = MeteredFactory::new(structure, vec![dense(cycles, 2)]);
        let mut ruler = super::ruler::Ruler::new(factory.stf(), structure, 1);
        ruler
            .collect(structure.window_start(1), log2_stride)
            .unwrap();
        assert_eq!(
            factory.take(),
            Work {
                feeds: 1,
                big_cycles: cycles as u64,
                hashes: cycles.div_ceil(spacing) as u64 + 1,
                ..Work::default()
            },
            "{cycles} cycles"
        );
    }
}

#[test]
fn dense_leaf_hashes_each_distinct_leaf_once() {
    // A two-level leaf (stride 0, 2^38 transitions) built from big-cycle
    // roots. A big cycle with d active usteps has d + 2 distinct leaves
    // (each active post-state, the halted run, the closing reset), which
    // is all the hashing the commitment needs; the idle rest of the leaf
    // costs one captured span per collect, however long it is.
    let structure = Structure::PRODUCTION;
    let usteps = [3u64, 1, 5, 2, 7];
    let factory = MeteredFactory::new(structure, vec![accept(&usteps)]);
    let mut ruler = super::ruler::Ruler::new(factory.stf(), structure, 1);
    ruler.collect_big_cycle_roots(U256::from(1) << 38).unwrap();

    let active: u64 = usteps.iter().sum();
    let cycles = usteps.len() as u64;
    assert_eq!(
        factory.take(),
        Work {
            feeds: 1,
            usteps: active + cycles + IDLE_CHURN_TICKS + 1,
            uresets: cycles + 1,
            hashes: active + 2 * cycles + IDLE_CHURN_TICKS + 2,
            ..Work::default()
        }
    );
}

#[test]
fn a_resumed_tall_build_steps_only_its_missing_spans() {
    // Over a script with no idle cycle, the stopped build and its resume
    // step the uarch exactly as often as one whole build: positioning at
    // the first missing span runs whole cycles natively.
    let structure = S_TALL;
    let window_bigs = 1usize << structure.log2_barch_span;
    let script =
        vec![dense(window_bigs, structure.big_span() - 1); structure.max_inputs() as usize];
    let root = Quartet::level_root(0, 0, structure.log2_ruler_span());
    let stepped = |work: Work| (work.usteps, work.uresets);

    let mut factory = MeteredFactory::new(structure, script.clone());
    get_or_compute(&mut toy_storage(structure), &structure, &mut factory, &root).unwrap();
    let whole = stepped(factory.take());

    let mut cache = toy_storage(structure);
    let mut stopping = Stopping {
        inner: MeteredFactory::new(structure, script),
        spans: 100,
    };
    assert!(get_or_compute(&mut cache, &structure, &mut stopping, &root).is_err());
    let first = stepped(stopping.inner.take());
    stopping.spans = u64::MAX;
    get_or_compute(&mut cache, &structure, &mut stopping, &root).unwrap();
    let rest = stepped(stopping.inner.take());
    assert_eq!((first.0 + rest.0, first.1 + rest.1), whole);
    assert!(first.0 > 0 && rest.0 > 0);
}

#[test]
fn a_tall_build_captures_one_idle_cycle_per_span() {
    // A tall build stores each bottom-stratum span as it completes, so an
    // idle stretch costs one captured cycle per span it covers: 256 for an
    // empty epoch, where one whole-span collect would capture one. The
    // cost is bounded per build, not per idle cycle.
    let structure = S_TALL;
    let root = Quartet::level_root(0, 0, structure.log2_ruler_span());
    let mut factory = MeteredFactory::new(structure, vec![]);
    get_or_compute(&mut toy_storage(structure), &structure, &mut factory, &root).unwrap();
    let work = factory.take();
    assert_eq!(
        (work.trips, work.uresets),
        (1, 1 << PRECOMPUTE_LEVELS),
        "one trip, one capture per span"
    );
}

#[test]
fn positioning_runs_the_prefix_once_and_hashes_nothing() {
    // Whole big cycles run natively, a sub-cycle remainder steps the
    // uarch, and no state is hashed on the way.
    let structure = Structure::PRODUCTION;
    let mut factory = MeteredFactory::new(structure, vec![dense(10, 2), dense(20, 2)]);
    let position =
        structure.window_start(1) + (U256::from(7) << structure.log2_uarch_span) + U256::ONE;
    factory.ruler_at(position, Hashing::Sampled).unwrap();
    assert_eq!(
        factory.take(),
        Work {
            trips: 1,
            feeds: 2,
            big_cycles: 10 + 7,
            usteps: 1,
            ..Work::default()
        }
    );
}

#[test]
fn join_descent_replays_the_prefix_once_per_stratum() {
    // Pinned: a join builds the two-level leaf (one trip) and proves its
    // last leaf, which descends four fanout strata (heights 30, 22, 14 and
    // 6), each a trip that re-runs the input's prefix from the window
    // boundary. The prefix replay is native and unhashed, so even a leaf
    // deep inside a long input stays within the node's measured overhead
    // over the emulator (docs/measurements/node-vs-emulator.md).
    let structure = Structure::PRODUCTION;
    let leaf_cycles = 1usize << (38 - structure.log2_uarch_span);
    // The input runs through the first leaf and 50 cycles into the
    // second, which is the one disputed.
    let cycles = leaf_cycles + 50;
    let factory = MeteredFactory::new(structure, vec![dense(cycles, 2)]);
    let mut source = DisputeSource::new(toy_storage(structure), factory, 0, 38).unwrap();
    let level = LevelCoords::new(0, U256::from(1) << 38, 0, 38);

    source.node(&level.root()).unwrap();
    let build = source.factory().take();
    assert_eq!((build.trips, build.big_cycles), (1, leaf_cycles as u64));

    source.prove_last(&level).unwrap();
    let descent = source.factory().take();
    assert_eq!(
        (descent.trips, descent.big_cycles),
        (4, 4 * cycles as u64),
        "each stratum trip re-runs the whole input"
    );
}

#[test]
fn tail_overlay_diverges_at_its_position_and_never_writes() -> Result<()> {
    // The harness adversary: every ruler leaf at or past `from` reads as
    // Z, on every stride, with proofs that open the patched roots; and the
    // store it shares keeps only honest rows.
    let structure = S_SMALL;
    let (_, script) = scripts_for(&structure).remove(3); // mixed
    let total = structure.log2_ruler_span();
    let honest_leaves = oracle_digests(&structure, &script);
    let z = Digest::from_digest(&[0xee; 32])?;

    for (from, recorded) in [0u64, 1, 7, 8, 37, 127]
        .into_iter()
        .flat_map(|from| [(from, false), (from, true)])
    {
        let mut shared = toy_storage(structure);
        // With the runner's window roots recorded, root-stride quartets at
        // window granularity and above come from the frontier fold, which
        // the overlay must also override.
        if recorded {
            record_toy_material(&mut shared, &structure, &script, structure.log2_uarch_span)?;
        }
        let state_dir = shared.state_dir().to_path_buf();
        let mut adversary = toy_source_over(shared, structure, &script, structure.log2_uarch_span);
        adversary.set_tail(super::dispute::Tail {
            from: U256::from(from),
            value: z,
        });

        for log2_stride in [0, structure.log2_uarch_span] {
            let height = total - log2_stride;
            let level = LevelCoords::new(0, U256::ZERO, log2_stride, height);
            let root = adversary.node(&level.root())?;
            for j in 0..1u64 << height {
                let position = (j + 1) * (1 << log2_stride) - 1;
                let expected = if position >= from {
                    z
                } else {
                    honest_leaves[position as usize]
                };
                let proof = adversary.prove_leaf(&level, U256::from(j))?;
                assert_eq!(
                    proof.node, expected,
                    "from {from}, stride {log2_stride}, leaf {j}"
                );
                assert!(
                    proof.verify_root(root),
                    "from {from}, stride {log2_stride}, leaf {j}"
                );
            }
        }

        // Every quartet, from an honest source over the shared store and
        // from a fresh one: a stored patched row would show here.
        let mut over_shared = toy_source_over(
            Storage::new(&state_dir)?,
            structure,
            &script,
            structure.log2_uarch_span,
        );
        let mut fresh = toy_source(structure, &script);
        for log2_stride in 0..=total {
            for height in 0..=total - log2_stride {
                for shift in 0..1u64 << (total - log2_stride - height) {
                    let quartet = Quartet {
                        epoch: 0,
                        log2_stride,
                        height,
                        shift: U256::from(shift),
                    };
                    assert_eq!(
                        over_shared.node(&quartet)?,
                        fresh.node(&quartet)?,
                        "from {from}: {quartet:?}"
                    );
                }
            }
        }
    }
    Ok(())
}
