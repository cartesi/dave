//! Module for communication with the Cartesi machine using RPC.

use crate::{machine::constants, merkle::Digest, utils::arithmetic};
use cartesi_machine::{
    configuration::RuntimeConfig,
    log::{AccessLog, AccessLogType, AccessType},
    Machine,
};

use anyhow::Result;
use std::path::Path;

#[derive(Debug)]
pub struct MachineState {
    pub root_hash: Digest,
    pub halted: bool,
    pub uhalted: bool,
}

impl std::fmt::Display for MachineState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "{{root_hash = {:?}, halted = {}, uhalted = {}}}",
            self.root_hash, self.halted, self.uhalted
        )
    }
}

pub type MachineProof = Vec<u8>;

pub struct MachineInstance {
    machine: Machine,
    root_hash: Digest,
    start_cycle: u64,
    cycle: u64,
    ucycle: u64,
}

impl MachineInstance {
    pub fn new(snapshot_path: &str) -> Result<Self> {
        let mut machine = Machine::load(&Path::new(snapshot_path), RuntimeConfig::default())?;

        let root_hash = machine.get_root_hash()?;
        let start_cycle = machine.read_mcycle()?;

        // Machine can never be advanced on the micro arch.
        // Validators must verify this first
        assert_eq!(machine.read_uarch_cycle()?, 0);

        Ok(MachineInstance {
            machine,
            start_cycle,
            root_hash: Digest::from_digest(root_hash.as_bytes())?,
            cycle: 0,
            ucycle: 0,
        })
    }

    pub fn root_hash(&self) -> Digest {
        self.root_hash
    }

    pub fn get_logs(&mut self, cycle: u64, ucycle: u64) -> Result<MachineProof> {
        self.run(cycle)?;
        self.run_uarch(ucycle)?;

        let access_log = AccessLogType {
            annotations: true,
            proofs: true,
            large_data: false,
        };
        let logs;

        if ucycle == constants::UARCH_SPAN {
            logs = self.machine.log_uarch_reset(access_log, false)?;
        } else {
            logs = self.machine.log_uarch_step(access_log, false)?;
        }

        Ok(encode_access_log(&logs))
    }

    pub fn run(&mut self, cycle: u64) -> Result<()> {
        assert!(self.cycle <= cycle);

        let physical_cycle = add_and_clamp(self.start_cycle, cycle);

        loop {
            let halted = self.machine.read_iflags_h()?;
            if halted {
                break;
            }

            let mcycle = self.machine.read_mcycle()?;
            if mcycle == physical_cycle {
                break;
            }

            self.machine.run(physical_cycle)?;
        }

        self.cycle = cycle;

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

    pub fn increment_uarch(&mut self) -> Result<()> {
        self.machine.run_uarch(self.ucycle + 1)?;
        self.ucycle += 1;
        Ok(())
    }

    pub fn ureset(&mut self) -> Result<()> {
        self.machine.reset_uarch()?;
        self.cycle += 1;
        self.ucycle = 0;
        Ok(())
    }

    pub fn machine_state(&mut self) -> Result<MachineState> {
        let root_hash = self.machine.get_root_hash()?;
        let halted = self.machine.read_iflags_h()?;
        let uhalted = self.machine.read_uarch_halt_flag()?;

        Ok(MachineState {
            root_hash: Digest::from_digest(root_hash.as_bytes())?,
            halted,
            uhalted,
        })
    }

    pub fn write_memory(&mut self, address: u64, data: String) -> Result<()> {
        self.machine
            .write_memory(address, &hex::decode(data.as_bytes())?)?;
        Ok(())
    }

    pub fn position(&self) -> (u64, u64) {
        (self.cycle, self.ucycle)
    }
}

fn add_and_clamp(x: u64, y: u64) -> u64 {
    if x < arithmetic::max_uint(64) - y {
        x + y
    } else {
        arithmetic::max_uint(64)
    }
}

fn encode_access_log(log: &AccessLog) -> Vec<u8> {
    let mut encoded: Vec<Vec<u8>> = Vec::new();

    for a in log.accesses().iter() {
        assert_eq!(a.log2_size(), 3);
        if a.access_type() == AccessType::Read {
            encoded.push(a.read_data().to_vec());
        }

        encoded.push(a.read_hash().as_bytes().to_vec());

        let decoded_siblings: Vec<Vec<u8>> = a
            .sibling_hashes()
            .iter()
            .map(|h| h.as_bytes().to_vec())
            .collect();
        encoded.extend_from_slice(&decoded_siblings);
    }

    encoded.iter().flatten().cloned().collect()
}
