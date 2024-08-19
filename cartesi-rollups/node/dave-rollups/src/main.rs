use anyhow::Result;
use clap::Parser;
use dave_rollups::{
    create_blockchain_reader_task, create_epoch_manager_task, create_machine_runner_task,
    DaveParameters,
};
use log::info;
use rollups_state_manager::persistent_state_access::PersistentStateAccess;
use rusqlite::Connection;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    info!("Hello from Dave Rollups!");

    env_logger::init();

    let parameters = DaveParameters::parse();
    let state_manager = Arc::new(PersistentStateAccess::new(Connection::open(
        &parameters.path_to_db,
    )?)?);

    let blockchain_reader_task = create_blockchain_reader_task(state_manager.clone(), &parameters);
    let epoch_manager_task = create_epoch_manager_task(state_manager.clone(), &parameters);
    let machine_runner_task = create_machine_runner_task(state_manager.clone(), &parameters);

    let (_blockchain_reader_res, _epoch_manager_res, _machine_runner_res) = futures::join!(
        blockchain_reader_task,
        epoch_manager_task,
        machine_runner_task
    );

    Ok(())
}
