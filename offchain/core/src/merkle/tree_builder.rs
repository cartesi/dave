//! Module for building merkle trees from leafs.

use std::collections::HashMap;

use crate::merkle::{Digest, MerkleTree, MerkleTreeLeaf, MerkleTreeNode};

pub type Int = u128;

/// A [MerkleBuilder] is used to build a [MerkleTree] from its leafs.
#[derive(Debug, Default)]
pub struct MerkleBuilder {
    leafs: Vec<MerkleTreeLeaf>,
    nodes: HashMap<Digest, MerkleTreeNode>,
    interned: HashMap<Digest, Vec<Digest>>,
}

impl MerkleBuilder {
    /// Adds a new leaf to the merkle tree. The leaf is represented by its 
    /// digest and its repetition.
    pub fn add(&mut self, digest: Digest, rep: Int) {
        assert!(rep != 0, "repetition is zero");
            
        self.add_new_node(digest);

        let count = self.calculate_accumulated_count(rep);

        self.leafs.push(MerkleTreeLeaf {
            node: digest,
            accumulated_count: count,
            log2_size: None,
        });
    }

    fn calculate_accumulated_count(&mut self, rep: u128) -> u128 {
        if let Some(last) = self.leafs.last() {
            assert!(last.accumulated_count != 0, "merkle builder is full");
            let accumulated_count = rep.wrapping_add(last.accumulated_count);    
            if rep >= accumulated_count {
                assert_eq!(accumulated_count, 0);
            }
            accumulated_count
        } else {
            rep
        }
    }

    fn add_new_node(&mut self, digest: Digest) {
        if !self.nodes.contains_key(&digest) {
            let node = MerkleTreeNode::new(digest);
            self.nodes.insert(node.digest, node.clone());
            self.interned.insert(node.digest, vec![node.digest]);
        }
    }

    /// Builds the merkle tree from the leafs.
    pub fn build(&mut self) -> MerkleTree {
        let last = self.leafs.last().expect("no leafs in merkle builder");
        let count = last.accumulated_count;
        let mut log2_size = Int::BITS as u32;

        if count != 0 {
            assert!(count.is_power_of_two(), "is not a power of two {}", count);
            log2_size = count.trailing_zeros();
        };


        let root = self.build_merkle(0, self.leafs.len() as Int, log2_size, 0);

        MerkleTree::new(log2_size, root.0, self.leafs.clone(), self.nodes.clone())
    }

    fn build_merkle(
        &mut self,
        first_leaf: Int,
        last_leaf: Int,
        log2_size: u32,
        stride: Int,
    ) -> (Digest, Int, Int) {
        let leafs = &self.leafs.as_slice()[first_leaf as usize..last_leaf as usize];

        let first_time = stride * (Int::from(1u8).wrapping_shl(log2_size)) + 1;
        let last_time = (stride + 1) * (Int::from(1u8).wrapping_shl(log2_size));

        let first_cell = find_cell_containing(leafs, first_time);
        let last_cell = find_cell_containing(leafs, last_time);

        if first_cell == last_cell {
            let node = self.leafs[first_cell as usize].node;
            let iterated = self.iterated_merkle(node, log2_size);
            return (iterated, first_time, last_time);
        }

        let left = self.build_merkle(first_cell, last_cell + 1, log2_size - 1, stride << 1);
        let right = self.build_merkle(first_cell, last_cell + 1, log2_size - 1, (stride << 1) + 1);

        let result = self.join_nodes(left.0, right.0);
        (result, first_time, last_time)
    }

    /// Builds the iterated merkle tree from the given node and level.
    pub fn iterated_merkle(&mut self, node: Digest, level: u32) -> Digest {
        let iterated = self.interned.get(&node).unwrap();
        if let Some(node) = iterated.get(level as usize) {
            return *node;
        }
        self.build_iterated_merkle(node, level)
    }

    fn build_iterated_merkle(&mut self, node: Digest, level: u32) -> Digest {
        let iterated = self.interned.get(&node).unwrap();
        let mut i = iterated.len() - 1;
        let mut highest_level = *iterated.get(i).unwrap();

        while i < level as usize {
            highest_level = self.join_nodes(highest_level, highest_level);
            i += 1;
            self.interned.get_mut(&node).unwrap().push(highest_level);
        }
        
        highest_level
    }

    fn join_nodes(&mut self, left: Digest, right: Digest) -> Digest {
        let digest = left.join(right);

        if let Some(node) = self.nodes.get_mut(&digest) {
            node.set_children(left, right);
        } else {
            let mut node = MerkleTreeNode::new(digest);
            node.set_children(left, right);
            self.nodes.insert(node.digest, node.clone());
            self.interned.insert(node.digest, vec![node.digest]);
        };

        digest
    }
}

// Binary search to find the cell containing the element.
fn find_cell_containing(leafs: &[MerkleTreeLeaf], elem: Int) -> Int {
    let mut left = 0;
    let mut right = leafs.len() as Int - 1;

    while left < right {
        let needle = left + (right - left) / 2;
        if leafs[needle as usize].accumulated_count.wrapping_sub(1) < elem.wrapping_sub(1) {
            left = needle + 1;
        } else {
            right = needle;
        }
    }

    left
}

#[cfg(test)]
mod tests {
    use crate::merkle::Digest;
    use super::MerkleBuilder;

    #[test]
    fn test_merkle_builder_8() {
        let mut builder = MerkleBuilder::default();
        builder.add(Digest::zeroed(), 2); 
        builder.add(Digest::zeroed(), 6);
        let merkle = builder.build();
        assert_eq!(merkle.root_hash(), builder.iterated_merkle(Digest::zeroed(), 3));
    }

    #[test]
    fn test_merkle_builder_64() {
        let mut builder = MerkleBuilder::default();
        builder.add(Digest::zeroed(), 2); 
        builder.add(Digest::zeroed(), 2u128.pow(64) - 2);
        let merkle = builder.build();
        assert_eq!(merkle.root_hash(), builder.iterated_merkle(Digest::zeroed(), 64));
    }

    #[test]
    fn test_merkle_builder_128() {
        let mut builder = MerkleBuilder::default();
        builder.add(Digest::zeroed(), 2); 
        builder.add(Digest::zeroed(),0u128.wrapping_sub(2));
        let merkle = builder.build();
        assert_eq!(merkle.root_hash(), builder.iterated_merkle(Digest::zeroed(), 128));
    }
}
