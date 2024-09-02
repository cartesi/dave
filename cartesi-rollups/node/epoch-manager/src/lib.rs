use alloy::{
    network::{Ethereum, EthereumWallet, NetworkWallet},
    providers::ProviderBuilder,
    signers::local::PrivateKeySigner,
    sol_types::private::Address,
};
use anyhow::Result;
use std::{str::FromStr, sync::Arc, time::Duration};

use cartesi_dave_contracts::daveconsensus;
use cartesi_prt_core::arena::{BlockchainConfig, SenderFiller};
use rollups_state_manager::StateManager;

// TODO: setup constants for commitment builder
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
            .with_nonce_management()
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

    pub async fn start(&mut self) -> Result<()> {
        let dave_consensus = daveconsensus::DaveConsensus::new(self.consensus, &self.client);
        loop {
            let can_settle = dave_consensus.canSettle().call().await?._0;

            if can_settle {
                match self.state_manager.computation_hash(0)? {
                    Some(computation_hash) => {
                        dave_consensus.settle().send().await?.watch().await?;
                        // match claim
                        //  + None -> claim
                        //  + Some({x, false}) if x is same as comp_hash -> return;
                        //  + Some({x, false}) if x is not same comp_hash -> claim;
                        //  + Some({_, true}) -> instantiate/join dave;
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
