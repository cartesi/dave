use alloy::primitives::Address;
use log::error;
use std::path::PathBuf;
use std::result::Result;
use std::{str::FromStr, sync::Arc, time::Duration};

use cartesi_prt_core::{
    arena::{BlockchainConfig, EthArenaSender},
    db::compute_state_access::{Input, Leaf},
    strategy::player::Player,
};
use rollups_state_manager::StateManager;

pub struct ComputeRunner<SM: StateManager> {
    arena_sender: EthArenaSender,
    config: BlockchainConfig,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    state_dir: PathBuf,
}

impl<SM: StateManager> ComputeRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        arena_sender: EthArenaSender,
        config: &BlockchainConfig,
        state_manager: Arc<SM>,
        sleep_duration: u64,
        state_dir: PathBuf,
    ) -> Self {
        Self {
            arena_sender,
            config: config.clone(),
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            state_dir,
        }
    }

    pub async fn start(&mut self) -> Result<(), <SM as StateManager>::Error> {
        loop {
            // participate in last sealed epoch tournament
            if let Some(last_sealed_epoch) = self.state_manager.last_sealed_epoch()? {
                match self
                    .state_manager
                    .computation_hash(last_sealed_epoch.epoch_number)?
                {
                    Some(_) => {
                        if let Some(snapshot) = self
                            .state_manager
                            .snapshot(last_sealed_epoch.epoch_number, 0)?
                        {
                            let inputs =
                                self.state_manager.inputs(last_sealed_epoch.epoch_number)?;
                            let leafs = self
                                .state_manager
                                .machine_state_hashes(last_sealed_epoch.epoch_number)?;
                            let mut player = Player::new(
                                Some(inputs.into_iter().map(Input).collect()),
                                leafs
                                    .into_iter()
                                    .map(|l| {
                                        Leaf(
                                            l.0.as_slice().try_into().expect(
                                                "fail to convert leafs from machine state hash",
                                            ),
                                            l.1,
                                        )
                                    })
                                    .collect(),
                                &self.config,
                                snapshot,
                                Address::from_str(&last_sealed_epoch.root_tournament)
                                    .expect("fail to convert tournament address"),
                                self.state_dir.clone(),
                            )
                            .expect("fail to initialize compute player");
                            let _ = player
                                .react_once(&self.arena_sender)
                                .await
                                .inspect_err(|e| error!("{e}"));
                        }
                    }
                    None => {
                        // wait for the `machine-runner` to insert the value
                    }
                }
            }
            std::thread::sleep(self.sleep_duration);
        }
    }
}
