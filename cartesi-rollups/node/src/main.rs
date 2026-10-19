// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use cartesi_sling_node::{args::NodeConfig, fatal, run};

use env_logger::Env;
use log::{error, info};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    // A panic in any thread reaches the log as an ERROR record when it
    // happens; the default hook still prints it, with any backtrace. One
    // line, so a line-oriented pipeline keeps the message with its level.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        error!("{}", info.to_string().replace('\n', " | "));
        default_hook(info);
    }));
    // CI's release build sets the tag (build.yml); the Cargo version names
    // no release.
    let release = match option_env!("CARTESI_SLING_RELEASE") {
        Some(tag) if !tag.is_empty() => tag,
        _ => "unreleased build",
    };
    info!(
        "Hello from the sling node ({release}, Cartesi Machine {}, MARCHID {})",
        cartesi_machine::format_emulator_version(cartesi_machine::Machine::version()),
        cartesi_machine::cartesi_machine_sys::CM_MARCHID,
    );

    let result = async {
        let config = NodeConfig::setup().await?;
        info!("Running with config: {config}");
        run(config).await
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
