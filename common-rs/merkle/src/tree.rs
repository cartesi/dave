//! This module contains the [MerkleTree] struct and related types like the
//! [MerkleProof].

use crate::Digest;

use ruint::{UintTryFrom, aliases::U256};
use std::{ops::Rem, sync::Arc};

/// A [MerkleProof] is used to verify that a leaf is part of a [MerkleTree].
pub struct MerkleProof {
    pub position: U256,
    pub node: Digest,
    pub siblings: Vec<Digest>,
}

impl MerkleProof {
    pub fn leaf(node: Digest, position: U256) -> Self {
        Self {
            node,
            position,
            siblings: Vec::new(),
        }
    }

    pub fn empty() -> Self {
        Self {
            position: U256::ZERO,
            node: Digest::ZERO,
            siblings: Vec::new(),
        }
    }

    pub fn build_root(&self) -> Digest {
        let two = U256::from(2);

        let mut root = self.node;

        for (i, s) in self.siblings.iter().enumerate() {
            if (self.position >> i).rem(two) == U256::ZERO {
                root = root.join(s);
            } else {
                root = s.join(&root);
            }
        }

        root
    }

    pub fn verify_root(&self, root: Digest) -> bool {
        let other = self.build_root();
        root == other
    }

    fn push_hash(&mut self, h: Digest) {
        self.siblings.push(h);
    }
}

/// A [MerkleTree] is a binary tree where the leafs are the data and the nodes
/// are the hashes of the children. The root of the tree is the hash of the
/// entire tree. The tree is balanced, so the height of the tree is log2(n)
/// where n is the number of leafs.
#[derive(Clone, Debug)]
pub struct MerkleTree {
    root_hash: Digest,
    height: u32,

    subtrees: Option<InnerNode>,
}

impl PartialEq for MerkleTree {
    fn eq(&self, other: &Self) -> bool {
        self.height == other.height && self.root_hash == other.root_hash
    }
}

#[derive(Clone, Debug)]
enum InnerNode {
    Pair {
        left: Arc<MerkleTree>,
        right: Arc<MerkleTree>,
    },

    Iterated {
        child: Arc<MerkleTree>,
    },
}

impl InnerNode {
    fn children(&self) -> (Arc<MerkleTree>, Arc<MerkleTree>) {
        match &self {
            InnerNode::Pair { left, right } => (Arc::clone(left), Arc::clone(right)),
            InnerNode::Iterated { child } => (Arc::clone(child), Arc::clone(child)),
        }
    }
}

impl From<Digest> for Arc<MerkleTree> {
    fn from(value: Digest) -> Self {
        MerkleTree::leaf(value)
    }
}

impl MerkleTree {
    pub fn leaf(hash: Digest) -> Arc<Self> {
        Arc::new(Self {
            height: 0,
            root_hash: hash,
            subtrees: None,
        })
    }

    pub fn zeroed() -> Arc<Self> {
        Self::leaf(Digest::ZERO)
    }

    pub fn root_hash(&self) -> Digest {
        self.root_hash
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn subtrees(&self) -> Option<(Arc<MerkleTree>, Arc<MerkleTree>)> {
        match self.subtrees {
            None => None,
            Some(ref x) => Some(x.children()),
        }
    }

    pub fn find_child(self: &Arc<Self>, digest: &Digest) -> Option<Arc<Self>> {
        if self.root_hash == *digest {
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
        assert_eq!(self.height, other.height, "tree size mismatch");
        let root_hash = self.root_hash.join(&other.root_hash);

        let subtrees = Some(InnerNode::Pair {
            left: Arc::clone(self),
            right: Arc::clone(other),
        });

        Arc::new(Self {
            height: self.height + 1,
            root_hash,
            subtrees,
        })
    }

    pub fn iterated(self: &Arc<Self>, rep: usize) -> Arc<Self> {
        let rep = rep.into();
        let mut root = Arc::clone(self);

        for _ in 0..rep {
            let root_hash = root.root_hash.join(&root.root_hash);
            let height = root.height + 1;
            let subtrees = Some(InnerNode::Iterated { child: root });

            root = Arc::new(Self {
                root_hash,
                height,
                subtrees,
            });
        }

        root
    }

    pub fn prove_leaf<T>(&self, index: T) -> MerkleProof
    where
        U256: UintTryFrom<T>,
    {
        let index = U256::from(index);
        self.prove_leaf_rec(index)
    }

    pub fn prove_last(&self) -> MerkleProof {
        let one = U256::from(1);
        self.prove_leaf((one << self.height()) - one)
    }
}

impl MerkleTree {
    fn prove_leaf_rec(&self, index: U256) -> MerkleProof {
        let one = U256::from(1);
        assert!((one << self.height) > index, "index out of bounds");

        let Some(subtree) = &self.subtrees else {
            assert_eq!(index, U256::ZERO);
            assert_eq!(self.height, 0);
            return MerkleProof::leaf(self.root_hash, index.clone());
        };

        let shift = (self.height - 1) as usize;
        let leaf_at_left = (index.wrapping_shr(shift) & one).is_zero();
        let inner_index = index & (!(one << shift));

        let (left, right) = subtree.children();

        let mut proof = if leaf_at_left {
            let mut proof = left.prove_leaf_rec(inner_index);
            proof.push_hash(right.root_hash);
            proof
        } else {
            let mut proof = right.prove_leaf_rec(inner_index);
            proof.push_hash(left.root_hash);
            proof
        };

        proof.position = index;
        proof
    }
}

#[cfg(test)]
mod tests {
    use crate::{Digest, MerkleTree};

    fn one_digest() -> Digest {
        Digest::from_digest_hex(
            "0x0000000000000000000000000000000000000000000000000000000000000001",
        )
        .unwrap()
    }

    #[test]
    pub fn simple_tree() {
        let zero_tree = MerkleTree::leaf(Digest::ZERO);
        assert_eq!(zero_tree, MerkleTree::zeroed());
        assert_eq!(zero_tree.root_hash(), Digest::ZERO);
        assert_eq!(zero_tree.height(), 0);
        assert!(zero_tree.subtrees().is_none());

        let one_digest = one_digest();
        let one_tree = MerkleTree::leaf(one_digest);
        assert_eq!(one_tree.root_hash(), one_digest);
        assert_eq!(one_tree.height(), 0);
        assert!(one_tree.subtrees().is_none());
    }

    #[test]
    pub fn test_tree() {
        let mut builder = crate::MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, 2);
        builder.append_repeated(Digest::ZERO, 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_leaf(0);
        assert_eq!(proof.node, Digest::ZERO);
    }

    #[test]
    pub fn proof_test() {
        let mut builder = crate::MerkleBuilder::default();
        for _ in 0..8 {
            builder.append(one_digest());
            builder.append(Digest::ZERO);
        }
        let tree = builder.build();

        let proof = tree.prove_leaf(0);
        assert!(proof.verify_root(tree.root_hash()));
        let proof = tree.prove_leaf(1);
        assert!(proof.verify_root(tree.root_hash()));
        let proof = tree.prove_leaf(2);
        assert!(proof.verify_root(tree.root_hash()));
        let proof = tree.prove_leaf(3);
        assert!(proof.verify_root(tree.root_hash()));
    }

    #[test]
    pub fn proof_test_2() {
        let mut builder = crate::MerkleBuilder::default();
        let hashes = {
            let h = [
                "0x0000000000000000000000000000000000000000000000000000000000000000",
                "0x0000000000000000000000000000000000000000000000000000000000000001",
                "0x0000000000000000000000000000000000000000000000000000000000000002",
                "0x0000000000000000000000000000000000000000000000000000000000000003",
            ];

            h.map(|x| Digest::from_digest_hex(x).unwrap())
        };

        let root = hashes[0].join(&hashes[1]).join(&hashes[2].join(&hashes[3]));

        for h in hashes {
            builder.append(h);
        }
        let tree = builder.build();
        assert_eq!(tree.root_hash(), root);

        let proof = tree.prove_leaf(0);
        assert!(proof.verify_root(root));
        let proof = tree.prove_leaf(1);
        assert!(proof.verify_root(root));
        let proof = tree.prove_leaf(2);
        assert!(proof.verify_root(root));
        let proof = tree.prove_leaf(3);
        assert!(proof.verify_root(root));
    }

    #[test]
    pub fn last_proof_test() {
        let mut builder = crate::MerkleBuilder::default();
        builder.append_repeated(Digest::ZERO, 2);
        builder.append_repeated(Digest::ZERO, 2u128.pow(64) - 2);
        let tree = builder.build();

        let proof = tree.prove_last();

        let mut root = proof.node;

        for node in proof.siblings {
            root = Digest::join(&node, &root);
        }

        assert_eq!(root, tree.root_hash());
    }
}
