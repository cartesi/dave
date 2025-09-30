use crate::db::dispute_state_access::DisputeStateAccess;
use crate::machine::constants::{
    BARCH_SPAN_TO_INPUT, INPUT_SPAN_TO_EPOCH, LOG2_UARCH_SPAN_TO_BARCH, LOG2_UARCH_SPAN_TO_INPUT,
    UARCH_SPAN_TO_BARCH,
};
use crate::machine::error::Result;
use cartesi_dave_arithmetic as arithmetic;
use cartesi_dave_merkle::Digest;
use cartesi_machine::{
    cartesi_machine_sys,
    config::runtime::{HTIFRuntimeConfig, RuntimeConfig},
    machine::Machine,
    types::access_proof::AccessLog,
    types::{LogType, cmio::CmioResponseReason},
};
use log::trace;
use num_traits::{One, ToPrimitive};

use alloy::primitives::U256;
use std::path::PathBuf;

#[derive(Debug)]
pub struct MachineState {
    pub root_hash: Digest,
    pub halted: bool,
    pub yielded: bool,
    pub uhalted: bool,
}

impl std::fmt::Display for MachineState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "{{root_hash = {}, halted = {}, yielded = {}, uhalted = {}}}",
            self.root_hash.to_hex(),
            self.halted,
            self.yielded,
            self.uhalted,
        )
    }
}

impl MachineState {
    pub fn from_current_machine_state(machine: &mut MachineInstance) -> Result<MachineState> {
        let root_hash = machine.root_hash()?;
        Ok(MachineState {
            root_hash,
            halted: machine.is_halted()?,
            yielded: machine.is_yielded()?,
            uhalted: machine.is_uarch_halted()?,
        })
    }
}

pub type MachineProof = Vec<u8>;

pub struct MachineInstance {
    machine: Machine,
    _start_cycle: u64,
    pub input_count: u64,
    pub cycle: u64,
    pub ucycle: u64,
    pub snapshot_path: PathBuf,
}

const CHECKPOINT_ADDRESS: u64 = 0x7ffff000;
impl MachineInstance {
    pub fn new_from_path(path: &str) -> Result<Self> {
        let runtime_config = RuntimeConfig {
            htif: Some(HTIFRuntimeConfig {
                no_console_putchar: Some(true),
            }),
            ..Default::default()
        };
        let path = PathBuf::from(path);
        let mut machine = Machine::load(&path, &runtime_config)?;

        let _start_cycle = machine.mcycle()?;

        // Machine can never be advanced on the micro arch.
        // Validators must verify this first
        assert_eq!(machine.ucycle()?, 0);

        Ok(MachineInstance {
            machine,
            _start_cycle,
            input_count: 0,
            cycle: 0,
            ucycle: 0,
            snapshot_path: PathBuf::from(path),
        })
    }

    /*
        pub fn take_snapshot(&mut self, base_cycle: u64, db: &DisputeStateAccess) -> Result<()> {
            let mask = arithmetic::max_uint(constants::LOG2_BARCH_SPAN_TO_INPUT);
            if db.handle_rollups && ((base_cycle & mask) == 0) && !self.is_yielded()? {
                // don't snapshot a machine state that's freshly fed with input without advance
                return Ok(());
            }

            let snapshot_path = db.work_path.join(format!("{}", base_cycle));
            if !snapshot_path.exists() {
                self.machine.store(&snapshot_path)?;
            }
            Ok(())
        }

        // load inner machine with snapshot, update cycle, keep everything else the same
        pub fn load_snapshot(&mut self, snapshot_path: &Path, snapshot_cycle: u64) -> Result<()> {
            debug!("load snapshot from {}", snapshot_path.display());
            let runtime_config = RuntimeConfig {
                htif: Some(HTIFRuntimeConfig {
                    no_console_putchar: Some(true),
                }),
                ..Default::default()
            };
            let mut machine = Machine::load(Path::new(snapshot_path), &runtime_config)?;

            let cycle = machine.mcycle()?;
            debug!("cycle: {}, start_cycle: {}", cycle, self.start_cycle);

            // Machine can not go backward behind the initial machine
            assert!(cycle >= self.start_cycle);
            self.cycle = snapshot_cycle;

            assert_eq!(machine.ucycle()?, 0);

            self.machine = machine;

            Ok(())
        }
    */

    pub fn advance_rollups(&mut self, meta_cycle: U256, db: &DisputeStateAccess) -> Result<()> {
        assert!(self.is_yielded()?);

        let input_count = (meta_cycle >> LOG2_UARCH_SPAN_TO_INPUT)
            .to_u64()
            .expect("input count too big to fit in u64");
        let cycle = {
            let c = (meta_cycle >> LOG2_UARCH_SPAN_TO_BARCH) & U256::from(BARCH_SPAN_TO_INPUT);
            c.to_u64().expect("cycle too big to fit in u64")
        };
        let ucycle = (meta_cycle & U256::from(UARCH_SPAN_TO_BARCH))
            .to_u64()
            .expect("ucycle too big to fit in u64");

        let snapshot_path = db.work_path.join(format!("{}", self.root_hash()?.to_hex()));
        if !snapshot_path.exists() {
            self.machine.store(&snapshot_path)?;
        }
        self.snapshot_path = snapshot_path;

        while self.input_count < input_count {
            // snapshot the machine state before feeding the input

            self.feed_next_input(db)?;

            loop {
                self.run(u64::MAX)?;
                if self.is_halted()? | self.is_yielded()? {
                    break;
                }
            }
            assert!(!self.is_halted()?);

            self.input_count += 1;
        }
        assert!(self.input_count == input_count);

        if cycle == 0 && ucycle == 0 {
            return Ok(());
        }

        self.feed_next_input(db)?;

        self.run(cycle)?;
        self.run_uarch(ucycle)?;

        Ok(())
    }

    pub fn new_rollups_advanced_until(
        path: &str,
        meta_cycle: U256,
        db: &DisputeStateAccess,
    ) -> Result<MachineInstance> {
        let input_count = (meta_cycle >> LOG2_UARCH_SPAN_TO_INPUT).to_u64().unwrap();
        assert!(input_count <= INPUT_SPAN_TO_EPOCH);

        let mut machine = MachineInstance::new_from_path(path)?;
        assert!(machine.is_yielded()?);

        machine.advance_rollups(meta_cycle, db)?;
        Ok(machine)
    }

    pub fn feed_next_input(&mut self, db: &DisputeStateAccess) -> Result<()> {
        assert!(self.is_yielded()?);
        let input = db.input(self.input_count)?;
        let root_hash = self.root_hash()?;
        let new_snapshot_path = db.work_path.join(format!("{}", root_hash.to_hex()));
        if let Some(input_bin) = input {
            if !new_snapshot_path.exists() {
                self.machine.store(&new_snapshot_path)?;
                if self.snapshot_path.exists() {
                    std::fs::remove_dir_all(&self.snapshot_path)?;
                }
            }

            self.snapshot_path = new_snapshot_path;
            self.machine
                .write_memory(CHECKPOINT_ADDRESS, root_hash.slice())?;
            self.machine
                .send_cmio_response(CmioResponseReason::Advance, &input_bin)?;
        }
        Ok(())
    }

    pub fn state(&mut self) -> Result<MachineState> {
        MachineState::from_current_machine_state(self)
    }

    pub fn root_hash(&mut self) -> Result<Digest> {
        Ok(self.machine.root_hash()?.into())
    }

    pub fn is_halted(&mut self) -> Result<bool> {
        Ok(self.machine.iflags_h()?)
    }

    pub fn is_yielded(&mut self) -> Result<bool> {
        Ok(self.machine.iflags_y()?)
    }

    pub fn is_uarch_halted(&mut self) -> Result<bool> {
        Ok(self.machine.uarch_halt_flag()?)
    }

    pub fn physical_cycle(&mut self) -> Result<u64> {
        Ok(self.machine.mcycle()?)
    }

    pub fn physical_uarch_cycle(&mut self) -> Result<u64> {
        Ok(self.machine.ucycle()?)
    }

    pub fn revert_if_needed(&mut self) -> Result<()> {
        // revert if needed only when machine yields
        assert!(self.is_yielded()?);

        // we check if the request is accepted
        // if it is not, we revert the machine state to previous snapshot
        if self.machine.receive_cmio_request()?.reason()
            != cartesi_machine::constants::cmio::tohost::manual::RX_ACCEPTED
        {
            trace!("Reject input,revert to previous snapshot");
            let runtime_config = RuntimeConfig {
                htif: Some(HTIFRuntimeConfig {
                    no_console_putchar: Some(true),
                }),
                ..Default::default()
            };

            self.machine = Machine::load(&self.snapshot_path, &runtime_config)?;
        }
        Ok(())
    }

    pub fn run_uarch(&mut self, ucycle: u64) -> Result<()> {
        assert!(
            self.ucycle <= ucycle,
            "{}",
            format!("{}, {}", self.ucycle, ucycle)
        );

        self.machine.run_uarch(ucycle)?;
        self.ucycle = ucycle;

        Ok(())
    }

    // Runs to the `cycle` directly and returns the machine state after the run
    pub fn run(&mut self, cycle: u64) -> Result<MachineState> {
        assert!(self.cycle <= cycle);

        let target_physical_cycle =
            arithmetic::add_and_clamp(self.physical_cycle()?, cycle - self.cycle);

        loop {
            self.machine.run(target_physical_cycle)?;

            let halted = self.is_halted()?;
            if halted {
                panic!("run break with halt");
            }

            if self.is_yielded()? {
                trace!("run break with yield");
                // if it is not reverted, we store the new snapshot and remove the old one
                self.revert_if_needed()?;

                break;
            }

            if self.physical_cycle()? == target_physical_cycle {
                trace!("run break with meeting physical cycle");
                break;
            }
        }

        self.cycle = cycle;

        self.state()
    }

    pub fn increment_uarch(&mut self) -> Result<MachineState> {
        self.machine.run_uarch(self.ucycle + 1)?;
        self.ucycle += 1;
        self.state()
    }

    pub fn ureset(&mut self) -> Result<MachineState> {
        self.machine.reset_uarch()?;
        self.cycle += 1;
        self.ucycle = 0;
        self.state()
    }

    fn prove_read_word(&mut self, address: u64) -> Result<Vec<u8>> {
        // always read aligned 32 bytes (one leaf)
        let aligned_address = address & !0x1Fu64;
        let mut read = self.machine.read_memory(aligned_address, 32)?;
        let proof = self.machine.proof(aligned_address, 5)?;

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
        let proof = self.machine.proof(aligned_address, 5)?;

        let mut encoded: Vec<u8> = Vec::new();

        encoded.append(&mut read);
        encoded.append(&mut read_hash.slice().to_vec());

        let mut decoded_siblings: Vec<u8> =
            proof.sibling_hashes.iter().flatten().cloned().collect();
        encoded.append(&mut decoded_siblings);

        Ok(encoded)
    }

    fn prove_write_leaf(&mut self, address: u64) -> Result<Vec<u8>> {
        // always write aligned 32 bytes (one leaf)
        assert!(address & 0x1F == 0);
        let read = self.machine.read_memory(address, 32)?;
        let read_hash = Digest::from_data(&read);
        // Get proof of write address
        let proof = self.machine.proof(address, 5)?;

        let mut encoded: Vec<u8> = Vec::new();

        encoded.append(&mut read_hash.slice().to_vec());
        let mut decoded_siblings: Vec<u8> =
            proof.sibling_hashes.iter().flatten().cloned().collect();
        encoded.append(&mut decoded_siblings);

        let checkpoint = self.root_hash()?;
        self.machine.write_memory(address, checkpoint.slice())?;

        Ok(encoded)
    }

    fn prove_revert_if_needed(&mut self) -> Result<Vec<u8>> {
        let mut proof = Vec::new();

        let iflags_y_address =
            cartesi_machine::Machine::reg_address(cartesi_machine_sys::CM_REG_IFLAGS_Y)?;
        proof.append(&mut self.prove_read_word(iflags_y_address)?);

        let iflags_y = self.is_yielded()?;
        if iflags_y {
            let to_host_address =
                cartesi_machine::Machine::reg_address(cartesi_machine_sys::CM_REG_HTIF_TOHOST)?;
            proof.append(&mut self.prove_read_word(to_host_address)?);

            if self.machine.receive_cmio_request()?.reason()
                != cartesi_machine::constants::cmio::tohost::manual::RX_ACCEPTED
            {
                proof.append(&mut self.prove_read_leaf(CHECKPOINT_ADDRESS)?);
            }
        }
        Ok(proof)
    }

    fn encode_access_logs(logs: Vec<&AccessLog>) -> Vec<u8> {
        let mut encoded: Vec<Vec<u8>> = Vec::new();

        for log in logs.into_iter() {
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
        }

        encoded.iter().flatten().cloned().collect()
    }

    fn encode_da(input_bin: &[u8]) -> Vec<u8> {
        let input_size_be = (input_bin.len() as u64).to_be_bytes().to_vec();
        let mut da_proof = input_size_be;
        da_proof.extend_from_slice(input_bin);
        da_proof
    }

    fn get_logs_rollups(
        path: &str,
        agree_hash: Digest,
        meta_cycle: U256,
        db: &DisputeStateAccess,
    ) -> Result<(Vec<u8>, Digest)> {
        let input_mask = (U256::one() << LOG2_UARCH_SPAN_TO_INPUT) - U256::one();
        let big_step_mask = UARCH_SPAN_TO_BARCH;

        assert!(((meta_cycle >> LOG2_UARCH_SPAN_TO_INPUT) & !input_mask).is_zero());

        let meta_cycle_u128 = meta_cycle
            .to_u128()
            .expect("meta_cycle is too large to fit in u128");
        let input_count = (meta_cycle_u128 >> LOG2_UARCH_SPAN_TO_INPUT) as u64;

        let mut logs = Vec::new();

        let mut machine = MachineInstance::new_rollups_advanced_until(path, meta_cycle, db)?;
        assert_eq!(machine.state()?.root_hash, agree_hash);

        if (meta_cycle & input_mask).is_zero() {
            let input = db.input(input_count)?;
            let mut da_proof;
            let cmio_log;

            if let Some(input_bin) = input {
                let write_checkpoint_proof = machine.prove_write_leaf(CHECKPOINT_ADDRESS)?;
                cmio_log = machine.machine.log_send_cmio_response(
                    CmioResponseReason::Advance,
                    &input_bin,
                    LogType::default(),
                )?;

                logs.push(&cmio_log);
                da_proof = Self::encode_da(&input_bin);
                da_proof = [da_proof, write_checkpoint_proof].concat();
            } else {
                da_proof = Self::encode_da(&[]);
            }

            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);

            let cmio_step_proof = Self::encode_access_logs(logs);
            let proof = [da_proof, cmio_step_proof].concat();
            Ok((proof, machine.state()?.root_hash))
        } else if ((meta_cycle_u128 + 1) & (big_step_mask as u128)) == 0 {
            assert!(machine.is_uarch_halted()?);

            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);
            let ureset_log = machine.machine.log_reset_uarch(LogType::default())?;
            logs.push(&ureset_log);
            let step_reset_proof = Self::encode_access_logs(logs);
            let revert_proof = machine.prove_revert_if_needed()?;

            Ok((
                [step_reset_proof, revert_proof].concat(),
                machine.state()?.root_hash,
            ))
        } else {
            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);
            Ok((Self::encode_access_logs(logs), machine.state()?.root_hash))
        }
    }

    pub fn get_logs(
        path: &str,
        agree_hash: Digest,
        meta_cycle: U256,
        db: &DisputeStateAccess,
    ) -> Result<(Vec<u8>, Digest)> {
        let (proofs, next_hash);

        let result = Self::get_logs_rollups(path, agree_hash, meta_cycle, db)?;
        proofs = result.0;
        next_hash = result.1;

        Ok((proofs, next_hash))
    }

    pub fn position(&mut self) -> Result<(u64, u64)> {
        Ok((self.cycle, self.ucycle))
    }
}
