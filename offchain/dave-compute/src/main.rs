use cartesi_compute_core::arena::{ArenaConfig, ContractArtifactsConfig, EthersArena};
use cartesi_compute_core::machine::{CachingMachineCommitmentBuilder, MachineFactory};
use cartesi_compute_core::player::Player;
use ethers::types::Address;
use log::info;
use std::str::FromStr;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();
    info!("Hello from Dave!");
    let web3_rpc_url = String::from("http://127.0.0.1:8545");
    let artifacts_path = "/root/offchain/core/artifacts";
    let web3_chain_id = 31337;
    let contract_artifacts = ContractArtifactsConfig {
        single_level_factory: format!("{}/SingleLevelTournamentFactory.json", artifacts_path),
        top_factory: format!("{}/TopTournamentFactory.json", artifacts_path),
        middle_factory: format!("{}/MiddleTournamentFactory.json", artifacts_path),
        bottom_factory: format!("{}/BottomTournamentFactory.json", artifacts_path),
        tournament_factory: format!("{}/TournamentFactory.json", artifacts_path),
    };

    let player1_private_key =
        String::from("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");

    let player1_arena_config = ArenaConfig {
        web3_rpc_url,
        web3_chain_id,
        web3_private_key: player1_private_key,
        contract_artifacts,
    };

    let player1_arena = EthersArena::new(
        player1_arena_config,
        Some(Address::from_str(
            "0xdc64a140aa3e981100a9beca4e685f962f0cf6c9",
        )?),
    )?;

    let simple_linux_program =
        String::from("/root/permissionless-arbitration/lua_node/program/simple-program");

    let machine_rpc_host = "http://127.0.0.1";
    let machine_rpc_port = 5002;

    let player1_machine_factory =
        MachineFactory::new(String::from(machine_rpc_host), machine_rpc_port).await?;

    let mut player1 = Player::new(
        player1_arena,
        player1_machine_factory.clone(),
        simple_linux_program.clone(),
        CachingMachineCommitmentBuilder::new(player1_machine_factory, simple_linux_program),
        Address::from_str("0xcafac3dd18ac6c6e92c921884f9e4176737c052c")?,
    );

    loop {
        let res = player1.react().await?;
        if let Some(r) = res {
            info!("Tournament finished, {:?}", r);
            break;
        }
        // player2.react().await?;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }

    Ok(())
}
