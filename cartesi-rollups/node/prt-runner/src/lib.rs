mod error;

use alloy::{primitives::Address, providers::DynProvider};
use log::trace;
use std::path::PathBuf;
use std::{str::FromStr, sync::Arc, time::Duration};

use cartesi_prt_core::{
    db::compute_state_access::{Input, Leaf},
    strategy::player::Player,
    tournament::EthArenaSender,
};
use error::{PRTRunnerError, Result};
use rollups_state_manager::{Epoch, StateManager};

pub struct PRTRunner<SM: StateManager> {
    arena_sender: EthArenaSender,
    provider: DynProvider,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    state_dir: PathBuf,
}

impl<SM: StateManager> PRTRunner<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        arena_sender: EthArenaSender,
        provider: DynProvider,
        state_manager: Arc<SM>,
        sleep_duration: u64,
        state_dir: PathBuf,
    ) -> Self {
        Self {
            arena_sender,
            provider,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            state_dir,
        }
    }

    pub async fn start(&mut self) -> Result<(), SM> {
        loop {
            // participate in last sealed epoch tournament
            if let Some(last_sealed_epoch) = self
                .state_manager
                .last_sealed_epoch()
                .map_err(PRTRunnerError::StateManagerError)?
            {
                match self
                    .state_manager
                    .settlement_info(last_sealed_epoch.epoch_number)
                    .map_err(PRTRunnerError::StateManagerError)?
                {
                    Some(_) => {
                        self.react_dispute(&last_sealed_epoch).await?;
                    }
                    None => {
                        trace!("wait for `machine-runner` to insert settlement values");
                    }
                }
            }
            std::thread::sleep(self.sleep_duration);
        }
    }

    async fn react_dispute(&mut self, last_sealed_epoch: &Epoch) -> Result<(), SM> {
        let Some(snapshot) = self
            .state_manager
            .snapshot(last_sealed_epoch.epoch_number, 0)
            .map_err(PRTRunnerError::StateManagerError)?
        else {
            trace!("wait for `machine-runner` to save machine snapshot");
            return Ok(());
        };

        let inputs = self
            .state_manager
            .inputs(last_sealed_epoch.epoch_number)
            .map_err(PRTRunnerError::StateManagerError)?;
        let leafs = self
            .state_manager
            .machine_state_hashes(last_sealed_epoch.epoch_number)
            .map_err(PRTRunnerError::StateManagerError)?;

        let mut player = {
            let inputs = Some(inputs.into_iter().map(Input).collect());
            let leafs = leafs
                .into_iter()
                .map(|l| Leaf {
                    hash: l
                        .0
                        .as_slice()
                        .try_into()
                        .expect("fail to convert leafs from machine state hash"),
                    repetitions: l.1,
                })
                .collect();

            let address = Address::from_str(&last_sealed_epoch.root_tournament)
                .expect("fail to convert tournament address from string");

            Player::new(
                inputs,
                leafs,
                self.provider.clone(),
                snapshot,
                address,
                last_sealed_epoch.block_created_number,
                self.state_dir.clone(),
            )
            .expect("fail to initialize prt player")
        };

        // TODO: there are errors which are irrecoverable!
        // We should bail on these cases.
        player.react_once(&self.arena_sender).await?;
        Ok(())
    }
}
