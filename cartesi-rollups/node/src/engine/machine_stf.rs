// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The reference collector: the [`Stf`] verbs implemented on the real
//! Cartesi machine through the current API, one step at a time.
//!
//! This is deliberately the slow, obviously-correct implementation. It
//! exists to be validated against the prototype and CLI commitment
//! builders and to serve, permanently, as the differential reference
//! for the fast bulk collectors. Machine errors propagate as errors; geometry
//! violations remain panics (see the stf module doc).

use super::dispute::DisputeSource;
use super::ruler::{Ruler, RulerFactory};
use super::stf::{ProvingStf, Stf};
use super::structure::Structure;
use crate::arithmetic::add_and_clamp;
use crate::merkle::Digest;
use crate::storage::{InputId, Storage};
use alloy::primitives::U256;
use anyhow::{Context, Result, ensure};
use cartesi_machine::{
    config::runtime::RuntimeConfig,
    constants::{
        break_reason,
        cmio::tohost::manual::{RX_ACCEPTED, RX_REJECTED},
    },
    format_emulator_version,
    machine::Machine,
    types::{
        LogType,
        access_proof::{AccessLog, AccessType},
        cmio::CmioResponseReason,
    },
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
            stf.yielded()?,
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

    fn manual_yield_reason(&mut self) -> Result<Option<u16>> {
        if !self.machine.iflags_y()? {
            return Ok(None);
        }
        Ok(Some(self.machine.receive_cmio_request()?.reason()))
    }

    fn mcycle_overflow(&mut self) -> Result<bool> {
        Ok(self.machine.mcycle()? >= self.machine.imcyclemax()?)
    }

    fn terminal_fixed(&mut self) -> Result<bool> {
        if self.halted()? || self.mcycle_overflow()? {
            return Ok(true);
        }
        Ok(matches!(
            self.manual_yield_reason()?,
            Some(reason) if reason != RX_ACCEPTED && reason != RX_REJECTED
        ))
    }

    /// A logged reset substitutes the canonical root on rejection, but
    /// the emulator deliberately leaves the physical machine reset in
    /// place. Reload the pre-feed snapshot so subsequent plain execution
    /// starts from that same canonical state.
    fn restore_rejected(&mut self) -> Result<bool> {
        if self.manual_yield_reason()? != Some(RX_REJECTED) {
            return Ok(false);
        }
        let checkpoint = self
            .checkpoint
            .clone()
            .expect("revert requires a fed checkpoint");
        self.machine = Machine::load(&checkpoint, &RuntimeConfig::quiet_console())
            .context("reload checkpoint")?;
        self.ucycle = 0;
        if let Feeder::Advance { reverted, .. } = &mut self.feeder {
            *reverted = true;
        }
        Ok(true)
    }

    fn fixed(&mut self) -> Result<bool> {
        Ok(self.terminal()? || self.yielded()?)
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
        Ok(self.manual_yield_reason()? == Some(RX_ACCEPTED))
    }

    fn terminal(&mut self) -> Result<bool> {
        self.terminal_fixed()
    }

    fn uarch_halted(&mut self) -> Result<bool> {
        Ok(self.machine.uarch_halt_flag()?)
    }

    fn feed(&mut self, window: u64) -> Result<()> {
        assert!(self.yielded()?, "feed requires a machine awaiting input");

        // Snapshot the pre-feed state. send_cmio_response records this
        // root in the shadow state, while the physical snapshot is what
        // lets the mutable machine follow the same revert off-chain.
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

        self.machine
            .send_cmio_response(CmioResponseReason::Advance, &payload, Some(&root))?;
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
        self.restore_rejected()?;
        Ok(())
    }

    fn run_big(&mut self, big_cycles: u64) -> Result<u64> {
        assert_eq!(self.ucycle, 0, "run_big requires a big-cycle boundary");
        if big_cycles == 0 || self.fixed()? {
            return Ok(0);
        }
        let start = self.machine.mcycle()?;
        let target = add_and_clamp(start, big_cycles);
        loop {
            let reason = self.machine.run(target)?;
            if self.machine.iflags_h()?
                || self.machine.iflags_y()?
                || reason == break_reason::MCYCLE_OVERFLOW
            {
                break;
            }
            if self.machine.mcycle()? == target {
                break;
            }
        }
        let ran = self.machine.mcycle()? - start;
        self.restore_rejected()?;
        Ok(ran)
    }
}

// The chain witness encoding, byte-compatible with what the on-chain
// state transition decodes (and with the prototype proof path it
// replaces; the differential test in tests/engine_machine.rs pins the
// bytes).
impl MachineStf {
    fn encode_access_log(log: &AccessLog) -> Vec<u8> {
        let mut encoded: Vec<Vec<u8>> = Vec::new();

        for a in log.accesses.iter() {
            if a.log2_size == 3 {
                encoded.push(
                    a.read
                        .clone()
                        .expect("word access must carry its read value"),
                );
            } else if matches!(&a.r#type, AccessType::Read) {
                let read = a
                    .read
                    .clone()
                    .expect("region read must carry its raw value");
                assert_eq!(read.len(), 32, "chain region reads are one bytes32 value");
                encoded.push(read);
                encoded.push(a.read_hash.to_vec());
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
                let revert_root = self.machine.root_hash()?;
                let cmio_log = self.machine.log_send_cmio_response(
                    CmioResponseReason::Advance,
                    &input,
                    &revert_root,
                    LogType::default(),
                )?;
                Ok([Self::encode_da(&input), Self::encode_access_log(&cmio_log)].concat())
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
        let proof = Self::encode_access_log(&log);
        self.restore_rejected()?;
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
    use crate::engine::constants::UARCH_MASK_TO_BARCH;
    use cartesi_machine::constants::rollup::{
        LOG2_MAX_ADVANCE_STATES_PER_EPOCH, LOG2_MAX_MCYCLES_PER_ADVANCE_STATE,
        LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
    };
    use cartesi_machine::types::access_proof::{Access, AccessLogType};

    fn access(r#type: AccessType, log2_size: u64, read: Option<Vec<u8>>, byte: u8) -> Access {
        Access {
            r#type,
            address: 0,
            log2_size,
            read_hash: [byte; 32],
            read,
            written_hash: None,
            written: None,
            sibling_hashes: Some(vec![]),
        }
    }

    #[test]
    fn chain_encoder_includes_region_read_value() {
        let log = AccessLog {
            log_type: AccessLogType::default(),
            accesses: vec![
                access(AccessType::Read, 3, Some(vec![1; 8]), 2),
                access(AccessType::Read, 5, Some(vec![3; 32]), 4),
                access(AccessType::Write, 5, None, 5),
            ],
            notes: None,
            brackets: None,
        };

        assert_eq!(
            MachineStf::encode_access_log(&log),
            [vec![1; 8], vec![3; 32], vec![4; 32], vec![5; 32]].concat()
        );
    }

    #[test]
    fn cycle_overflow_closing_slot_proves_step_then_reset() -> Result<()> {
        let mut pristine_config = Machine::default_config()?;
        pristine_config.ram.length = 4096;
        pristine_config.processor.registers.iflags.y = 1;
        // HTIF_BUILD(yield device, manual command, RX_ACCEPTED, no data).
        pristine_config.processor.registers.htif.tohost =
            (2u64 << 56) | (1u64 << 48) | (u64::from(RX_ACCEPTED) << 32);

        let mut pristine = Machine::create(&pristine_config, &RuntimeConfig::quiet_console())?;
        let canonical_post: Digest = pristine.root_hash()?.into();

        let mut overflow_config = pristine.initial_config()?;
        overflow_config.uarch.processor.registers.cycle = UARCH_MASK_TO_BARCH;
        overflow_config.uarch.processor.registers.halt = 0;

        // This is the closing source state exercised by the v0.21
        // uarch-overflow-tail case: the counter is maxed but halt is clear.
        let mut oracle = Machine::create(&overflow_config, &RuntimeConfig::quiet_console())?;
        assert_eq!(oracle.ucycle()?, UARCH_MASK_TO_BARCH);
        assert!(!oracle.uarch_halt_flag()?);
        let agree: Digest = oracle.root_hash()?.into();
        assert_ne!(agree, canonical_post);

        let step = oracle.log_step_uarch(LogType::default())?;
        assert_eq!(Digest::from(oracle.root_hash()?), agree);
        let reset = oracle.log_reset_uarch(LogType::default())?;
        assert_eq!(Digest::from(oracle.root_hash()?), canonical_post);
        let step_proof = MachineStf::encode_access_log(&step);
        let reset_proof = MachineStf::encode_access_log(&reset);
        assert_eq!(step_proof.len(), 1_920);
        assert_eq!(reset_proof.len(), 5_216);
        let expected_proof = [step_proof, reset_proof].concat();

        let machine = Machine::create(&overflow_config, &RuntimeConfig::quiet_console())?;
        let stf = MachineStf {
            machine,
            ucycle: UARCH_MASK_TO_BARCH,
            work_dir: PathBuf::new(),
            checkpoint: None,
            feeder: Feeder::Scratch {
                fed: 0,
                inputs: vec![],
            },
        };
        let mut ruler = Ruler::new_at(
            stf,
            Structure::PRODUCTION,
            0,
            U256::from(UARCH_MASK_TO_BARCH),
        );
        let (proof, post) = ruler.prove_transition()?;

        assert_eq!(proof, expected_proof);
        assert_eq!(post, canonical_post);
        Ok(())
    }

    /// Drift guard: the engine structure and the machine constants must
    /// describe the same ruler.
    #[test]
    fn production_structure_maps_machine_fields() {
        let production = Structure::PRODUCTION;
        assert_eq!(production.log2_uarch_span, LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);
        assert_eq!(
            production.log2_barch_span,
            LOG2_MAX_MCYCLES_PER_ADVANCE_STATE
        );
        assert_eq!(
            production.log2_input_span,
            LOG2_MAX_ADVANCE_STATES_PER_EPOCH
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
