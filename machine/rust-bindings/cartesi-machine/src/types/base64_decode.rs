// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::types::Hash;
use base64::{Engine, prelude::BASE64_STANDARD};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

macro_rules! decode_base64_str {
    ($base64_string:expr) => {
        BASE64_STANDARD
            .decode($base64_string)
            .map_err(|err| serde::de::Error::custom(format!("base64 decode error: {err}")))
    };
}

macro_rules! encode_to_base64_str {
    ($bytes:expr) => {
        BASE64_STANDARD.encode($bytes)
    };
}

macro_rules! unwrap_ref {
    ($val:expr) => {
        $val.as_ref().expect("serde should skip when None")
    };
}

macro_rules! decode_base64_hash {
    ($base64_string:expr) => {{
        let bytes = decode_base64_str!($base64_string)?;
        if bytes.len() != 32 {
            Err(serde::de::Error::invalid_length(bytes.len(), &"32"))
        } else {
            let mut hash = Hash::default();
            hash.copy_from_slice(&bytes);
            Ok(hash)
        }
    }};
}

#[allow(dead_code)]
pub fn deserialize_base64_vec<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    let base64_string = String::deserialize(deserializer)?;
    decode_base64_str!(&base64_string)
}

#[allow(dead_code)]
pub fn serialize_base64_vec<S>(val: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let encoded = encode_to_base64_str!(&val);
    serializer.serialize_str(&encoded)
}

pub fn deserialize_base64_vec_opt<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt_str = Option::<String>::deserialize(deserializer)?;

    match opt_str {
        None => Ok(None),
        Some(base64_string) => Ok(Some(decode_base64_str!(&base64_string)?)),
    }
}

pub fn serialize_base64_vec_opt<S>(val: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let encoded = encode_to_base64_str!(unwrap_ref!(&val));
    serializer.serialize_str(&encoded)
}

pub fn deserialize_base64_32<'de, D>(deserializer: D) -> Result<Hash, D::Error>
where
    D: Deserializer<'de>,
{
    let base64_string = String::deserialize(deserializer)?;
    decode_base64_hash!(&base64_string)
}

pub fn serialize_base64_32<S>(val: &Hash, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let encoded = encode_to_base64_str!(&val);
    serializer.serialize_str(&encoded)
}

pub fn deserialize_base64_32_opt<'de, D>(deserializer: D) -> Result<Option<Hash>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt_str = Option::<String>::deserialize(deserializer)?;
    match opt_str {
        None => Ok(None),
        Some(base64_string) => Ok(Some(decode_base64_hash!(&base64_string)?)),
    }
}

pub fn serialize_base64_32_opt<S>(val: &Option<Hash>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let encoded = encode_to_base64_str!(unwrap_ref!(&val));
    serializer.serialize_str(&encoded)
}

pub fn deserialize_base64_32_array<'de, D>(deserializer: D) -> Result<Vec<Hash>, D::Error>
where
    D: Deserializer<'de>,
{
    let strings = Vec::<String>::deserialize(deserializer)?;
    let mut out = Vec::with_capacity(strings.len());

    for base64_string in strings {
        out.push(decode_base64_hash!(&base64_string)?);
    }

    Ok(out)
}

pub fn serialize_base64_32_array<S>(val: &[Hash], serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let encoded: Vec<String> = val.iter().map(|arr| encode_to_base64_str!(&arr)).collect();

    encoded.serialize(serializer)
}

pub fn deserialize_base64_32_array_opt<'de, D>(
    deserializer: D,
) -> Result<Option<Vec<Hash>>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt_strings = Option::<Vec<String>>::deserialize(deserializer)?;

    match opt_strings {
        None => Ok(None),
        Some(strings) => {
            let mut out = Vec::with_capacity(strings.len());
            for base64_string in strings {
                out.push(decode_base64_hash!(&base64_string)?);
            }
            Ok(Some(out))
        }
    }
}

pub fn serialize_base64_32_array_opt<S>(
    val: &Option<Vec<Hash>>,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let hashes = unwrap_ref!(&val);

    // Map each Hash to a base64 string
    let encoded: Vec<String> = hashes
        .iter()
        .map(|arr| encode_to_base64_str!(&arr))
        .collect();

    encoded.serialize(serializer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::from_str;

    use serde::Deserialize;

    #[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
    pub struct Foo {
        #[serde(
            deserialize_with = "deserialize_base64_vec",
            serialize_with = "serialize_base64_vec"
        )]
        pub bytes: Vec<u8>,

        #[serde(
            deserialize_with = "deserialize_base64_vec_opt",
            serialize_with = "serialize_base64_vec_opt",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        pub bytes_opt: Option<Vec<u8>>,

        #[serde(
            deserialize_with = "deserialize_base64_32",
            serialize_with = "serialize_base64_32"
        )]
        pub hash: Hash,

        #[serde(
            deserialize_with = "deserialize_base64_32_opt",
            serialize_with = "serialize_base64_32_opt",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        pub hash_opt: Option<Hash>,

        #[serde(
            deserialize_with = "deserialize_base64_32_array",
            serialize_with = "serialize_base64_32_array"
        )]
        pub hashes: Vec<Hash>,

        #[serde(
            deserialize_with = "deserialize_base64_32_array_opt",
            serialize_with = "serialize_base64_32_array_opt",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        pub hashes_opt: Option<Vec<Hash>>,
    }

    #[test]
    fn test_deserialize_base64() {
        let json_data = r#"
        {
          "bytes": "SGVsbG8gV29ybGQh",
          "hash":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
          "hashes": [
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
          ]
        }
        "#;

        let proof: Foo = from_str(json_data).expect("should deserialize fine");

        // bytes -> "Hello World!"
        assert_eq!(proof.bytes, b"Hello World!");

        // hash -> 32 bytes of zeros
        assert_eq!(proof.hash, [0u8; 32]);

        // hashes -> first is 32 zeros, second is 32 ones
        assert_eq!(proof.hashes.len(), 2);
        assert_eq!(proof.hashes[0], [0u8; 32]);
        assert_eq!(proof.hashes[1], [1u8; 32]);

        assert!(proof.bytes_opt.is_none());
        assert!(proof.hash_opt.is_none());
        assert!(proof.hashes_opt.is_none());

        assert_eq!(
            proof,
            from_str(&serde_json::to_string(&proof).unwrap()).unwrap()
        );
    }

    #[test]
    fn test_deserialize_proof_with_all_fields() {
        let json_data = r#"
        {
          "bytes_opt": "SGVsbG8gV29ybGQh",
          "bytes": "SGVsbG8gV29ybGQh",

          "hash":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
          "hash_opt":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",

          "hashes": [
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
          ],
          "hashes_opt": [
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
          ]
        }
        "#;

        let proof: Foo = from_str(json_data).expect("should deserialize fine");
        assert_eq!(proof.bytes, b"Hello World!".to_vec());
        assert_eq!(proof.bytes_opt, Some(b"Hello World!".to_vec()));
        assert_eq!(proof.hash, [0u8; 32]);
        assert_eq!(proof.hash_opt, Some([0u8; 32]));
        assert_eq!(proof.hashes.len(), 2);
        assert_eq!(proof.hashes[1], [1u8; 32]);
        assert_eq!(proof.hashes_opt.as_ref().unwrap().len(), 2);
        assert_eq!(proof.hashes_opt.as_ref().unwrap()[1], [1u8; 32]);

        assert_eq!(
            proof,
            from_str(&serde_json::to_string(&proof).unwrap()).unwrap()
        );
    }
}
