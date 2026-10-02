// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Results of the bulk hash collectors, `cm_collect_mcycle_root_hashes` and
//! `cm_collect_uarch_cycle_root_hashes`, kept whole: every entry, offset,
//! continuation and break reason the emulator reports. Parsing validates the
//! shape the C API documents, so a caller can index periods without
//! re-checking the metadata.

use crate::constants::break_reason;
use crate::types::{BreakReason, Hash, base64_decode::deserialize_base64_32_array};
use serde::{Deserialize, Deserializer};

/// The emulator's bundling continuation: an opaque JSON object, handed back
/// verbatim to the next mcycle collection call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PartialBundle(pub(crate) String);

impl PartialBundle {
    pub fn as_json(&self) -> &str {
        &self.0
    }
}

/// State root hashes sampled every 2^log2_mcycle_period mcycles, or bundle
/// roots over 2^log2_bundle_mcycle_count consecutive samples.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct McycleRootHashes {
    #[serde(deserialize_with = "deserialize_base64_32_array")]
    pub hashes: Vec<Hash>,
    /// Mcycles elapsed in the current sampling period, to pass to the next call.
    pub mcycle_phase: u64,
    #[serde(deserialize_with = "deserialize_break_reason")]
    pub break_reason: BreakReason,
    /// Present while a bundle is incomplete; absent at fixed points.
    #[serde(default, deserialize_with = "deserialize_partial_bundle")]
    pub partial_bundle: Option<PartialBundle>,
    /// Console errors do not stop collection; the first one is reported here.
    #[serde(default)]
    pub console_io_error: Option<String>,
}

impl McycleRootHashes {
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}

/// State root hashes after every uarch cycle, or bundle roots over
/// 2^log2_bundle_uarch_cycle_count of them, grouped by mcycle period.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UarchCycleRootHashes {
    pub hashes: Vec<Hash>,
    /// Half-open offsets into `hashes`, one more than the periods: starts at
    /// zero, non-decreasing, ends at `hashes.len()`.
    pub mcycle_hash_offsets: Vec<u64>,
    pub break_reason: BreakReason,
}

impl UarchCycleRootHashes {
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        #[derive(Deserialize)]
        struct Raw {
            #[serde(deserialize_with = "deserialize_base64_32_array")]
            hashes: Vec<Hash>,
            mcycle_hash_offsets: Vec<u64>,
            #[serde(deserialize_with = "deserialize_break_reason")]
            break_reason: BreakReason,
        }
        let raw: Raw = serde_json::from_str(json)?;
        let offsets = &raw.mcycle_hash_offsets;
        let well_formed = offsets.first() == Some(&0)
            && offsets.windows(2).all(|w| w[0] <= w[1])
            && offsets.last() == Some(&(raw.hashes.len() as u64));
        if !well_formed {
            return Err(serde::de::Error::custom(format!(
                "mcycle_hash_offsets {offsets:?} do not partition {} hashes",
                raw.hashes.len()
            )));
        }
        Ok(Self {
            hashes: raw.hashes,
            mcycle_hash_offsets: raw.mcycle_hash_offsets,
            break_reason: raw.break_reason,
        })
    }

    /// Each collected mcycle period's entries, in order. Every period ends
    /// with the post-reset entry, preceded by the halted-padding entry.
    pub fn periods(&self) -> impl Iterator<Item = &[Hash]> {
        self.mcycle_hash_offsets
            .windows(2)
            .map(|w| &self.hashes[w[0] as usize..w[1] as usize])
    }
}

fn deserialize_break_reason<'de, D>(deserializer: D) -> Result<BreakReason, D::Error>
where
    D: Deserializer<'de>,
{
    use cartesi_machine_sys::{CM_BREAK_REASON_CONSOLE_INPUT, CM_BREAK_REASON_CONSOLE_OUTPUT};
    let name = String::deserialize(deserializer)?;
    Ok(match name.as_str() {
        "failed" => break_reason::FAILED,
        "halted" => break_reason::HALTED,
        "yielded_manually" => break_reason::YIELDED_MANUALLY,
        "yielded_automatically" => break_reason::YIELDED_AUTOMATICALLY,
        "yielded_softly" => break_reason::YIELDED_SOFTLY,
        "reached_target_mcycle" => break_reason::REACHED_TARGET_MCYCLE,
        "console_output" => CM_BREAK_REASON_CONSOLE_OUTPUT,
        "console_input" => CM_BREAK_REASON_CONSOLE_INPUT,
        "mcycle_overflow" => break_reason::MCYCLE_OVERFLOW,
        other => {
            return Err(serde::de::Error::custom(format!(
                "unknown break reason {other:?}"
            )));
        }
    })
}

fn deserialize_partial_bundle<'de, D>(deserializer: D) -> Result<Option<PartialBundle>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(value.map(|value| PartialBundle(value.to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    const B: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";

    fn uarch(hashes: &[&str], offsets: &[u64], reason: &str) -> String {
        serde_json::json!({
            "hashes": hashes,
            "mcycle_hash_offsets": offsets,
            "break_reason": reason,
        })
        .to_string()
    }

    #[test]
    fn uarch_result_partitions_its_hashes_into_periods() {
        let parsed =
            UarchCycleRootHashes::from_json(&uarch(&[A, B, A, B], &[0, 2, 4], "yielded_manually"))
                .unwrap();
        assert_eq!(parsed.break_reason, break_reason::YIELDED_MANUALLY);
        let periods: Vec<_> = parsed.periods().collect();
        assert_eq!(periods.len(), 2);
        assert_eq!(periods[0], &[[0u8; 32], [1u8; 32]]);
    }

    #[test]
    fn empty_uarch_result_has_no_periods() {
        let parsed =
            UarchCycleRootHashes::from_json(&uarch(&[], &[0], "reached_target_mcycle")).unwrap();
        assert_eq!(parsed.periods().count(), 0);
    }

    #[test]
    fn malformed_uarch_metadata_is_refused() {
        for (hashes, offsets) in [
            (&[A, B][..], &[][..]),
            (&[A, B][..], &[1, 2][..]),
            (&[A, B][..], &[0, 1][..]),
            (&[A, B][..], &[0, 3][..]),
            (&[A, B][..], &[0, 2, 1, 2][..]),
        ] {
            assert!(
                UarchCycleRootHashes::from_json(&uarch(hashes, offsets, "halted")).is_err(),
                "offsets {offsets:?} over {} hashes",
                hashes.len()
            );
        }
        assert!(UarchCycleRootHashes::from_json(&uarch(&[A], &[0, 1], "running")).is_err());
        assert!(UarchCycleRootHashes::from_json(&uarch(&["AAAA"], &[0, 1], "halted")).is_err());
    }

    #[test]
    fn mcycle_result_keeps_its_continuation_opaque() {
        let json = serde_json::json!({
            "hashes": [A],
            "mcycle_phase": 7,
            "break_reason": "reached_target_mcycle",
            "partial_bundle": {"log2_max_leaves": 2, "leaf_count": 1},
        })
        .to_string();
        let parsed = McycleRootHashes::from_json(&json).unwrap();
        assert_eq!(parsed.mcycle_phase, 7);
        assert_eq!(parsed.console_io_error, None);
        let bundle: serde_json::Value =
            serde_json::from_str(parsed.partial_bundle.unwrap().as_json()).unwrap();
        assert_eq!(bundle["leaf_count"], 1);
    }
}
