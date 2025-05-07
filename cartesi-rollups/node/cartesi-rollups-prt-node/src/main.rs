use cartesi_rollups_prt_node::{
    PRTConfig, create_blockchain_reader_task, create_epoch_manager_task, create_machine_runner_task,
};
use rollups_state_manager::persistent_state_access::PersistentStateAccess;

use anyhow::Result;
use clap::Parser;
use env_logger::Env;
use log::info;
use rusqlite::Connection;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    // This safely uses RUST_LOG if it exists, or falls back to "info"
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();

    info!("Hello from Dave Rollups!");

    let mut parameters = PRTConfig::parse();
    let provider = parameters.initialize().await;
    info!("Running with config:\n{}", parameters);

    let state_manager = Arc::new(PersistentStateAccess::new(Connection::open(
        parameters.state_dir.join("state.db"),
    )?)?);

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
