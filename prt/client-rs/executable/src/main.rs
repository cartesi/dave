use alloy::{
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::client::RpcClient,
    transports::{http::reqwest::Url, layers::RetryBackoffLayer},
};
use cartesi_prt_compute::ComputeConfig;
use cartesi_prt_core::{
    strategy::player::{Player, PlayerTournamentResult},
    tournament::{BlockchainConfig, EthArenaSender, get_wallet_from_private},
};

use anyhow::Result;
use clap::Parser;
use env_logger::Env;
use log::{error, info};
use std::{env, fs::OpenOptions, io, path::Path};

// A simple implementation of `% touch path` (ignores existing files)
fn touch(path: &Path) -> io::Result<()> {
    match OpenOptions::new().create(true).append(true).open(path) {
        Ok(_) => Ok(()),
        Err(e) => Err(e),
    }
}

fn create_provider(config: &BlockchainConfig) -> DynProvider {
    let endpoint_url: Url = Url::parse(&config.web3_rpc_url).expect("invalid rpc url");

    let retry = RetryBackoffLayer::new(
        5,   // max_rate_limit_retries
        200, // initial_backoff_ms
        500, // compute_units_per_sec
    );

    let client = RpcClient::builder().layer(retry).http(endpoint_url);

    let wallet = get_wallet_from_private(&config.web3_private_key.as_deref().unwrap());

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .with_chain(
            config
                .web3_chain_id
                .try_into()
                .expect("fail to convert chain id"),
        )
        .on_client(client);

    provider.erased()
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();

    info!("Hello from Dave!");

    let mut config = ComputeConfig::parse();
    config.blockchain_config.initialize();
    let provider = create_provider(&config.blockchain_config);
    let sender = EthArenaSender::new(provider.clone())?;

    let mut player = Player::new(
        None,
        Vec::new(),
        provider,
        config.machine_path,
        config.root_tournament,
        0, // TODO update to a sensible block number
        config.state_dir,
    )
    .expect("fail to create player object");

    let finished = env::temp_dir()
        .join(config.root_tournament.to_string().to_uppercase())
        .join("finished");

    if config.interval == u64::MAX {
        match player.react_once(&sender).await {
            Ok(state) => {
                if state != PlayerTournamentResult::TournamentRunning {
                    info!(
                        "Tournament finished, {:?}, touching finished path {:#?}",
                        state, finished
                    );
                    touch(&finished)?;
                }
            }
            Err(e) => {
                error!("{}", e);
            }
        }
    } else {
        let res = player.react(&sender, config.interval).await;
        info!("Tournament finished, {:?}", res);
    }

    Ok(())
}
