// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_sling_node::{args::NodeConfig, fatal, run, sync::ShutdownSignal};

use env_logger::Env;
use log::{error, info};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    // A panic in any thread reaches the log as an ERROR record when it
    // happens; the default hook still prints it, with any backtrace.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        error!("{info}");
        default_hook(info);
    }));
    info!("Hello from the sling node!");

    let result = async {
        let config = NodeConfig::setup().await?;
        info!("Running with config:\n{}", config);
        run(config, ShutdownSignal::default()).await
    }
    .await;
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            error!("{e:#}");
            ExitCode::from(fatal::exit_code(&e))
        }
    }
}
