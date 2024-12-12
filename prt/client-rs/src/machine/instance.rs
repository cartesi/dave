use crate::db::compute_state_access::{ComputeStateAccess, Input};
use crate::machine::constants;
use cartesi_dave_arithmetic as arithmetic;
use cartesi_dave_merkle::Digest;
use cartesi_machine::{
    configuration::RuntimeConfig,
    htif,
    log::{AccessLog, AccessLogType},
    machine::Machine,
};
use log::{debug, trace};

use alloy::hex::ToHexExt;
use anyhow::Result;
use ruint::aliases::U256;
use std::path::Path;

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
    pub fn take_snapshot(&mut self, base_cycle: u64, db: &ComputeStateAccess) -> Result<()> {
        let mask = arithmetic::max_uint(constants::LOG2_EMULATOR_SPAN);
        if db.handle_rollups && base_cycle & mask == 0 {
            // don't snapshot a machine state that's freshly fed with input without advance
            assert!(
                self.machine_state()?.yielded,
                "don't snapshot a machine state that's freshly fed with input without advance",
            );
        }

        let snapshot_path = db.work_path.join(format!("{}", base_cycle));
        if !snapshot_path.exists() {
            self.machine.store(&snapshot_path)?;
        }
        Ok(())
    }

    // load inner machine with snapshot, update cycle, keep everything else the same
    pub fn load_snapshot(&mut self, snapshot_path: &Path, snapshot_cycle: u64) -> Result<()> {
        let machine = Machine::load(&Path::new(snapshot_path), RuntimeConfig::default())?;

        let cycle = machine.read_mcycle()?;

        // Machine can not go backward behind the initial machine
        assert!(cycle >= self.start_cycle);
        self.cycle = snapshot_cycle;

        assert_eq!(machine.read_uarch_cycle()?, 0);

        self.machine = machine;

        debug!("load snapshot from {}", snapshot_path.display());
        debug!("loaded machine: {}", self.machine_state()?);

        Ok(())
    }

    pub fn root_hash(&self) -> Digest {
        self.root_hash
    }

    pub fn get_logs(
        &mut self,
        cycle: u64,
        ucycle: u64,
        db: &ComputeStateAccess,
    ) -> Result<MachineProof> {
        let log_type = AccessLogType {
            annotations: true,
            proofs: true,
            large_data: false,
        };

        let mut logs = Vec::new();
        let mut encode_input = None;
        if db.handle_rollups {
            // treat it as rollups
            // the cycle may be the cycle to receive input,
            // we need to include the process of feeding input to the machine in the log
            if cycle == 0 {
                self.run(cycle)?;
            } else {
                self.run_with_inputs(cycle - 1, db)?;
                self.run(cycle)?;
            }

            let mask = arithmetic::max_uint(constants::LOG2_EMULATOR_SPAN);
            let inputs = &db.inputs()?;
            let input = inputs.get((cycle >> constants::LOG2_EMULATOR_SPAN) as usize);
            if cycle & mask == 0 {
                if let Some(data) = input {
                    // need to process input
                    if ucycle == 0 {
                        let cmio_logs = self.machine.log_send_cmio_response(
                            htif::fromhost::ADVANCE_STATE,
                            &data,
                            log_type,
                            false,
                        )?;
                        // append step logs to cmio logs
                        let step_logs = self.machine.log_uarch_step(log_type, false)?;
                        logs.push(&cmio_logs);
                        logs.push(&step_logs);
                        return Ok(encode_access_logs(logs, Some(Input { 0: data.clone() })));
                    } else {
                        self.machine
                            .send_cmio_response(htif::fromhost::ADVANCE_STATE, &data)?;
                    }
                } else {
                    if ucycle == 0 {
                        encode_input = Some(Input { 0: Vec::new() });
                    }
                }
            }
        } else {
            // treat it as compute
            self.run(cycle)?;
        }

        self.run_uarch(ucycle)?;
        if ucycle == constants::UARCH_SPAN {
            let reset_logs = self.machine.log_uarch_reset(log_type, false)?;
            logs.push(&reset_logs);
            Ok(encode_access_logs(logs, encode_input))
        } else {
            let step_logs = self.machine.log_uarch_step(log_type, false)?;
            logs.push(&step_logs);
            Ok(encode_access_logs(logs, encode_input))
        }
    }

    // Runs to the `cycle` directly and returns the machine state after the run
    pub fn run(&mut self, cycle: u64) -> Result<MachineState> {
        assert!(self.cycle <= cycle);

        let mcycle = self.machine.read_mcycle()?;

        let physical_cycle = arithmetic::add_and_clamp(mcycle, cycle - self.cycle);
        trace!("physical cycle {}", physical_cycle);

        loop {
            let halted = self.machine.read_iflags_h()?;
            if halted {
                trace!("run break with halt");
                break;
            }

            let yielded = self.machine.read_iflags_y()?;
            if yielded {
                trace!("run break with yield");
                break;
            }

            if self.machine.read_mcycle()? == physical_cycle {
                trace!("run break with meeting physical cycle");
                break;
            }

            self.machine.run(physical_cycle)?;
        }

        self.cycle = cycle;

        Ok(self.machine_state()?)
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

    // Runs to the `cycle` with all necessary inputs added to the machine
    // Returns the machine state after the run;
    // One exception is that if `cycle` is supposed to receive an input, in this case
    // the machine state would be `without` input included in the machine,
    // this is useful when we need the initial state to compute the commitments
    pub fn run_with_inputs(&mut self, cycle: u64, db: &ComputeStateAccess) -> Result<MachineState> {
        trace!(
            "run_with_inputs self cycle: {}, target cycle: {}",
            self.cycle,
            cycle
        );

        let inputs = &db.inputs()?;
        let mut machine_state_without_input = self.machine_state()?;
        let input_mask = arithmetic::max_uint(constants::LOG2_EMULATOR_SPAN);
        let current_input_index = self.cycle >> constants::LOG2_EMULATOR_SPAN;

        let mut next_input_index;

        if self.cycle & input_mask == 0 {
            next_input_index = current_input_index;
        } else {
            next_input_index = current_input_index + 1;
        }
        let mut next_input_cycle = next_input_index << constants::LOG2_EMULATOR_SPAN;

        while next_input_cycle <= cycle {
            trace!("next input index: {}", next_input_index);
            trace!("run to next input cycle: {}", next_input_cycle);
            machine_state_without_input = self.run(next_input_cycle)?;
            if next_input_cycle == cycle {
                self.take_snapshot(next_input_cycle, &db)?;
            }

            let input = inputs.get(next_input_index as usize);
            if let Some(data) = input {
                trace!(
                    "before input, machine state: {}",
                    self.machine_state()?.root_hash
                );
                trace!("input: 0x{}", data.encode_hex());

                self.machine
                    .send_cmio_response(htif::fromhost::ADVANCE_STATE, data)?;

                trace!(
                    "after input, machine state: {}",
                    self.machine_state()?.root_hash
                );
            }

            next_input_index += 1;
            next_input_cycle = next_input_index << constants::LOG2_EMULATOR_SPAN;
        }
        if cycle > self.cycle {
            machine_state_without_input = self.run(cycle)?;
            self.take_snapshot(cycle, &db)?;
        }
        Ok(machine_state_without_input)
    }

    pub fn increment_uarch(&mut self) -> Result<MachineState> {
        self.machine.run_uarch(self.ucycle + 1)?;
        self.ucycle += 1;
        Ok(self.machine_state()?)
    }

    pub fn ureset(&mut self) -> Result<MachineState> {
        self.machine.reset_uarch()?;
        self.cycle += 1;
        self.ucycle = 0;
        Ok(self.machine_state()?)
    }

    pub fn machine_state(&mut self) -> Result<MachineState> {
        let root_hash = self.machine.get_root_hash()?;
        let halted = self.machine.read_iflags_h()?;
        let yielded = self.machine.read_iflags_y()?;
        let uhalted = self.machine.read_uarch_halt_flag()?;

        Ok(MachineState {
            root_hash: Digest::from_digest(root_hash.as_bytes())?,
            halted,
            yielded,
            uhalted,
        })
    }

    pub fn write_memory(&mut self, address: u64, data: String) -> Result<()> {
        self.machine
            .write_memory(address, &hex::decode(data.as_bytes())?)?;
        Ok(())
    }

    pub fn position(&self) -> Result<(u64, u64, u64)> {
        Ok((self.cycle, self.ucycle, self.machine.read_mcycle()?))
    }
}

fn encode_access_logs(logs: Vec<&AccessLog>, encode_input: Option<Input>) -> Vec<u8> {
    let mut encoded: Vec<Vec<u8>> = Vec::new();

    if let Some(i) = encode_input {
        encoded.push(U256::from(i.0.len()).to_be_bytes_vec());
        if i.0.len() > 0 {
            encoded.push(i.0);
        }
    }

    for log in logs.iter() {
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
    }

    encoded.iter().flatten().cloned().collect()
}
