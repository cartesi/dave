use std::{
    path::Path,
    sync::{Arc, Mutex},
};

use cartesi_machine::{
    configuration::RuntimeConfig, errors::MachineError, BreakReason, HtifYieldReason,
};
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
    pub fn load(path: &Path, runtime: RuntimeConfig) -> Result<Machine, MachineError> {
        let machine = cartesi_machine::Machine::load(path, runtime)?;
        Ok(Self { machine })
    }

    fn feed(&mut self, input: &[u8]) -> Result<(), MachineError> {
        self.machine
            .send_cmio_response(HtifYieldReason::HtifYieldReasonAdvanceState, input)?;
        Ok(())
    }

    pub fn advance(&mut self, data: &[u8]) -> Result<Halted, MachineError> {
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

    pub async fn start(&mut self, _s: Arc<StateManager>) -> Result<(), MachineError> {
        //load the latest cached machine snapshot, sort the machine snapshots cached by key to get the latest one
        // ```

        // tick
        // ```
        // loop {

        // calculate next-input from meta-counter
        // loop {
        //  if not next-input then break;

        //  add next-input to machine and run until yield
        //  increment state meta-counter
        //  increment var next-input
        // }

        // if self.epoch == db.curr_epoch, break
        // elseif self.epoch < curr_epoch:
        //  - calculate computation-hash (db read)
        //  - write computation-hash to db
        //  - reset self.meta-counter, increment self.epoch
        //  - continue

        // } // end outer loop

        Ok(())
    }
}
