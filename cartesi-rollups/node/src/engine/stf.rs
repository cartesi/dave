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

use super::structure::Structure;
use crate::merkle::Digest;
use anyhow::Result;

pub trait Stf {
    /// Hash of the current state. This is what commitment leaves are
    /// made of.
    fn state_hash(&mut self) -> Result<Digest>;

    /// Machine halted.
    fn halted(&mut self) -> Result<bool>;

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
    /// The default composes the uarch verbs.
    fn run_big(&mut self, big_cycles: u64) -> Result<u64> {
        let mut executed = 0;
        while executed < big_cycles && !self.terminal()? && !self.yielded()? {
            while !self.uarch_halted()? {
                self.ustep()?;
            }
            self.ureset()?;
            executed += 1;
        }
        Ok(executed)
    }
}

/// The proving verbs: each mirrors a plain verb, performing the same
/// state change while emitting the chain-encoded witness the on-chain
/// state transition consumes. The byte layout is consensus-critical -
/// it must match what prt/contracts' state-transition decodes - and is
/// pinned by a differential test against the prototype proof path plus
/// the stf e2e scenarios, which drive every shape through the chain.
///
/// Only the real machine's witnesses mean anything to the chain. The
/// toy implements these verbs with inert marker bytes so the proof
/// PATH (positioning, the agree-state check, shape selection) can run
/// under the toy in unit tests; nothing consumes toy bytes.
pub trait ProvingStf: Stf {
    /// The window-opening witness: the data-availability encoding of
    /// window `window`'s input (empty when the window has none) and,
    /// when it does, the input-delivery log that also records the
    /// revert root. The implementation resolves
    /// the window to its payload, as with [`Stf::feed`]. The fused
    /// first ustep is logged separately by [`ProvingStf::log_ustep`].
    fn log_feed(&mut self, window: u64) -> Result<Vec<u8>>;

    /// One uarch cycle, with its access log.
    fn log_ustep(&mut self) -> Result<Vec<u8>>;

    /// The uarch reset, including rejected-input substitution, with its
    /// access log.
    fn log_ureset(&mut self) -> Result<Vec<u8>>;
}

/// How a toy input's processing ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToyOutcome {
    Accept,
    Reject,
    Halt,
}

/// Per-input script: how many active usteps each big cycle runs before
/// its uarch halts (the remaining slots repeat, the last slot is the
/// ureset), and how processing ends after the final big cycle. The
/// final big cycle models the yield (or halt) instruction itself, so
/// the machine is yielded (halted) as of that cycle's ureset.
#[derive(Debug, Clone)]
pub struct ToyInput {
    pub big_cycles: Vec<u64>,
    pub outcome: ToyOutcome,
}

/// Idle churn ticks per idle uarch span: how many usteps the toy's
/// "interpreter" spends noticing the machine is yielded or halted
/// before its uarch halts. The real machine spends a few dozen; one
/// tick keeps toy trees hand-computable while modeling the shape.
pub const IDLE_CHURN_TICKS: u64 = 1;

/// The toy state-transition function. Its state hash is a counter
/// encoded as bytes32, incremented on every state-changing transition,
/// so on a fully active script the state after transition N is N + 1
/// (with initial state 0). A revert restores the counter to the
/// window's checkpoint. Idle spans (machine yielded or halted) churn a
/// uarch-local tick that colors the hash without touching the counter;
/// the ureset clears it, restoring the base hash, mirroring the real
/// machine's idle periodicity. This keeps expected trees computable by
/// hand in the spec tests.
#[derive(Debug, Clone)]
pub struct ToyStf {
    script: Vec<ToyInput>,

    counter: u64,
    halted: bool,
    yielded: bool,
    uarch_halted: bool,
    /// Idle churn ticks since the last ureset; nonzero only inside an
    /// idle uarch span.
    uticks: u64,

    // Current input bookkeeping, valid between feed and yield/halt.
    fed: usize,
    checkpoint: u64,
    outcome: ToyOutcome,
    big_cycles: Vec<u64>,
    current_big_cycle: usize,
    usteps_in_big_cycle: u64,
}

impl ToyStf {
    /// A pristine toy at the epoch's start: yielded, awaiting input 0,
    /// counter (and thus implicit hash) zero.
    pub fn new(structure: Structure, script: Vec<ToyInput>) -> Self {
        structure.assert_valid();
        for input in &script {
            assert!(!input.big_cycles.is_empty(), "input needs a big cycle");
            assert!(
                input.big_cycles[0] >= 1,
                "big cycle 0 needs an active ustep (the fused feed)"
            );
            for &k in &input.big_cycles {
                assert!(
                    k < structure.big_span(),
                    "usteps must fit before the ureset slot"
                );
            }
        }
        assert!(
            IDLE_CHURN_TICKS < structure.big_span() - 1,
            "idle churn must fit before the closing slot"
        );
        ToyStf {
            script,
            counter: 0,
            halted: false,
            yielded: true,
            uarch_halted: false,
            uticks: 0,
            fed: 0,
            checkpoint: 0,
            outcome: ToyOutcome::Accept,
            big_cycles: vec![],
            current_big_cycle: 0,
            usteps_in_big_cycle: 0,
        }
    }

    pub fn counter(&self) -> u64 {
        self.counter
    }

    /// The hash of a base state (no idle churn in flight).
    pub fn hash_of(counter: u64) -> Digest {
        Self::churned_hash_of(counter, 0)
    }

    /// The hash of a state mid-idle-span: the counter colored by the
    /// uarch-local churn ticks.
    pub fn churned_hash_of(counter: u64, uticks: u64) -> Digest {
        let mut data = [0u8; 32];
        data[16..24].copy_from_slice(&uticks.to_be_bytes());
        data[24..].copy_from_slice(&counter.to_be_bytes());
        Digest::from_digest(&data).expect("32 bytes")
    }

    fn fixed(&self) -> bool {
        self.halted || self.yielded
    }
}

impl Stf for ToyStf {
    fn state_hash(&mut self) -> Result<Digest> {
        Ok(Self::churned_hash_of(self.counter, self.uticks))
    }

    fn halted(&mut self) -> Result<bool> {
        Ok(self.halted)
    }

    fn yielded(&mut self) -> Result<bool> {
        Ok(self.yielded)
    }

    fn terminal(&mut self) -> Result<bool> {
        Ok(self.halted)
    }

    fn uarch_halted(&mut self) -> Result<bool> {
        Ok(self.uarch_halted)
    }

    fn feed(&mut self, window: u64) -> Result<()> {
        assert!(
            self.yielded && !self.halted,
            "feed requires a yielded machine"
        );
        assert_eq!(
            window as usize, self.fed,
            "windows feed sequentially from the resume point"
        );
        let scripted = self
            .script
            .get(self.fed)
            .expect("toy script must cover every fed input")
            .clone();
        self.fed += 1;
        self.checkpoint = self.counter;
        self.outcome = scripted.outcome;
        self.big_cycles = scripted.big_cycles;
        self.current_big_cycle = 0;
        self.usteps_in_big_cycle = 0;
        self.yielded = false;
        self.uarch_halted = false;
        Ok(())
    }

    fn ustep(&mut self) -> Result<()> {
        if self.uarch_halted {
            return Ok(());
        }
        if self.fixed() {
            // Idle churn: uarch-local only.
            self.uticks += 1;
            if self.uticks == IDLE_CHURN_TICKS {
                self.uarch_halted = true;
            }
            return Ok(());
        }
        self.counter += 1;
        self.usteps_in_big_cycle += 1;
        if self.usteps_in_big_cycle == self.big_cycles[self.current_big_cycle] {
            self.uarch_halted = true;
        }
        Ok(())
    }

    fn ureset(&mut self) -> Result<()> {
        if self.fixed() {
            // An idle span closes: the churn unwinds, the base state
            // returns, and the script does not progress.
            assert!(self.uarch_halted, "idle churn must halt the uarch");
            self.uticks = 0;
            self.uarch_halted = false;
            return Ok(());
        }
        assert!(
            self.uarch_halted,
            "toy script must halt the uarch before the ureset slot"
        );
        self.counter += 1;
        self.uarch_halted = false;
        self.usteps_in_big_cycle = 0;
        self.current_big_cycle += 1;
        if self.current_big_cycle == self.big_cycles.len() {
            // This big cycle was the yield (or halt) instruction.
            match self.outcome {
                ToyOutcome::Accept => self.yielded = true,
                ToyOutcome::Reject => {
                    self.counter = self.checkpoint;
                    self.yielded = true;
                }
                ToyOutcome::Halt => self.halted = true,
            }
        }
        Ok(())
    }
}

/// Toy witnesses: inert marker bytes over the exact plain-verb state
/// changes, so the Hero's proof path (positioning, agree-state check,
/// shape selection) runs under the toy. Tests may assert which shape
/// was proved from the markers alone.
impl ProvingStf for ToyStf {
    fn log_feed(&mut self, window: u64) -> Result<Vec<u8>> {
        if (window as usize) < self.script.len() {
            self.feed(window)?;
        }
        Ok(b"toy-feed;".to_vec())
    }

    fn log_ustep(&mut self) -> Result<Vec<u8>> {
        self.ustep()?;
        Ok(b"toy-ustep;".to_vec())
    }

    fn log_ureset(&mut self) -> Result<Vec<u8>> {
        self.ureset()?;
        Ok(b"toy-ureset;".to_vec())
    }
}
