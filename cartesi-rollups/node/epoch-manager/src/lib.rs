use alloy::{hex::ToHexExt, primitives::Address, providers::DynProvider};
use anyhow::Result;
use log::{error, info};
use num_traits::cast::ToPrimitive;
use std::{sync::Arc, time::Duration};

use cartesi_dave_contracts::daveconsensus;
use rollups_state_manager::StateManager;

pub struct EpochManager<SM: StateManager> {
    client: DynProvider,
    consensus: Address,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
}

impl<SM: StateManager> EpochManager<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        client: DynProvider,
        consensus_address: Address,
        state_manager: Arc<SM>,
        sleep_duration: u64,
    ) -> Self {
        Self {
            consensus: consensus_address,
            sleep_duration: Duration::from_secs(sleep_duration),
            state_manager,
            client,
        }
    }

    pub async fn start(&self) -> Result<()> {
        let dave_consensus = daveconsensus::DaveConsensus::new(self.consensus, &self.client);
        loop {
            let can_settle = dave_consensus.canSettle().call().await?;

            if can_settle.isFinished {
                match self.state_manager.computation_hash(
                    can_settle
                        .epochNumber
                        .to_u64()
                        .expect("fail to convert epoch number to u64"),
                )? {
                    Some(computation_hash) => {
                        info!(
                            "settle epoch {} with claim 0x{}",
                            can_settle.epochNumber,
                            computation_hash.encode_hex()
                        );
                        match dave_consensus.settle(can_settle.epochNumber).send().await {
                            Ok(tx_builder) => {
                                let _ = tx_builder.watch().await.inspect_err(|e| error!("{}", e));
                            }
                            // allow retry when errors happen
                            Err(e) => error!("{e}"),
                        }
                        // TODO: if claim doesn't match, that can be a serious problem, send out alert
                    }
                    None => {
                        // wait for the `machine-runner` to insert the value
                    }
                }
            }
            tokio::time::sleep(self.sleep_duration).await;
        }
    }
}
