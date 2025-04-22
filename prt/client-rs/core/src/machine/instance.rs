use crate::db::compute_state_access::ComputeStateAccess;
use crate::machine::constants::{
    self, INPUT_SPAN_TO_EPOCH, LOG2_UARCH_SPAN_TO_BARCH, LOG2_UARCH_SPAN_TO_INPUT,
    UARCH_SPAN_TO_BARCH,
};
use crate::machine::error::Result;
use cartesi_dave_arithmetic as arithmetic;
use cartesi_dave_merkle::Digest;
use cartesi_machine::config::runtime::HTIFRuntimeConfig;
use cartesi_machine::types::LogType;
use cartesi_machine::types::cmio::CmioResponseReason;
use cartesi_machine::{
    config::runtime::RuntimeConfig, machine::Machine, types::access_proof::AccessLog,
};
use log::{debug, trace};
use num_traits::{One, ToPrimitive};

use alloy::primitives::U256;
use std::path::{Path, PathBuf};
use std::u64;

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
            self.uhalted
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
    start_cycle: u64,
    input_count: u64,
    cycle: u64,
    ucycle: u64,
}

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

        let start_cycle = machine.mcycle()?;

        // Machine can never be advanced on the micro arch.
        // Validators must verify this first
        assert_eq!(machine.ucycle()?, 0);

        Ok(MachineInstance {
            machine,
            start_cycle,
            input_count: 0,
            cycle: 0,
            ucycle: 0,
        })
    }

    pub fn take_snapshot(&mut self, base_cycle: u64, db: &ComputeStateAccess) -> Result<()> {
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

    pub fn advance_rollups(&mut self, meta_cycle: U256, db: &ComputeStateAccess) -> Result<()> {
        assert!(self.is_yielded()?);

        let meta_cycle_u128 = meta_cycle
            .to_u128()
            .expect("meta_cycle is too large to fit in u128");
        let input_count = (meta_cycle >> LOG2_UARCH_SPAN_TO_INPUT)
            .to_u64()
            .expect("input count too big to fit in u64");
        let cycle = (meta_cycle_u128 >> LOG2_UARCH_SPAN_TO_BARCH) as u64;
        let ucycle = (meta_cycle_u128 & (UARCH_SPAN_TO_BARCH as u128)) as u64;

        while self.input_count < input_count {
            let input = db.input(self.input_count)?;
            if input.is_none() {
                self.input_count = input_count;
                break;
            }

            let input_bin = input.unwrap();
            self.machine
                .send_cmio_response(CmioResponseReason::Advance, &input_bin)?;

            loop {
                self.machine.run(u64::MAX)?;
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

        let input = db.input(self.input_count)?;
        if let Some(input_bin) = input {
            self.machine
                .send_cmio_response(CmioResponseReason::Advance, &input_bin)?;
        }

        self.run(cycle)?;
        self.run_uarch(ucycle)?;

        Ok(())
    }

    pub fn new_rollups_advanced_until(
        path: &str,
        meta_cycle: U256,
        db: &ComputeStateAccess,
    ) -> Result<MachineInstance> {
        let meta_cycle_u128 = meta_cycle
            .to_u128()
            .expect("meta_cycle is too large to fit in u128");

        let input_count = (meta_cycle_u128 >> LOG2_UARCH_SPAN_TO_INPUT) as u64;
        assert!(input_count <= INPUT_SPAN_TO_EPOCH);

        let mut machine = MachineInstance::new_from_path(path)?;

        // load snapshot
        // let base_cycle = (meta_cycle >> LOG2_UARCH_SPAN_TO_BARCH)
        //     .to_u64()
        //     .expect("base_cycle is too large to fit in u64");
        // if let Some(snapshot) = db.closest_snapshot(base_cycle)? {
        //     machine.load_snapshot(&snapshot.1, snapshot.0)?;
        // };

        machine.advance_rollups(meta_cycle, db)?;
        Ok(machine)
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
                trace!("run break with halt");
                break;
            }

            let yielded = self.is_yielded()?;
            if yielded {
                trace!("run break with yield");
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

    fn get_logs_compute(
        path: &str,
        agree_hash: Digest,
        meta_cycle: U256,
        db: &ComputeStateAccess,
    ) -> Result<(Vec<u8>, Digest)> {
        let meta_cycle_u128 = meta_cycle
            .to_u128()
            .expect("meta_cycle is too large to fit in u128");
        let big_step_mask = UARCH_SPAN_TO_BARCH as u128;

        let base_cycle = (meta_cycle_u128 >> LOG2_UARCH_SPAN_TO_BARCH) as u64;
        let ucycle = (meta_cycle_u128 & big_step_mask) as u64;

        let mut machine = MachineInstance::new_from_path(path)?;
        if let Some(snapshot_path) = db.closest_snapshot(base_cycle)? {
            machine.load_snapshot(&snapshot_path.1, snapshot_path.0)?;
        }
        machine.run(base_cycle)?;
        machine.run_uarch(ucycle)?;
        assert_eq!(machine.state()?.root_hash, agree_hash);

        let mut logs = Vec::new();
        if (meta_cycle_u128 + 1) & big_step_mask == 0 {
            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);
            let ureset_log = machine.machine.log_reset_uarch(LogType::default())?;
            logs.push(&ureset_log);
            Ok((Self::encode_access_logs(logs), machine.state()?.root_hash))
        } else {
            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);
            Ok((Self::encode_access_logs(logs), machine.state()?.root_hash))
        }
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
        db: &ComputeStateAccess,
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
            let da_proof;
            let cmio_log;

            if let Some(input_bin) = input {
                cmio_log = machine.machine.log_send_cmio_response(
                    CmioResponseReason::Advance,
                    &input_bin,
                    LogType::default(),
                )?;

                logs.push(&cmio_log);
                da_proof = Self::encode_da(&input_bin);
            } else {
                da_proof = Self::encode_da(&[]);
            }

            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);

            let step_proof = Self::encode_access_logs(logs);
            let proof = [da_proof, step_proof].concat();
            return Ok((proof, machine.state()?.root_hash));
        } else {
            if ((meta_cycle_u128 + 1) & (big_step_mask as u128)) == 0 {
                assert!(machine.is_uarch_halted()?);

                let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
                logs.push(&uarch_step_log);
                let ureset_log = machine.machine.log_reset_uarch(LogType::default())?;
                logs.push(&ureset_log);

                return Ok((Self::encode_access_logs(logs), machine.state()?.root_hash));
            } else {
                let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
                logs.push(&uarch_step_log);
                return Ok((Self::encode_access_logs(logs), machine.state()?.root_hash));
            }
        }
    }

    pub fn get_logs(
        path: &str,
        agree_hash: Digest,
        meta_cycle: U256,
        db: &ComputeStateAccess,
    ) -> Result<(Vec<u8>, Digest)> {
        let (proofs, next_hash);

        if db.handle_rollups {
            let result = Self::get_logs_rollups(path, agree_hash, meta_cycle, db)?;
            proofs = result.0;
            next_hash = result.1;
        } else {
            let result = Self::get_logs_compute(path, agree_hash, meta_cycle, db)?;
            proofs = result.0;
            next_hash = result.1;
        }

        Ok((proofs, next_hash))
    }

    pub fn position(&mut self) -> Result<(u64, u64)> {
        Ok((self.cycle, self.ucycle))
    }
}
