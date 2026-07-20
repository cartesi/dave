// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The reference collector: the [`Stf`] verbs implemented on the real
//! Cartesi machine through the current (0.20) API, one step at a time.
//!
//! This is deliberately the slow, obviously-correct implementation. It
//! exists to be validated against the prototype's commitment builder
//! (the only oracle available today) and to serve, permanently, as the
//! differential reference for the fast bulk collectors that arrive with
//! emulator 0.21. Machine errors propagate as errors; geometry
//! violations remain panics (see the stf module doc).

use super::dispute::DisputeSource;
use super::ruler::{Ruler, RulerFactory};
use super::stf::{ProvingStf, Stf};
use super::structure::Structure;
use crate::arithmetic::add_and_clamp;
use crate::engine::constants::CHECKPOINT_ADDRESS;
use crate::merkle::Digest;
use crate::storage::{InputId, Storage};
use alloy::primitives::U256;
use anyhow::{Context, Result, ensure};
use cartesi_machine::{
    cartesi_machine_sys,
    config::runtime::RuntimeConfig,
    constants::cmio::tohost::manual::{RX_ACCEPTED, RX_REJECTED, TX_EXCEPTION},
    constants::machine::HASH_TREE_LOG2_ROOT_SIZE,
    format_emulator_version,
    machine::Machine,
    types::{LogType, access_proof::AccessLog, cmio::CmioResponseReason},
};
use std::path::{Path, PathBuf};

/// Where feed's payloads and its pre-feed snapshot live - both are
/// aspects of the one fused verb. Scratch carries explicit payload
/// vectors and per-ruler checkpoint dirs (the storage-less
/// harnesses: measure, the differential tests). Store is the dispute
/// path's mode: payloads come from the inputs table and the pre-feed
/// snapshot commits into the boundary store, where it doubles as
/// dispute densification and the row insert as a cross-regime
/// nondeterminism tripwire. Advance is the machine runner's mode:
/// one window, its payload handed in (the runner already read the
/// inputs table to schedule it), and the pre-feed snapshot IS the
/// batch's committed boundary directory - never a store; a revert
/// restores through the boundary store's own artifact.
enum Feeder {
    Scratch {
        fed: usize,
        inputs: Vec<Vec<u8>>,
    },
    Store {
        storage: Storage,
        epoch: u64,
        next_input: u64,
    },
    Advance {
        window: u64,
        payload: Option<Vec<u8>>,
        boundary: PathBuf,
        reverted: bool,
    },
}

pub struct MachineStf {
    machine: Machine,
    /// Uarch cycles since the last reset; run_uarch takes absolutes.
    ucycle: u64,
    /// Scratch-mode checkpoints live here; one at a time.
    work_dir: PathBuf,
    checkpoint: Option<PathBuf>,
    feeder: Feeder,
}

impl MachineStf {
    /// Loads a template machine (the epoch's initial state). It must be
    /// yielded awaiting the first input, with a pristine uarch.
    pub fn load(template_path: &Path, work_dir: PathBuf) -> Result<Self> {
        // resume already validates the pristine uarch
        let mut stf = Self::resume(template_path, work_dir)?;
        ensure!(
            stf.machine.iflags_y()?,
            "template machine must be yielded awaiting input"
        );
        Ok(stf)
    }

    /// Resumes a stored machine mid-epoch (a boundary-store answer).
    /// Positions are big-cycle boundaries, so the uarch must be
    /// pristine, but the machine may be in any big state.
    pub fn resume(path: &Path, work_dir: PathBuf) -> Result<Self> {
        let mut machine = Machine::load(path, &RuntimeConfig::quiet_console())
            .context("failed to load stored machine")?;
        ensure!(
            machine.ucycle()? == 0,
            "stored machine must sit at a big-cycle boundary"
        );
        std::fs::create_dir_all(&work_dir).context("work dir")?;
        Ok(MachineStf {
            machine,
            ucycle: 0,
            work_dir,
            checkpoint: None,
            feeder: Feeder::Scratch {
                fed: 0,
                inputs: vec![],
            },
        })
    }

    /// Scratch-mode payloads for the windows this stf will feed
    /// (index 0 is the first window fed from here). Panics in store
    /// mode, which carries payloads from the inputs table.
    pub fn with_inputs(mut self, payloads: Vec<Vec<u8>>) -> Self {
        match &mut self.feeder {
            Feeder::Scratch { inputs, .. } => *inputs = payloads,
            _ => panic!("only the scratch feeder carries payload vectors"),
        }
        self
    }

    /// The machine runner's stf: wraps the live working-clone machine
    /// the caller owns (SHARING_ALL, mutated in place, sitting at
    /// `window`'s boundary), feeds exactly that window, and restores
    /// a revert from `boundary` - the batch's committed pre-input
    /// directory. No filesystem effects of its own; the counterpart
    /// of [`MachineStf::into_machine`].
    pub fn over_advancing(
        machine: Machine,
        window: u64,
        payload: Vec<u8>,
        boundary: PathBuf,
    ) -> Self {
        MachineStf {
            machine,
            ucycle: 0,
            // Advance mode never writes scratch checkpoints; an empty
            // path fails loudly if a bug ever routes there.
            work_dir: PathBuf::new(),
            checkpoint: None,
            feeder: Feeder::Advance {
                window,
                payload: Some(payload),
                boundary,
                reverted: false,
            },
        }
    }

    /// Deconstructs into the wrapped machine: the working clone
    /// (accepted window) or the boundary-restored instance (reverted
    /// window), which the caller's record verbs swap out anyway.
    pub fn into_machine(self) -> Machine {
        self.machine
    }

    /// Whether the last fed window reverted (advance mode only; the
    /// dispute path replays reverts positionally and never asks).
    pub fn took_revert(&self) -> bool {
        matches!(self.feeder, Feeder::Advance { reverted: true, .. })
    }

    /// Upgrades the feeder into the node's storage: this machine sits
    /// at `next_input`'s boundary of `epoch`; every window it feeds
    /// from here reads its payload from the inputs table and commits
    /// the crossed boundary.
    pub fn with_write_back(mut self, storage: Storage, epoch: u64, next_input: u64) -> Self {
        self.feeder = Feeder::Store {
            storage,
            epoch,
            next_input,
        };
        self
    }

    /// Stores the machine; the counterpart of resume.
    pub fn store(&mut self, path: &Path) -> Result<()> {
        self.machine.store(path)?;
        Ok(())
    }

    fn fixed(&mut self) -> Result<bool> {
        Ok(self.halted()? || self.yielded()?)
    }
}

impl Stf for MachineStf {
    fn state_hash(&mut self) -> Result<Digest> {
        Ok(self.machine.root_hash()?.into())
    }

    fn halted(&mut self) -> Result<bool> {
        Ok(self.machine.iflags_h()?)
    }

    fn yielded(&mut self) -> Result<bool> {
        Ok(self.machine.iflags_y()?)
    }

    fn uarch_halted(&mut self) -> Result<bool> {
        Ok(self.machine.uarch_halt_flag()?)
    }

    fn feed(&mut self, window: u64) -> Result<()> {
        assert!(self.yielded()? && !self.halted()?, "feed requires yielded");

        // Snapshot the pre-feed state: the off-chain form of the
        // checkpoint the on-chain revert reads from the shadow slot.
        // The snapshot predates the slot write below, matching what
        // the on-chain revert restores (the pre-checkpoint root).
        let root = self.machine.root_hash()?;
        let (checkpoint, payload) = match &mut self.feeder {
            Feeder::Scratch { fed, inputs } => {
                assert_eq!(
                    window as usize, *fed,
                    "windows feed sequentially from the resume point"
                );
                let path = self.work_dir.join(format!("checkpoint-{fed}"));
                *fed += 1;
                self.machine.store(&path).context("store checkpoint")?;
                if let Some(old) = self.checkpoint.take() {
                    std::fs::remove_dir_all(old).ok();
                }
                let payload = inputs
                    .get(window as usize)
                    .cloned()
                    .expect("scratch feeder must carry every fed payload");
                (path, payload)
            }
            Feeder::Store {
                storage,
                epoch,
                next_input,
            } => {
                assert_eq!(
                    window, *next_input,
                    "windows feed sequentially from the resume point"
                );
                *next_input += 1;
                let payload = storage
                    .input(&InputId {
                        epoch_number: *epoch,
                        input_index_in_epoch: window,
                    })?
                    .expect("fed windows lie in the ingested contiguous prefix")
                    .data;
                // The write-back: this boundary joins the store
                // (stored only where regime 1 has not already), and
                // the committed directory is the revert point -
                // never removed here, it is the store's.
                let dir =
                    storage.commit_boundary_machine(*epoch, window, &root, &mut self.machine)?;
                (dir, payload)
            }
            Feeder::Advance {
                window: expected,
                payload,
                boundary,
                reverted,
            } => {
                assert_eq!(
                    window, *expected,
                    "the advance stf feeds exactly its window"
                );
                *reverted = false;
                let payload = payload.take().expect("the advance stf feeds once");
                // The pre-feed state is already committed: it is the
                // boundary the working clone was checked out from.
                (boundary.clone(), payload)
            }
        };
        self.checkpoint = Some(checkpoint);

        self.machine.write_memory(CHECKPOINT_ADDRESS, &root)?;
        self.machine
            .send_cmio_response(CmioResponseReason::Advance, &payload)?;
        Ok(())
    }

    fn ustep(&mut self) -> Result<()> {
        if self.uarch_halted()? {
            return Ok(());
        }
        self.machine.run_uarch(self.ucycle + 1)?;
        self.ucycle += 1;
        Ok(())
    }

    fn ureset(&mut self) -> Result<()> {
        self.machine.reset_uarch()?;
        self.ucycle = 0;
        Ok(())
    }

    fn revert_if_needed(&mut self) -> Result<bool> {
        if !self.yielded()? {
            return Ok(false);
        }
        // The on-chain closing slot restores the checkpoint ONLY on
        // RX_REJECTED (AdvanceStatus + CmioStateTransition
        // .revertIfNeeded): an exception yield KEEPS the exception
        // state, and any other manual reason has no defined
        // transition on-chain (InvalidReason), so it is fatal here
        // too. Solidity is the source of truth for these semantics;
        // treating every non-accept as a revert was a consensus
        // mismatch (found 2026-07-15).
        let reason = self.machine.receive_cmio_request()?.reason();
        match reason {
            RX_ACCEPTED | TX_EXCEPTION => Ok(false),
            RX_REJECTED => {
                let checkpoint = self
                    .checkpoint
                    .as_ref()
                    .expect("revert requires a fed checkpoint");
                // Replacing the instance drops the old machine
                // (flushing and unlocking a shared working clone);
                // the poisoned directory is the caller's to discard.
                self.machine = Machine::load(checkpoint, &RuntimeConfig::quiet_console())
                    .context("reload checkpoint")?;
                self.ucycle = 0;
                if let Feeder::Advance { reverted, .. } = &mut self.feeder {
                    *reverted = true;
                }
                Ok(true)
            }
            other => panic!(
                "manual yield reason {other} has no defined state transition \
                 (the on-chain advanceStatus rejects it)"
            ),
        }
    }

    fn run_big(&mut self, big_cycles: u64) -> Result<u64> {
        assert_eq!(self.ucycle, 0, "run_big requires a big-cycle boundary");
        if big_cycles == 0 || self.fixed()? {
            return Ok(0);
        }
        let start = self.machine.mcycle()?;
        let target = add_and_clamp(start, big_cycles);
        loop {
            self.machine.run(target)?;
            if self.halted()? || self.yielded()? {
                break;
            }
            if self.machine.mcycle()? == target {
                break;
            }
        }
        Ok(self.machine.mcycle()? - start)
    }
}

// The chain witness encoding, byte-compatible with what the on-chain
// state transition decodes (and with the prototype proof path it
// replaces; the differential test in tests/engine_machine.rs pins the
// bytes).
impl MachineStf {
    fn prove_read_word(&mut self, address: u64) -> Result<Vec<u8>> {
        // always read aligned 32 bytes (one leaf)
        let aligned_address = address & !0x1Fu64;
        let mut read = self.machine.read_memory(aligned_address, 32)?;
        let proof = self
            .machine
            .proof(aligned_address, 5, HASH_TREE_LOG2_ROOT_SIZE)?;

        let mut encoded: Vec<u8> = Vec::new();
        encoded.append(&mut read);
        let mut decoded_siblings: Vec<u8> =
            proof.sibling_hashes.iter().flatten().cloned().collect();
        encoded.append(&mut decoded_siblings);

        Ok(encoded)
    }

    fn prove_read_leaf(&mut self, address: u64) -> Result<Vec<u8>> {
        // always read aligned 32 bytes (one leaf)
        let aligned_address = address & !0x1Fu64;
        let mut read = self.machine.read_memory(aligned_address, 32)?;
        let read_hash = Digest::from_data(&read);
        let proof = self
            .machine
            .proof(aligned_address, 5, HASH_TREE_LOG2_ROOT_SIZE)?;

        let mut encoded: Vec<u8> = Vec::new();
        encoded.append(&mut read);
        encoded.append(&mut read_hash.slice().to_vec());
        let mut decoded_siblings: Vec<u8> =
            proof.sibling_hashes.iter().flatten().cloned().collect();
        encoded.append(&mut decoded_siblings);

        Ok(encoded)
    }

    /// Proves the pre-write leaf value, then performs the checkpoint
    /// write (the current root hash into the shadow slot).
    fn prove_write_checkpoint(&mut self) -> Result<Vec<u8>> {
        let address = CHECKPOINT_ADDRESS;
        assert!(address & 0x1F == 0);
        let read = self.machine.read_memory(address, 32)?;
        let read_hash = Digest::from_data(&read);
        let proof = self.machine.proof(address, 5, HASH_TREE_LOG2_ROOT_SIZE)?;

        let mut encoded: Vec<u8> = Vec::new();
        encoded.append(&mut read_hash.slice().to_vec());
        let mut decoded_siblings: Vec<u8> =
            proof.sibling_hashes.iter().flatten().cloned().collect();
        encoded.append(&mut decoded_siblings);

        let checkpoint = self.state_hash()?;
        self.machine.write_memory(address, checkpoint.slice())?;

        Ok(encoded)
    }

    fn encode_access_log(log: &AccessLog) -> Vec<u8> {
        let mut encoded: Vec<Vec<u8>> = Vec::new();

        for a in log.accesses.iter() {
            if a.log2_size == 3 {
                encoded.push(a.read.clone().unwrap());
            } else {
                encoded.push(a.read_hash.to_vec());
            }

            let decoded_siblings: Vec<Vec<u8>> = a
                .sibling_hashes
                .clone()
                .unwrap()
                .iter()
                .map(|h| h.to_vec())
                .collect();
            encoded.extend_from_slice(&decoded_siblings);
        }

        encoded.iter().flatten().cloned().collect()
    }

    fn encode_da(input: &[u8]) -> Vec<u8> {
        let input_size_be = (input.len() as u64).to_be_bytes().to_vec();
        let mut da_proof = input_size_be;
        da_proof.extend_from_slice(input);
        da_proof
    }
}

impl ProvingStf for MachineStf {
    fn log_feed(&mut self, window: u64) -> Result<Vec<u8>> {
        // The proving path resolves the payload without touching the
        // feed cursor or the checkpoint: the machine is spent after
        // the proof.
        let payload = match &mut self.feeder {
            Feeder::Scratch { inputs, .. } => inputs.get(window as usize).cloned(),
            Feeder::Store { storage, epoch, .. } => storage
                .input(&InputId {
                    epoch_number: *epoch,
                    input_index_in_epoch: window,
                })?
                .map(|input| input.data),
            Feeder::Advance { .. } => {
                unreachable!("the advance stf collects forward; proving rides the dispute path")
            }
        };
        match payload {
            Some(input) => {
                let checkpoint_proof = self.prove_write_checkpoint()?;
                let cmio_log = self.machine.log_send_cmio_response(
                    CmioResponseReason::Advance,
                    &input,
                    LogType::default(),
                )?;
                Ok([
                    Self::encode_da(&input),
                    checkpoint_proof,
                    Self::encode_access_log(&cmio_log),
                ]
                .concat())
            }
            None => Ok(Self::encode_da(&[])),
        }
    }

    fn log_ustep(&mut self) -> Result<Vec<u8>> {
        let log = self.machine.log_step_uarch(LogType::default())?;
        self.ucycle += 1;
        Ok(Self::encode_access_log(&log))
    }

    fn log_ureset(&mut self) -> Result<Vec<u8>> {
        let log = self.machine.log_reset_uarch(LogType::default())?;
        self.ucycle = 0;
        Ok(Self::encode_access_log(&log))
    }

    fn log_revert_check(&mut self) -> Result<Vec<u8>> {
        let mut proof = Vec::new();

        let iflags_y_address =
            cartesi_machine::Machine::reg_address(cartesi_machine_sys::CM_REG_IFLAGS_Y)?;
        proof.append(&mut self.prove_read_word(iflags_y_address)?);

        if self.yielded()? {
            let to_host_address =
                cartesi_machine::Machine::reg_address(cartesi_machine_sys::CM_REG_HTIF_TOHOST)?;
            proof.append(&mut self.prove_read_word(to_host_address)?);

            // The chain consumes the checkpoint leaf only on the
            // REJECTED branch (getRevertRootHash); an exception yield
            // keeps its state and reads nothing more.
            if self.machine.receive_cmio_request()?.reason() == RX_REJECTED {
                proof.append(&mut self.prove_read_leaf(CHECKPOINT_ADDRESS)?);
            }
        }
        Ok(proof)
    }
}

/// The engine's positioning residue: a work dir, a spawn counter,
/// and the store handle they serve. Positions rulers by resuming
/// from the boundary store's nearest stored machine and advancing
/// the remainder. The store is live: boundaries recorded by any
/// writer (the open regime's gap fill, a future dispute write-back)
/// shorten the next positioning. On a freshly migrated store only
/// the epoch start exists, which is the full-replay behavior the
/// prototype had. Constructed only by [`DisputeSource::on_store`];
/// the type is public for signatures alone.
pub struct Positioner {
    structure: Structure,
    work_dir: PathBuf,
    /// How many windows feed (the inputs are a contiguous prefix);
    /// payloads stay in the inputs table, read at feed time.
    fed_windows: u64,
    store: Storage,
    epoch: u64,
    spawned: usize,
}

/// The production constructor of the facade: one closed epoch's
/// computation, assembled entirely from the node's durable state.
/// Lives beside the machine stf because only this impl block knows
/// how positioning constructs itself from storage; consumers hold no
/// engine pieces.
impl DisputeSource<Positioner> {
    pub fn on_store(mut storage: Storage, epoch: u64, work_dir: PathBuf) -> Result<Self> {
        // The migration pinned the config; assert engine
        // compatibility before serving any quartet.
        let structure = Structure::PRODUCTION;
        super::config::assert_compatible(
            &storage.sling_config()?,
            &structure,
            &format_emulator_version(Machine::version()),
        )?;

        let fed_windows = storage.input_count(epoch)?;

        let positioner = Positioner {
            structure,
            work_dir,
            fed_windows,
            // Its own store handle: one connection per holder, like
            // every Storage user.
            store: Storage::new(storage.state_dir())?,
            epoch,
            spawned: 0,
        };
        // The level-0 material was recorded at the rollups stride;
        // the source reads it (window-root rows, interior runs) from
        // storage on demand.
        DisputeSource::new(
            storage,
            positioner,
            epoch,
            crate::storage::rollups_machine::LOG2_STRIDE,
        )
    }
}

impl RulerFactory for Positioner {
    type S = MachineStf;

    fn ruler_at(&mut self, position: U256) -> Result<Ruler<MachineStf>> {
        let mut target = self.structure.decompose(position).input;
        let (boundary, stf) = loop {
            let (boundary, path) = self
                .store
                .nearest_boundary_at_or_before(self.epoch, target)?;

            let dir = self.work_dir.join(format!("stf-{}", self.spawned));
            self.spawned += 1;
            // A previous process may have left checkpoints here, and
            // the machine refuses to store over an existing directory.
            std::fs::remove_dir_all(&dir).ok();
            let mut stf = if boundary.0 == 0 {
                MachineStf::load(&path, dir)?
            } else {
                MachineStf::resume(&path, dir)?
            };

            // Assert-on-load: the emulator validates nothing, so the
            // loaded machine must reproduce its row's hash (nearly
            // free - committed boundaries carry exact sidecars). A
            // torn snapshot is skipped, not fatal: any earlier
            // boundary only lengthens the replay.
            let expected = self
                .store
                .snapshot_hash(self.epoch, boundary.0)?
                .expect("nearest answered from an existing row");
            if stf.state_hash()? == Digest::from_digest(&expected)? {
                break (boundary, stf);
            }
            log::error!(
                "stored boundary {} of epoch {} does not hash to its row: \
                 torn snapshot? skipping it",
                boundary.0,
                self.epoch
            );
            ensure!(boundary.0 > 0, "the epoch start snapshot is corrupt");
            target = boundary.0 - 1;
        };

        // The seam's one boundary-to-position conversion.
        let at = boundary.position(&self.structure);
        assert!(at <= position, "boundary store answered past the target");

        // Positioning densifies: every window boundary crossed on the
        // way to `position` commits through the store, so the next
        // ruler resumes at most one window away.
        let stf = stf.with_write_back(
            Storage::new(self.store.state_dir())?,
            self.epoch,
            boundary.0,
        );
        let mut ruler = Ruler::new_at(stf, self.structure, self.fed_windows, at);
        ruler.advance(position)?;
        Ok(ruler)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::constants;

    /// Drift guard: the engine structure and the machine constants must
    /// describe the same ruler.
    #[test]
    fn production_structure_matches_machine_constants() {
        let production = Structure::PRODUCTION;
        assert_eq!(
            production.log2_uarch_span,
            constants::LOG2_UARCH_SPAN_TO_BARCH
        );
        assert_eq!(
            production.log2_barch_span,
            constants::LOG2_BARCH_SPAN_TO_INPUT
        );
        assert_eq!(
            production.log2_input_span,
            constants::LOG2_INPUT_SPAN_TO_EPOCH
        );
    }

    /// Drift guard: the coordinate the runner prepays (window-root
    /// quartet rows at commit) must be the one the facade's top tier
    /// looks up - the source reads rows at (run stride, window
    /// height, shift = window) under its production run stride.
    #[test]
    fn runner_and_facade_agree_on_window_root_coordinates() {
        use crate::storage::rollups_machine;
        let structure = Structure::PRODUCTION;
        let quartet = rollups_machine::window_root_quartet(3, 7);
        assert_eq!(quartet.log2_stride, rollups_machine::LOG2_STRIDE);
        assert_eq!(
            quartet.height,
            structure.log2_window_span() - rollups_machine::LOG2_STRIDE
        );
        assert_eq!(quartet.shift, U256::from(7));
        assert_eq!(quartet.epoch, 3);
    }
}
