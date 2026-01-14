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
    io::{Read, Seek},
    path::PathBuf,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const PROGRAM: &str = "../../../test/programs/echo/";
const ANVIL_STATE: &str = "../../../cartesi-rollups/contracts/state.json";
const DEPLOYMENTS: &str = "../../../cartesi-rollups/contracts/deployments/31337";

#[derive(Deserialize)]
struct Deployment {
    address: String,
}

pub fn program_path() -> PathBuf {
    PathBuf::from(PROGRAM).canonicalize().unwrap()
}

pub fn anvil_state_path() -> PathBuf {
    PathBuf::from(ANVIL_STATE).canonicalize().unwrap()
}

pub fn deployments_path() -> PathBuf {
    PathBuf::from(DEPLOYMENTS).canonicalize().unwrap()
}

pub fn deployment_address(contract_id: &str) -> Address {
    let deployment_path = deployments_path().join(format!("{}.json", contract_id));
    let deployment_json = fs::read_to_string(deployment_path).unwrap();
    let deployment: Deployment = serde_json::from_str(&deployment_json).unwrap();
    Address::from_hex(deployment.address).unwrap()
}

pub async fn spawn_anvil_and_provider() -> Result<(AnvilInstance, DynProvider, AddressBook)> {
    let program_path = program_path();

    let anvil = Anvil::default()
        .block_time(1)
        .args([
            "--preserve-historical-states",
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

    let input_box = deployment_address("InputBox");
    let dave_app_factory = deployment_address("DaveAppFactory");

    let initial_hash = {
        // Root hash is stored in hash_tree.sht at offset 0x60 (node 1's hash in sparse tree).
        // Equivalent to: xxd -seek 0x60 -l 0x20 -c 0x20 -p .../machine-image/hash_tree.sht
        let mut file =
            File::open(program_path.join("machine-image").join("hash_tree.sht")).unwrap();
        file.seek(std::io::SeekFrom::Start(0x60)).unwrap();
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
