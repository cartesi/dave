// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The geometry engine: drives an [`Stf`] along the ruler, mapping each
//! meta-cycle position to its transition shape and exploiting the
//! periodicity of idle spans so padded regions cost almost nothing.
//!
//! Every meta-cycle convention lives here, once, and nowhere else:
//!
//! - Position p counts applied transitions; the leaf at p is the
//!   post-state of transition p.
//! - Window starts (p multiple of the window span): the fused
//!   transition, checkpoint write plus input delivery plus the first
//!   ustep, when the epoch has an input for that window. Inputs are a
//!   contiguous prefix; window w feeds input w.
//! - Big-cycle closing slots (p one short of a big-span multiple): a
//!   final (possibly identity) ustep, the ureset, and the revert check.
//! - Everything else: one ustep.
//! - Idle regions (halted forever, or yielded until the next fed
//!   window): the machine's big state is a fixed point, but only at
//!   big-cycle boundaries. Within each idle big cycle the uarch churns
//!   its own bookkeeping (the emulated interpreter checks the flags
//!   and declines to execute) until it halts, and the closing ureset
//!   restores the base hash exactly. Every idle big cycle therefore
//!   repeats one identical leaf pattern, so the engine steps a single
//!   idle span and replays it for the whole region.
//!
//! Invariant, with a tripwire: an input's computation never crosses its
//! window boundary. The spans (a, b, c) are deliberate overestimates -
//! far more inputs than a chain can carry (batching makes one input a
//! whole bundle of transactions) and far more big cycles than gas-bounded
//! input processing can consume - so a machine still running at a window
//! start means a broken machine or broken assumptions, and the engine
//! panics rather than inventing a transition shape for it.

use super::stf::{ProvingStf, Stf, ToyInput, ToyStf};
use super::structure::Structure;
use crate::merkle::Digest;
use alloy::primitives::U256;
use anyhow::Result;

/// A run of identical consecutive leaves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub hash: Digest,
    pub repetitions: U256,
}

/// A leaf value the engine reports: the live machine (its hash pulled
/// only when a sample lands) or a known digest from a captured idle
/// pattern.
enum Leaf<'a, S: Stf> {
    Live(&'a mut S),
    Known(Digest),
}

impl<'a, S: Stf> Leaf<'a, S> {
    fn digest(self) -> Result<Digest> {
        match self {
            Leaf::Live(stf) => stf.state_hash(),
            Leaf::Known(digest) => Ok(digest),
        }
    }
}

pub struct Ruler<S: Stf> {
    structure: Structure,
    stf: S,
    /// How many windows feed: inputs are a contiguous prefix, so the
    /// geometry needs only the count. Payloads live with the Stf.
    fed_windows: u64,
    position: U256,
}

impl<S: Stf> Ruler<S> {
    /// Takes an stf at the epoch's initial state (position zero).
    pub fn new(stf: S, structure: Structure, fed_windows: u64) -> Self {
        Self::new_at(stf, structure, fed_windows, U256::ZERO)
    }

    /// Takes an stf whose state is the machine at `position` - the
    /// caller's provenance contract (a boundary-store answer). The
    /// cache's collision tripwire cross-checks computed hashes
    /// wherever resumed and replayed runs overlap.
    pub fn new_at(stf: S, structure: Structure, fed_windows: u64, position: U256) -> Self {
        structure.assert_valid();
        assert!(
            fed_windows <= structure.max_inputs(),
            "more inputs than the epoch admits"
        );
        assert!(position <= structure.ruler_span(), "past the epoch's end");
        Ruler {
            structure,
            stf,
            fed_windows,
            position,
        }
    }

    pub fn position(&self) -> U256 {
        self.position
    }

    /// Deconstructs into the stf: the forward schedule hands the
    /// machine back to its owner between windows.
    pub fn into_stf(self) -> S {
        self.stf
    }

    pub fn state_hash(&mut self) -> Result<Digest> {
        self.stf.state_hash()
    }

    /// Advance to `to` without collecting: the big-architecture
    /// shortcut for whole big cycles, uarch steps for the remainder.
    /// Nothing samples, so nothing is hashed along the way; the coarse
    /// leg chunks at window granularity (the only boundaries where the
    /// coarse loop must stop anyway).
    pub fn advance(&mut self, to: U256) -> Result<()> {
        let c = self.structure.log2_uarch_span;
        let one = U256::from(1);
        let big_ceil = ((self.position + (one << c) - one) >> c) << c;
        let big_floor = (to >> c) << c;
        if big_ceil < big_floor {
            self.step_until(big_ceil, &mut |_, _| Ok(()))?;
            let chunk = self.structure.log2_window_span();
            self.coarse_step_until(big_floor, chunk, &mut |_, _| Ok(()))?;
        }
        self.step_until(to, &mut |_, _| Ok(()))
    }

    /// Advance to `to`, sampling the post-state every 2^log2_stride
    /// transitions. Position and `to` must be stride-aligned so the
    /// samples land on quartet boundaries. Sampling at or above big
    /// cycles rides the big architecture; finer sampling steps the
    /// uarch.
    pub fn collect(&mut self, to: U256, log2_stride: u64) -> Result<Vec<Run>> {
        let stride = U256::from(1) << log2_stride;
        assert!((self.position % stride).is_zero(), "unaligned start");
        assert!((to % stride).is_zero(), "unaligned end");
        let mut sampler = StrideSampler::new(self.position, log2_stride);
        if log2_stride >= self.structure.log2_uarch_span {
            self.coarse_step_until(to, log2_stride, &mut |leaf, count| {
                sampler.feed(leaf, count)
            })?;
        } else {
            self.step_until(to, &mut |leaf, count| sampler.feed(leaf, count))?;
        }
        Ok(sampler.finish())
    }

    /// The core loop. `emit(leaf, n)` reports that the next n
    /// transitions all produced `leaf`; consumers pull live hashes only
    /// when a sample lands in the run, so unsampled stretches cost no
    /// hashing. Whole idle big cycles replay one captured span; every
    /// other position, including partial idle spans, executes
    /// transition by transition.
    fn step_until(
        &mut self,
        to: U256,
        emit: &mut impl FnMut(Leaf<'_, S>, U256) -> Result<()>,
    ) -> Result<()> {
        assert!(self.position <= to, "ruler cannot move backwards");
        assert!(to <= self.structure.ruler_span(), "past the epoch's end");

        let big_span = U256::from(self.structure.big_span());
        let one = U256::from(1);

        while self.position < to {
            let p = self.structure.decompose(self.position);
            let has_input = p.input < self.fed_windows;
            let feeds_now = p.is_window_start() && has_input;

            if p.is_big_start() {
                let halted = self.stf.halted()?;
                if halted || (self.stf.yielded()? && !feeds_now) {
                    // Idle until the next fed window (never, when
                    // halted). Whole cycles replay one captured span; a
                    // trailing partial cycle steps plainly below.
                    let idle_end = if halted {
                        to
                    } else {
                        let next_window = p.input + 1;
                        let next_feed = if next_window < self.fed_windows {
                            self.structure.window_start(next_window)
                        } else {
                            to
                        };
                        next_feed.min(to)
                    };
                    let cycles = (idle_end - self.position) / big_span;
                    if !cycles.is_zero() {
                        self.replay_idle_cycles(cycles, emit)?;
                        continue;
                    }
                } else if p.is_window_start() {
                    if self.stf.yielded()? {
                        // Fused transition: feed plus the first ustep.
                        self.stf.feed(p.input)?;
                        self.stf.ustep()?;
                        emit(Leaf::Live(&mut self.stf), one)?;
                        self.position += one;
                        continue;
                    }
                    panic!(
                        "input overran its window at position {}; \
                         transition shape undefined (see module doc)",
                        self.position
                    );
                }
            }

            if p.is_closing_slot(&self.structure) {
                // Closing slot: (identity when uarch already halted)
                // ustep, ureset, then the revert check.
                self.stf.ustep()?;
                self.stf.ureset()?;
                if self.stf.yielded()? {
                    self.stf.revert_if_needed()?;
                }
                emit(Leaf::Live(&mut self.stf), one)?;
                self.position += one;
            } else if self.stf.uarch_halted()? {
                // Identity usteps until the closing slot.
                let skip =
                    U256::from(self.structure.big_span() - 1 - p.ustep).min(to - self.position);
                emit(Leaf::Live(&mut self.stf), skip)?;
                self.position += skip;
            } else {
                self.stf.ustep()?;
                emit(Leaf::Live(&mut self.stf), one)?;
                self.position += one;
            }
        }
        Ok(())
    }

    /// Emits `cycles` whole idle big cycles from a big-aligned
    /// position. Steps one span to capture the churn pattern - the
    /// machine ends back at its base state, which is also its exact
    /// state at every big boundary of the region - then replays it
    /// arithmetically. Output size is proportional to the sampled
    /// runs, which is the true leaf structure at sub-big strides.
    fn replay_idle_cycles(
        &mut self,
        cycles: U256,
        emit: &mut impl FnMut(Leaf<'_, S>, U256) -> Result<()>,
    ) -> Result<()> {
        let big_span = U256::from(self.structure.big_span());
        let pattern = self.collect_idle_span()?;
        let mut remaining = cycles;
        while !remaining.is_zero() {
            for run in &pattern {
                emit(Leaf::Known(run.hash), run.repetitions)?;
            }
            self.position += big_span;
            remaining -= U256::from(1);
        }
        Ok(())
    }

    /// One idle uarch span, stepped: churn usteps until the uarch
    /// halts, arithmetic padding, and the closing ureset (with its
    /// revert check) restoring the base state.
    fn collect_idle_span(&mut self) -> Result<Vec<Run>> {
        fn push(runs: &mut Vec<Run>, hash: Digest, count: u64) {
            match runs.last_mut() {
                Some(last) if last.hash == hash => last.repetitions += U256::from(count),
                _ => runs.push(Run {
                    hash,
                    repetitions: U256::from(count),
                }),
            }
        }

        let big_span = self.structure.big_span();
        let mut runs = vec![];
        let mut slot = 0u64;
        while slot < big_span - 1 && !self.stf.uarch_halted()? {
            self.stf.ustep()?;
            slot += 1;
            push(&mut runs, self.stf.state_hash()?, 1);
        }
        if slot < big_span - 1 {
            push(&mut runs, self.stf.state_hash()?, big_span - 1 - slot);
        }
        // The closing slot.
        self.stf.ustep()?;
        self.stf.ureset()?;
        if self.stf.yielded()? {
            self.stf.revert_if_needed()?;
        }
        push(&mut runs, self.stf.state_hash()?, 1);
        Ok(runs)
    }
}

impl<S: Stf> Ruler<S> {
    /// The coarse loop: valid only when every sampled position is a
    /// big-cycle end (log2_stride >= log2_uarch_span). Emits runs at
    /// chunk granularity, where a chunk never crosses a sample boundary
    /// or a window boundary; intermediate big-cycle hashes inside a
    /// chunk are never sampled, so attributing the chunk's end hash to
    /// the whole chunk is exact where it matters. An early stop inside
    /// a chunk leaves the machine idle, and idle machines carry their
    /// base hash at every big boundary, so the end hash is exact there
    /// too.
    fn coarse_step_until(
        &mut self,
        to: U256,
        log2_stride: u64,
        emit: &mut impl FnMut(Leaf<'_, S>, U256) -> Result<()>,
    ) -> Result<()> {
        let structure = self.structure;
        let c = structure.log2_uarch_span;
        assert!(log2_stride >= c, "coarse mode needs big-cycle sampling");
        assert!(self.position <= to, "ruler cannot move backwards");
        assert!(to <= structure.ruler_span(), "past the epoch's end");
        assert!(
            (self.position % (U256::from(1) << c)).is_zero(),
            "coarse mode needs big-cycle alignment"
        );

        let one = U256::from(1);

        while self.position < to {
            let p = structure.decompose(self.position);
            let has_input = p.input < self.fed_windows;

            if self.stf.halted()? {
                let n = to - self.position;
                emit(Leaf::Live(&mut self.stf), n)?;
                self.position = to;
                break;
            }
            if self.stf.yielded()? {
                let feeds_now = p.is_window_start() && has_input;
                if !feeds_now {
                    let next_window = p.input + 1;
                    let next_feed = if next_window < self.fed_windows {
                        structure.window_start(next_window)
                    } else {
                        to
                    };
                    let stop = next_feed.min(to);
                    let n = stop - self.position;
                    assert!(!n.is_zero(), "yielded with nothing to do");
                    emit(Leaf::Live(&mut self.stf), n)?;
                    self.position = stop;
                    continue;
                }
                // The feed is part of the window's first transition; its
                // fused ustep is subsumed by running big cycle 0 whole.
                self.stf.feed(p.input)?;
            } else if p.is_window_start() {
                panic!(
                    "input overran its window at position {}; \
                     invariant violated (see module doc)",
                    self.position
                );
            }

            let next_sample = ((self.position >> log2_stride) + one) << log2_stride;
            let window_end = structure.window_start(p.input + 1);
            let chunk_end = next_sample.min(window_end).min(to);

            let mut remaining = (chunk_end - self.position) >> c;
            while !remaining.is_zero() {
                let batch = if remaining > U256::from(u64::MAX) {
                    u64::MAX
                } else {
                    u64::try_from(remaining).expect("bounded by u64::MAX")
                };
                let ran = self.stf.run_big(batch)?;
                remaining -= U256::from(ran);
                if ran < batch {
                    break;
                }
            }
            if self.stf.yielded()? {
                self.stf.revert_if_needed()?;
            }
            emit(Leaf::Live(&mut self.stf), chunk_end - self.position)?;
            self.position = chunk_end;
        }
        Ok(())
    }
}

impl<S: ProvingStf> Ruler<S> {
    /// Proves the transition at the current position: the chain
    /// witness for exactly one of the three shapes the ruler names,
    /// plus the post-transition state hash. The caller positions the
    /// ruler (a snapshot resume plus advance) and checks the machine
    /// against the on-chain agree hash first; the machine is spent
    /// afterwards. Each proving verb applies the same state change as
    /// its plain twin - including the closing slot's revert - so the
    /// reported post-state is the leaf the builder emitted there.
    pub fn prove_transition(&mut self) -> Result<(Vec<u8>, Digest)> {
        let p = self.structure.decompose(self.position);

        let proof = if p.is_window_start() {
            // The window-opening transition: data availability (plus
            // checkpoint and delivery when the window feeds) and the
            // fused first ustep.
            let feed_proof = self.stf.log_feed(p.input)?;
            [feed_proof, self.stf.log_ustep()?].concat()
        } else if p.is_closing_slot(&self.structure) {
            // The closing slot: the (identity) ustep, the ureset, and
            // the revert witness.
            assert!(
                self.stf.uarch_halted()?,
                "the uarch must have halted before its closing slot"
            );
            [
                self.stf.log_ustep()?,
                self.stf.log_ureset()?,
                self.stf.log_revert_check()?,
            ]
            .concat()
        } else {
            self.stf.log_ustep()?
        };

        Ok((proof, self.stf.state_hash()?))
    }
}

/// Compresses a stream of per-transition post-state runs into sampled
/// runs at a stride: sample j is the post-state at position
/// (j + 1) * 2^log2_stride - 1. Pulls the state hash only for runs
/// that contain at least one sample.
struct StrideSampler {
    log2_stride: u64,
    position: U256,
    out: Vec<Run>,
}

impl StrideSampler {
    fn new(position: U256, log2_stride: u64) -> Self {
        StrideSampler {
            log2_stride,
            position,
            out: vec![],
        }
    }

    fn feed<S: Stf>(&mut self, leaf: Leaf<'_, S>, count: U256) -> Result<()> {
        let lo = self.position;
        let hi = lo + count;
        // Samples in [lo, hi) are the positions p with (p + 1) divisible
        // by the stride, i.e. the stride multiples in (lo, hi].
        let n = (hi >> self.log2_stride) - (lo >> self.log2_stride);
        if !n.is_zero() {
            let hash = leaf.digest()?;
            match self.out.last_mut() {
                Some(last) if last.hash == hash => last.repetitions += n,
                _ => self.out.push(Run {
                    hash,
                    repetitions: n,
                }),
            }
        }
        self.position = hi;
        Ok(())
    }

    fn finish(self) -> Vec<Run> {
        self.out
    }
}

/// Provides rulers positioned anywhere on the epoch. Implementations
/// own the positioning strategy: the toy replays from the start, the
/// machine implementation will resume from the nearest snapshot.
pub trait RulerFactory {
    type S: Stf;
    fn ruler_at(&mut self, position: U256) -> Result<Ruler<Self::S>>;
}

/// Toy factory: each scripted input is one epoch input (payloads are
/// irrelevant to the toy).
pub struct ToyFactory {
    pub structure: Structure,
    pub script: Vec<ToyInput>,
}

impl RulerFactory for ToyFactory {
    type S = ToyStf;

    fn ruler_at(&mut self, position: U256) -> Result<Ruler<ToyStf>> {
        let stf = ToyStf::new(self.structure, self.script.clone());
        let mut ruler = Ruler::new(stf, self.structure, self.script.len() as u64);
        ruler.advance(position)?;
        Ok(ruler)
    }
}
