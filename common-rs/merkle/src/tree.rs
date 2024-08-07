//! This module contains the [MerkleTree] struct and related types like the
//! [MerkleProof].

use ruint::{aliases::U256, UintTryFrom};
use std::sync::Arc;

use crate::Digest;

/// A leaf of a [MerkleTree], it contains the offset of the leaf in the tree,
/// and the hash of the data.
#[derive(Clone, Debug)]
pub struct MerkleTreeLeaf {
    pub node: Digest,
    pub accumulated_count: U256,
    pub log2_size: Option<u32>,
}

/// A [MerkleProof] is used to verify that a leaf is part of a [MerkleTree].
pub struct MerkleProof {
    pub node: Digest,
    pub siblings: Vec<Digest>,
}

impl MerkleProof {
    pub(crate) fn push_hash(&mut self, h: Digest) {
        self.siblings.push(h);
    }
}

impl MerkleProof {
    pub fn leaf(node: Digest) -> Self {
        Self {
            node,
            siblings: Vec::new(),
        }
    }
}

/// A [MerkleTree] is a binary tree where the leafs are the data and the nodes
/// are the hashes of the children. The root of the tree is the hash of the
/// entire tree. The tree is balanced, so the height of the tree is log2(n)
/// where n is the number of leafs.
#[derive(Clone, Debug)]
pub struct MerkleTree {
    pub log2_size: u32,
    root: Digest,
    subtrees: Option<InnerNode>,
}

impl PartialEq for MerkleTree {
    fn eq(&self, other: &Self) -> bool {
        self.root == other.root
    }
}

#[derive(Clone, Debug)]
pub enum InnerNode {
    Pair {
        left: Arc<MerkleTree>,
        right: Arc<MerkleTree>,
    },

    Iterated {
        child: Arc<MerkleTree>,
    },
}

impl InnerNode {
    pub fn children(&self) -> (Arc<MerkleTree>, Arc<MerkleTree>) {
        match &self {
            InnerNode::Pair { left, right } => (Arc::clone(left), Arc::clone(right)),
            InnerNode::Iterated { child } => (Arc::clone(child), Arc::clone(child)),
        }
    }
}

// pub struct MerkleTree {
//     log2_size: u32,
//     leaf_log2_size: Option<u32>,
//     root: Digest,
//     nodes: HashMap<Digest, MerkleTreeNode>,
// }

impl MerkleTree {
    pub fn leaf(root: Digest) -> Self {
        Self {
            log2_size: 0,
            root,
            subtrees: None,
        }
    }

    pub fn root_hash(&self) -> Digest {
        self.root
    }

    pub fn subtrees(&self) -> Option<InnerNode> {
        self.subtrees.clone()
    }

    pub fn find_child(self: &Arc<Self>, digest: &Digest) -> Option<Arc<Self>> {
        if self.root == *digest {
            Some(Arc::clone(self))
        } else {
            match &self.subtrees {
                None => None,
                Some(InnerNode::Pair { left, right }) => {
                    let r = left.find_child(digest);
                    if r.is_some() {
                        r
                    } else {
                        right.find_child(digest)
                    }
                }
                Some(InnerNode::Iterated { child }) => child.find_child(digest),
            }
        }
    }

    pub fn log2_size(&self) -> u32 {
        self.log2_size
    }

    //     pub fn prove_leaf(&self, index: U256) -> (Digest, MerkleProof) {
    //         let height = self.log2_size;

    //         assert!(index.wrapping_shr(height) == 0);

    //         let mut proof_acc = ProofAccumulator::default();

    //         self.proof(&mut proof_acc, height as u64, index);

    //         (proof_acc.leaf, proof_acc.proof)
    //     }

    //     fn calculate_height(&self) -> u32 {
    //         match self.leaf_log2_size {
    //             Some(leaf_log2_size) => self.log2_size + leaf_log2_size,
    //             None => self.log2_size,
    //         }
    // }

    pub fn prove_leaf<T>(&self, index: T) -> MerkleProof
    where
        U256: UintTryFrom<T>,
    {
        self.prove_leaf_rec(U256::from(index))
        // let new_height = height - 1;
        // let (left, right) = root.children().expect("root does not have children");
        // let left = self.nodes.get(&left).expect("left child does not exist");
        // let right = self.nodes.get(&right).expect("right child does not exist");

        // if (include_index.wrapping_shr(new_height as u32)) & 1 == 0 {
        //     self.proof(proof_acc, left, new_height, include_index);
        //     proof_acc.proof.push(right.digest);
        // } else {
        //     self.proof(proof_acc, right, new_height, include_index);
        //     proof_acc.proof.push(left.digest);
        // }
    }

    pub fn prove_last(&self) -> MerkleProof {
        let one = U256::from(1);
        self.prove_leaf((one << self.log2_size()) - one)

        // let mut proof = Vec::new();
        // let mut children = Some(self.root_children());
        // let mut old_right = self.root;

        // while let Some((left, right)) = children {
        //     proof.push(left);
        //     old_right = right;
        //     children = self.node_children(right);
        // }

        // proof.reverse();

        // (old_right, proof)
    }
}

impl MerkleTree {
    fn prove_leaf_rec(&self, index: U256) -> MerkleProof {
        let one = U256::from(1);

        assert!((one << self.log2_size) > index, "index out of bounds");

        let Some(subtree) = &self.subtrees else {
            assert_eq!(index, U256::ZERO);
            assert_eq!(self.log2_size, 1);
            return MerkleProof::leaf(self.root);
        };

        let (left, right) = subtree.children();
        let inner_index = index.wrapping_shr(1);
        let leaf_at_left = (inner_index & one).is_zero();

        if leaf_at_left {
            let mut proof = left.prove_leaf_rec(inner_index);
            proof.push_hash(right.root);
            proof
        } else {
            let mut proof = right.prove_leaf_rec(inner_index);
            proof.push_hash(left.root);
            proof
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::Digest;

    #[test]
    pub fn test_tree() {
        let mut builder = crate::MerkleBuilder::default();
        builder.add_with_repetition(Digest::zeroed(), 2);
        builder.add_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_leaf(0);
        assert_eq!(proof.node, Digest::zeroed());
    }

    #[test]
    pub fn proof_test() {
        let mut builder = crate::MerkleBuilder::default();
        builder.add_with_repetition(Digest::zeroed(), 8);
        let tree = builder.build();

        let proof = tree.prove_leaf(0);

        let mut root = proof.node;

        for node in proof.siblings {
            root = Digest::join(&node, &root);
        }

        assert_eq!(root, tree.root_hash());
    }

    #[test]
    pub fn last_proof_test() {
        let mut builder = crate::MerkleBuilder::default();
        builder.add_with_repetition(Digest::zeroed(), 2);
        builder.add_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_last();

        let mut root = proof.node;

        for node in proof.siblings {
            root = Digest::join(&node, &root);
        }

        assert_eq!(root, tree.root_hash());
    }
}
