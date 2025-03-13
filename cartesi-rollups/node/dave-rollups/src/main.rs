use cartesi_prt_core::arena::EthArenaSender;
use dave_rollups::{
    create_blockchain_reader_task, create_compute_runner_task, create_epoch_manager_task,
    create_machine_runner_task, DaveParameters,
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

    let arena_sender = EthArenaSender::new(&parameters.blockchain_config).await?;
    let client = arena_sender.client();

    let blockchain_reader_task = create_blockchain_reader_task(state_manager.clone(), &parameters);
    let epoch_manager_task = create_epoch_manager_task(client, state_manager.clone(), &parameters);
    let machine_runner_task = create_machine_runner_task(state_manager.clone(), &parameters);
    let compute_runner_task =
        create_compute_runner_task(arena_sender, state_manager.clone(), &parameters);

    let (_blockchain_reader_res, _epoch_manager_res, _machine_runner_res, _compute_runner_res) = futures::join!(
        blockchain_reader_task,
        epoch_manager_task,
        machine_runner_task,
        compute_runner_task
    );

    Ok(())
}
