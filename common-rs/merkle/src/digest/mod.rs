//! Definition of the [Digest] type and its associated methods. A digest is the output of a hash
//! function. It's used to identify the data in the MerkleTree.

use alloy::primitives::B256;
use hex::FromHex;
use std::fmt;
use thiserror::Error;

pub mod keccak;

const HASH_SIZE: usize = 32;

#[derive(Error, Debug)]
pub enum DigestError {
    #[error("Invalid digest data length")]
    InvalidDigestLength,

    #[error("Invalid hex string")]
    InvalidHexString(#[from] hex::FromHexError),
}

/// The output of a hash function.
#[derive(Eq, Hash, PartialEq, Clone, Copy, Debug)]
pub struct Digest {
    data: [u8; HASH_SIZE],
}

impl Digest {
    pub const ZERO: Digest = Digest::new([0; HASH_SIZE]);

    /// Creates a new [Digest] with the provided 32-byte data.
    pub const fn new(data: [u8; HASH_SIZE]) -> Self {
        Digest { data }
    }

    /// Attempts to create a [Digest] from a Vec<u8> containing 32 bytes of data.
    pub fn from_digest(digest_data: &[u8]) -> Result<Digest, DigestError> {
        if digest_data.len() != HASH_SIZE {
            return Err(DigestError::InvalidDigestLength);
        }

        let mut data = [0u8; HASH_SIZE];
        data.copy_from_slice(digest_data);
        Ok(Digest::new(data))
    }

    /// Attempts to create a [Digest] from a hexadecimal string.
    pub fn from_digest_hex(digest_hex: &str) -> Result<Digest, DigestError> {
        let data = Vec::from_hex(&digest_hex[2..])?;
        Self::from_digest(&data)
    }

    pub fn data(&self) -> [u8; 32] {
        self.data
    }

    pub fn slice(&self) -> &[u8] {
        self.data.as_slice()
    }

    /// Converts the [Digest] to a hexadecimal string.
    pub fn to_hex(&self) -> String {
        format!("0x{}", hex::encode(self.data))
    }

    /// Checks if the [Digest] is zeroed.
    pub fn is_zeroed(&self) -> bool {
        self.data.iter().all(|&x| x == 0)
    }
}

impl From<[u8; HASH_SIZE]> for Digest {
    fn from(data: [u8; HASH_SIZE]) -> Self {
        Digest::new(data)
    }
}

impl From<Digest> for [u8; HASH_SIZE] {
    fn from(hash: Digest) -> Self {
        hash.data
    }
}

impl From<B256> for Digest {
    fn from(data: B256) -> Self {
        Digest::new(data.0)
    }
}

impl From<Digest> for B256 {
    fn from(hash: Digest) -> Self {
        B256::from_slice(hash.slice())
    }
}

impl fmt::Display for Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_hex())
    }
}
