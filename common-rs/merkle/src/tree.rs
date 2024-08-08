//! This module contains the [MerkleTree] struct and related types like the
//! [MerkleProof].

use crate::Digest;

use ruint::{aliases::U256, UintTryFrom};
use std::sync::Arc;

/// A [MerkleProof] is used to verify that a leaf is part of a [MerkleTree].
pub struct MerkleProof {
    pub node: Digest,
    pub siblings: Vec<Digest>,
}

impl MerkleProof {
    pub fn leaf(node: Digest) -> Self {
        Self {
            node,
            siblings: Vec::new(),
        }
    }

    pub(crate) fn push_hash(&mut self, h: Digest) {
        self.siblings.push(h);
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

impl MerkleTree {
    pub fn leaf(root: Digest) -> Arc<Self> {
        Arc::new(Self {
            log2_size: 0,
            root,
            subtrees: None,
        })
    }

    pub fn zeroed() -> Arc<Self> {
        Self::leaf(Digest::zeroed())
    }

    pub fn root_hash(&self) -> Digest {
        self.root
    }

    pub fn subtrees(&self) -> Option<InnerNode> {
        self.subtrees.clone()
    }

    pub fn log2_size(&self) -> u32 {
        self.log2_size
    }

    pub fn find_child(self: &Arc<Self>, digest: &Digest) -> Option<Arc<Self>> {
        if self.root == *digest {
            return Some(Arc::clone(self));
        }

        match &self.subtrees {
            None => None,

            Some(InnerNode::Pair { left, right }) => {
                left.find_child(digest).or_else(|| right.find_child(digest))
            }

            Some(InnerNode::Iterated { child }) => child.find_child(digest),
        }
    }

    pub fn join(self: &Arc<Self>, other: &Arc<Self>) -> Arc<Self> {
        assert_eq!(self.log2_size, other.log2_size, "tree size mismatch");
        let root = self.root.join(&other.root);

        let subtrees = Some(InnerNode::Pair {
            left: Arc::clone(self),
            right: Arc::clone(other),
        });

        Arc::new(Self {
            log2_size: self.log2_size + 1,
            root,
            subtrees,
        })
    }

    pub fn iterated(self: &Arc<Self>, rep: usize) -> Arc<Self> {
        let rep = rep.into();
        let mut root = Arc::clone(self);

        for _ in 0..rep {
            let log2_size = root.log2_size + 1;
            let h = root.root.join(&root.root);
            let subtrees = Some(InnerNode::Iterated { child: root });
            root = Arc::new(Self {
                log2_size,
                root: h,
                subtrees,
            });
        }

        root
    }

    pub fn prove_leaf<T>(&self, index: T) -> MerkleProof
    where
        U256: UintTryFrom<T>,
    {
        self.prove_leaf_rec(U256::from(index))
    }

    pub fn prove_last(&self) -> MerkleProof {
        let one = U256::from(1);
        self.prove_leaf((one << self.log2_size()) - one)
    }
}

impl MerkleTree {
    fn prove_leaf_rec(&self, index: U256) -> MerkleProof {
        let one = U256::from(1);

        assert!((one << self.log2_size) > index, "index out of bounds");

        let Some(subtree) = &self.subtrees else {
            assert_eq!(index, U256::ZERO);
            assert_eq!(self.log2_size, 0);
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
        builder.add_leaf_with_repetition(Digest::zeroed(), 2);
        builder.add_leaf_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_leaf(0);
        assert_eq!(proof.node, Digest::zeroed());
    }

    #[test]
    pub fn proof_test() {
        let mut builder = crate::MerkleBuilder::default();
        builder.add_leaf_with_repetition(Digest::zeroed(), 8);
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
        builder.add_leaf_with_repetition(Digest::zeroed(), 2);
        builder.add_leaf_with_repetition(Digest::zeroed(), 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_last();

        let mut root = proof.node;

        for node in proof.siblings {
            root = Digest::join(&node, &root);
        }

        assert_eq!(root, tree.root_hash());
    }
}
