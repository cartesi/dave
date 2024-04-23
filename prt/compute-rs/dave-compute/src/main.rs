use cartesi_compute_core::{
    arena::{ArenaConfig, EthArenaSender, StateReader},
    machine::CachingMachineCommitmentBuilder,
    strategy::{gc::GarbageCollector, player::Player},
};

use anyhow::Result;
use ethers::types::Address;
use log::info;
use std::{env::var, str::FromStr, time::Duration};

#[tokio::main]
async fn main() -> Result<()> {
    info!("Hello from Dave!");

    const ANVIL_URL: &str = "http://127.0.0.1:8545";
    const ANVIL_CHAIN_ID: u64 = 31337;
    const ANVIL_KEY_1: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const ANVIL_ROOT_TOURNAMENT: &str = "0xcafac3dd18ac6c6e92c921884f9e4176737c052c";

    env_logger::init();
    let web3_rpc_url = var("URL").unwrap_or(String::from(ANVIL_URL));
    let web3_chain_id = var("CHAIN_ID")
        .map(|c| c.parse::<u64>().expect("INVALID CHAIN ID"))
        .unwrap_or(ANVIL_CHAIN_ID);
    let private_key = var("PRIV_KEY").unwrap_or(String::from(ANVIL_KEY_1));
    let root_tournament_string =
        var("ROOT_TOURNAMENT").unwrap_or(String::from(ANVIL_ROOT_TOURNAMENT));
    let root_tournament = Address::from_str(root_tournament_string.as_str())?;
    let machine_path = var("MACHINE_PATH").expect("MACHINE_PATH is not set");

    let arena_config = ArenaConfig {
        web3_rpc_url,
        web3_chain_id,
        web3_private_key: private_key,
    };

    let reader = StateReader::new(arena_config.clone())?;
    let sender = EthArenaSender::new(arena_config)?;

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

        let tournament_states = reader.fetch_from_root(root_tournament).await?;
        gc.react(&sender, tournament_states).await?;
        tokio::time::sleep(Duration::from_secs(5)).await;
    }

    Ok(())
}
