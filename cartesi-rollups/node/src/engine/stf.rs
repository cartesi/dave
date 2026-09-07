// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The machine-verbs boundary between the geometry engine and a concrete
//! state-transition function.
//!
//! The Ruler orchestrates these verbs by meta-cycle position; the
//! implementation supplies the machine mechanics. Production wraps the
//! Cartesi machine; the toy makes the geometry hand-checkable. Verbs are
//! fallible: machine errors propagate as errors, while geometry
//! violations (a feed on a running machine, a ureset off-boundary)
//! remain panics - those are engine bugs, not machine conditions.

use crate::merkle::Digest;
use anyhow::Result;

pub trait Stf {
    /// Hash of the current state. This is what commitment leaves are
    /// made of.
    fn state_hash(&mut self) -> Result<Digest>;

    /// Machine yielded with RX_ACCEPTED and is awaiting input.
    fn yielded(&mut self) -> Result<bool>;

    /// A terminal fixed point: halt, exception, unexpected manual yield,
    /// or mcycle overflow. No later input can resume execution.
    fn terminal(&mut self) -> Result<bool>;

    /// The uarch finished emulating the current big instruction; usteps
    /// are identity until the closing ureset.
    fn uarch_halted(&mut self) -> Result<bool>;

    /// Feed window `window`'s input, recording the pre-feed root as the
    /// response's revert root. Valid only when awaiting input, and
    /// only for windows that feed (the geometry passes the window
    /// index; the implementation owns the payloads - the machine
    /// fetches from the input store, the toy consults its script -
    /// and cross-checks the index against its own cursor). Its state
    /// change surfaces through the post-state of the fused first
    /// ustep.
    fn feed(&mut self, window: u64) -> Result<()>;

    /// One uarch cycle. Identity only when the uarch is halted: the
    /// big machine's yield and halt flags do not gate the uarch, so
    /// stepping an idle machine churns the uarch's own bookkeeping (the
    /// emulated interpreter checks the flags and declines to execute)
    /// until the uarch halts, without touching the big state.
    fn ustep(&mut self) -> Result<()>;

    /// Reset the uarch, completing a big cycle. A rejected input's
    /// canonical post-state is its recorded revert root, so implementations
    /// with a mutable physical machine restore their pre-feed snapshot here.
    /// On an idle machine the post-reset state equals the state before the
    /// span: idle churn is uarch-local, which is what makes idle spans
    /// periodic.
    fn ureset(&mut self) -> Result<()>;

    /// The big-architecture shortcut: run up to `big_cycles` whole big
    /// cycles, stopping early at yield or halt, returning how many ran.
    /// The machine-swapping equivalence makes one big step identical to
    /// a full uarch span plus its reset, so implementations may run the
    /// big machine directly. Idle cycles do not count: the big machine
    /// does not advance while yielded or halted (idle uarch spans are
    /// state-preserving, so skipping them is exact at big boundaries).
    fn run_big(&mut self, big_cycles: u64) -> Result<u64>;

    // Logged operations apply the same transitions and emit the witness
    // encoding consumed by the on-chain state transition. Machine
    // differentials and STF e2e tests check that separate contract.

    /// The window-opening witness: the data-availability encoding of
    /// window `window`'s input (empty when the window has none) and,
    /// when it does, the input-delivery log that also records the
    /// revert root. The implementation resolves
    /// the window to its payload, as with [`Stf::feed`]. The fused
    /// first ustep is logged separately by [`Stf::log_ustep`].
    fn log_feed(&mut self, window: u64) -> Result<Vec<u8>>;

    /// One uarch cycle, with its access log.
    fn log_ustep(&mut self) -> Result<Vec<u8>>;

    /// The uarch reset, including rejected-input substitution, with its
    /// access log.
    fn log_ureset(&mut self) -> Result<Vec<u8>>;
}
