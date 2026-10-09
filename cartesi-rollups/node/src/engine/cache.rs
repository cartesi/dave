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

use super::ruler::{Hashing, Ruler, RulerFactory, Run};
use super::structure::{Quartet, Structure};
use crate::merkle::{Digest, MerkleBuilder, MerkleTree};
use crate::storage::Storage;
use alloy::primitives::U256;
use anyhow::{Result, bail, ensure};
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

    // Quartets the level-0 frontier serves never get here, so this line
    // means dispute-time machine work.
    log::info!(
        "computing quartet stride 2^{} height {} shift {} of epoch {}",
        quartet.log2_stride,
        quartet.height,
        quartet.shift,
        quartet.epoch
    );

    let tree = if quartet.log2_stride == 0
        && quartet.height >= structure.log2_uarch_span + PRECOMPUTE_LEVELS
    {
        build_tall(storage, structure, factory, quartet)?
    } else {
        let mut ruler = factory.ruler_at(
            quartet.span_start(),
            Hashing::for_stride(quartet.log2_stride),
        )?;
        let runs = ruler.collect(quartet.span_end(), quartet.log2_stride)?;
        fold(&runs, quartet, quartet.height)?
    };

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

/// A single-transition quartet whose fanout stays above big-cycle
/// granularity is built from big-cycle roots: the stored levels never
/// reach inside a cycle, and memory stays one cycle's runs. That is what
/// makes a whole leaf-level commitment (2^38 transitions under two
/// levels) buildable. It is built span by span over its bottom fanout
/// stratum, storing each span's row as it completes, so a stop between
/// spans keeps them and the next build resumes after them; a span row
/// stored any other way (a descent's fanout) is reused too. An idle
/// stretch costs one captured cycle per span it covers.
fn build_tall<F: RulerFactory>(
    storage: &mut Storage,
    structure: &Structure,
    factory: &mut F,
    quartet: &Quartet,
) -> Result<Arc<MerkleTree>> {
    let spans = 1u64 << PRECOMPUTE_LEVELS;
    let span_height = quartet.height - PRECOMPUTE_LEVELS;
    let mut top = MerkleBuilder::default();
    // Positioned once, at the first missing span; stored spans are skipped
    // by advancing, which hashes nothing.
    let mut ruler: Option<Ruler<F::S>> = None;
    for index in 0..spans {
        let span = Quartet {
            height: span_height,
            shift: (quartet.shift << PRECOMPUTE_LEVELS) + U256::from(index),
            ..quartet.clone()
        };
        if let Some(root) = storage.quartet_node(&span)? {
            top.append(root);
            continue;
        }
        if factory.interrupted() {
            bail!("stopped by shutdown at span {index} of {spans}");
        }
        let ruler = match &mut ruler {
            Some(ruler) => {
                ruler.advance(span.span_start())?;
                ruler
            }
            None => {
                if index > 0 {
                    log::info!("{index} of {spans} spans already stored, resuming");
                }
                ruler.insert(factory.ruler_at(span.span_start(), Hashing::PerStep)?)
            }
        };
        let runs = ruler.collect_big_cycle_roots(span.span_end())?;
        let root = fold(&runs, &span, span_height - structure.log2_uarch_span)?.root_hash();
        storage.insert_quartet_nodes(&[(span, root)])?;
        top.append(root);
    }
    Ok(top.build())
}

/// The tree over a quartet's runs, which must be `tree_height` tall.
fn fold(runs: &[Run], quartet: &Quartet, tree_height: u64) -> Result<Arc<MerkleTree>> {
    let mut builder = MerkleBuilder::default();
    for run in runs {
        builder.append_repeated(run.hash, run.repetitions);
    }
    let tree = builder.build();
    ensure!(
        u64::from(tree.height()) == tree_height,
        "span tree height {} does not match the expected {tree_height} for quartet height {}",
        tree.height(),
        quartet.height
    );
    Ok(tree)
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
