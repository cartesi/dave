//! Definition of the [Digest] type and its associated methods. A digest is the output of a hash 
//! function. It's used to identify the data in the MerkleTree.

use std::fmt;
use hex::FromHex;

pub mod keccak;

use hex;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum DigestError {
    #[error("Invalid digest data length")]
    InvalidDigestLength,
}

/// The output of a hash function. 
#[derive(Eq, Hash, PartialEq, Clone, Copy, Debug)]
pub struct Digest {
    data: [u8; 32],
}

impl Digest {
    /// Creates a new [Digest] with the provided 32-byte data.
    pub fn new(data: [u8; 32]) -> Self {
        Digest { data }
    }

    /// Attempts to create a [Digest] from a Vec<u8> containing 32 bytes of data.
    pub fn from_digest(digest_data: &[u8]) -> Result<Digest, DigestError> {
        if digest_data.len() != 32 {
            return Err(DigestError::InvalidDigestLength);
        }

        let mut data = [0u8; 32];
        data.copy_from_slice(digest_data);
        Ok(Digest::new(data))
    }

    /// Attempts to create a [Digest] from a hexadecimal string.
    pub fn from_digest_hex(digest_hex: &str) -> Result<Digest, DigestError> {
        let data = Vec::from_hex(digest_hex).map_err(|_| DigestError::InvalidDigestLength)?;
        Self::from_digest(&data)
    }

    /// Converts the [Digest] to a hexadecimal string.
    pub fn to_hex(&self) -> String {
        hex::encode(self.data)
    }

    /// Creates a [Digest] with all bytes set to zero.
    pub fn zeroed() -> Self {
        Digest::new([0;32])
    }

    /// Checks if the [Digest] is zeroed.
    pub fn is_zeroed(&self) -> bool {
        self.data.iter().all(|&x| x == 0)
    }
}

impl From<[u8; 32]> for Digest {
    fn from(data: [u8; 32]) -> Self {
        Digest { data }
    }
}

impl From<Digest> for [u8; 32] {
    fn from(hash: Digest) -> Self {
        hash.data
    }
}

impl fmt::Display for Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_hex())
    }
}
