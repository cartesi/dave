use cartesi_prt_compute::ComputeConfig;
use cartesi_prt_core::{arena::EthArenaSender, strategy::player::Player};

use anyhow::Result;
use clap::Parser;
use log::{error, info};
use std::{fs::OpenOptions, io, path::Path};

const FINISHED_PATH: &str = "/root/prt/tests/compute/finished";
// A simple implementation of `% touch path` (ignores existing files)
fn touch(path: &Path) -> io::Result<()> {
    match OpenOptions::new().create(true).write(true).open(path) {
        Ok(_) => Ok(()),
        Err(e) => Err(e),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    info!("Hello from Dave!");

    env_logger::init();

    let config = ComputeConfig::parse();
    let blockchain_config = config.blockchain_config;
    let sender = EthArenaSender::new(&blockchain_config).await?;

    let mut player = Player::new(
        None,
        Vec::new(),
        &blockchain_config,
        config.machine_path,
        config.root_tournament,
        config.state_dir,
    )
    .expect("fail to create player object");

    if config.interval == u64::MAX {
        match player.react_once(&sender).await {
            Ok(Some(state)) => {
                info!("Tournament finished, {:?}", state);
                let finished_path = Path::new(FINISHED_PATH);
                touch(finished_path)?;
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
