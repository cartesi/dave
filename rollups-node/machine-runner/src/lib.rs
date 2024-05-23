use anyhow::Result;
use std::{path::Path, sync::Arc, time::SystemTime};

use cartesi_machine::{configuration::RuntimeConfig, BreakReason, HtifYieldReason};
use rollups_state_manager::StateManager;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Halted {
    Yes,
    No,
}

pub struct Machine {
    machine: cartesi_machine::Machine,
}

impl Machine {
    pub fn load(path: &Path, runtime: RuntimeConfig) -> Result<Machine> {
        let machine = cartesi_machine::Machine::load(path, runtime)?;
        Ok(Self { machine })
    }

    fn feed(&mut self, input: &[u8]) -> Result<()> {
        self.machine
            .send_cmio_response(HtifYieldReason::HtifYieldReasonAdvanceState, input)?;
        Ok(())
    }

    pub fn advance(&mut self, data: &[u8]) -> Result<Halted> {
        loop {
            self.machine.reset_iflags_y()?;
            self.feed(data)?;

            let reason = self.machine.run(u64::MAX)?;

            match reason {
                BreakReason::YieldedAutomatically => continue,
                BreakReason::YieldedManually => return Ok(Halted::No),
                _ => return Ok(Halted::Yes),
            }
        }
    }

    pub async fn start(
        s: Arc<StateManager>,
        initial_machine: &str,
        snapshot_frequency: u64,
    ) -> Result<()> {
        let (snapshot, mut epoch_number, mut next_input_index) = match s.latest_snapshot()? {
            Some(r) => (r.0, r.1, r.2 + 1),
            None => (initial_machine.to_string(), 0, 0),
        };
        let mut machine = Machine::load(&Path::new(&snapshot), RuntimeConfig::default())?;
        let mut now = SystemTime::now();

        loop {
            match s.input(epoch_number, next_input_index) {
                Ok(input) => {
                    machine.advance(&input)?;
                    let machine_state = machine.machine.get_root_hash()?;
                    s.add_state(machine_state.as_bytes(), epoch_number, next_input_index)?;

                    if now.elapsed()?.as_secs() > (snapshot_frequency * 60) {
                        // take snapshot every 20 minutes
                        let path = machine_state.to_string();
                        machine.machine.store(&Path::new(&path))?;
                        s.add_snapshot(&path, epoch_number, next_input_index)?;
                        now = SystemTime::now();
                    }
                    next_input_index += 1;
                }
                Err(_) => {
                    // fail to get next input, try get input 0 from next epoch
                    if s.input(epoch_number + 1, 0).is_ok() {
                        // new epoch starts and current epoch closes
                        // TODO: calculate computation-hash
                        epoch_number += 1;
                        next_input_index = 0;
                    }
                }
            }
        }
    }
}
