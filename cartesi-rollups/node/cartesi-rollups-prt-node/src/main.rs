use cartesi_rollups_prt_node::{
    PRTConfig, create_blockchain_reader_task, create_epoch_manager_task, create_machine_runner_task,
};
use rollups_state_manager::sync::Watch;

use anyhow::Result;
use clap::Parser;
use env_logger::Env;
use log::info;

fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();

    info!("Hello from Dave Rollups!");

    let parameters = DaveParameters::parse();
    let mut parameters = PRTConfig::parse();
    info!("Running with config:\n{}", parameters);

    PersistentStateAccess::migrate(parameters.state_dir.join("state.db")?)?;
    let provider = create_provider(&parameters.blockchain_config);
    let watch = Watch::default();

    // spawn workers
    let blockchain_reader_task =
        create_blockchain_reader_task(watch.clone(), provider.clone(), &parameters);
    let epoch_manager_task =
        create_epoch_manager_task(watch.clone(), provider.clone(), &parameters);
    let machine_runner_task = create_machine_runner_task(watch.clone(), &parameters);

    // monitor status
    let err = loop {
        match watch.wait(std::time::Duration::from_millis(1000)) {
            std::ops::ControlFlow::Continue(()) => continue,
            std::ops::ControlFlow::Break(e) => break e,
        }
    };

    // shutdown
    let _ = blockchain_reader_task.join();
    let _ = epoch_manager_task.join();
    let _ = machine_runner_task.join();

    anyhow::bail!(err);
}
