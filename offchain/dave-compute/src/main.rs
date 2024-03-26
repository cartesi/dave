use cartesi_compute_core::{
    arena::{ArenaConfig, EthArenaSender, StateReader},
    machine::CachingMachineCommitmentBuilder,
    strategy::{gc::GarbageCollector, player::Player},
};

use anyhow::Result;
use ethers::types::Address;
use log::info;
use std::{str::FromStr, time::Duration};

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();
    info!("Hello from Dave!");
    let web3_rpc_url = String::from("http://127.0.0.1:8545");
    let web3_chain_id = 31337;

    let private_key =
        String::from("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");

    let arena_config = ArenaConfig {
        web3_rpc_url,
        web3_chain_id,
        web3_private_key: private_key,
    };

    let reader = StateReader::new(arena_config.clone())?;
    let sender = EthArenaSender::new(arena_config)?;

    let machine_path = std::env::var("MACHINE_PATH").expect("MACHINE_PATH is not set");

    let root_tournament = Address::from_str("0xcafac3dd18ac6c6e92c921884f9e4176737c052c")?;

    let mut player = Player::new(
        machine_path.clone(),
        CachingMachineCommitmentBuilder::new(machine_path),
        root_tournament.clone(),
    );

    let mut gc = GarbageCollector::new(root_tournament.clone());

    loop {
        let tournament_states = reader.fetch_from_root(root_tournament).await?;
        let res = player.react(&sender, tournament_states).await?;
        if let Some(r) = res {
            info!("Tournament finished, {:?}", r);
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;

        let tournament_states = reader.fetch_from_root(root_tournament).await?;
        gc.react(&sender, tournament_states).await?;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }

    Ok(())
}
