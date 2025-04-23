use alloy::{
    network::EthereumWallet,
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::client::RpcClient,
    signers::local::PrivateKeySigner,
    transports::{http::reqwest::Url, layers::RetryBackoffLayer},
};
use clap::Parser;
use log::error;
use std::sync::Arc;
use std::{path::PathBuf, str::FromStr};
use tokio::task::JoinHandle;
use tokio::task::{spawn, spawn_blocking};

use cartesi_dave_kms::{CommonSignature, KmsSignerBuilder};
use cartesi_prt_core::tournament::{BlockchainConfig, EthArenaSender};
use rollups_blockchain_reader::{AddressBook, BlockchainReader};
use rollups_epoch_manager::EpochManager;
use rollups_machine_runner::MachineRunner;
use rollups_state_manager::persistent_state_access::PersistentStateAccess;

const SLEEP_DURATION: u64 = 30;
const SNAPSHOT_DURATION: u64 = 30;

#[derive(Debug, Clone, Parser)]
#[command(name = "cartesi_dave_config")]
#[command(about = "Config of Cartesi Dave")]
pub struct DaveParameters {
    #[command(flatten)]
    pub address_book: AddressBook,
    #[command(flatten)]
    pub blockchain_config: BlockchainConfig,
    #[arg(long, env)]
    machine_path: String,
    #[arg(long, env, default_value_t = SLEEP_DURATION)]
    sleep_duration: u64,
    #[arg(long, env, default_value_t = SNAPSHOT_DURATION)]
    snapshot_duration: u64,
    #[arg(long, env)] // TODO: add default
    pub state_dir: PathBuf,
}

pub async fn create_provider(config: &BlockchainConfig) -> DynProvider {
    let endpoint_url: Url = Url::parse(&config.web3_rpc_url).expect("invalid rpc url");

    // let throttle = ThrottleLayer::new(20);

    let retry = RetryBackoffLayer::new(
        5,   // max_rate_limit_retries
        200, // initial_backoff_ms
        500, // compute_units_per_sec
    );

    let client = RpcClient::builder()
        // .layer(throttle) // first throttle outbound QPS
        .layer(retry) // then retry failed requests with backoff
        .http(endpoint_url);

    let signer: Box<CommonSignature> = if let Some(key_id) = &config.aws_config.aws_kms_key_id {
        let kms_signer = KmsSignerBuilder::new()
            .await
            .with_chain_id(config.web3_chain_id)
            .with_key_id(key_id.clone())
            .build()
            .await
            .expect("could not create Kms signer");
        Box::new(kms_signer)
    } else {
        let local_signer = PrivateKeySigner::from_str(config.web3_private_key.as_str())
            .expect("could not create private key signer");
        Box::new(local_signer)
    };

    let wallet = EthereumWallet::from(signer);

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

pub fn create_blockchain_reader_task(
    state_manager: Arc<PersistentStateAccess>,
    provider: DynProvider,
    parameters: &DaveParameters,
) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn(async move {
        let blockchain_reader = BlockchainReader::new(
            state_manager,
            params.address_book,
            provider,
            params.sleep_duration,
        )
        .await
        .inspect_err(|e| error!("{e}"))
        .unwrap();

        blockchain_reader
            .start()
            .await
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}

pub fn create_epoch_manager_task(
    provider: DynProvider,
    state_manager: Arc<PersistentStateAccess>,
    parameters: &DaveParameters,
) -> JoinHandle<()> {
    let arena_sender =
        EthArenaSender::new(provider.clone()).expect("could not create arena sender");
    let params = parameters.clone();

    spawn(async move {
        let epoch_manager = EpochManager::new(
            arena_sender,
            provider,
            params.address_book.consensus,
            state_manager,
            params.sleep_duration,
            params.state_dir,
        );

        epoch_manager
            .start()
            .await
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}

pub fn create_machine_runner_task(
    state_manager: Arc<PersistentStateAccess>,
    parameters: &DaveParameters,
) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn_blocking(move || {
        // `MachineRunner` has to be constructed in side the spawn block since `machine::Machine`` doesn't implement `Send`
        let mut machine_runner = MachineRunner::new(
            state_manager,
            params.machine_path.as_str(),
            params.sleep_duration,
            params.snapshot_duration,
            params.state_dir.clone(),
        )
        .inspect_err(|e| error!("{e}"))
        .unwrap();

        machine_runner
            .start()
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}
