//! Keccak256 hash for the Digest Type. It's used to hash the data in the Digest.

use sha3::{Digest as Keccak256Digest, Keccak256};

use super::Digest;

impl Digest {
    /// Computes the Keccak256 hash of the given data and returns a new Digest.
    pub fn from_data(data: &[u8]) -> Digest {
        let mut keccak = Keccak256::new();
        keccak.update(data);
        let digest: [u8; 32] = keccak.finalize().into();
        Digest::from(digest)
    }

    /// Joins the current Digest with another Digest to create a new Digest.
    pub fn join(&self, digest: &Digest) -> Digest {
        let mut keccak = Keccak256::new();
        keccak.update(self.data);
        keccak.update(digest.data);
        let digest: [u8; 32] = keccak.finalize().into();
        Digest::from(digest)
    }
}
