use alloy::sol_types::private::Address;
use std::result::Result;
use std::{str::FromStr, sync::Arc, time::Duration};

use cartesi_prt_core::{
    arena::{BlockchainConfig, EthArenaSender},
    db::compute_state_access::{Input, Leaf},
    strategy::player::Player,
};
use rollups_state_manager::StateManager;

pub struct ComputeRunner<SM: StateManager> {
    config: BlockchainConfig,
    sender: EthArenaSender,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
}

impl<SM: StateManager> ComputeRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(config: &BlockchainConfig, state_manager: Arc<SM>, sleep_duration: u64) -> Self {
        let sender = EthArenaSender::new(&config).expect("fail to initialize sender");
        Self {
            config: config.clone(),
            sender,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
        }
    }

    pub async fn start(&mut self) -> Result<(), <SM as StateManager>::Error> {
        loop {
            if let Some(last_sealed_epoch) = self.state_manager.last_epoch()? {
                if let Some(snapshot) = self
                    .state_manager
                    .snapshot(last_sealed_epoch.epoch_number, 0)?
                {
                    // TODO: make sure all snapshots are available to compute
                    let inputs = self.state_manager.inputs(last_sealed_epoch.epoch_number)?;
                    let leafs = self
                        .state_manager
                        .machine_state_hashes(last_sealed_epoch.epoch_number)?;
                    let mut player = Player::new(
                        Some(inputs.into_iter().map(|i| Input(i)).collect()),
                        leafs
                            .into_iter()
                            .map(|l| {
                                Leaf(
                                    l.0.as_slice()
                                        .try_into()
                                        .expect("fail to convert leaf from machine state hash"),
                                    l.1,
                                )
                            })
                            .collect(),
                        &self.config,
                        snapshot,
                        Address::from_str(&last_sealed_epoch.root_tournament)
                            .expect("fail to convert tournament address"),
                    )
                    .expect("fail to initialize compute player");
                    let _ = player.react_once(&self.sender).await;
                }
            }
            std::thread::sleep(self.sleep_duration);
        }
    }
}
