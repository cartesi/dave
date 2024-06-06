use log::error;
use rollups_blockchain_reader::{AddressBook, BlockchainReader};
use rollups_epoch_manager::EpochManager;
use rollups_machine_runner::MachineRunner;
use rollups_state_manager::persistent_state_access::PersistentStateAccess;
use rusqlite::Connection;
use std::{sync::Arc, time::Duration};
use tokio::task::JoinHandle;
use tokio::task::{spawn, spawn_blocking};

#[derive(Clone)]
pub struct DaveParameters {
    state_manager: Arc<PersistentStateAccess>,
    web3_rpc_url: String,
    machine_path: String,
    sleep_duration: Duration,
    snapshot_duration: Duration,
}

impl DaveParameters {
    pub fn new() -> anyhow::Result<Self> {
        let state_manager = Arc::new(PersistentStateAccess::new(Connection::open_in_memory()?)?);

        Ok(Self {
            state_manager,
            web3_rpc_url: String::new(),
            machine_path: String::new(),
            sleep_duration: Duration::default(),
            snapshot_duration: Duration::default(),
        })
    }
}

pub fn create_blockchain_reader_task(
    parameters: &DaveParameters,
    address_book: AddressBook,
) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn(async move {
        let mut blockchain_reader = BlockchainReader::new(
            params.state_manager,
            address_book,
            params.web3_rpc_url.as_str(),
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

pub fn create_epoch_manager_task(parameters: &DaveParameters) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn(async move {
        let mut epoch_manager = EpochManager::new(params.state_manager, params.sleep_duration);

        epoch_manager
            .start()
            .await
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}

pub fn create_machine_runner_task(parameters: &DaveParameters) -> JoinHandle<()> {
    let params = parameters.clone();

    spawn_blocking(move || {
        // `MachineRunner` has to be constructed in side the spawn block since `machine::Machine`` doesn't implement `Send`
        let mut machine_runner = MachineRunner::new(
            params.state_manager,
            params.machine_path.as_str(),
            params.sleep_duration,
            params.snapshot_duration,
        )
        .inspect_err(|e| error!("{e}"))
        .unwrap();

        machine_runner
            .start()
            .inspect_err(|e| error!("{e}"))
            .unwrap();
    })
}
