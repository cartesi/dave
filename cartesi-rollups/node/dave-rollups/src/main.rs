use dave_rollups::{
    DaveParameters, create_blockchain_reader_task, create_epoch_manager_task,
    create_machine_runner_task, create_provider,
};
use rollups_state_manager::persistent_state_access::PersistentStateAccess;

use anyhow::Result;
use clap::Parser;
use log::info;
use rusqlite::Connection;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    info!("Hello from Dave Rollups!");

    let parameters = DaveParameters::parse();
    let state_manager = Arc::new(PersistentStateAccess::new(Connection::open(
        parameters.state_dir.join("state.db"),
    )?)?);
    let provider = create_provider(&parameters.blockchain_config).await;

    let blockchain_reader_task =
        create_blockchain_reader_task(state_manager.clone(), provider.clone(), &parameters);
    let epoch_manager_task =
        create_epoch_manager_task(provider.clone(), state_manager.clone(), &parameters);
    let machine_runner_task = create_machine_runner_task(state_manager.clone(), &parameters);

    futures::try_join!(
        blockchain_reader_task,
        epoch_manager_task,
        machine_runner_task,
    )?;

    unreachable!("node services should run forever")
}
