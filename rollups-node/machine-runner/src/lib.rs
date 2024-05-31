use anyhow::Result;
use std::{path::Path, sync::Arc, thread::sleep, time::Duration};

use cartesi_machine::{break_reason, configuration::RuntimeConfig, htif, machine::Machine};
use rollups_state_manager::{InputId, StateManager};

pub struct MachineRunner<SM: StateManager> {
    machine: Machine,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    _snapshot_frequency: Duration,

    epoch_number: u64,
    next_input_index_in_epoch: u64,
}

impl<SM: StateManager> MachineRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        state_manager: Arc<SM>,
        initial_machine: &str,
        sleep_duration: Duration,
        _snapshot_frequency: Duration,
    ) -> Result<Self> {
        let (snapshot, epoch_number, next_input_index_in_epoch) =
            match state_manager.latest_snapshot()? {
                Some(r) => (r.0, r.1, r.2 + 1),
                None => (initial_machine.to_string(), 0, 0),
            };

        let machine = Machine::load(&Path::new(&snapshot), RuntimeConfig::default())?;

        Ok(Self {
            machine,
            sleep_duration,
            state_manager,
            _snapshot_frequency,
            epoch_number,
            next_input_index_in_epoch,
        })
    }

    pub fn start(&mut self) -> Result<()> {
        loop {
            self.process_rollup()?;

            // all inputs have been processed up to this point,
            // sleep and come back later
            sleep(self.sleep_duration);
        }
        // TODO: snapshot after some time

        Ok(())
    }

    fn process_rollup(&mut self) -> Result<()> {
        // process all inputs that are currently availalble
        loop {
            self.advance_epoch()?;
            let latest_epoch = self.state_manager.epoch_count()?;

            if self.epoch_number == latest_epoch {
                break Ok(());
            } else if self.epoch_number < latest_epoch {
                self.epoch_number += 1;
                self.next_input_index_in_epoch = 0;
            } else {
                // self.epoch_number > latest_epoch
                break Err(anyhow::anyhow!(
                    "current epoch is greater than latest epoch on blockchain"
                ));
            }
        }
    }

    fn advance_epoch(&mut self) -> Result<()> {
        loop {
            let next = self.state_manager.input(&InputId {
                epoch_number: self.epoch_number,
                input_index_in_epoch: self.next_input_index_in_epoch,
            })?;

            match next {
                Some(input) => {
                    self.process_input(&input.data)?;
                    self.next_input_index_in_epoch += 1;
                }
                None => {
                    break;
                }
            }
        }

        Ok(())
    }

    fn process_input(&mut self, data: &[u8]) -> Result<()> {
        // TODO: setup constants
        let stride = 1 << 30;
        let b = 1 << 48;
        //

        self.feed_input(data)?;
        self.run_machine(stride)?;

        let mut i: u64 = 0;
        while !self.machine.read_iflags_y()? {
            self.add_state_hash(1)?;
            self.run_machine(stride)?;
            i += 1;
        }
        self.add_state_hash(b - i)?;

        Ok(())
    }

    fn feed_input(&mut self, input: &[u8]) -> Result<()> {
        self.machine
            .send_cmio_response(htif::fromhost::ADVANCE_STATE, input)?;
        self.machine.reset_iflags_y()?;
        Ok(())
    }

    fn run_machine(&mut self, cycles: u64) -> Result<()> {
        let mcycle = self.machine.read_mcycle()?;

        loop {
            let reason = self.machine.run(mcycle + cycles)?;
            match reason {
                break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => continue,
                break_reason::YIELDED_MANUALLY | break_reason::REACHED_TARGET_MCYCLE => {
                    return Ok(())
                }
                _ => return Err(anyhow::anyhow!(reason.to_string())),
            }
        }
    }

    fn add_state_hash(&mut self, repetitions: u64) -> Result<()> {
        let machine_state_hash = self.machine.get_root_hash()?;
        self.state_manager.add_machine_state_hash(
            machine_state_hash.as_bytes(),
            self.epoch_number,
            self.next_input_index_in_epoch,
            repetitions,
        )?;

        Ok(())
    }

    /*
    pub fn start(&mut self) -> Result<()> {
        let mut now = SystemTime::now();

        loop {
            match self
                .state_manager
                .input(self.epoch_number, self.next_input_index_in_epoch)
            {
                Ok(input) => {
                    self.process_input(&input)?;

                    //                     if now.elapsed()?.as_secs() > (snapshot_frequency * 60) {
                    //                         // take snapshot every `snapshot_frequency` minutes
                    //                         let path = machine_state_hash.to_string();
                    //                         machine.machine.store(&Path::new(&path))?;
                    //                         s.add_snapshot(&path, epoch_number, next_input_index_in_epoch)?;
                    //                         now = SystemTime::now();
                    //                     }
                    //                     next_input_index_in_epoch += 1;
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
    */
}
