//! This module contains the [MerkleTree] struct and related types like the
//! [MerkleProof].

use std::collections::HashMap;

use crate::merkle::{Digest, MerkleTreeNode};

use super::UInt;

/// A leaf of a [MerkleTree], it contains the offset of the leaf in the tree,
/// and the hash of the data.
#[derive(Clone, Debug)]
pub struct MerkleTreeLeaf {
    pub node: Digest,
    pub accumulated_count: UInt,
    pub log2_size: Option<u32>,
}

/// A [MerkleProof] is used to verify that a leaf is part of a [MerkleTree].
pub type MerkleProof = Vec<Digest>;

struct ProofAccumulator {
    pub leaf: Digest,
    pub proof: MerkleProof,
}

impl Default for ProofAccumulator {
    fn default() -> Self {
        ProofAccumulator {
            leaf: Digest::zeroed(),
            proof: Vec::new(),
        }
    }
}

/// A [MerkleTree] is a binary tree where the leafs are the data and the nodes
/// are the hashes of the children. The root of the tree is the hash of the
/// entire tree. The tree is balanced, so the height of the tree is log2(n)
/// where n is the number of leafs.
#[derive(Clone, Debug)]
pub struct MerkleTree {
    log2_size: u32,
    root: Digest,
    leafs: Vec<MerkleTreeLeaf>,
    nodes: HashMap<Digest, MerkleTreeNode>,
}

impl MerkleTree {
    pub fn new(
        log2_size: u32,
        root: Digest,
        leafs: Vec<MerkleTreeLeaf>,
        nodes: HashMap<Digest, MerkleTreeNode>,
    ) -> Self {
        MerkleTree {
            log2_size,
            root,
            leafs,
            nodes,
        }
    }

    pub fn root_hash(&self) -> Digest {
        self.root
    }

    pub fn root_children(&self) -> (Digest, Digest) {
        self.node_children(self.root)
            .expect("root does not have children")
    }

    pub fn node_children(&self, digest: Digest) -> Option<(Digest, Digest)> {
        match self.nodes.get(&digest) {
            Some(node) => node.children(),
            None => None,
        }
    }

    pub fn nodes(&self) -> HashMap<Digest, MerkleTreeNode> {
        self.nodes.clone()
    }

    pub fn log2_size(&self) -> u32 {
        self.log2_size.clone()
    }

    pub fn prove_leaf(&self, index: u64) -> (Digest, MerkleProof) {
        let height = self.calculate_height();

        assert!(index.wrapping_shr(height) == 0);

        let mut proof_acc = ProofAccumulator::default();

        self.proof(
            &mut proof_acc,
            self.nodes.get(&self.root).expect("root does not exist"),
            height as u64,
            index,
        );

        (proof_acc.leaf, proof_acc.proof)
    }

    fn calculate_height(&self) -> u32 {
        let mut height = self.log2_size;

        if let Some(leaf) = self.leafs.get(0) {
            if let Some(log2_size) = leaf.log2_size {
                height = log2_size + self.log2_size;
            }
        }

        height
    }

    fn proof(
        &self,
        proof_acc: &mut ProofAccumulator,
        root: &MerkleTreeNode,
        height: u64,
        include_index: u64,
    ) {
        if height == 0 {
            proof_acc.leaf = root.digest;
            return;
        }

        let new_height = height - 1;
        let (left, right) = root.children().expect("root does not have children");
        let left = self.nodes.get(&left).expect("left child does not exist");
        let right = self.nodes.get(&right).expect("right child does not exist");

        if (include_index.wrapping_shr(new_height as u32)) & 1 == 0 {
            self.proof(proof_acc, left, new_height, include_index);
            proof_acc.proof.push(right.digest);
        } else {
            self.proof(proof_acc, right, new_height, include_index);
            proof_acc.proof.push(left.digest);
        }
    }

    pub fn last(&self) -> (Digest, MerkleProof) {
        let mut proof = Vec::new();
        let mut children = Some(self.root_children());
        let mut old_right = self.root;

        while let Some((left, right)) = children {
            proof.push(left);
            old_right = right;
            children = self.node_children(right);
        }

        proof.reverse();

        (old_right, proof)
    }
}

#[cfg(test)]
mod tests {
    use crate::merkle::Digest;

    #[test]
    pub fn test_tree() {
        let mut builder = crate::merkle::MerkleBuilder::default();
        builder.add_with_repetition(Digest::zeroed(), 2);
        builder.add_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_leaf(0);
        assert_eq!(proof.0, Digest::zeroed());
    }

    #[test]
    pub fn proof_test() {
        let mut builder = crate::merkle::MerkleBuilder::default();
        builder.add_with_repetition(Digest::zeroed(), 8);
        let tree = builder.build();

        let (leaf, proof) = tree.prove_leaf(0);

        let mut root = leaf;

        for node in proof {
            root = Digest::join(&node, &root);
        }

        assert_eq!(root, tree.root_hash());
    }

    #[test]
    pub fn last_proof_test() {
        let mut builder = crate::merkle::MerkleBuilder::default();
        builder.add_with_repetition(Digest::zeroed(), 2);
        builder.add_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let tree = builder.build();

        let (leaf, proof) = tree.last();

        let mut root = leaf;

        for node in proof {
            root = Digest::join(&node, &root);
        }

        assert_eq!(root, tree.root_hash());
    }
}
