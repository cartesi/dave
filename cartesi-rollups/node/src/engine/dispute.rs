// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The dispute-facing node source: every merkle node a tournament
//! hero needs, answered by quartet.
//!
//! A tournament level's commitment tree lives at a [`LevelCoords`]:
//! its root, the node a match contests, bisection children, and
//! leaf-proof siblings are all quartets under it. The source serves
//! them from three places, in order: the level-0 tiers (the leaf
//! runs regime 1 recorded while the epoch was open, served through
//! the persisted window-root rows plus lazy interior folds), the
//! quartet cache, and machine execution through
//! [`compute_and_store`]'s fanout.
//!
//! Proofs are descents: `prove_leaf` walks root to leaf collecting the
//! off-path sibling at each height through `children`, which
//! recomputes a parent's whole span when its children are missing -
//! one ruler pass per fanout stratum, and the recomputed parent must
//! agree with its cached row (a nondeterminism probe on every cold
//! descent).

use super::cache::{compute_and_store, get_or_compute};
use super::ruler::RulerFactory;
use super::structure::{Quartet, Structure};
use crate::merkle::{Digest, MerkleBuilder, MerkleProof, MerkleTree};
use crate::storage::Storage;
use alloy::primitives::U256;
use anyhow::{Result, ensure};
use std::sync::Arc;

/// Where a tournament level's commitment tree sits on the ruler. The
/// tournament contract supplies the shape (log2_stride, height) and
/// the span start (base_cycle, a meta-cycle); levels always tile
/// exactly, so base_cycle is aligned to the level's full span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LevelCoords {
    pub epoch: u64,
    pub base_cycle: U256,
    pub log2_stride: u64,
    pub height: u64,
}

impl LevelCoords {
    pub fn new(epoch: u64, base_cycle: U256, log2_stride: u64, height: u64) -> Self {
        let span = U256::from(1) << (log2_stride + height);
        assert!(
            (base_cycle % span).is_zero(),
            "level base {base_cycle} not aligned to its span 2^{}",
            log2_stride + height
        );
        LevelCoords {
            epoch,
            base_cycle,
            log2_stride,
            height,
        }
    }

    pub fn root(&self) -> Quartet {
        self.node(self.height, U256::ZERO)
    }

    /// The node at `height` whose span starts at the level-local leaf
    /// offset `leaf_offset`. This is the contested-node map: a match at
    /// currentHeight h with runningLeafPosition p contests node(h, p),
    /// since p is the leftmost leaf the contested node covers.
    pub fn node(&self, height: u64, leaf_offset: U256) -> Quartet {
        assert!(height <= self.height, "node higher than the level root");
        assert!(
            leaf_offset < (U256::from(1) << self.height),
            "leaf offset outside the level"
        );
        assert!(
            (leaf_offset % (U256::from(1) << height)).is_zero(),
            "leaf offset not aligned to the node span"
        );
        Quartet {
            epoch: self.epoch,
            log2_stride: self.log2_stride,
            height,
            shift: (self.base_cycle >> (self.log2_stride + height)) + (leaf_offset >> height),
        }
    }
}

/// Folds leaf runs into the subtree they tile: repetitions must sum
/// to exactly 2^log2_leaves. Run-compressed - cost is bounded by
/// distinct runs, not leaves. The one level-0 fold both regimes
/// share: the runner folds each closed window's runs into its root
/// row, the facade folds window interiors on demand, and the epoch
/// roll folds window roots into the settlement root.
pub fn fold_runs(
    runs: impl IntoIterator<Item = (Digest, u64)>,
    log2_leaves: u64,
) -> Result<Arc<MerkleTree>> {
    let mut builder = MerkleBuilder::default();
    let mut total = 0u128;
    for (hash, repetitions) in runs {
        ensure!(repetitions > 0, "empty leaf run");
        builder.append_repeated(hash, repetitions);
        total += repetitions as u128;
    }
    ensure!(
        total == 1u128 << log2_leaves,
        "leaf runs must tile 2^{log2_leaves} leaves, got {total}"
    );
    Ok(builder.build())
}

/// Positional lookup: walk `depth` levels down from the root, taking
/// the branch each `index` bit names (high bit first).
fn descend(tree: Arc<MerkleTree>, depth: u64, index: U256) -> Arc<MerkleTree> {
    let mut node = tree;
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

/// The frontier composition: the one thing level 0 keeps for itself.
/// The open regime leaves a
/// dense prefix of window-root rows; everything right of the
/// frontier is the fixed point repeated. Nodes at or above window
/// granularity have spans that cross the frontier, so neither rows
/// alone nor the machine (a whole-epoch replay) can serve them -
/// this fold can, and it is the ONLY level-0 exception. Everything
/// below window granularity rides the ordinary machine regime,
/// exactly like a nested tournament below its level root, priced by
/// the same one-window replay that level-1 entry already pays.
///
/// Rows are strict: a recorded window's root row is prepaid by the
/// advance commit, and its absence is corruption or version drift,
/// never something to heal around.
struct Frontier {
    /// Windows with recorded material: the closed epoch's input
    /// count. Zero stands the fold down (an inputless epoch is all
    /// fixed point; the machine serves it as idle arithmetic).
    recorded: u64,
    /// What padding leaves repeat: the epoch's final boundary hash.
    padding: Digest,
    /// The tree over all window roots, folded on first touch from
    /// one range scan; O(recorded) resident (run-compressed).
    top: Option<Arc<MerkleTree>>,
}

/// One epoch's node source. The cache spans epochs; the level-0
/// material and the factory (its inputs) do not, so neither does the
/// source.
pub struct DisputeSource<F: RulerFactory> {
    storage: Storage,
    structure: Structure,
    factory: F,
    epoch: u64,
    /// The stride the level-0 window roots were recorded at
    /// (production: the rollups LOG2_STRIDE). The frontier fold
    /// serves quartets at or above window granularity on it; below
    /// that is the machine's domain.
    log2_run_stride: u64,
    frontier: Frontier,
}

impl<F: RulerFactory> DisputeSource<F> {
    pub fn new(mut storage: Storage, factory: F, epoch: u64, log2_run_stride: u64) -> Result<Self> {
        let structure = storage.sling_config()?.structure;
        assert!(
            log2_run_stride >= structure.log2_uarch_span,
            "run stride below a big cycle: idle padding would churn"
        );
        assert!(
            log2_run_stride <= structure.log2_window_span(),
            "run stride wider than a window"
        );

        // The frontier stands on the open regime's actual material,
        // read as the PREFIX of window-root rows (shift < inputs):
        // the coordinate legitimately carries machine-bought rows
        // beyond the prefix - a dispute descent through a padding
        // window's root stores its fanout there - and counting those
        // once bricked reconstruction after the hero's own join. A
        // store the runner never processed (the engine harnesses; a
        // freshly migrated node) has an empty prefix and the machine
        // serves everything - the pre-frontier full-replay behavior.
        // A nonzero prefix must match the closed epoch's input count
        // exactly; anything else is corruption. The padding value is
        // the final boundary hash - the row the gap GC always keeps.
        let interior_height = structure.log2_window_span() - log2_run_stride;
        let inputs = storage.input_count(epoch)?;
        let rows = storage.window_root_count(epoch, log2_run_stride, interior_height, inputs)?;
        // Invariant violations panic: the callers' tick loops retry
        // Err forever, which would silently livelock the dispute on a
        // corrupt store (the loudness doctrine, node-architecture.md).
        let recorded = if rows == 0 {
            0
        } else {
            assert_eq!(
                rows, inputs,
                "epoch {epoch} has {rows} window-root rows in the prefix of \
                 {inputs} inputs: corruption or version drift"
            );
            inputs
        };
        let padding = if recorded > 0 {
            let hash = storage.snapshot_hash(epoch, recorded)?.unwrap_or_else(|| {
                panic!(
                    "final boundary row missing for epoch {epoch} at input {recorded}: \
                     corruption or version drift"
                )
            });
            Digest::from_digest(&hash)?
        } else {
            Digest::ZERO
        };

        Ok(DisputeSource {
            storage,
            structure,
            factory,
            epoch,
            log2_run_stride,
            frontier: Frontier {
                recorded,
                padding,
                top: None,
            },
        })
    }

    pub fn factory(&self) -> &F {
        &self.factory
    }

    /// A ruler positioned at `position`: the machine verb of the
    /// facade. This is what proof positioning uses (the disputed
    /// leaf's transition witness) and what entering a nested
    /// tournament uses to start producing the nested computation
    /// hash. Positioning resumes from the boundary store's nearest
    /// answer and densifies as it advances.
    pub fn machine_at(&mut self, position: U256) -> Result<super::ruler::Ruler<F::S>> {
        self.factory.ruler_at(position)
    }

    /// Frontier coverage: the quartet sits at or above window
    /// granularity on the run stride, and the epoch recorded material
    /// to serve it from. Below window granularity every quartet -
    /// real or padding window alike - is the machine's domain, like
    /// any nested level (a padding-window replay is one snapshot load
    /// plus idle arithmetic).
    ///
    /// Coverage caveat (inherited from the SeedTree, unreachable
    /// today): a covered height-0 quartet at a stride strictly above
    /// the run stride names one sampled state, which is not the fold
    /// this serves; the two agree only when the leaf stride equals
    /// the run stride. No reachable geometry asks for one (production
    /// level strides are 44/27/0 and levels never coarsen), but
    /// revisit this dispatch if a level stride ever lands strictly
    /// above the run stride.
    fn covered(&self, quartet: &Quartet) -> bool {
        assert_eq!(quartet.epoch, self.epoch, "quartet from another epoch");
        self.frontier.recorded > 0
            && quartet.log2_stride >= self.log2_run_stride
            && quartet.height + (quartet.log2_stride - self.log2_run_stride)
                >= self.interior_height()
    }

    /// Leaves of one window's level-0 subtree: log2_window_span less
    /// the run stride (production: height 24 over stride 44).
    fn interior_height(&self) -> u64 {
        self.structure.log2_window_span() - self.log2_run_stride
    }

    /// The tree over all window roots, tiling the whole ruler: the
    /// recorded prefix from its rows (one strict range scan), the
    /// padding window root - the fixed point iterated up - repeated
    /// to fill the input span. Memoized; folding is O(recorded).
    fn top_tree(&mut self) -> Result<Arc<MerkleTree>> {
        if let Some(tree) = &self.frontier.top {
            return Ok(Arc::clone(tree));
        }
        let interior_height = self.interior_height();
        let roots = self.storage.window_root_range(
            self.epoch,
            self.log2_run_stride,
            interior_height,
            self.frontier.recorded,
        )?;
        let mut runs: Vec<(Digest, u64)> = roots.into_iter().map(|root| (root, 1)).collect();
        let max_windows = self.structure.max_inputs();
        if self.frontier.recorded < max_windows {
            let padding_root = fold_runs(
                [(self.frontier.padding, 1u64 << interior_height)],
                interior_height,
            )?
            .root_hash();
            runs.push((padding_root, max_windows - self.frontier.recorded));
        }
        let tree = fold_runs(runs, self.structure.log2_input_span)?;
        self.frontier.top = Some(Arc::clone(&tree));
        Ok(tree)
    }

    /// A covered quartet's subtree: a positional walk down the top
    /// tree. Covered quartets consume exactly their shift bits.
    fn level0_subtree(&mut self, quartet: &Quartet) -> Result<Arc<MerkleTree>> {
        debug_assert!(self.covered(quartet));
        let height_in_level0 = quartet.height + (quartet.log2_stride - self.log2_run_stride);
        let depth = self.structure.log2_input_span - (height_in_level0 - self.interior_height());
        Ok(descend(self.top_tree()?, depth, quartet.shift))
    }

    /// The hash of any quartet.
    pub fn node(&mut self, quartet: &Quartet) -> Result<Digest> {
        if self.covered(quartet) {
            return Ok(self.level0_subtree(quartet)?.root_hash());
        }
        get_or_compute(
            &mut self.storage,
            &self.structure,
            &mut self.factory,
            quartet,
        )
    }

    /// Both children of a quartet: the bisection and proof primitive.
    /// A missing child recomputes the parent's span, not the child's -
    /// half the machine trips of computing each child separately, and
    /// the parent row collision-checks the recomputation.
    pub fn children(&mut self, parent: &Quartet) -> Result<(Digest, Digest)> {
        let (left, right) = parent.children().expect("children of a leaf quartet");
        if self.covered(&left) {
            // Both children (hence the parent) sit at or above window
            // granularity: the frontier fold serves them.
            return Ok((self.node(&left)?, self.node(&right)?));
        }
        if let (Some(l), Some(r)) = (
            self.storage.quartet_node(&left)?,
            self.storage.quartet_node(&right)?,
        ) {
            return Ok((l, r));
        }
        // When the parent is a window root, this span recomputation
        // collision-checks the open regime's persisted fold - the
        // dispute path re-verifying level-0 material with the machine.
        compute_and_store(
            &mut self.storage,
            &self.structure,
            &mut self.factory,
            parent,
        )?;
        let l = self
            .storage
            .quartet_node(&left)?
            .expect("fanout stores the children");
        let r = self
            .storage
            .quartet_node(&right)?
            .expect("fanout stores the children");
        Ok((l, r))
    }

    /// Merkle proof of a level leaf: the descent from the level root,
    /// collecting the off-path sibling at each height. Siblings come
    /// out bottom-up, matching the on-chain verifier's order.
    pub fn prove_leaf(&mut self, level: &LevelCoords, index: U256) -> Result<MerkleProof> {
        assert!(
            index < (U256::from(1) << level.height),
            "leaf index outside the level"
        );
        let mut siblings = Vec::with_capacity(level.height as usize);
        let mut node = level.root();
        let mut hash = self.node(&node)?;
        while node.height > 0 {
            let (left_hash, right_hash) = self.children(&node)?;
            let (left, right) = node.children().expect("non-leaf by loop condition");
            let bit = (index >> (node.height - 1)) & U256::from(1);
            (node, hash) = if bit.is_zero() {
                siblings.push(right_hash);
                (left, left_hash)
            } else {
                siblings.push(left_hash);
                (right, right_hash)
            };
        }
        siblings.reverse();
        Ok(MerkleProof {
            position: index,
            node: hash,
            siblings,
        })
    }

    /// Proof of the level's last leaf, as join demands.
    pub fn prove_last(&mut self, level: &LevelCoords) -> Result<MerkleProof> {
        let last = (U256::from(1) << level.height) - U256::from(1);
        self.prove_leaf(level, last)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_coordinates_by_hand() {
        // Level of span 2^5 (stride 2, height 3) starting at ruler
        // position 0x80: base leaf index 32, so the node of height 1
        // at leaf offset 6 covers leaves 38..40, i.e. shift 19.
        let level = LevelCoords::new(3, U256::from(0x80), 2, 3);
        let root = level.root();
        assert_eq!(root.epoch, 3);
        assert_eq!(root.log2_stride, 2);
        assert_eq!(root.height, 3);
        assert_eq!(root.shift, U256::from(4));
        assert_eq!(root.span_start(), U256::from(0x80));
        assert_eq!(root.span_end(), U256::from(0xa0));

        let contested = level.node(1, U256::from(6));
        assert_eq!(contested.height, 1);
        assert_eq!(contested.shift, U256::from(19));
        assert_eq!(contested.span_start(), U256::from(0x80 + 6 * 4));
    }

    #[test]
    #[should_panic(expected = "not aligned")]
    fn level_base_must_tile() {
        LevelCoords::new(0, U256::from(1), 2, 3);
    }
}
