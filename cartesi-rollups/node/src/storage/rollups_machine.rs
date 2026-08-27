// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::path::Path;

use crate::engine::constants::{LOG2_EPOCH_RULER_SPAN, LOG2_INPUT_WINDOW_SPAN};
use crate::merkle::Digest;
use crate::storage::{LeafProof, MACHINE_MEMORY_PROOF_SIBLING_COUNT, MachineValidityProof, Proof};
use anyhow::ensure;
use cartesi_machine::{
    cartesi_machine_sys::{
        CM_HTIF_CMD_MASK, CM_HTIF_CMD_SHIFT, CM_HTIF_DEV_MASK, CM_HTIF_DEV_SHIFT,
        CM_HTIF_DEV_YIELD, CM_HTIF_REASON_MASK, CM_HTIF_REASON_SHIFT, CM_HTIF_YIELD_CMD_MANUAL,
        CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED, CM_REG_HTIF_TOHOST, CM_REG_IFLAGS_Y,
    },
    config::runtime::RuntimeConfig,
    constants::{
        ar::TX_START,
        machine::{HASH_TREE_LOG2_ROOT_SIZE, HASH_TREE_LOG2_WORD_SIZE},
    },
    error::MachineResult,
    machine::Machine,
    types::{Hash, SharingMode, memory_proof::Proof as MachineMemoryProof},
};

const DATA_BLOCK_SIZE: u64 = 1 << HASH_TREE_LOG2_WORD_SIZE;
const DATA_BLOCK_MASK: u64 = DATA_BLOCK_SIZE - 1;
const _: () = assert!(
    MACHINE_MEMORY_PROOF_SIBLING_COUNT
        == (HASH_TREE_LOG2_ROOT_SIZE - HASH_TREE_LOG2_WORD_SIZE) as usize
);

fn machine_memory_root(target_address: u64, target_hash: Hash, siblings: &[Hash]) -> Hash {
    let mut index = target_address >> HASH_TREE_LOG2_WORD_SIZE;
    let mut node = Digest::new(target_hash);
    for sibling in siblings {
        let sibling = Digest::new(*sibling);
        node = if index & 1 == 0 {
            node.join(&sibling)
        } else {
            sibling.join(&node)
        };
        index >>= 1;
    }
    node.into()
}

fn data_block_word(data_block: &Hash, address: u64) -> u64 {
    let offset = (address & DATA_BLOCK_MASK) as usize;
    let end = offset + size_of::<u64>();
    let bytes = data_block
        .get(offset..end)
        .expect("canonical machine register must fit in its data block");
    u64::from_le_bytes(bytes.try_into().unwrap())
}

fn validity_register_addresses() -> (u64, u64) {
    let iflags_y = Machine::reg_address(CM_REG_IFLAGS_Y)
        .unwrap_or_else(|error| panic!("Cartesi Machine has no iflags_Y address: {error}"));
    let htif_tohost = Machine::reg_address(CM_REG_HTIF_TOHOST)
        .unwrap_or_else(|error| panic!("Cartesi Machine has no HTIF tohost address: {error}"));
    (iflags_y, htif_tohost)
}

fn validate_leaf_root(
    label: &str,
    address: u64,
    expected_root: Hash,
    proof: &LeafProof,
) -> anyhow::Result<()> {
    let target_address = address & !DATA_BLOCK_MASK;
    let target_hash: Hash = Digest::from_data(&proof.data_block).into();
    ensure!(
        machine_memory_root(target_address, target_hash, proof.siblings.inner()) == expected_root,
        "{label} proof does not reconstruct the final machine state"
    );
    Ok(())
}

/// Verifies exactly the proof and terminal-state predicates enforced by
/// LibMachineValidityProof. The HTIF data field is intentionally ignored.
pub(super) fn validate_machine_validity_proof(
    final_state: Hash,
    proof: &MachineValidityProof,
) -> anyhow::Result<()> {
    let (iflags_y_address, htif_tohost_address) = validity_register_addresses();

    validate_leaf_root(
        "iflags_Y",
        iflags_y_address,
        final_state,
        &proof.iflags_y_proof,
    )?;
    validate_leaf_root(
        "HTIF tohost",
        htif_tohost_address,
        final_state,
        &proof.htif_tohost_proof,
    )?;
    validate_leaf_root(
        "CMIO tx buffer",
        TX_START,
        final_state,
        &proof.tx_buffer_proof,
    )?;

    ensure!(
        data_block_word(&proof.iflags_y_proof.data_block, iflags_y_address) != 0,
        "post-epoch machine is not yielded"
    );

    let htif_tohost = data_block_word(&proof.htif_tohost_proof.data_block, htif_tohost_address);
    let device = (htif_tohost & CM_HTIF_DEV_MASK) >> CM_HTIF_DEV_SHIFT;
    let command = (htif_tohost & CM_HTIF_CMD_MASK) >> CM_HTIF_CMD_SHIFT;
    let reason = (htif_tohost & CM_HTIF_REASON_MASK) >> CM_HTIF_REASON_SHIFT;
    ensure!(
        device == u64::from(CM_HTIF_DEV_YIELD)
            && command == u64::from(CM_HTIF_YIELD_CMD_MANUAL)
            && reason == u64::from(CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED),
        "post-epoch machine is not yielded manually with RX_ACCEPTED"
    );

    Ok(())
}

fn validate_machine_memory_proof(
    label: &str,
    target_address: u64,
    data_block: Hash,
    expected_root: Hash,
    proof: MachineMemoryProof,
) -> LeafProof {
    assert_eq!(
        proof.target_address, target_address,
        "invalid {label} machine memory proof target address"
    );
    assert_eq!(
        proof.log2_target_size,
        u64::from(HASH_TREE_LOG2_WORD_SIZE),
        "invalid {label} machine memory proof target size"
    );
    assert_eq!(
        proof.log2_root_size,
        u64::from(HASH_TREE_LOG2_ROOT_SIZE),
        "invalid {label} machine memory proof root size"
    );
    assert_eq!(
        proof.sibling_hashes.len(),
        MACHINE_MEMORY_PROOF_SIBLING_COUNT,
        "invalid {label} machine memory proof sibling count"
    );

    let target_hash: Hash = Digest::from_data(&data_block).into();
    assert_eq!(
        proof.target_hash, target_hash,
        "invalid {label} machine memory proof target hash"
    );
    assert_eq!(
        proof.root_hash, expected_root,
        "invalid {label} machine memory proof reported root"
    );
    assert_eq!(
        machine_memory_root(target_address, target_hash, &proof.sibling_hashes),
        expected_root,
        "invalid {label} machine memory proof reconstructed root"
    );

    let siblings = Proof::new(proof.sibling_hashes)
        .expect("machine memory proof sibling count was checked above");
    LeafProof {
        data_block,
        siblings,
    }
}

fn capture_machine_memory_proof(
    machine: &mut Machine,
    label: &str,
    address: u64,
    expected_root: Hash,
) -> MachineResult<LeafProof> {
    let target_address = address & !DATA_BLOCK_MASK;
    let proof = machine.proof(
        target_address,
        HASH_TREE_LOG2_WORD_SIZE,
        HASH_TREE_LOG2_ROOT_SIZE,
    )?;
    let data = machine.read_memory(target_address, DATA_BLOCK_SIZE)?;
    let actual = data.len();
    let data_block = data.try_into().unwrap_or_else(|_| {
        panic!(
            "invalid {label} machine memory proof data block: read returned {actual} bytes, expected {DATA_BLOCK_SIZE}"
        )
    });

    Ok(validate_machine_memory_proof(
        label,
        target_address,
        data_block,
        expected_root,
        proof,
    ))
}

// gap of each leaf in the commitment tree, should use the same value as ArbitrationConstants.sol:log2step(0)
pub const LOG2_STRIDE: u64 = 44;

/// Level-0 leaves in one input window; also the height of a window's
/// subtree, making (epoch, LOG2_STRIDE, this, window) the canonical
/// quartet coordinate of a window root.
pub const LOG2_STRIDE_COUNT_IN_INPUT: u64 = LOG2_INPUT_WINDOW_SPAN - LOG2_STRIDE;

pub const STRIDE_COUNT_IN_INPUT: u64 = 1 << LOG2_STRIDE_COUNT_IN_INPUT;

pub const STRIDE_COUNT_IN_EPOCH: u64 = 1 << (LOG2_EPOCH_RULER_SPAN - LOG2_STRIDE);

/// The canonical quartet coordinate of a window's final level-0
/// subtree root: one ordinary cache row per input, written by the
/// open regime as the window closes. It is final by the frontier rule:
/// the window lies entirely left of the input frontier.
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

    /// Captures the three data-block proofs consumed by DaveConsensus.
    /// Every proof is checked against the same current machine root.
    pub fn machine_validity_proof(&mut self) -> MachineResult<(Hash, MachineValidityProof)> {
        machine_validity_proof_for(self.inner())
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

pub(super) fn machine_validity_proof_for(
    machine: &mut Machine,
) -> MachineResult<(Hash, MachineValidityProof)> {
    let (iflags_y_address, htif_tohost_address) = validity_register_addresses();
    let root = machine.root_hash()?;

    let iflags_y_proof = capture_machine_memory_proof(machine, "iflags_Y", iflags_y_address, root)?;
    let htif_tohost_proof =
        capture_machine_memory_proof(machine, "HTIF tohost", htif_tohost_address, root)?;
    let tx_buffer_proof = capture_machine_memory_proof(machine, "CMIO tx buffer", TX_START, root)?;

    let proof = MachineValidityProof {
        iflags_y_proof,
        htif_tohost_proof,
        tx_buffer_proof,
    };
    validate_machine_validity_proof(root, &proof)
        .unwrap_or_else(|error| panic!("invalid post-epoch machine validity proof: {error:#}"));
    Ok((root, proof))
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::PathBuf;

    use alloy::{
        primitives::{Address, U256},
        sol_types::SolCall,
    };
    use cartesi_machine::{
        config::runtime::RuntimeConfig,
        constants::break_reason,
        types::cmio::{CmioRequest, CmioResponseReason, ManualReason},
    };
    use cartesi_rollups_contracts::inputs::Inputs::EvmAdvanceCall;

    fn required_image(program: &str) -> PathBuf {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../test/programs")
            .join(program)
            .join("machine-image");
        path.canonicalize().unwrap_or_else(|error| {
            panic!(
                "{program} machine image is unavailable at {}: {error}; run `just programs::build-{program}`",
                path.display()
            )
        })
    }

    fn evm_advance_input(payload: &[u8]) -> Vec<u8> {
        EvmAdvanceCall {
            chainId: U256::from(31337),
            appContract: Address::ZERO,
            msgSender: Address::ZERO,
            blockNumber: U256::from(1),
            blockTimestamp: U256::from(1),
            prevRandao: U256::ZERO,
            index: U256::ZERO,
            payload: payload.to_vec().into(),
        }
        .abi_encode()
    }

    fn machine_after_advance(program: &str) -> MachineResult<Machine> {
        let mut machine = Machine::load(&required_image(program), &RuntimeConfig::quiet_console())?;
        assert!(machine.iflags_y()?, "template machine must be yielded");
        assert!(
            matches!(
                machine.receive_cmio_request()?,
                CmioRequest::Manual(ManualReason::RxAccepted { .. })
            ),
            "template machine must be awaiting input"
        );

        let revert_root = machine.root_hash()?;
        machine.send_cmio_response(
            CmioResponseReason::Advance,
            &evm_advance_input(b"hello dave"),
            Some(&revert_root),
        )?;
        assert!(
            !machine.iflags_y()?,
            "Advance response must clear the yield flag"
        );
        Ok(machine)
    }

    fn run_to_manual_yield(machine: &mut Machine) -> MachineResult<CmioRequest> {
        loop {
            let reason = machine.run(u64::MAX)?;
            assert_ne!(reason, break_reason::FAILED, "machine run failed");
            assert_ne!(
                reason,
                break_reason::HALTED,
                "machine halted before yielding"
            );
            assert_ne!(
                reason,
                break_reason::MCYCLE_OVERFLOW,
                "machine overflowed before yielding"
            );
            if machine.iflags_y()? {
                return machine.receive_cmio_request();
            }
        }
    }

    #[test]
    fn proof_requires_the_canonical_machine_tree_height() {
        assert!(Proof::new(vec![[0; 32]; MACHINE_MEMORY_PROOF_SIBLING_COUNT - 1]).is_err());
        assert!(Proof::new(vec![[0; 32]; MACHINE_MEMORY_PROOF_SIBLING_COUNT + 1]).is_err());

        let proof = Proof::new(vec![[0xAB; 32]; MACHINE_MEMORY_PROOF_SIBLING_COUNT]).unwrap();
        let flattened = proof.flatten();
        assert_eq!(Proof::from_flattened(flattened).unwrap(), proof);
        assert!(
            Proof::from_flattened(vec![0; MACHINE_MEMORY_PROOF_SIBLING_COUNT * 32 - 1]).is_err()
        );
    }

    #[test]
    #[should_panic(expected = "invalid test machine memory proof sibling count")]
    fn malformed_machine_proof_is_not_retryable() {
        let proof = MachineMemoryProof {
            target_address: 0,
            log2_target_size: u64::from(HASH_TREE_LOG2_WORD_SIZE),
            target_hash: [0; 32],
            log2_root_size: u64::from(HASH_TREE_LOG2_ROOT_SIZE),
            root_hash: [0; 32],
            sibling_hashes: vec![[0; 32]; MACHINE_MEMORY_PROOF_SIBLING_COUNT - 1],
        };

        let _ = validate_machine_memory_proof("test", 0, [0; 32], [0; 32], proof);
    }

    #[test]
    #[should_panic(expected = "post-epoch machine is not yielded")]
    fn capture_refuses_a_real_machine_before_it_yields() {
        let mut machine = machine_after_advance("echo").unwrap();

        let _ = machine_validity_proof_for(&mut machine);
    }

    #[test]
    fn captures_proof_after_a_real_echo_advance() -> MachineResult<()> {
        let mut machine = machine_after_advance("echo")?;
        let output_hashes_root_hash = match run_to_manual_yield(&mut machine)? {
            CmioRequest::Manual(ManualReason::RxAccepted {
                output_hashes_root_hash,
            }) => output_hashes_root_hash,
            request => panic!("echo machine must accept the input, found {request:?}"),
        };
        let expected_root = machine.root_hash()?;

        let (root, proof) = machine_validity_proof_for(&mut machine)?;

        assert_eq!(root, expected_root);
        assert_eq!(
            proof.outputs_merkle_root().as_slice(),
            output_hashes_root_hash.as_slice()
        );
        Ok(())
    }

    #[test]
    #[should_panic(expected = "not yielded manually with RX_ACCEPTED")]
    fn capture_refuses_a_real_rx_rejected_yield() {
        let mut machine = machine_after_advance("yield").unwrap();
        let request = run_to_manual_yield(&mut machine).unwrap();
        assert!(
            matches!(request, CmioRequest::Manual(ManualReason::RxRejected)),
            "yield machine must reject the input"
        );

        let _ = machine_validity_proof_for(&mut machine);
    }

    #[test]
    fn proof_validation_ignores_the_htif_data_field() -> MachineResult<()> {
        let mut config = Machine::default_config()?;
        config.ram.length = 4096;
        let mut machine = Machine::create(&config, &RuntimeConfig::quiet_console())?;

        let htif_tohost = (u64::from(CM_HTIF_DEV_YIELD) << CM_HTIF_DEV_SHIFT)
            | (u64::from(CM_HTIF_YIELD_CMD_MANUAL) << CM_HTIF_CMD_SHIFT)
            | (u64::from(CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED) << CM_HTIF_REASON_SHIFT)
            | 0xFFFF_FFFF;
        machine.write_reg(CM_REG_IFLAGS_Y, 1)?;
        machine.write_reg(CM_REG_HTIF_TOHOST, htif_tohost)?;

        let (_, proof) = machine_validity_proof_for(&mut machine)?;

        assert_eq!(
            word_at(
                &proof.htif_tohost_proof.data_block,
                Machine::reg_address(CM_REG_HTIF_TOHOST)?
            ),
            htif_tohost
        );
        Ok(())
    }

    fn word_at(data_block: &Hash, address: u64) -> u64 {
        let offset = (address & DATA_BLOCK_MASK) as usize;
        u64::from_le_bytes(data_block[offset..offset + 8].try_into().unwrap())
    }
}
