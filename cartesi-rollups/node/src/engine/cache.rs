// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The quartet compute engine over the storage-backed cache.
//!
//! `get_or_compute` is the one entry point disputes need for tree
//! material: commitment roots, bisection children, and proof siblings
//! are all just quartets. On a miss it computes the node's whole span
//! once and stores the subtree `PRECOMPUTE_LEVELS` deep, so descents
//! re-execute machine work only every `PRECOMPUTE_LEVELS` levels; the
//! total machine cost of a full descent is bounded by span * 1/(1 - 2^-8).
//!
//! The rows and their integrity semantics live behind [`Storage`]
//! (write-once positional keys, collision tripwire); this module owns
//! only what to compute and when.

use super::ruler::{Hashing, RulerFactory};
use super::structure::{Quartet, Structure};
use crate::merkle::{Digest, MerkleBuilder, MerkleTree};
use crate::storage::Storage;
use anyhow::{Result, ensure};
use std::sync::Arc;

/// Fanout depth stored per miss: 2^0 + ... + 2^8 = 511 rows. Tunable;
/// storage is negligible next to the machine time a miss costs.
pub const PRECOMPUTE_LEVELS: u64 = 8;

/// The engine of disputes: the hash of any quartet, computed at most
/// once per fanout stratum.
pub(crate) fn get_or_compute<F: RulerFactory>(
    storage: &mut Storage,
    structure: &Structure,
    factory: &mut F,
    quartet: &Quartet,
) -> Result<Digest> {
    quartet.assert_valid(structure);
    if let Some(hash) = storage.quartet_node(quartet)? {
        return Ok(hash);
    }
    compute_and_store(storage, structure, factory, quartet)
}

/// The miss path: one span execution, fanout stored, regardless of
/// whether the root row already exists. Callers use it directly to
/// materialize a cached node's descendants (a proof descent crossing a
/// fanout stratum); the insert then doubles as a nondeterminism probe,
/// since a recomputed root that disagrees with its row fails loudly.
pub(crate) fn compute_and_store<F: RulerFactory>(
    storage: &mut Storage,
    structure: &Structure,
    factory: &mut F,
    quartet: &Quartet,
) -> Result<Digest> {
    quartet.assert_valid(structure);

    // Also a stable log marker the test harness kills on (see
    // docs/test-harness.md); level-0 queries are seed-served, so this
    // line means dispute-time machine work.
    log::info!(
        "computing quartet stride 2^{} height {} shift {} of epoch {}",
        quartet.log2_stride,
        quartet.height,
        quartet.shift,
        quartet.epoch
    );

    let mut ruler = factory.ruler_at(
        quartet.span_start(),
        Hashing::for_stride(quartet.log2_stride),
    )?;
    // A single-transition quartet whose fanout stays above big-cycle
    // granularity is built from big-cycle roots: the stored levels never
    // reach inside a cycle, idle stretches cost one cycle however long, and
    // memory stays one cycle's runs. That is what makes a whole leaf-level
    // commitment (2^37 transitions under two levels) buildable.
    let c = structure.log2_uarch_span;
    let (runs, tree_height) = if quartet.log2_stride == 0 && quartet.height >= c + PRECOMPUTE_LEVELS
    {
        (
            ruler.collect_big_cycle_roots(quartet.span_end())?,
            quartet.height - c,
        )
    } else {
        (
            ruler.collect(quartet.span_end(), quartet.log2_stride)?,
            quartet.height,
        )
    };

    let mut builder = MerkleBuilder::default();
    for run in &runs {
        builder.append_repeated(run.hash, run.repetitions);
    }
    let tree = builder.build();
    ensure!(
        u64::from(tree.height()) == tree_height,
        "span tree height {} does not match the expected {tree_height} for quartet height {}",
        tree.height(),
        quartet.height
    );

    let mut rows = vec![];
    collect_fanout(
        &tree,
        quartet,
        PRECOMPUTE_LEVELS.min(quartet.height),
        &mut rows,
    );
    storage.insert_quartet_nodes(&rows)?;

    Ok(tree.root_hash())
}

fn collect_fanout(
    node: &Arc<MerkleTree>,
    quartet: &Quartet,
    depth_left: u64,
    rows: &mut Vec<(Quartet, Digest)>,
) {
    rows.push((quartet.clone(), node.root_hash()));
    if depth_left == 0 {
        return;
    }
    let (left_q, right_q) = quartet.children().expect("depth bounded by height");
    let (left_t, right_t) = node.subtrees().expect("non-leaf by height");
    collect_fanout(&left_t, &left_q, depth_left - 1, rows);
    collect_fanout(&right_t, &right_q, depth_left - 1, rows);
}
