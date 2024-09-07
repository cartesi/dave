use alloy::{
    network::EthereumWallet, providers::ProviderBuilder, signers::local::PrivateKeySigner,
    sol_types::private::Address,
};
use anyhow::Result;
use std::{str::FromStr, sync::Arc, time::Duration};

use cartesi_dave_contracts::daveconsensus;
use cartesi_prt_core::arena::{BlockchainConfig, SenderFiller};
use rollups_state_manager::StateManager;

pub struct EpochManager<SM: StateManager> {
    consensus: Address,
    sleep_duration: Duration,
    state_manager: Arc<SM>,
    client: Arc<SenderFiller>,
}

impl<SM: StateManager> EpochManager<SM>
where
    <SM as StateManager>::Error: Send + Sync + 'static,
{
    pub fn new(
        config: &BlockchainConfig,
        consensus_address: Address,
        state_manager: Arc<SM>,
        sleep_duration: u64,
    ) -> Self {
        let signer = PrivateKeySigner::from_str(config.web3_private_key.as_str())
            .expect("fail to construct signer");
        let wallet = EthereumWallet::from(signer);

        let url = config.web3_rpc_url.parse().expect("fail to parse url");
        let provider = ProviderBuilder::new()
            .with_recommended_fillers()
            .wallet(wallet)
            .with_chain(
                config
                    .web3_chain_id
                    .try_into()
                    .expect("fail to convert chain id"),
            )
            .on_http(url);
        let client = Arc::new(provider);

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
                match self.state_manager.computation_hash(0)? {
                    Some(computation_hash) => {
                        dave_consensus
                            .settle(can_settle.epochNumber)
                            .send()
                            .await?
                            .watch()
                            .await?;
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
