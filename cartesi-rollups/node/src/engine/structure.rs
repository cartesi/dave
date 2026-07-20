// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The ruler's coordinate system.
//!
//! A position on the ruler is the number of transitions applied since
//! the epoch's initial state. The leaf at position m is the state hash
//! after transition m; the state before leaf 0 rides outside the tree
//! (the commitment's implicit hash).

use crate::engine::constants;
use alloy::primitives::U256;

/// The structural shape of the state-transition function: the log2
/// spans of the ruler's three fields. Fixed by the machine at
/// deployment, never by the node; tournament level parameters and cache
/// strides are choices layered on top of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Structure {
    /// Maximum inputs in an epoch (a): log2.
    pub log2_input_span: u64,
    /// Maximum big cycles an input may take (b): log2.
    pub log2_barch_span: u64,
    /// Uarch slots in a big cycle, including the closing ureset (c): log2.
    pub log2_uarch_span: u64,
}

impl Structure {
    /// The production shape, derived from the one span authority
    /// (engine/constants.rs).
    pub const PRODUCTION: Structure = Structure {
        log2_input_span: constants::LOG2_INPUT_SPAN_TO_EPOCH,
        log2_barch_span: constants::LOG2_BARCH_SPAN_TO_INPUT,
        log2_uarch_span: constants::LOG2_UARCH_SPAN_TO_BARCH,
    };

    pub fn log2_ruler_span(&self) -> u64 {
        self.log2_input_span + self.log2_barch_span + self.log2_uarch_span
    }

    /// Meta-cycles in one input window.
    pub fn log2_window_span(&self) -> u64 {
        self.log2_barch_span + self.log2_uarch_span
    }

    pub fn window_span(&self) -> U256 {
        U256::from(1) << self.log2_window_span()
    }

    /// Uarch slots in one big cycle. Bounded by u64 (c < 64 always).
    pub fn big_span(&self) -> u64 {
        1u64 << self.log2_uarch_span
    }

    pub fn ruler_span(&self) -> U256 {
        U256::from(1) << self.log2_ruler_span()
    }

    pub fn max_inputs(&self) -> u64 {
        1u64 << self.log2_input_span
    }

    pub fn assert_valid(&self) {
        assert!(self.log2_uarch_span >= 1, "big cycle needs a ureset slot");
        assert!(self.log2_ruler_span() < 256, "ruler must fit in U256");
        assert!(
            self.log2_input_span < 64 && self.log2_barch_span < 64 && self.log2_uarch_span < 64,
            "position fields must fit in u64"
        );
    }

    /// Splits a flat ruler position into the paper's (input, big,
    /// ustep) coordinates. Valid for transition positions, which are
    /// strictly inside the ruler.
    pub fn decompose(&self, position: U256) -> Position {
        assert!(position < self.ruler_span(), "past the epoch's end");
        let field = |shift: u64, bits: u64| -> u64 {
            u64::try_from((position >> shift) & ((U256::from(1) << bits) - U256::from(1)))
                .expect("field bounded by its span")
        };
        Position {
            input: field(self.log2_window_span(), self.log2_input_span),
            big: field(self.log2_uarch_span, self.log2_barch_span),
            ustep: field(0, self.log2_uarch_span),
        }
    }

    /// The inverse of [`Structure::decompose`].
    pub fn compose(&self, p: Position) -> U256 {
        assert!(p.input < self.max_inputs(), "input field out of range");
        assert!(
            p.big < (1u64 << self.log2_barch_span),
            "big field out of range"
        );
        assert!(p.ustep < self.big_span(), "ustep field out of range");
        (U256::from(p.input) << self.log2_window_span())
            | (U256::from(p.big) << self.log2_uarch_span)
            | U256::from(p.ustep)
    }

    /// The flat position where input window `w` begins.
    pub fn window_start(&self, w: u64) -> U256 {
        U256::from(w) << self.log2_window_span()
    }
}

/// A ruler position in the paper's (c, b, a) coordinates: which input
/// window, which big cycle within it, which uarch slot within that.
/// The single authority for the meta-cycle field layout; pack and
/// unpack through [`Structure::compose`] / [`Structure::decompose`]
/// only at the chain boundary and quartet math.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Position {
    pub input: u64,
    pub big: u64,
    pub ustep: u64,
}

impl Position {
    /// The window-opening slot: the fused transition (checkpoint plus
    /// input delivery plus the first ustep) when the window feeds.
    pub fn is_window_start(&self) -> bool {
        self.big == 0 && self.ustep == 0
    }

    /// A big-cycle boundary: the uarch is pristine here.
    pub fn is_big_start(&self) -> bool {
        self.ustep == 0
    }

    /// The big cycle's closing slot: the final (possibly identity)
    /// ustep, the ureset, and the revert check. Kept as the span's
    /// last uarch index rather than an explicit Reset variant: the
    /// slot always fuses the three operations, so a separate
    /// representation state would never change behavior (explored per
    /// the workstream-4 note; the spec tests hold either way).
    pub fn is_closing_slot(&self, structure: &Structure) -> bool {
        self.ustep == structure.big_span() - 1
    }
}

/// An input window boundary: the position [`Structure::window_start`]
/// of its index, where the open regime stores machines (yielded at an
/// input boundary, pristine uarch - asserted at store and resume).
/// The snapshot seam speaks boundaries end to end, so the conversion
/// to a flat ruler position happens in exactly one place (the machine
/// factory) instead of shift arithmetic at every module seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct InputBoundary(pub u64);

impl InputBoundary {
    pub fn position(&self, structure: &Structure) -> U256 {
        structure.window_start(self.0)
    }
}

/// The identifier of a computation-hash node: every merkle node of
/// every commitment tree over the epoch is one quartet. A level root
/// (shift 0, full height for its stride) identifies a computation hash
/// itself; bisection children and proof siblings are the general case.
///
/// The node has 2^height sampled leaves; sampled leaf j is the ruler
/// leaf at position (j + 1) * 2^log2_stride - 1, i.e. the post-state
/// after each full stride. The node covers ruler positions
/// [shift * 2^(height + log2_stride), (shift + 1) * 2^(height + log2_stride)).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Quartet {
    pub epoch: u64,
    pub log2_stride: u64,
    pub height: u64,
    pub shift: U256,
}

impl Quartet {
    /// The root of a whole tournament level's commitment tree.
    pub fn level_root(epoch: u64, log2_stride: u64, height: u64) -> Self {
        Quartet {
            epoch,
            log2_stride,
            height,
            shift: U256::ZERO,
        }
    }

    pub fn assert_valid(&self, structure: &Structure) {
        let total = structure.log2_ruler_span();
        assert!(
            self.log2_stride + self.height <= total,
            "quartet exceeds the ruler: stride {} + height {} > {}",
            self.log2_stride,
            self.height,
            total
        );
        let log2_max_shift = total - self.log2_stride - self.height;
        assert!(
            self.shift < (U256::from(1) << log2_max_shift),
            "shift out of range"
        );
    }

    /// First ruler position covered (a transition count, not a leaf).
    pub fn span_start(&self) -> U256 {
        self.shift << (self.height + self.log2_stride)
    }

    /// One past the last ruler position covered.
    pub fn span_end(&self) -> U256 {
        (self.shift + U256::from(1)) << (self.height + self.log2_stride)
    }

    pub fn leaf_count(&self) -> U256 {
        U256::from(1) << self.height
    }

    /// The two children, one height down. None at height 0 (a sampled
    /// leaf has no children in this tree; finer detail lives at a
    /// smaller stride, which is a different quartet subspace).
    pub fn children(&self) -> Option<(Quartet, Quartet)> {
        if self.height == 0 {
            return None;
        }
        let left = Quartet {
            epoch: self.epoch,
            log2_stride: self.log2_stride,
            height: self.height - 1,
            shift: self.shift << 1,
        };
        let right = Quartet {
            shift: (self.shift << 1) + U256::from(1),
            ..left.clone()
        };
        Some((left, right))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn position_round_trips_and_names_the_slots() {
        let s = Structure {
            log2_input_span: 2,
            log2_barch_span: 2,
            log2_uarch_span: 3,
        };
        s.assert_valid();

        // The toy picture of docs/computation-hash.md: window span 32,
        // big span 8.
        let cases = [
            (
                0u64,
                Position {
                    input: 0,
                    big: 0,
                    ustep: 0,
                },
            ),
            (
                7,
                Position {
                    input: 0,
                    big: 0,
                    ustep: 7,
                },
            ),
            (
                8,
                Position {
                    input: 0,
                    big: 1,
                    ustep: 0,
                },
            ),
            (
                31,
                Position {
                    input: 0,
                    big: 3,
                    ustep: 7,
                },
            ),
            (
                32,
                Position {
                    input: 1,
                    big: 0,
                    ustep: 0,
                },
            ),
            (
                127,
                Position {
                    input: 3,
                    big: 3,
                    ustep: 7,
                },
            ),
        ];
        for (flat, expect) in cases {
            let p = s.decompose(U256::from(flat));
            assert_eq!(p, expect);
            assert_eq!(s.compose(p), U256::from(flat));
        }

        assert!(s.decompose(U256::ZERO).is_window_start());
        assert!(!s.decompose(U256::from(8)).is_window_start());
        assert!(s.decompose(U256::from(8)).is_big_start());
        assert!(s.decompose(U256::from(7)).is_closing_slot(&s));
        assert!(!s.decompose(U256::from(6)).is_closing_slot(&s));
        assert_eq!(s.window_start(3), U256::from(96));

        // Production-shape spot check against the documented layout:
        // input = meta >> 68, big = (meta >> 20) & (2^48 - 1),
        // ustep = meta & (2^20 - 1).
        let prod = Structure::PRODUCTION;
        let meta = (U256::from(5u64) << 68) | (U256::from(77u64) << 20) | U256::from(9u64);
        assert_eq!(
            prod.decompose(meta),
            Position {
                input: 5,
                big: 77,
                ustep: 9
            }
        );
    }

    #[test]
    fn spans_and_children() {
        let s = Structure {
            log2_input_span: 2,
            log2_barch_span: 2,
            log2_uarch_span: 3,
        };
        s.assert_valid();
        assert_eq!(s.log2_ruler_span(), 7);
        assert_eq!(s.big_span(), 8);
        assert_eq!(s.window_span(), U256::from(32));

        let root = Quartet::level_root(0, 3, 4);
        root.assert_valid(&s);
        assert_eq!(root.span_start(), U256::ZERO);
        assert_eq!(root.span_end(), U256::from(128));
        assert_eq!(root.leaf_count(), U256::from(16));

        let (l, r) = root.children().unwrap();
        assert_eq!(l.span_end(), r.span_start());
        assert_eq!(l.span_start(), root.span_start());
        assert_eq!(r.span_end(), root.span_end());
        assert!(Quartet::level_root(0, 0, 0).children().is_none());
    }
}
