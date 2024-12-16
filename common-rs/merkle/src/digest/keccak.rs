//! Keccak256 hash for the Digest Type. It's used to hash the data in the Digest.

use tiny_keccak::{Hasher, Keccak};

use super::Digest;

impl Digest {
    /// Computes the Keccak256 hash of the given data and returns a new Digest.
    pub fn from_data(data: &[u8]) -> Digest {
        let mut keccak = Keccak::v256();
        keccak.update(data);
        let mut digest: [u8; 32] = [0; 32];
        keccak.finalize(&mut digest);
        Digest::from(digest)
    }

    /// Joins the current Digest with another Digest to create a new Digest.
    pub fn join(&self, digest: &Digest) -> Digest {
        let mut keccak = Keccak::v256();
        keccak.update(&self.data);
        keccak.update(&digest.data);
        let mut digest: [u8; 32] = [0; 32];
        keccak.finalize(&mut digest);
        Digest::from(digest)
    }
}

#[cfg(test)]
mod tests {
    use super::Digest;

    fn assert_data_eq(expected_digest_hex: &str, digest: Digest) {
        assert_eq!(
            Digest::from_digest_hex(expected_digest_hex).expect("invalid hex"),
            digest
        );
    }

    #[test]
    fn test_from_data() {
        assert_data_eq(
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            Digest::from_data(&[]), // cast keccak ""
        );

        assert_data_eq(
            "0x6228290203658fd4987e40cbb257cabf258f9c288cdee767eaba6b234a73a2f9",
            Digest::from_data("bananas".as_bytes()), // cast keccak "bananas"
        );
    }

    #[test]
    fn test_join() {
        assert_data_eq(
            "0x4441036546894c6fcf905b48b722f6b149ec0902955a6445c63cfec478568268",
            // cast keccak (cast concat-hex (cast keccak "minhas") (cast keccak "bananas"))
            Digest::from_data("minhas".as_bytes()).join(&Digest::from_data("bananas".as_bytes())),
        );
    }
}
