//! Module for a node in a Merkle tree. It can be either a leaf or an inner node.
//! Inner nodes have two children, which are also Merkle tree nodes but here
//! we only store their hashes.

use crate::Digest;

/// A node in a merkle tree. It can be either a leaf or an inner node.
#[derive(Clone, Debug)]
pub struct MerkleTreeNode {
    pub digest: Digest,
    children: Option<(Digest, Digest)>,
}

impl MerkleTreeNode {
    /// Creates a new Merkle tree node with the given digest.
    pub fn new(left: Digest, right: Digest) -> Self {
        MerkleTreeNode {
            digest: left.join(&right),
            children: Some((left, right)),
        }
    }

    pub fn from_digest(digest: Digest) -> Self {
        MerkleTreeNode {
            digest,
            children: None,
        }
    }

    /// Sets the children of the node.
    pub(crate) fn set_children(&mut self, left: Digest, right: Digest) {
        self.children = Some((left, right));
    }

    /// Retrieves the children of the node.
    pub fn children(&self) -> Option<(Digest, Digest)> {
        self.children
    }
}
