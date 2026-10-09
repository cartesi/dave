// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The deployed tournament's level table: each level's leaf stride and
//! commitment height, top level first.
//!
//! The node never compiles a geometry in. It reads the table from the
//! tournament factory at startup, validates it here, and pins it with the
//! rest of the engine configuration: the root stride shapes every stored
//! window root and settlement hash, so a store built under one table must
//! never serve another.

use super::structure::Structure;
use anyhow::{Result, bail, ensure};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Level {
    pub log2_stride: u64,
    pub height: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TournamentGeometry {
    levels: Vec<Level>,
}

impl TournamentGeometry {
    /// Mirrors the shape rules of the contracts' test-only table validator
    /// (non-empty, nonzero heights, the root spanning the whole ruler,
    /// each level tiling one leaf of its parent, a stride-0 leaf level);
    /// production providers validate nothing on chain. Allowances are not
    /// read here, and the per-row level count is the caller's check. On
    /// top, the node's own bound: the root stride must sit between one big
    /// cycle and one input window, since the runner samples whole big
    /// cycles and folds one window root per input.
    pub fn new(levels: Vec<Level>, structure: &Structure) -> Result<Self> {
        let Some((root, _)) = levels.split_first() else {
            bail!("the tournament table has no levels");
        };
        for (level, row) in levels.iter().enumerate() {
            ensure!(row.height > 0, "level {level} has a zero height");
        }
        ensure!(
            root.log2_stride.checked_add(root.height) == Some(structure.log2_ruler_span()),
            "the root level spans 2^({} + {}) transitions, but an epoch spans 2^{}",
            root.log2_stride,
            root.height,
            structure.log2_ruler_span()
        );
        for (level, pair) in levels.windows(2).enumerate() {
            let (parent, child) = (pair[0], pair[1]);
            ensure!(
                child.log2_stride.checked_add(child.height) == Some(parent.log2_stride),
                "level {} spans 2^({} + {}) transitions, but a level-{level} leaf spans 2^{}",
                level + 1,
                child.log2_stride,
                child.height,
                parent.log2_stride
            );
        }
        let leaf = levels.last().expect("non-empty");
        ensure!(
            leaf.log2_stride == 0,
            "the leaf level has stride 2^{}, not single transitions",
            leaf.log2_stride
        );
        ensure!(
            (structure.log2_uarch_span..=structure.log2_window_span()).contains(&root.log2_stride),
            "the root stride 2^{} lies outside [2^{}, 2^{}] (one big cycle to one input window)",
            root.log2_stride,
            structure.log2_uarch_span,
            structure.log2_window_span()
        );
        Ok(TournamentGeometry { levels })
    }

    pub fn levels(&self) -> &[Level] {
        &self.levels
    }

    /// The stride the runner samples at: every window root and
    /// settlement hash is folded from leaves this far apart.
    pub fn root_stride(&self) -> u64 {
        self.levels[0].log2_stride
    }

    /// The pinned text form: `stride/height` per level, top first.
    pub fn encode(&self) -> String {
        self.to_string()
    }

    pub fn decode(encoded: &str, structure: &Structure) -> Result<Self> {
        let levels = encoded
            .split(',')
            .map(|row| {
                let (stride, height) = row
                    .split_once('/')
                    .ok_or_else(|| anyhow::anyhow!("malformed level `{row}`"))?;
                Ok(Level {
                    log2_stride: stride.parse()?,
                    height: height.parse()?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Self::new(levels, structure)
    }
}

impl fmt::Display for TournamentGeometry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, level) in self.levels.iter().enumerate() {
            if index > 0 {
                write!(f, ",")?;
            }
            write!(f, "{}/{}", level.log2_stride, level.height)?;
        }
        Ok(())
    }
}

#[cfg(test)]
impl TournamentGeometry {
    /// The table checked into ArbitrationConstants.sol, whichever it is.
    /// Tests that need a particular geometry name it instead.
    pub fn checked_in() -> Self {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let arbitration = std::fs::read_to_string(
            manifest_dir
                .join("../../prt/contracts/src/arbitration-config/ArbitrationConstants.sol"),
        )
        .expect("read ArbitrationConstants.sol");
        // Each function's array literal lists its levels, top first.
        let array_after = |marker: &str| -> Vec<u64> {
            let from = arbitration
                .find(marker)
                .expect("function in ArbitrationConstants.sol");
            let open = from + arbitration[from..].find("= [").expect("array literal");
            let close = open + arbitration[open..].find(']').expect("array literal end");
            arbitration[open..close]
                .split("uint64(")
                .skip(1)
                .map(|item| {
                    item.split(')')
                        .next()
                        .unwrap()
                        .trim()
                        .parse()
                        .expect("uint64 literal")
                })
                .collect()
        };
        let log2steps = array_after("function log2step");
        let heights = array_after("function height");
        assert_eq!(log2steps.len(), heights.len());
        let pairs: Vec<_> = log2steps.into_iter().zip(heights).collect();
        Self::from_pairs(&pairs)
    }

    /// The three-level table [44, 27, 0] / [48, 17, 27].
    pub fn three_level() -> Self {
        Self::from_pairs(&[(44, 48), (27, 17), (0, 27)])
    }

    /// The two-level table [38, 0] / [54, 38] (docs/dimensioning.md).
    pub fn two_level() -> Self {
        Self::from_pairs(&[(38, 54), (0, 38)])
    }

    pub fn from_pairs(pairs: &[(u64, u64)]) -> Self {
        let levels = pairs
            .iter()
            .map(|&(log2_stride, height)| Level {
                log2_stride,
                height,
            })
            .collect();
        Self::new(levels, &Structure::PRODUCTION).expect("valid test geometry")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(pairs: &[(u64, u64)]) -> Result<TournamentGeometry> {
        let levels = pairs
            .iter()
            .map(|&(log2_stride, height)| Level {
                log2_stride,
                height,
            })
            .collect();
        TournamentGeometry::new(levels, &Structure::PRODUCTION)
    }

    fn refusal(pairs: &[(u64, u64)]) -> String {
        format!("{:#}", table(pairs).unwrap_err())
    }

    #[test]
    fn accepts_the_three_and_two_level_tables() {
        let three_level = TournamentGeometry::three_level();
        assert_eq!(three_level.root_stride(), 44);
        let two_level = TournamentGeometry::two_level();
        assert_eq!(two_level.root_stride(), 38);
        // The minimum root stride and four levels are valid too.
        assert!(table(&[(20, 72), (0, 20)]).is_ok());
        assert!(table(&[(60, 32), (40, 20), (20, 20), (0, 20)]).is_ok());
    }

    #[test]
    fn refuses_malformed_tables() {
        assert!(refusal(&[]).contains("no levels"));
        assert!(refusal(&[(44, 48), (27, 0), (0, 27)]).contains("zero height"));
        assert!(refusal(&[(44, 47), (27, 17), (0, 27)]).contains("an epoch spans"));
        assert!(refusal(&[(44, 48), (28, 17), (0, 27)]).contains("level-0 leaf"));
        assert!(refusal(&[(44, 48), (27, 17)]).contains("not single transitions"));
    }

    #[test]
    fn refuses_root_strides_the_runner_cannot_sample() {
        assert!(refusal(&[(19, 73), (0, 19)]).contains("outside"));
        assert!(refusal(&[(69, 23), (0, 69)]).contains("outside"));
        assert!(table(&[(68, 24), (0, 68)]).is_ok());
        // A single level would sample single transitions at the root.
        assert!(refusal(&[(0, 92)]).contains("outside"));
    }

    #[test]
    fn text_form_round_trips() {
        for geometry in [
            TournamentGeometry::three_level(),
            TournamentGeometry::two_level(),
        ] {
            let encoded = geometry.encode();
            assert_eq!(
                TournamentGeometry::decode(&encoded, &Structure::PRODUCTION).unwrap(),
                geometry
            );
        }
        assert_eq!(
            TournamentGeometry::three_level().encode(),
            "44/48,27/17,0/27"
        );
        assert!(TournamentGeometry::decode("44-48", &Structure::PRODUCTION).is_err());
    }
}
