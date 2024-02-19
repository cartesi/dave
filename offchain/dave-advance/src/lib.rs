use std::path::Path;

use cartesi_machine::{
    configuration::{MemoryRangeConfig, RuntimeConfig},
    errors::MachineError,
    BreakReason,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Halted {
    Yes,
    No
}

pub struct Machine {
    machine: cartesi_machine::Machine,
    rollup: MemoryRangeConfig,
}

impl Machine {
    pub fn load(path: &Path, runtime: RuntimeConfig) -> Result<Machine, MachineError> {
        let mut machine = cartesi_machine::Machine::load(path, runtime)?;
        let config = machine.get_initial_config()?;
        let rollup = config.rollup.rx_buffer.clone();
        Ok(Self { machine, rollup })
    }

    fn feed(&mut self, input: &[u8]) -> Result<(), MachineError> {
        self.machine.replace_memory_range(self.rollup.clone())?;
        self.machine
            .write_memory(self.rollup.start.clone(), input)?;
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
}
