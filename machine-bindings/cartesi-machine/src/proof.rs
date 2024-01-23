//! Structures for merkle proofs

use crate::hash::Hash;

/// Merkle tree proof structure
pub struct MerkleTreeProof(*mut cartesi_machine_sys::cm_merkle_tree_proof);

impl Drop for MerkleTreeProof {
    fn drop(&mut self) {
        unsafe { cartesi_machine_sys::cm_delete_merkle_tree_proof(self.0) };
    }
}

impl MerkleTreeProof {
    pub(crate) fn new(ptr: *mut cartesi_machine_sys::cm_merkle_tree_proof) -> Self {
        Self(ptr)
    }

    /// Address of the target node
    pub fn target_address(&self) -> u64 {
        unsafe { (*self.0).target_address }
    }

    /// Log2 of size of target node
    pub fn log2_target_size(&self) -> usize {
        unsafe { (*self.0).log2_target_size }
    }

    /// Hash of target node
    pub fn target_hash(&self) -> Hash {
        Hash::new(unsafe { (*self.0).target_hash })
    }

    /// Log2 of size of root node
    pub fn log2_root_size(&self) -> usize {
        unsafe { (*self.0).log2_root_size }
    }

    /// Hash of root node
    pub fn root_hash(&self) -> Hash {
        Hash::new(unsafe { (*self.0).root_hash })
    }

    /// Sibling hashes towards root
    pub fn sibling_hashes(&self) -> Vec<Hash> {
        let sibling_hashes = unsafe { (*self.0).sibling_hashes };
        let sibling_hashes = unsafe { std::slice::from_raw_parts(sibling_hashes.entry, sibling_hashes.count) };

        sibling_hashes.iter().map(|hash| Hash::new(*hash)).collect()
    }
}