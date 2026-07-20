// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::Path;

use crate::engine::constants::{
    LOG2_BARCH_SPAN_TO_INPUT, LOG2_INPUT_SPAN_TO_EPOCH, LOG2_UARCH_SPAN_TO_BARCH,
};

use crate::storage::Proof;
use cartesi_machine::{
    config::runtime::RuntimeConfig,
    constants::{ar::TX_START, machine::HASH_TREE_LOG2_ROOT_SIZE},
    error::MachineResult,
    machine::Machine,
    types::{Hash, SharingMode},
};

// gap of each leaf in the commitment tree, should use the same value as ArbitrationConstants.sol:log2step(0)
pub const LOG2_STRIDE: u64 = 44;

/// Level-0 leaves in one input window; also the height of a window's
/// subtree, making (epoch, LOG2_STRIDE, this, window) the canonical
/// quartet coordinate of a window root.
pub const LOG2_STRIDE_COUNT_IN_INPUT: u64 =
    LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH - LOG2_STRIDE;

pub const STRIDE_COUNT_IN_INPUT: u64 = 1 << LOG2_STRIDE_COUNT_IN_INPUT;

pub const STRIDE_COUNT_IN_EPOCH: u64 = 1
    << (LOG2_INPUT_SPAN_TO_EPOCH + LOG2_BARCH_SPAN_TO_INPUT + LOG2_UARCH_SPAN_TO_BARCH
        - LOG2_STRIDE);

/// The canonical quartet coordinate of a window's final level-0
/// subtree root: one ordinary cache row per input, written by the
/// open regime as the window closes. Final by the frontier rule -
/// the window lies entirely left of the input frontier
/// (docs/plans/sling-design.md, the increment-E note).
pub fn window_root_quartet(epoch: u64, window: u64) -> crate::engine::Quartet {
    crate::engine::Quartet {
        epoch,
        log2_stride: LOG2_STRIDE,
        height: LOG2_STRIDE_COUNT_IN_INPUT,
        shift: alloy::primitives::U256::from(window),
    }
}

pub struct RollupsMachine {
    /// None only between [`RollupsMachine::close`] and
    /// [`RollupsMachine::reopen_shared`] - the chain-of-clones swap
    /// window, where the old instance must be destroyed (releasing
    /// its directory locks) before its directory can be cloned.
    machine: Option<Machine>,
    epoch_number: u64,
    next_input_index_in_epoch: u64,
}

impl RollupsMachine {
    pub fn new(
        path: &Path,
        epoch_number: u64,
        next_input_index_in_epoch: u64,
    ) -> MachineResult<Self> {
        let runtime_config = RuntimeConfig::quiet_console();
        let machine = Machine::load(path, &runtime_config)?;

        Ok(Self {
            machine: Some(machine),
            epoch_number,
            next_input_index_in_epoch,
        })
    }

    /// Loads a working clone SHARING_ALL: the directory IS the live
    /// state, mutated in place and exclusively locked until close.
    pub(super) fn load_shared(
        path: &Path,
        epoch_number: u64,
        next_input_index_in_epoch: u64,
    ) -> MachineResult<Self> {
        let machine =
            Machine::load_with_sharing(path, &RuntimeConfig::quiet_console(), SharingMode::All)?;

        Ok(Self {
            machine: Some(machine),
            epoch_number,
            next_input_index_in_epoch,
        })
    }

    /// Destroys the machine instance, flushing the working clone and
    /// releasing its locks; epoch and input bookkeeping survive the
    /// swap. Every other method panics until reopen_shared.
    pub(super) fn close(&mut self) {
        self.machine = None;
    }

    /// Reopens on a (new) working clone after close.
    pub(super) fn reopen_shared(&mut self, path: &Path) -> MachineResult<()> {
        assert!(self.machine.is_none(), "reopen requires a closed machine");
        self.machine = Some(Machine::load_with_sharing(
            path,
            &RuntimeConfig::quiet_console(),
            SharingMode::All,
        )?);
        Ok(())
    }

    fn inner(&mut self) -> &mut Machine {
        self.machine
            .as_mut()
            .expect("machine open (closed only inside the clone swap)")
    }

    pub fn epoch(&self) -> u64 {
        self.epoch_number
    }

    pub fn next_input_index_in_epoch(&self) -> u64 {
        self.next_input_index_in_epoch
    }

    pub fn finish_epoch(&mut self) {
        self.epoch_number += 1;
        self.next_input_index_in_epoch = 0;
    }

    pub fn outputs_proof(&mut self) -> MachineResult<(Hash, Proof)> {
        let proof = self.inner().proof(TX_START, 5, HASH_TREE_LOG2_ROOT_SIZE)?;
        let siblings = Proof::new(proof.sibling_hashes);
        let output_merkle = self.inner().read_memory(TX_START, 32)?;

        assert_eq!(output_merkle.len(), 32);
        Ok((output_merkle.try_into().unwrap(), siblings))
    }

    pub fn state_hash(&mut self) -> MachineResult<Hash> {
        self.inner().root_hash()
    }

    pub fn increment_input(&mut self) {
        self.next_input_index_in_epoch += 1;
    }

    /// Moves the machine out for a window-sized engine collect (the
    /// runner wraps it in the advance stf); the counterpart of
    /// [`RollupsMachine::put_machine`]. Distinct from close(), which
    /// drops the instance to release its directory.
    pub(crate) fn take_machine(&mut self) -> Machine {
        self.machine
            .take()
            .expect("machine open (taken only around a window collect)")
    }

    /// Returns the machine after a window collect: the same instance
    /// (accepted) or the boundary-restored one (reverted); the record
    /// verbs swap the backing clone either way.
    pub(crate) fn put_machine(&mut self, machine: Machine) {
        assert!(self.machine.is_none(), "put requires a taken machine");
        self.machine = Some(machine);
    }

    /// Plain machine store into `dir`. The boundary store owns the
    /// staging discipline and the content-addressed naming
    /// (storage/snapshots.rs); this is its raw write.
    pub(super) fn store_dir(&mut self, dir: &Path) -> MachineResult<()> {
        self.inner().store(dir)
    }
}
