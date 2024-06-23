use cartesi_compute_core::{
    arena::{EthArenaSender, StateReader},
    config::ComputeConfig,
    machine::CachingMachineCommitmentBuilder,
    strategy::{gc::GarbageCollector, player::Player}
};

use anyhow::Result;
use ethers::types::Address;
use log::info;
use std::{time::Duration};
use clap::Parser;

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

    loop {
        let tournament_states = reader.fetch_from_root(config.root_tournament).await?;
        let res = player.react(&sender, tournament_states).await?;
        if let Some(r) = res {
            info!("Tournament finished, {:?}", r);
            break;
        }

        let tournament_states = reader.fetch_from_root(config.root_tournament).await?;
        gc.react(&sender, tournament_states).await?;
        tokio::time::sleep(Duration::from_secs(5)).await;
    }

    Ok(())
}
