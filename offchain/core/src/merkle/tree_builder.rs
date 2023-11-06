use std::collections::HashMap;

use sha3::{Digest, Keccak256};

use crate::merkle::{Hash, MerkleTree, MerkleTreeLeaf, MerkleTreeNode};

pub type Int = u128;

#[derive(Debug)]
pub struct MerkleBuilder {
    leafs: Vec<MerkleTreeLeaf>,
    nodes: HashMap<Hash, MerkleTreeNode>,
    iterateds: HashMap<Hash, Vec<Hash>>,
}

impl MerkleBuilder {
    pub fn new() -> Self {
        MerkleBuilder {
            leafs: Vec::new(),
            iterateds: HashMap::new(),
            nodes: HashMap::new(),
        }
    }

    pub fn add(&mut self, digest: Hash, rep: Int) {
        self.add_new_node(digest);

        let accumulated_count = if let Some(last) = self.leafs.last() {
            assert!(last.accumulated_count != 0, "merkle builder is full");
            let accumulated_count = rep.wrapping_add(last.accumulated_count);
            if rep >= accumulated_count {
                assert_eq!(accumulated_count, 0);
            }
            accumulated_count
        } else {
            rep
        };

        self.leafs.push(MerkleTreeLeaf {
            node: digest,
            accumulated_count,
            log2_size: None,
        });
    }

    fn add_new_node(&mut self, digest: Hash) {
        if !self.nodes.contains_key(&digest) {
            let node = MerkleTreeNode::new(digest);
            self.nodes.insert(node.digest, node.clone());
            self.iterateds.insert(node.digest, vec![node.digest]);
        }
    }

    pub fn build(&mut self) -> MerkleTree {
        let last = self.leafs.last().expect("no leafs in merkle builder");
        let count = last.accumulated_count;
        let mut log2_size = Int::BITS as u32;

        if count != 0 {
            assert!(count.is_power_of_two(), "is not a power of two {}", count);
            log2_size = count.leading_zeros();
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
    ) -> (Hash, Int, Int) {
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

    pub fn iterated_merkle(&mut self, node: Hash, level: u32) -> Hash {
        let iterated = self.iterateds.get(&node).unwrap();
        if let Some(node) = iterated.get(level as usize) {
            return *node;
        }
        self.build_iterated_merkle(node, level)
    }

    fn build_iterated_merkle(&mut self, node: Hash, level: u32) -> Hash {
        let iterated = self.iterateds.get(&node).unwrap();
        let mut i = iterated.len() - 1;
        let mut highest_level = *iterated.get(i).unwrap();
        while i < level as usize {
            highest_level = self.join_nodes(highest_level, highest_level);
            i += 1;
            self.iterateds.get_mut(&node).unwrap().push(highest_level);
        }
        highest_level
    }

    fn join_nodes(&mut self, left: Hash, right: Hash) -> Hash {
        let digest = join_merkle_tree_node_digests(left, right);

        let node = if let Some(node) = self.nodes.get_mut(&digest) {
            node
        } else {
            let node = MerkleTreeNode::new(digest);
            self.nodes.insert(node.digest, node.clone());
            self.iterateds.insert(node.digest, vec![node.digest]);
            self.nodes.get_mut(&digest).unwrap()
        };
        node.set_children(left, right);

        digest
    }
}

pub fn join_merkle_tree_node_digests(digest_1: Hash, digest_2: Hash) -> Hash {
    let mut keccak = Keccak256::new();

    let digest_1: [u8; 32] = digest_1.into();
    keccak.update(digest_1);

    let digest_2: [u8; 32] = digest_2.into();
    keccak.update(digest_2);

    let digest: [u8; 32] = keccak.finalize().into();
    Hash::from(digest)
}

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
    use crate::merkle::Hash;

    use super::MerkleBuilder;

    #[test]
    fn test_merkle_builder() {
        let mut builder = MerkleBuilder::new();
        builder.add(Hash::default(), 0);
        let merkle = builder.build();
        println!("{}", merkle.root_hash());
        println!("{}", builder.iterated_merkle(Hash::default(), 128));
    }
}
