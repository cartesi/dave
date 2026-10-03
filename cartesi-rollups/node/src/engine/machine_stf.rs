// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The [`Stf`] verbs on the real Cartesi machine. Dense leaf builds take
//! their big-cycle roots from the emulator's bulk uarch collector; every
//! other verb steps the machine through the per-step API. Under
//! [`Collector::Stepped`] dense leaves are stepped too: the slow,
//! obviously-correct path, kept permanently as the collector's
//! differential reference (computation-hash.md). Machine errors
//! propagate as errors; geometry violations remain panics (see the stf
//! module doc).

use super::dispute::DisputeSource;
use super::ruler::{Hashing, Ruler, RulerFactory};
use super::stf::Stf;
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
        rollup::LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
    },
    format_emulator_version,
    machine::Machine,
    types::{
        Hash, LogType,
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
/// snapshot commits into the boundary store; positioning has usually
/// published it already (Positioner::cross), so the commit adopts it,
/// and the row insert is a cross-regime nondeterminism tripwire.
/// Advance is the mode of the machine runner and of positioning's
/// crossed windows: one window, its payload handed in, and the
/// pre-feed snapshot is the batch's closed checkpoint. It may be
/// transient until the batch's final boundary is published; a revert
/// only needs it to be immutable for the current window.
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

/// How dense leaves are built: the emulator's bulk uarch collector, or
/// the per-step API one transition at a time (the reference).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Collector {
    Bulk,
    Stepped,
}

/// Big cycles per bulk collection call, bounding the result's size; a
/// call's overhead is small next to even an idle cycle's uarch work.
const BULK_CHUNK: u64 = 1 << 8;

pub struct MachineStf {
    machine: Machine,
    /// Reloads (a rejected input's revert) keep the load's concurrency.
    hashing: Hashing,
    collector: Collector,
    /// The idle period of the machine the last feed may revert to, which
    /// the bulk collector needs to report a rejection.
    revert_tail: Option<Vec<Hash>>,
    /// Uarch cycles since the last reset; run_uarch takes absolutes.
    ucycle: u64,
    /// Scratch-mode checkpoints live here; one at a time.
    work_dir: PathBuf,
    /// The last feed's pre-input snapshot and the revert root it holds.
    checkpoint: Option<(PathBuf, Hash)>,
    feeder: Feeder,
}

/// The emulator fixes its hash-tree concurrency at load. It hashes in
/// parallel once a hash's dirty pages outnumber the host's cores, and at
/// one root hash per ustep the thread pool's fork and join then costs
/// several times the hashing itself (about 110 us against 12 us per hash
/// on 18 cores, nine times slower overall). A leaf build hashes every
/// ustep over a few dirty pages, so it hashes serially; sampled strides
/// hash large dirty sets, where the parallel path wins.
fn runtime_config(hashing: Hashing) -> RuntimeConfig {
    let mut config = RuntimeConfig::quiet_console();
    if hashing == Hashing::PerStep {
        config.concurrency.update_hash_tree = 1;
    }
    config
}

impl MachineStf {
    /// Loads a template machine (the epoch's initial state). It must be
    /// yielded awaiting the first input, with a pristine uarch.
    pub fn load(template_path: &Path, work_dir: PathBuf, hashing: Hashing) -> Result<Self> {
        // Storage checks the template's pristine uarch at import
        // (docs/computation-hash.md); resume checks only that the
        // uarch sits at cycle zero.
        let mut stf = Self::resume(template_path, work_dir, hashing)?;
        ensure!(
            stf.yielded()?,
            "template machine must be yielded awaiting input"
        );
        Ok(stf)
    }

    /// Resumes a stored machine mid-epoch (a boundary-store answer).
    /// Positions are big-cycle boundaries, so the uarch must be
    /// pristine, but the machine may be in any big state.
    pub fn resume(path: &Path, work_dir: PathBuf, hashing: Hashing) -> Result<Self> {
        let mut machine = Machine::load(path, &runtime_config(hashing))
            .context("failed to load stored machine")?;
        ensure!(
            machine.ucycle()? == 0,
            "stored machine must sit at a big-cycle boundary"
        );
        std::fs::create_dir_all(&work_dir).context("work dir")?;
        Ok(MachineStf {
            machine,
            hashing,
            collector: Collector::Bulk,
            revert_tail: None,
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

    /// Selects how dense leaves are built (production collects in bulk).
    pub fn with_collector(mut self, collector: Collector) -> Self {
        self.collector = collector;
        self
    }

    /// The machine runner's stf: wraps the live working-clone machine
    /// the caller owns (SHARING_ALL, mutated in place, sitting at
    /// `window`'s boundary), feeds exactly that window, and restores
    /// a revert from `boundary` - the batch's closed pre-input
    /// checkpoint, durable or transient. No filesystem effects of its
    /// own; the counterpart of [`MachineStf::into_machine`].
    pub fn over_advancing(
        machine: Machine,
        window: u64,
        payload: Vec<u8>,
        boundary: PathBuf,
    ) -> Self {
        MachineStf {
            machine,
            // The runner hashes once per stride sample.
            hashing: Hashing::Sampled,
            // and builds no dense leaves.
            collector: Collector::Stepped,
            revert_tail: None,
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

    /// The step reads only the pending yield, never the halt flag or the
    /// input budget: SendCmioResponse delivers the next input to any
    /// RX_ACCEPTED yield (on the budget's last cycle, or even halted), and
    /// UArchReset reverts any RX_REJECTED one. So halt and overflow are
    /// terminal only with no manual yield pending.
    fn terminal_fixed(&mut self) -> Result<bool> {
        match self.manual_yield_reason()? {
            Some(reason) => Ok(reason != RX_ACCEPTED && reason != RX_REJECTED),
            None => Ok(self.machine.iflags_h()? || self.mcycle_overflow()?),
        }
    }

    /// A logged reset substitutes the canonical root on rejection, but
    /// the emulator deliberately leaves the physical machine reset in
    /// place. Reload the pre-feed snapshot so subsequent plain execution
    /// starts from that same canonical state.
    fn restore_rejected(&mut self) -> Result<bool> {
        if self.manual_yield_reason()? != Some(RX_REJECTED) {
            return Ok(false);
        }
        let (checkpoint, revert_root) = self
            .checkpoint
            .clone()
            .expect("revert requires a fed checkpoint");
        self.machine = Machine::load(&checkpoint, &runtime_config(self.hashing))
            .context("reload checkpoint")?;
        // Publication verifies a content-addressed snapshot, but a feed
        // adopts an existing directory without rehashing it, so a torn
        // one would otherwise become a wrong post-state silently.
        assert_eq!(
            self.machine.root_hash()?,
            revert_root,
            "revert checkpoint `{}` does not hash to the input's revert root: corrupt snapshot",
            checkpoint.display()
        );
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
                if let Some((old, _)) = self.checkpoint.take() {
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
                // The pre-feed state is the batch's closed checkpoint,
                // which may remain transient until batch publication.
                (boundary.clone(), payload)
            }
        };
        self.checkpoint = Some((checkpoint, root));

        if self.collector == Collector::Bulk {
            // Collected while awaiting input, the idle period ends with
            // this root, the revert root the response records.
            let mcycle = self.machine.mcycle()?;
            let idle = self
                .machine
                .collect_uarch_cycle_root_hashes(mcycle, 0, None)?;
            self.revert_tail = Some(idle.hashes);
        }

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

    fn collects_big_cycle_roots(&self) -> bool {
        self.collector == Collector::Bulk
    }

    fn big_cycle_roots(&mut self, big_cycles: u64) -> Result<Vec<Digest>> {
        assert_eq!(
            self.ucycle, 0,
            "bulk collection starts at a big-cycle boundary"
        );
        // Seam 1: v0.21.0's collector keeps the physical root when an input
        // is rejected on its budget's last cycle, where the step reverts
        // (computation-hash.md, seam 1). Declining that cycle leaves it to
        // stepping.
        let start = self.machine.mcycle()?;
        let last_budget_cycle = self.machine.imcyclemax()?.saturating_sub(1);
        let end = add_and_clamp(start, big_cycles).min(last_budget_cycle);
        let mut roots = vec![];
        let mut mcycle = start;
        while mcycle < end {
            let tail = self
                .revert_tail
                .as_deref()
                .expect("a fed input carries its revert tail");
            let collected = self.machine.collect_uarch_cycle_root_hashes(
                end.min(add_and_clamp(mcycle, BULK_CHUNK)),
                LOG2_MAX_UARCH_CYCLES_PER_MCYCLE as u32,
                Some(tail),
            )?;
            let reached = self.machine.mcycle()?;
            // Bundled per big cycle, each period's last entry is the cycle's
            // root. At a fixed point one more period follows, the idle one,
            // which the ruler derives itself.
            let root =
                |period: &[Hash]| Digest::from(*period.last().expect("a period ends at reset"));
            if reached == mcycle {
                // Fed into a fixed point (a template preset halted with an
                // input yield pending): the opening cycle is that fixed
                // point's period, and the machine stays put.
                ensure!(
                    self.fixed()? && collected.periods().count() == 1,
                    "the uarch collector made no progress"
                );
                roots.extend(collected.periods().map(root));
                break;
            }
            roots.extend(
                collected
                    .periods()
                    .take((reached - mcycle) as usize)
                    .map(root),
            );
            mcycle = reached;
            if self.restore_rejected()? || self.fixed()? {
                break;
            }
        }
        Ok(roots)
    }

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

/// The engine's positioning residue: a work dir, a spawn counter,
/// and the store handle they serve. Positions rulers by resuming
/// from the boundary store's nearest stored machine, crossing whole
/// windows on the runner's clone chain, and advancing the remainder.
/// The store is live: boundaries recorded by any writer (the open
/// regime's gap fill, an earlier crossing) shorten the next
/// positioning. On a freshly initialized store only the epoch start
/// exists. Constructed only by [`DisputeSource::on_store`]; the type
/// is public for signatures alone.
pub struct Positioner {
    structure: Structure,
    work_dir: PathBuf,
    /// How many windows feed (the inputs are a contiguous prefix);
    /// payloads stay in the inputs table, read at feed time.
    fed_windows: u64,
    store: Storage,
    epoch: u64,
    spawned: usize,
    collector: Collector,
}

/// The production constructor of the facade: one closed epoch's
/// computation, assembled entirely from the node's durable state.
/// Lives beside the machine stf because only this impl block knows
/// how positioning constructs itself from storage; consumers hold no
/// engine pieces.
impl DisputeSource<Positioner> {
    pub fn on_store(storage: Storage, epoch: u64, work_dir: PathBuf) -> Result<Self> {
        Self::on_store_with(storage, epoch, work_dir, Collector::Bulk)
    }

    /// [`DisputeSource::on_store`] with a chosen dense-leaf collector:
    /// differential tests build leaves both ways. Not an operator setting.
    pub fn on_store_with(
        mut storage: Storage,
        epoch: u64,
        work_dir: PathBuf,
        collector: Collector,
    ) -> Result<Self> {
        // Initialization pinned the config; assert engine
        // compatibility before serving any quartet.
        let structure = Structure::PRODUCTION;
        let config = storage.sling_config()?;
        super::config::assert_compatible(
            &config,
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
            collector,
        };
        // The level-0 material was recorded at the pinned root stride;
        // the source reads it (window-root rows, interior runs) from
        // storage on demand.
        DisputeSource::new(storage, positioner, epoch, config.geometry.root_stride())
    }
}

impl Positioner {
    /// Crosses whole windows from the verified stored boundary `floor`
    /// to `to` on the runner's clone chain: each input runs on a
    /// copy-on-write clone, which costs its dirty pages, a rejection
    /// resumes from the pre-input clone, and only boundary `to` is
    /// published and registered. Every later action of a dispute stays
    /// inside one input, so that boundary is the one they resume from;
    /// a full store of each crossed boundary (about 410 MiB on the
    /// stress image) bought nothing more.
    fn cross(&mut self, floor: u64, path: PathBuf, hash: Hash, to: u64) -> Result<()> {
        let (mut machine, mut batch) = self.store.begin_crossing(path, self.epoch, floor, hash)?;
        for window in floor..to {
            let payload = self
                .store
                .input(&InputId {
                    epoch_number: self.epoch,
                    input_index_in_epoch: window,
                })?
                .expect("crossed windows lie in the ingested contiguous prefix")
                .data;
            let stf = MachineStf::over_advancing(
                machine.take_machine(),
                window,
                payload,
                batch.boundary_path().to_path_buf(),
            );
            let start = self.structure.window_start(window);
            let mut ruler = Ruler::new_at(stf, self.structure, window + 1, start);
            ruler.advance(self.structure.window_start(window + 1))?;
            let stf = ruler.into_stf();
            let reverted = stf.took_revert();
            machine.put_machine(stf.into_machine());
            machine.increment_input();
            if reverted {
                self.store.rotate_reverted(&mut batch, &mut machine)?;
            } else {
                let hash = machine.state_hash()?;
                self.store.rotate_accepted(&mut batch, &mut machine, hash)?;
            }
        }
        drop(machine);
        self.store.publish_crossing(batch)?;
        Ok(())
    }
}

impl RulerFactory for Positioner {
    type S = MachineStf;

    fn ruler_at(&mut self, position: U256, hashing: Hashing) -> Result<Ruler<MachineStf>> {
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
                MachineStf::load(&path, dir, hashing)?
            } else {
                MachineStf::resume(&path, dir, hashing)?
            }
            .with_collector(self.collector);

            // Assert-on-load: the emulator validates nothing, so the
            // loaded machine must reproduce its row's hash (nearly
            // free - committed boundaries carry exact sidecars). A
            // torn snapshot is skipped, not fatal: any earlier
            // boundary only lengthens the replay. A later feed still
            // adopts its directory as a revert checkpoint, which
            // restore_rejected checks.
            let expected = self
                .store
                .snapshot_hash(self.epoch, boundary.0)?
                .expect("nearest answered from an existing row");
            if stf.state_hash()? == Digest::from_digest(&expected)? {
                let to = target.min(self.fed_windows);
                if boundary.0 < to {
                    drop(stf);
                    self.cross(boundary.0, path, expected, to)?;
                    continue;
                }
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

        // Left to cross: padding windows past the inputs, or, when a torn
        // snapshot lowered the target, the windows above it, whose feeds
        // commit their boundaries through the store.
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
    use crate::engine::TournamentGeometry;
    use crate::engine::constants::UARCH_MASK_TO_BARCH;
    use crate::engine::ruler::Run;
    use crate::merkle::MerkleBuilder;
    use cartesi_machine::constants::ar::RAM_START;
    use cartesi_machine::constants::cmio::tohost::manual::TX_EXCEPTION;
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
            hashing: Hashing::Sampled,
            collector: Collector::Stepped,
            revert_tail: None,
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

    /// Clears fromhost, yields x19, then yields x20 each time it resumes.
    /// With imcyclemax = 3 the x19 yield executes on the input budget's
    /// last cycle.
    const BUDGET_SEAM_PROGRAM: [u32; 5] = [
        0x4000_82b7, // lui t0, 0x40008 (HTIF base)
        0x0002_b423, // sd zero, 8(t0) (fromhost)
        0x0132_b023, // sd x19, 0(t0) (tohost)
        0x0142_b023, // sd x20, 0(t0) (tohost)
        0xffdf_f06f, // j -4
    ];

    fn manual_yield(reason: u16) -> u64 {
        // HTIF_BUILD(yield device, manual command, reason, no data).
        (2u64 << 56) | (1u64 << 48) | (u64::from(reason) << 32)
    }

    /// Runs the guest until its budget or its x19 yield stops it. With
    /// imcyclemax = 3 the x19 yield executes on the budget's last cycle;
    /// with imcyclemax = 2 the budget runs out before the yield.
    fn seam_guest(imcyclemax: u64, x19_reason: u16) -> Result<Machine> {
        let mut config = Machine::default_config()?;
        config.ram.length = 4096;
        config.processor.registers.pc = RAM_START;
        config.processor.registers.imcyclemax = imcyclemax;
        config.processor.registers.x19 = manual_yield(x19_reason);
        config.processor.registers.x20 = manual_yield(RX_ACCEPTED);
        let mut machine = Machine::create(&config, &RuntimeConfig::quiet_console())?;
        let program: Vec<u8> = BUDGET_SEAM_PROGRAM
            .iter()
            .flat_map(|instruction| instruction.to_le_bytes())
            .collect();
        machine.write_memory(RAM_START, &program)?;
        machine.run(u64::MAX)?;
        assert_eq!(machine.mcycle()?, imcyclemax);
        Ok(machine)
    }

    /// An RX_ACCEPTED yield executed on the last cycle of the input budget
    /// (mcycle == imcyclemax): the step still delivers the next input.
    fn budget_seam_machine() -> Result<Machine> {
        let mut machine = seam_guest(3, RX_ACCEPTED)?;
        assert!(machine.iflags_y()?);
        assert_eq!(machine.receive_cmio_request()?.reason(), RX_ACCEPTED);
        assert_eq!(machine.imcyclemax()?, 3);
        Ok(machine)
    }

    /// Halted with an RX_ACCEPTED yield pending: unreachable by execution,
    /// but a template can preset it, and the step still delivers the input.
    fn halted_yield_machine() -> Result<Machine> {
        let mut config = Machine::default_config()?;
        config.ram.length = 4096;
        config.processor.registers.iflags.h = 1;
        config.processor.registers.iflags.y = 1;
        config.processor.registers.htif.tohost = manual_yield(RX_ACCEPTED);
        Ok(Machine::create(&config, &RuntimeConfig::quiet_console())?)
    }

    fn scratch_stf(machine: Machine, work_dir: PathBuf, inputs: Vec<Vec<u8>>) -> MachineStf {
        MachineStf {
            machine,
            hashing: Hashing::Sampled,
            collector: Collector::Stepped,
            revert_tail: None,
            ucycle: 0,
            work_dir,
            checkpoint: None,
            feeder: Feeder::Scratch { fed: 0, inputs },
        }
    }

    /// The leaf at `index` of a per-transition or per-sample run list.
    fn leaf_at(runs: &[Run], index: U256) -> Digest {
        let mut remaining = index;
        for run in runs {
            if remaining < run.repetitions {
                return run.hash;
            }
            remaining -= run.repetitions;
        }
        panic!("leaf {index} lies past the collected runs");
    }

    /// Only a pending input yield (accepted or rejected) outranks halt and
    /// the exhausted budget; every other class stays terminal.
    #[test]
    fn pending_input_yield_outranks_halt_and_budget() -> Result<()> {
        // (machine, terminal, yielded)
        let cases = [
            (
                "budget out before the yield",
                seam_guest(2, RX_ACCEPTED)?,
                true,
                false,
            ),
            (
                "exception on the last cycle",
                seam_guest(3, TX_EXCEPTION)?,
                true,
                false,
            ),
            (
                "unexpected yield on the last cycle",
                seam_guest(3, 0x7f)?,
                true,
                false,
            ),
            (
                "rejection on the last cycle",
                seam_guest(3, RX_REJECTED)?,
                false,
                false,
            ),
            (
                "acceptance on the last cycle",
                budget_seam_machine()?,
                false,
                true,
            ),
            (
                "acceptance while halted",
                halted_yield_machine()?,
                false,
                true,
            ),
        ];
        for (name, machine, terminal, yielded) in cases {
            let mut stf = scratch_stf(machine, PathBuf::new(), vec![]);
            assert_eq!(stf.terminal()?, terminal, "{name}: terminal");
            assert_eq!(stf.yielded()?, yielded, "{name}: yielded");
        }

        let mut config = Machine::default_config()?;
        config.ram.length = 4096;
        config.processor.registers.iflags.h = 1;
        let halted = Machine::create(&config, &RuntimeConfig::quiet_console())?;
        assert!(scratch_stf(halted, PathBuf::new(), vec![]).terminal()?);
        Ok(())
    }

    /// The step's opening delivers the input, so the collected leaf, the
    /// proof, and an independent send-then-step replay agree, and the leaf
    /// differs from an undelivered (idle) opening.
    fn assert_opening_delivers(make: fn() -> Result<Machine>) -> Result<()> {
        let payload = b"seam".to_vec();

        let mut oracle = make()?;
        let revert_root = oracle.root_hash()?;
        let cmio = oracle.log_send_cmio_response(
            CmioResponseReason::Advance,
            &payload,
            &revert_root,
            LogType::default(),
        )?;
        let step = oracle.log_step_uarch(LogType::default())?;
        let fed: Digest = oracle.root_hash()?.into();
        let expected_proof = [
            MachineStf::encode_da(&payload),
            MachineStf::encode_access_log(&cmio),
            MachineStf::encode_access_log(&step),
        ]
        .concat();

        let mut idle = make()?;
        idle.log_step_uarch(LogType::default())?;
        assert_ne!(Digest::from(idle.root_hash()?), fed);

        let work_dir = tempfile::tempdir()?;
        let stf = scratch_stf(
            make()?,
            work_dir.path().to_path_buf(),
            vec![payload.clone()],
        );
        let runs = Ruler::new(stf, Structure::PRODUCTION, 1).collect(U256::from(1), 0)?;
        assert_eq!(
            runs,
            vec![Run {
                hash: fed,
                repetitions: U256::from(1)
            }]
        );

        let stf = scratch_stf(make()?, PathBuf::new(), vec![payload]);
        let (proof, post) = Ruler::new(stf, Structure::PRODUCTION, 1).prove_transition()?;
        assert_eq!(proof, expected_proof);
        assert_eq!(post, fed);
        Ok(())
    }

    #[test]
    fn opening_on_the_last_budget_cycle_delivers_the_input() -> Result<()> {
        assert_opening_delivers(budget_seam_machine)
    }

    #[test]
    fn opening_on_a_halted_machine_with_a_pending_yield_delivers_the_input() -> Result<()> {
        assert_opening_delivers(halted_yield_machine)
    }

    /// The input budget's seams as chain witnesses for the Solidity step,
    /// which NodeWitnessesTest (cartesi-rollups/contracts) replays: RX_ACCEPTED
    /// openings on the budget's last cycle and on a halted machine (seam 2),
    /// and an RX_REJECTED closing on the budget's last cycle (seam 1), the
    /// boundaries where the v0.21 CLI departs from the step. No input can
    /// reach seam 1 by execution (it would run 2^48 - 1 cycles), so, as in
    /// the Lua vectors, the budget shrinks after a physical delivery.
    /// UPDATE_FIXTURES=1 regenerates tests/fixtures/node_seam_witnesses.json.
    #[test]
    fn seam_witness_vectors_hold() -> Result<()> {
        use cartesi_machine::cartesi_machine_sys::{
            CM_REG_IMCYCLEMAX, CM_REG_UARCH_CYCLE, CM_REG_X20,
        };
        use cartesi_machine::constants::uarch_break_reason::UARCH_HALTED;

        let payload = b"seam".to_vec();
        let vector = |position: U256, pre: Digest, post: Digest, proof: &[u8]| {
            serde_json::json!({
                "program": "seam",
                "meta_cycle": format!("{position:#x}"),
                "pre_state": pre.to_hex(),
                "post_state": post.to_hex(),
                "proof": format!("0x{}", hex::encode(proof)),
            })
        };
        let mut vectors = serde_json::Map::new();

        for (name, machine) in [
            ("budget_seam_accepted_opening", budget_seam_machine()?),
            ("halted_accepted_opening", halted_yield_machine()?),
        ] {
            let mut machine = machine;
            let pre: Digest = machine.root_hash()?.into();
            let work = tempfile::tempdir()?;
            let stf = scratch_stf(machine, work.path().to_path_buf(), vec![payload.clone()]);
            let (proof, post) = Ruler::new(stf, Structure::PRODUCTION, 1).prove_transition()?;
            vectors.insert(name.into(), vector(U256::ZERO, pre, post, &proof));
        }

        let work = tempfile::tempdir()?;
        let mut machine = seam_guest(3, RX_ACCEPTED)?;
        machine.write_reg(CM_REG_X20, manual_yield(RX_REJECTED))?;
        let revert_root = machine.root_hash()?;
        let checkpoint = work.path().join("checkpoint-0");
        machine.store(&checkpoint)?;
        machine.send_cmio_response(CmioResponseReason::Advance, &payload, Some(&revert_root))?;
        // Delivery renewed the budget; shrink it so the x20 rejection
        // executes on its last cycle.
        let mcycle = machine.mcycle()?;
        machine.write_reg(CM_REG_IMCYCLEMAX, mcycle + 1)?;
        let closing = Structure::PRODUCTION.big_span() - 1;
        assert_eq!(machine.run_uarch(closing)?, UARCH_HALTED);
        assert_eq!(machine.receive_cmio_request()?.reason(), RX_REJECTED);
        assert_eq!(machine.mcycle()?, machine.imcyclemax()?);
        let pre: Digest = machine.root_hash()?.into();
        let stf = MachineStf {
            ucycle: machine.read_reg(CM_REG_UARCH_CYCLE)?,
            machine,
            hashing: Hashing::Sampled,
            collector: Collector::Stepped,
            revert_tail: None,
            work_dir: work.path().to_path_buf(),
            checkpoint: Some((checkpoint, revert_root)),
            feeder: Feeder::Scratch {
                fed: 1,
                inputs: vec![payload.clone()],
            },
        };
        let position = U256::from(closing);
        let (proof, post) =
            Ruler::new_at(stf, Structure::PRODUCTION, 1, position).prove_transition()?;
        assert_eq!(
            post,
            Digest::from(revert_root),
            "the reset substitutes the revert root"
        );
        vectors.insert(
            "budget_seam_rejected_closing".into(),
            vector(position, pre, post, &proof),
        );

        let computed = serde_json::json!({
            "inputs": { "seam": [format!("0x{}", hex::encode(&payload))] },
            "vectors": vectors,
        });
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/node_seam_witnesses.json");
        if std::env::var("UPDATE_FIXTURES").is_ok() {
            std::fs::write(&path, serde_json::to_string_pretty(&computed)?)?;
            return Ok(());
        }
        let stored: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path)?)?;
        assert_eq!(
            computed, stored,
            "seam witnesses diverged; regenerate with UPDATE_FIXTURES=1 after review"
        );
        Ok(())
    }

    /// Dense leaves through the ruler, bulk against stepped, on the seam
    /// openings: on the budget's last cycle (the delivery renews the
    /// budget and the guest yields within the first chunk), and on a
    /// halted machine with a yield pending, which the delivery leaves at a
    /// fixed point.
    #[test]
    fn bulk_and_stepped_dense_leaves_agree_at_the_seam_openings() -> Result<()> {
        let structure = Structure::PRODUCTION;
        let to = U256::from(4) << structure.log2_uarch_span;
        let openings: [fn() -> Result<Machine>; 2] = [budget_seam_machine, halted_yield_machine];
        for make in openings {
            let [bulk, stepped] = [Collector::Bulk, Collector::Stepped].map(|collector| {
                let work = tempfile::tempdir().unwrap();
                let stf = scratch_stf(
                    make().unwrap(),
                    work.path().to_path_buf(),
                    vec![b"seam".to_vec()],
                )
                .with_collector(collector);
                Ruler::new(stf, structure, 1)
                    .collect_big_cycle_roots(to)
                    .unwrap()
            });
            assert_eq!(bulk, stepped);
        }
        Ok(())
    }

    /// Seam 1 on the bulk path: v0.21.0's collector reports the physical
    /// root for a rejection on the input budget's last cycle, where the step
    /// reverts, so bulk collection declines that cycle and the ruler steps
    /// it (seam_witness_vectors_hold pins the stepped answer). The control
    /// pins the collector's answer: once an emulator reports the revert
    /// root there, the guard in big_cycle_roots can go.
    #[test]
    fn bulk_collection_leaves_the_budgets_last_cycle_to_stepping() -> Result<()> {
        use cartesi_machine::cartesi_machine_sys::{CM_REG_IMCYCLEMAX, CM_REG_X20};

        let payload = b"seam".to_vec();
        // Delivered, with the x20 rejection due on the budget's last cycle.
        let delivered = |work: &Path| -> Result<(Machine, Hash, PathBuf, Vec<Hash>)> {
            let mut machine = seam_guest(3, RX_ACCEPTED)?;
            machine.write_reg(CM_REG_X20, manual_yield(RX_REJECTED))?;
            let revert_root = machine.root_hash()?;
            let checkpoint = work.join("checkpoint-0");
            machine.store(&checkpoint)?;
            let mcycle = machine.mcycle()?;
            let tail = machine
                .collect_uarch_cycle_root_hashes(mcycle, 0, None)?
                .hashes;
            machine.send_cmio_response(
                CmioResponseReason::Advance,
                &payload,
                Some(&revert_root),
            )?;
            let mcycle = machine.mcycle()?;
            machine.write_reg(CM_REG_IMCYCLEMAX, mcycle + 1)?;
            Ok((machine, revert_root, checkpoint, tail))
        };

        let work = tempfile::tempdir()?;
        let (machine, revert_root, checkpoint, tail) = delivered(work.path())?;
        let mut stf = MachineStf {
            machine,
            hashing: Hashing::PerStep,
            collector: Collector::Bulk,
            revert_tail: Some(tail),
            ucycle: 0,
            work_dir: work.path().to_path_buf(),
            checkpoint: Some((checkpoint, revert_root)),
            feeder: Feeder::Scratch {
                fed: 1,
                inputs: vec![payload.clone()],
            },
        };
        let mcycle = stf.machine.mcycle()?;
        assert!(stf.big_cycle_roots(4)?.is_empty(), "the cycle is declined");
        assert_eq!(stf.machine.mcycle()?, mcycle);

        let work = tempfile::tempdir()?;
        let (mut machine, revert_root, _, tail) = delivered(work.path())?;
        let collected = machine.collect_uarch_cycle_root_hashes(mcycle + 1, 0, Some(&tail))?;
        let reset = *collected.periods().next().unwrap().last().unwrap();
        assert_ne!(
            reset, revert_root,
            "the collector now reverts on the budget's last cycle: drop the guard"
        );
        assert_eq!(reset, machine.root_hash()?, "the physical root");
        Ok(())
    }

    /// Big-stride sampling (the runner and root levels) and uarch stepping
    /// (the leaf level) both land on the delivered input's x20 yield.
    #[test]
    fn seam_window_collects_alike_at_big_and_uarch_strides() -> Result<()> {
        let structure = Structure::PRODUCTION;
        let payload = b"seam".to_vec();
        let c = structure.log2_uarch_span;
        let to = U256::from(2) << c;

        let mut oracle = budget_seam_machine()?;
        let seam = oracle.root_hash()?;
        oracle.send_cmio_response(CmioResponseReason::Advance, &payload, Some(&seam))?;
        oracle.run(u64::MAX)?;
        assert!(oracle.iflags_y()?);
        assert_eq!(oracle.mcycle()?, 4);
        let delivered: Digest = oracle.root_hash()?.into();
        assert_ne!(delivered, Digest::from(seam));

        let coarse_dir = tempfile::tempdir()?;
        let coarse = Ruler::new(
            scratch_stf(
                budget_seam_machine()?,
                coarse_dir.path().to_path_buf(),
                vec![payload.clone()],
            ),
            structure,
            1,
        )
        .collect(to, c)?;
        let fine_dir = tempfile::tempdir()?;
        let fine = Ruler::new(
            scratch_stf(
                budget_seam_machine()?,
                fine_dir.path().to_path_buf(),
                vec![payload.clone()],
            ),
            structure,
            1,
        )
        .collect(to, 0)?;
        // The tall-quartet path: an active cycle and an idle one, each
        // folded to its root.
        let roots_dir = tempfile::tempdir()?;
        let roots = Ruler::new(
            scratch_stf(
                budget_seam_machine()?,
                roots_dir.path().to_path_buf(),
                vec![payload],
            ),
            structure,
            1,
        )
        .collect_big_cycle_roots(to)?;

        for sample in 0..2u64 {
            let position = (U256::from(sample + 1) << c) - U256::from(1);
            assert_eq!(leaf_at(&coarse, U256::from(sample)), delivered);
            assert_eq!(leaf_at(&fine, position), delivered);
        }
        let fold = |runs: &[Run]| {
            let mut builder = MerkleBuilder::default();
            for run in runs {
                builder.append_repeated(run.hash, run.repetitions);
            }
            builder.build().root_hash()
        };
        assert_eq!(roots.len(), 2);
        assert_eq!(fold(&roots), fold(&fine));
        Ok(())
    }

    /// The runner's own collect (advance feeder, run stride) feeds a
    /// machine that yielded on its budget's last cycle, and keeps feeding
    /// once the delivery renews the budget, at either root stride.
    #[test]
    fn runner_feeds_windows_after_a_yield_on_the_last_budget_cycle() -> Result<()> {
        let structure = Structure::PRODUCTION;
        for geometry in [
            TournamentGeometry::three_level(),
            TournamentGeometry::two_level(),
        ] {
            let log2_run_stride = geometry.root_stride();
            let mut machine = budget_seam_machine()?;
            let template: Digest = machine.root_hash()?.into();
            let samples_per_window =
                U256::from(1) << (structure.log2_window_span() - log2_run_stride);

            let mut mcycles = vec![];
            for window in 0..2u64 {
                let stf = MachineStf::over_advancing(machine, window, vec![0xd0], PathBuf::new());
                let mut ruler =
                    Ruler::new_at(stf, structure, window + 1, structure.window_start(window));
                let runs = ruler.collect(structure.window_start(window + 1), log2_run_stride)?;
                let stf = ruler.into_stf();
                assert!(!stf.took_revert());
                machine = stf.into_machine();

                let processed: Digest = machine.root_hash()?.into();
                assert_ne!(processed, template);
                assert_eq!(
                    runs,
                    vec![Run {
                        hash: processed,
                        repetitions: samples_per_window
                    }]
                );
                mcycles.push(machine.mcycle()?);
            }
            // Window 0 runs the x20 yield; window 1 jumps back and yields again.
            assert_eq!(mcycles, vec![4, 6]);
        }
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
}
