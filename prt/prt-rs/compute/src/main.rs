use cartesi_prt_core::{
    arena::{EthArenaSender, StateReader},
    config::ComputeConfig,
    machine::CachingMachineCommitmentBuilder,
    strategy::{gc::GarbageCollector, player::Player},
};

use anyhow::Result;
use clap::Parser;
use log::{error, info};
use std::{
    fs::{self, OpenOptions},
    io,
    path::Path,
    time::Duration,
};

const IDLE_PATH_STR: &str = "player2_idle";

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
    let arena_config = config.arena_config.clone();

    let reader = StateReader::new(arena_config.clone())?;
    let sender = EthArenaSender::new(arena_config)?;

    let mut player = Player::new(
        config.machine_path.clone(),
        CachingMachineCommitmentBuilder::new(config.machine_path.clone()),
        config.root_tournament.clone(),
    );

    let mut gc = GarbageCollector::new(config.root_tournament.clone());

    let idle_path = Path::new(IDLE_PATH_STR);

    loop {
        let tournament_states = reader.fetch_from_root(config.root_tournament).await?;

        let tx_count = sender.nonce().await?;
        let res = player.react(&sender, &tournament_states).await;

        match res {
            Err(e) => error!("{}", e),
            Ok(player_tournament_result) => {
                if let Some(r) = player_tournament_result {
                    info!("Tournament finished, {:?}", r);
                    break;
                }
            }
        }

        if sender.nonce().await? == tx_count {
            info!("player idling");
            touch(&idle_path)?;
        } else {
            // ignore error if the file doesn't exist
            let _ = fs::remove_file(IDLE_PATH_STR);
        }

        let tournament_states = reader.fetch_from_root(config.root_tournament).await?;
        gc.react(&sender, tournament_states).await?;
        tokio::time::sleep(Duration::from_secs(5)).await;
    }

    Ok(())
}
