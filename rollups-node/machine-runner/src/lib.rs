use anyhow::Result;
use std::{path::Path, sync::Arc, time::SystemTime};

use cartesi_machine::{configuration::RuntimeConfig, BreakReason, HtifYieldReason, Machine};
use rollups_state_manager::StateManager;

pub struct MachineRunner {
    machine: Machine,
}

impl MachineRunner {
    fn feed(&mut self, input: &[u8]) -> Result<()> {
        self.machine
            .send_cmio_response(HtifYieldReason::HtifYieldReasonAdvanceState, input)?;
        Ok(())
    }

    fn advance(&mut self, data: &[u8]) -> Result<()> {
        self.feed(data)?;
        self.machine.reset_iflags_y()?;
        let reason = self.machine.run(u64::MAX)?;

        // any break reason except `YieldedManually` is considered an error
        match reason {
            BreakReason::YieldedManually => Ok(()),
            _ => Err(anyhow::anyhow!(reason.to_string())),
        }
    }

    pub async fn start(
        s: Arc<StateManager>,
        initial_machine: &str,
        snapshot_frequency: u64,
    ) -> Result<()> {
        let (snapshot, mut epoch_number, mut next_input_index_in_epoch) =
            match s.latest_snapshot()? {
                Some(r) => (r.0, r.1, r.2 + 1),
                None => (initial_machine.to_string(), 0, 0),
            };
        let mut machine = Self {
            machine: Machine::load(&Path::new(&snapshot), RuntimeConfig::default())?,
        };
        let mut now = SystemTime::now();

        loop {
            match s.input(epoch_number, next_input_index_in_epoch) {
                Ok(input) => {
                    machine.advance(&input)?;
                    let machine_state_hash = machine.machine.get_root_hash()?;
                    s.add_machine_state_hash(
                        machine_state_hash.as_bytes(),
                        epoch_number,
                        next_input_index_in_epoch,
                    )?;

                    if now.elapsed()?.as_secs() > (snapshot_frequency * 60) {
                        // take snapshot every `snapshot_frequency` minutes
                        let path = machine_state_hash.to_string();
                        machine.machine.store(&Path::new(&path))?;
                        s.add_snapshot(&path, epoch_number, next_input_index_in_epoch)?;
                        now = SystemTime::now();
                    }
                    next_input_index_in_epoch += 1;
                }
                Err(_) => {
                    // fail to get next input, try get input 0 from next epoch
                    if s.input(epoch_number + 1, 0).is_ok() {
                        // new epoch starts and current epoch closes
                        // TODO: calculate computation-hash
                        epoch_number += 1;
                        next_input_index_in_epoch = 0;
                    }
                }
            }
        }
    }
}
