//! Module for building merkle trees from leafs.

use std::sync::Arc;

use crate::{Digest, MerkleTree};

use ruint::{aliases::U256, UintTryFrom};

#[derive(Clone, Debug)]
struct Node {
    tree: Arc<MerkleTree>,
    accumulated_count: U256,
}

/// A [MerkleBuilder] is used to build a [MerkleTree] from its leafs.
#[derive(Debug, Default)]
pub struct MerkleBuilder {
    trees: Vec<Node>,
    // nodes: HashMap<Digest, MerkleTreeNode>,
    // iterateds: HashMap<Digest, Vec<Digest>>,
}

impl MerkleBuilder {
    /// Adds a new leaf to the merkle tree. The leaf is represented by its digest.
    pub fn add_leaf(&mut self, leaf: Digest) {
        self.add_leaf_with_repetition(leaf, U256::from(1));
    }

    /// Adds a new leaf to the merkle tree. The leaf is represented by its
    /// digest and its repetition.
    pub fn add_leaf_with_repetition<T>(&mut self, leaf: Digest, rep: T)
    where
        U256: UintTryFrom<T>,
    {
        self.add_tree_with_repetition(&MerkleTree::leaf(leaf), rep);
    }

    /// Adds a new leaf to the merkle tree. The leaf is represented by a MerkleTree
    pub fn add_tree(&mut self, tree: &Arc<MerkleTree>) {
        self.add_tree_with_repetition(tree, U256::from(1));
    }

    /// Adds a new leaf to the merkle tree. The leaf is represented by a MerkleTree and its repetition.
    pub fn add_tree_with_repetition<T>(&mut self, tree: &Arc<MerkleTree>, rep: T)
    where
        U256: UintTryFrom<T>,
    {
        let rep = U256::from(rep);
        assert!(!rep.is_zero(), "repetition is zero");

        let accumulated_count = self.calculate_accumulated_count(rep);
        if let Some(last) = self.trees.last() {
            assert_eq!(
                last.tree.log2_size(),
                tree.log2_size(),
                "mismatched tree size"
            );
        }

        self.trees.push(Node {
            tree: Arc::clone(tree),
            accumulated_count,
        });
    }

    /// Builds the merkle tree from the leafs.
    pub fn build(&self) -> Arc<MerkleTree> {
        let last = self.trees.last().expect("no trees in merkle builder");
        let count = last.accumulated_count;

        assert!(count.is_power_of_two(), "is not a power of two {}", count);
        let log2_size = count.trailing_zeros();

        self.build_merkle(self.trees.as_slice(), log2_size, U256::ZERO)
    }
}

impl MerkleBuilder {
    fn calculate_accumulated_count(&mut self, rep: U256) -> U256 {
        if let Some(last) = self.trees.last() {
            assert!(!last.accumulated_count.is_zero(), "merkle builder is full");
            let accumulated_count = rep.wrapping_add(last.accumulated_count);
            if rep >= accumulated_count {
                assert_eq!(accumulated_count, U256::ZERO);
            }
            accumulated_count
        } else {
            rep
        }
    }

    fn build_merkle(&self, trees: &[Node], log2_size: usize, stride: U256) -> Arc<MerkleTree> {
        let one = U256::from(1);
        let size = one.wrapping_shl(log2_size);

        let first_time = stride * size + one;
        let last_time = (stride + one) * size;

        let first_cell = find_cell_containing(trees, first_time);
        let last_cell = find_cell_containing(trees, last_time);

        if first_cell == last_cell {
            let tree = &trees[first_cell].tree;
            let iterated = tree.iterated(log2_size);
            return iterated;
        }

        let left = self.build_merkle(
            &trees[first_cell..(last_cell + 1) as usize],
            log2_size - 1,
            stride << 1,
        );
        let right = self.build_merkle(
            &trees[first_cell..(last_cell + 1) as usize],
            log2_size - 1,
            (stride << 1) + one,
        );

        left.join(&right)
    }
}

// Binary search to find the cell containing the element.
fn find_cell_containing(trees: &[Node], elem: U256) -> usize {
    let one = U256::from(1);
    let mut left = 0;
    let mut right = trees.len() - 1;

    while left < right {
        let needle = left + (right - left) / 2;
        if trees[needle].accumulated_count.checked_sub(one) < elem.checked_sub(one) {
            left = needle + 1;
        } else {
            right = needle;
        }
    }

    left
}

#[cfg(test)]
mod tests {
    use super::MerkleBuilder;
    use crate::{Digest, MerkleTree};

    #[test]
    fn test_merkle_builder_8() {
        let mut builder = MerkleBuilder::default();
        builder.add_leaf_with_repetition(Digest::zeroed(), 2);
        builder.add_leaf_with_repetition(Digest::zeroed(), 6);
        let merkle = builder.build();
        assert_eq!(
            merkle.root_hash(),
            MerkleTree::zeroed().iterated(3).root_hash()
        );
    }

    #[test]
    fn test_merkle_builder_64() {
        let mut builder = MerkleBuilder::default();
        builder.add_leaf_with_repetition(Digest::zeroed(), 2);
        builder.add_leaf_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let merkle = builder.build();
        assert_eq!(
            merkle.root_hash(),
            MerkleTree::zeroed().iterated(64).root_hash()
        );
    }
}
