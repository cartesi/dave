use crate::merkle::Hash;

#[derive(Clone, Debug)]
pub struct MerkleTreeNode {
    pub digest: Hash,
    children: Option<(Hash, Hash)>,
}

impl MerkleTreeNode {
    pub fn new(digest: Hash) -> Self {
        MerkleTreeNode {
            digest: digest,
            children: None,
        }
    }

    pub fn set_children(&mut self, left: Hash, right: Hash) {
        self.children = Some((left, right));
    }

    pub fn children(&self) -> Option<(Hash, Hash)> {
        self.children
    }
}