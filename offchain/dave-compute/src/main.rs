use cartesi_compute_core::arena::{Arena, ArenaConfig};
use cartesi_compute_core::machine::{CachingMachineCommitmentBuilder, MachineFactory};
use cartesi_compute_core::strategy::{gc::GarbageCollector, player::Player};
use ethers::types::Address;
use log::info;
use std::str::FromStr;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
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

    let arena = Arena::new(arena_config)?;

    let simple_linux_program =
        String::from("/root/permissionless-arbitration/lua_node/program/simple-program");

    let machine_rpc_host = "http://127.0.0.1";
    let machine_rpc_port = 5002;

    let machine_factory =
        MachineFactory::new(String::from(machine_rpc_host), machine_rpc_port).await?;
    let root_tournament = Address::from_str("0xcafac3dd18ac6c6e92c921884f9e4176737c052c")?;

    let mut player = Player::new(
        arena.clone(),
        machine_factory.clone(),
        simple_linux_program.clone(),
        CachingMachineCommitmentBuilder::new(machine_factory, simple_linux_program),
        root_tournament.clone(),
    );

    let mut gc = GarbageCollector::new(arena.clone(), root_tournament.clone());

    loop {
        let tournament_states = arena.fetch_from_root(root_tournament).await?;
        let res = player.react(tournament_states).await?;
        if let Some(r) = res {
            info!("Tournament finished, {:?}", r);
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;

        let tournament_states = arena.fetch_from_root(root_tournament).await?;
        gc.react(tournament_states).await?;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }

    Ok(())
}
