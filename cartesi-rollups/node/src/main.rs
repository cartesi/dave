// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_rollups_prt_node::{args::NodeConfig, run, sync::ShutdownSignal};

use anyhow::Result;
use env_logger::Env;
use log::info;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    info!("Hello from PRT Rollup Node!");

    let (config, _storage) = NodeConfig::setup().await;
    info!("Running with config:\n{}", config);

    run(config, ShutdownSignal::default()).await
}
