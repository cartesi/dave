use crate::machine::constants;
use cartesi_dave_arithmetic as arithmetic;
use cartesi_dave_merkle::Digest;
use cartesi_machine::{
    configuration::RuntimeConfig,
    htif,
    log::{AccessLog, AccessLogType},
    machine::Machine,
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

    // load inner machine with snapshot, update cycle, keep everything else the same
    pub fn load_snapshot(&mut self, snapshot_path: &Path) -> Result<()> {
        let machine = Machine::load(&Path::new(snapshot_path), RuntimeConfig::default())?;

        let cycle = machine.read_mcycle()?;

        // Machine can not go backward behind the initial machine
        assert!(cycle >= self.start_cycle);
        self.cycle = cycle - self.start_cycle;

        assert_eq!(machine.read_uarch_cycle()?, 0);

        self.machine = machine;

        Ok(())
    }

    pub fn snapshot(&self, snapshot_path: &Path) -> Result<()> {
        if !snapshot_path.exists() {
            self.machine.store(snapshot_path)?;
        }
        Ok(())
    }

    pub fn root_hash(&self) -> Digest {
        self.root_hash
    }

    pub fn get_logs(
        &mut self,
        cycle: u64,
        ucycle: u64,
        input: Option<Vec<u8>>,
    ) -> Result<MachineProof> {
        self.run(cycle)?;

        let log_type = AccessLogType {
            annotations: true,
            proofs: true,
            large_data: false,
        };

        let mask = 1 << constants::LOG2_EMULATOR_SPAN - 1;
        if cycle & mask == 0 && input.is_some() {
            // need to process input
            let data = input.unwrap();
            if ucycle == 0 {
                let cmio_logs = self.machine.log_send_cmio_response(
                    htif::fromhost::ADVANCE_STATE,
                    &data,
                    log_type,
                    false,
                )?;
                // append step logs to cmio logs
                let step_logs = self.machine.log_uarch_step(log_type, false)?;
                let mut logs_encoded = encode_access_log(&cmio_logs);
                let mut step_logs_encoded = encode_access_log(&step_logs);
                logs_encoded.append(&mut step_logs_encoded);
                return Ok(logs_encoded);
            } else {
                self.machine
                    .send_cmio_response(htif::fromhost::ADVANCE_STATE, &data)?;
            }
        }

        self.run_uarch(ucycle)?;
        if ucycle == constants::UARCH_SPAN {
            let reset_logs = self.machine.log_uarch_reset(log_type, false)?;
            Ok(encode_access_log(&reset_logs))
        } else {
            let step_logs = self.machine.log_uarch_step(log_type, false)?;
            Ok(encode_access_log(&step_logs))
        }
    }

    pub fn run(&mut self, cycle: u64) -> Result<()> {
        assert!(self.cycle <= cycle);

        let physical_cycle = arithmetic::add_and_clamp(self.start_cycle, cycle);

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

fn encode_access_log(log: &AccessLog) -> Vec<u8> {
    let mut encoded: Vec<Vec<u8>> = Vec::new();

    for a in log.accesses().iter() {
        if a.log2_size() == 3 {
            encoded.push(a.read_data().to_vec());
        } else {
            encoded.push(a.read_hash().as_bytes().to_vec());
        }

        let decoded_siblings: Vec<Vec<u8>> = a
            .sibling_hashes()
            .iter()
            .map(|h| h.as_bytes().to_vec())
            .collect();
        encoded.extend_from_slice(&decoded_siblings);
    }

    encoded.iter().flatten().cloned().collect()
}
