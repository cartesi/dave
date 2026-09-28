// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! A scripted machine for geometry and action-preparation unit tests.
//! Inert proof markers allow preparation without real machine witnesses.

use super::ruler::{Ruler, RulerFactory};
use super::stf::Stf;
use super::structure::Structure;
use crate::merkle::Digest;
use alloy::primitives::U256;
use anyhow::Result;

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

    /// Closing uresets executed: one per big cycle actually stepped, for
    /// cost assertions.
    uresets: u64,
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
            uresets: 0,
        }
    }

    pub fn uresets(&self) -> u64 {
        self.uresets
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
        self.uresets += 1;
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
