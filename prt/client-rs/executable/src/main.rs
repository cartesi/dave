use cartesi_prt_compute::ComputeConfig;
use cartesi_prt_core::{strategy::player::Player, tournament::EthArenaSender};

use anyhow::Result;
use clap::Parser;
use log::{error, info};
use std::{fs::OpenOptions, io, path::Path};

// A simple implementation of `% touch path` (ignores existing files)
fn touch(path: &Path) -> io::Result<()> {
    match OpenOptions::new()
        .create(true)
        .write(true)
        .append(true)
        .open(path)
    {
        Ok(_) => Ok(()),
        Err(e) => Err(e),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    info!("Hello from Dave!");

    let config = ComputeConfig::parse();
    let blockchain_config = config.blockchain_config;
    let sender = EthArenaSender::new(&blockchain_config).await?;

    let mut player = Player::new(
        None,
        Vec::new(),
        &blockchain_config,
        config.machine_path,
        config.root_tournament,
        0, // TODO update to a sensible block number
        config.state_dir,
    )
    .expect("fail to create player object");

    let finished = tempfile::tempdir()
        .expect("Failed to create temp directory")
        .path()
        .parent()
        .expect("No temp directory to create finished notification")
        .join(config.root_tournament.to_string().to_uppercase())
        .join("finished");

    if config.interval == u64::MAX {
        match player.react_once(&sender).await {
            Ok(Some(state)) => {
                info!(
                    "Tournament finished, {:?}, touching finished path {:#?}",
                    state, finished
                );
                touch(&finished)?;
            }
            Err(e) => {
                error!("{}", e);
            }
            _ => {}
        }
    } else {
        let res = player.react(&sender, config.interval).await;
        info!("Tournament finished, {:?}", res);
    }

    Ok(())
}
