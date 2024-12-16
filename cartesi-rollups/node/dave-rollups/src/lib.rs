use cartesi_prt_core::arena::{BlockchainConfig, EthArenaSender, SenderFiller};

use clap::Parser;
use log::error;
use rollups_blockchain_reader::{AddressBook, BlockchainReader};
use rollups_epoch_manager::EpochManager;
use rollups_machine_runner::MachineRunner;
use rollups_prt_runner::ComputeRunner;
use rollups_state_manager::persistent_state_access::PersistentStateAccess;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::task::JoinHandle;
use tokio::task::{spawn, spawn_blocking};

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

pub fn create_blockchain_reader_task(
    state_manager: Arc<PersistentStateAccess>,
    parameters: &DaveParameters,
) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn(async move {
        let mut blockchain_reader = BlockchainReader::new(
            state_manager,
            params.address_book,
            params.blockchain_config.web3_rpc_url.as_str(),
            params.sleep_duration,
        )
        .inspect_err(|e| error!("{e}"))
        .unwrap();

        blockchain_reader
            .start()
            .await
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}

pub fn create_compute_runner_task(
    arena_sender: EthArenaSender,
    state_manager: Arc<PersistentStateAccess>,
    parameters: &DaveParameters,
) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn(async move {
        let mut compute_runner = ComputeRunner::new(
            arena_sender,
            &params.blockchain_config,
            state_manager,
            params.sleep_duration,
            params.state_dir,
        );

        compute_runner
            .start()
            .await
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}

pub fn create_epoch_manager_task(
    client: Arc<SenderFiller>,
    state_manager: Arc<PersistentStateAccess>,
    parameters: &DaveParameters,
) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn(async move {
        let epoch_manager = EpochManager::new(
            client,
            params.address_book.consensus,
            state_manager,
            params.sleep_duration,
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
