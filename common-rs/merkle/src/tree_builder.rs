//! Module for building merkle trees from leafs.

use crate::MerkleTree;

use ruint::{UintTryFrom, aliases::U256};
use std::sync::Arc;

#[derive(Clone, Debug)]
struct Node {
    tree: Arc<MerkleTree>,
    accumulated_count: U256,
}

/// A [MerkleBuilder] is used to build a [MerkleTree] from its leafs.
#[derive(Debug, Default)]
pub struct MerkleBuilder {
    trees: Vec<Node>,
}

impl MerkleBuilder {
    /// Returns the height of the leaf trees, or none if there are no leafs added.
    pub fn height(&self) -> Option<u32> {
        self.trees.last().map(|last| last.tree.height())
    }

    /// Returns the number of leafs (with repetition) in the builder, or none if there are no
    /// leafs. Zero means 2^256 leafs.
    pub fn count(&self) -> Option<U256> {
        self.trees.last().map(|last| last.accumulated_count)
    }

    /// Returns whether the builder has a balanced (i.e. power of two) number of leaves.
    pub fn can_build(&self) -> bool {
        match self.count() {
            Some(count) => is_count_pow2(count),
            None => false,
        }
    }

    /// Adds a new leaf to the merkle tree.
    pub fn append<L>(&mut self, leaf: L)
    where
        L: Into<Arc<MerkleTree>>,
    {
        self.append_repeated(leaf, 1);
    }

    /// Adds a new leaf to the merkle tree, repeating this leaf `rep` times.
    pub fn append_repeated<L, I>(&mut self, leaf: L, rep: I)
    where
        L: Into<Arc<MerkleTree>>,
        U256: UintTryFrom<I>,
    {
        let leaf = leaf.into();
        let rep = U256::from(rep);
        assert!(!rep.is_zero(), "repetition is zero");

        let accumulated_count = self.calculate_accumulated_count(rep);
        if let Some(height) = self.height() {
            assert_eq!(height, leaf.height(), "mismatched tree size");
        }

        self.trees.push(Node {
            tree: leaf,
            accumulated_count,
        });
    }

    /// Builds the merkle tree from the leafs.
    pub fn build(&self) -> Arc<MerkleTree> {
        let count = self.count().expect("no leafs in merkle builder");
        assert!(
            is_count_pow2(count),
            "builder has `{}` leafs, which is not a power of two",
            count
        );

        let log2_size = count.trailing_zeros();
        MerkleBuilder::build_merkle(self.trees.as_slice(), log2_size, U256::ZERO)
    }
}

impl MerkleBuilder {
    fn calculate_accumulated_count(&mut self, rep: U256) -> U256 {
        if let Some(last) = self.trees.last() {
            assert!(!last.accumulated_count.is_zero(), "merkle builder is full");
            let accumulated_count = rep.wrapping_add(last.accumulated_count);
            if rep >= accumulated_count {
                assert_eq!(accumulated_count, U256::ZERO, "merkle tree overflow");
            }
            accumulated_count
        } else {
            rep
        }
    }

    fn build_merkle(trees: &[Node], log2_size: usize, stride: U256) -> Arc<MerkleTree> {
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

        let left = MerkleBuilder::build_merkle(
            &trees[first_cell..(last_cell + 1)],
            log2_size - 1,
            stride << 1,
        );
        let right = MerkleBuilder::build_merkle(
            &trees[first_cell..(last_cell + 1)],
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
        if trees[needle].accumulated_count.wrapping_sub(one) < elem.wrapping_sub(one) {
            left = needle + 1;
        } else {
            right = needle;
        }
    }

    left
}

fn is_count_pow2(count: U256) -> bool {
    count.is_zero() || count.is_power_of_two()
}

#[cfg(test)]
mod tests {
    use super::MerkleBuilder;
    use crate::{Digest, MerkleTree};
    use ruint::aliases::U256;

    fn one_digest() -> Digest {
        Digest::from_digest_hex(
            "0x0000000000000000000000000000000000000000000000000000000000000001",
        )
        .unwrap()
    }

    #[test]
    fn test_is_pow2() {
        assert!(crate::tree_builder::is_count_pow2(U256::from(0)));
        assert!(crate::tree_builder::is_count_pow2(U256::from(1)));
        assert!(crate::tree_builder::is_count_pow2(U256::from(2)));
        assert!(!crate::tree_builder::is_count_pow2(U256::from(3)));
        assert!(crate::tree_builder::is_count_pow2(U256::from(4)));
        assert!(!crate::tree_builder::is_count_pow2(U256::from(5)));
    }

    #[test]
    #[should_panic(expected = "repetition is zero")]
    fn test_repeat_zero() {
        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, 0);
    }

    #[test]
    fn test_simple_0() {
        let one_digest = one_digest();
        let mut builder = MerkleBuilder::default();
        builder.append(one_digest);
        let tree_root = builder.build().root_hash();
        let expected = one_digest;
        assert_eq!(tree_root, expected);
    }

    #[test]
    fn test_simple_1() {
        let one_digest = one_digest();

        let mut builder = MerkleBuilder::default();
        builder.append(Digest::ZERO);
        builder.append(one_digest);
        let tree_root = builder.build().root_hash();

        let expected = Digest::ZERO.join(&one_digest);

        assert_eq!(tree_root, expected);
    }

    #[test]
    fn test_simple_2() {
        let one_digest = one_digest();

        let mut builder = MerkleBuilder::default();
        builder.append_repeated(one_digest, 2);
        builder.append_repeated(Digest::ZERO, 2);
        let tree_root = builder.build().root_hash();

        let expected = one_digest
            .join(&one_digest)
            .join(&Digest::ZERO.join(&Digest::ZERO));

        assert_eq!(tree_root, expected);
    }

    #[test]
    fn test_simple_3() {
        let one_digest = one_digest();

        let mut builder = MerkleBuilder::default();
        builder.append(Digest::ZERO);
        builder.append_repeated(one_digest, 2);
        builder.append(Digest::ZERO);
        let tree_root = builder.build().root_hash();

        let expected = Digest::ZERO
            .join(&one_digest)
            .join(&one_digest.join(&Digest::ZERO));

        assert_eq!(tree_root, expected);
    }

    #[test]
    fn test_merkle_builder_8() {
        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, 2);
        builder.append_repeated(Digest::ZERO, 6);
        assert!(builder.can_build());
        let merkle = builder.build();
        assert_eq!(
            merkle.root_hash(),
            MerkleTree::zeroed().iterated(3).root_hash()
        );
    }

    #[test]
    fn test_merkle_builder_64() {
        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, 2);
        builder.append_repeated(Digest::ZERO, 2u128.pow(64) - 2);
        assert!(builder.can_build());
        let merkle = builder.build();
        assert_eq!(
            merkle.root_hash(),
            MerkleTree::zeroed().iterated(64).root_hash()
        );
    }

    #[test]
    fn test_merkle_builder_256() {
        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, U256::MAX);
        builder.append(Digest::ZERO);
        assert!(builder.can_build());
        let merkle = builder.build();
        assert_eq!(
            merkle.root_hash(),
            MerkleTree::zeroed().iterated(256).root_hash()
        );
    }

    #[test]
    fn test_append_and_repeated() {
        let mut builder = MerkleBuilder::default();
        builder.append(Digest::ZERO);
        assert!(builder.can_build());
        let tree_1 = builder.build();

        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, 1);
        assert!(builder.can_build());
        let tree_2 = builder.build();

        assert_eq!(tree_1, tree_2);
    }
    #[test]
    #[should_panic(expected = "no leafs in merkle builder")]
    fn test_build_empty() {
        MerkleBuilder::default().build();
    }

    #[test]
    #[should_panic(expected = "builder has `3` leafs, which is not a power of two")]
    fn test_build_not_pow2() {
        let mut builder = MerkleBuilder::default();
        builder.append(Digest::ZERO);
        builder.append(Digest::ZERO);
        builder.append(Digest::ZERO);
        assert!(!builder.can_build());
        builder.build();
    }

    #[test]
    #[should_panic(expected = "merkle builder is full")]
    fn test_build_full() {
        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, U256::MAX);
        builder.append(Digest::ZERO);
        builder.append(Digest::ZERO);
    }

    #[test]
    #[should_panic(expected = "merkle tree overflow")]
    fn test_build_overflow() {
        let mut builder = MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, U256::MAX);
        builder.append_repeated(Digest::ZERO, 2);
    }
}
