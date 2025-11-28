use crate::AddressBook;
use alloy::{
    hex::FromHex,
    network::EthereumWallet,
    node_bindings::{Anvil, AnvilInstance},
    primitives::Address,
    primitives::FixedBytes,
    providers::{DynProvider, Provider, ProviderBuilder},
    signers::{Signer, local::PrivateKeySigner},
};
use cartesi_dave_contracts::i_dave_app_factory::IDaveAppFactory;
use cartesi_rollups_contracts::i_input_box::IInputBox;
use serde::Deserialize;
use std::{
    fs::{self, File},
    io::Read,
    path::PathBuf,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const PROGRAM: &str = "../../../test/programs/echo/";
const ROLLUPS_PRT: &str = "../../../cartesi-rollups/contracts";
const ANVIL_STATE: &str = "state.json";
const DEVNET_DEPLOYMENTS_DIR: &str = "deployments/31337";
const ROLLUPS_DIR: &str = "dependencies/cartesi-rollups-contracts-8ca7442d";

#[derive(Deserialize)]
struct Deployment {
    address: String,
}

pub fn program_path() -> PathBuf {
    PathBuf::from(PROGRAM).canonicalize().unwrap()
}

pub fn rollups_prt_path() -> PathBuf {
    PathBuf::from(ROLLUPS_PRT).canonicalize().unwrap()
}

pub fn anvil_state_path() -> PathBuf {
    rollups_prt_path().join(ANVIL_STATE)
}

pub fn rollups_prt_devnet_deployments_dir() -> PathBuf {
    rollups_prt_path().join(DEVNET_DEPLOYMENTS_DIR)
}

pub fn rollups_path() -> PathBuf {
    rollups_prt_path().join(ROLLUPS_DIR)
}

pub fn rollups_devnet_deployments_dir() -> PathBuf {
    rollups_path().join(DEVNET_DEPLOYMENTS_DIR)
}

pub fn load_deployment(deployments_dir: PathBuf, contract_id: &str) -> Address {
    let deployment_path = deployments_dir.join(format!("{}.json", contract_id));
    let deployments_json = fs::read_to_string(deployment_path).unwrap();
    let deployment: Deployment = serde_json::from_str(&deployments_json).unwrap();
    Address::from_hex(deployment.address).unwrap()
}

pub async fn spawn_anvil_and_provider() -> Result<(AnvilInstance, DynProvider, AddressBook)> {
    let program_path = program_path();

    let anvil = Anvil::default()
        .block_time(1)
        .args([
            "--slots-in-an-epoch",
            "1",
            "--load-state",
            anvil_state_path().to_str().unwrap(),
            "--block-base-fee-per-gas",
            "0",
        ])
        .spawn();

    let mut signer: PrivateKeySigner = anvil.keys()[0].clone().into();

    signer.set_chain_id(Some(anvil.chain_id()));
    let wallet = EthereumWallet::from(signer);

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(anvil.endpoint_url())
        .erased();

    let input_box = load_deployment(rollups_devnet_deployments_dir(), "InputBox");
    let dave_app_factory = load_deployment(rollups_prt_devnet_deployments_dir(), "DaveAppFactory");

    let initial_hash = {
        // $ xxd -p -c32 test/programs/echo/machine-image/hash
        let mut file = File::open(program_path.join("machine-image").join("hash")).unwrap();
        let mut buffer = [0u8; 32];
        file.read_exact(&mut buffer).unwrap();
        buffer
    };

    let salt = FixedBytes::default();

    let dave_app_factory_contract = IDaveAppFactory::new(dave_app_factory, &provider);
    let (app, consensus) = dave_app_factory_contract
        .calculateDaveAppAddress(initial_hash.into(), salt)
        .call()
        .await
        .expect("failed to calculate Dave app addresses")
        .try_into()
        .unwrap();

    IInputBox::new(input_box, &provider)
        .addInput(app, "Hello, world!".into())
        .send()
        .await?
        .watch()
        .await?;

    dave_app_factory_contract
        .newDaveApp(initial_hash.into(), salt)
        .send()
        .await?
        .watch()
        .await?;

    Ok((
        anvil,
        provider,
        AddressBook {
            app,
            consensus,
            input_box,
            genesis_block_number: 0,
            initial_hash,
        },
    ))
}
