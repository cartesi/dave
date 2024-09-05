use std::process::Command;
use std::result::Result;
use std::{sync::Arc, time::Duration};

use cartesi_prt_core::arena::BlockchainConfig;
use rollups_state_manager::{Epoch, StateManager};

pub struct ComputeRunner<SM: StateManager> {
    config: BlockchainConfig,
    last_processed_epoch: Epoch,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
}

impl<SM: StateManager> ComputeRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        config: &BlockchainConfig,
        state_manager: Arc<SM>,
        sleep_duration: u64,
    ) -> Result<Self, <SM as StateManager>::Error> {
        let last_sealed_epoch = state_manager.last_epoch()?;
        let last_processed_epoch = {
            match last_sealed_epoch {
                Some(e) => {
                    spawn_dave_process(config, &e);
                    e
                }
                None => Epoch {
                    epoch_number: 0,
                    epoch_boundary: 0,
                    root_tournament: String::new(),
                },
            }
        };

        Ok(Self {
            config: config.clone(),
            last_processed_epoch,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
        })
    }

    pub fn start(&mut self) -> Result<(), <SM as StateManager>::Error> {
        loop {
            let last_sealed_epoch = self.state_manager.last_epoch()?;
            if let Some(e) = last_sealed_epoch {
                if e.epoch_number != self.last_processed_epoch.epoch_number
                    || e.epoch_boundary != self.last_processed_epoch.epoch_boundary
                    || e.root_tournament != self.last_processed_epoch.root_tournament
                {
                    spawn_dave_process(&self.config, &e);
                    self.last_processed_epoch = e;
                }
            }

            std::thread::sleep(self.sleep_duration);
        }
    }
}

fn spawn_dave_process(config: &BlockchainConfig, epoch: &Epoch) {
    // Create a command to run `dave-compute`
    let cmd = Command::new("cartesi-prt-compute")
        .env("key", "val") // TODO: set up config properly
        .current_dir("path to the binary")
        .spawn()
        .expect("fail to spawn dave compute process");
}
