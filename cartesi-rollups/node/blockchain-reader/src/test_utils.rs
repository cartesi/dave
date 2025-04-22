use alloy::{
    hex::FromHex,
    network::EthereumWallet,
    node_bindings::{Anvil, AnvilInstance},
    primitives::Address,
    providers::{DynProvider, Provider, ProviderBuilder},
    signers::{Signer, local::PrivateKeySigner},
};
use cartesi_dave_merkle::Digest;
use std::{
    fs::{self, File},
    io::Read,
    path::PathBuf,
};

const PROGRAM: &str = "../../../test/programs/echo/";

pub fn program_path() -> PathBuf {
    PathBuf::from(PROGRAM).canonicalize().unwrap()
}

pub fn spawn_anvil_and_provider() -> (AnvilInstance, DynProvider, Address, Address, Digest) {
    let program_path = program_path();

    let anvil = Anvil::default()
        .block_time(1)
        .args([
            "--preserve-historical-states",
            "--slots-in-an-epoch",
            "1",
            "--load-state",
            program_path.join("anvil_state.json").to_str().unwrap(),
            "--block-base-fee-per-gas",
            "0",
        ])
        .spawn();

    let mut signer: PrivateKeySigner = anvil.keys()[0].clone().into();

    signer.set_chain_id(Some(anvil.chain_id()));
    let wallet = EthereumWallet::from(signer);

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .on_http(anvil.endpoint_url())
        .erased();

    let (input_box_address, consensus_address) = {
        let addresses = fs::read_to_string(program_path.join("addresses")).unwrap();
        let mut lines = addresses.lines().map(str::trim);
        (
            Address::from_hex(lines.next().unwrap()).unwrap(),
            Address::from_hex(lines.next().unwrap()).unwrap(),
        )
    };

    let initial_hash = {
        // $ xxd -p -c32 test/programs/echo/machine-image/hash
        let mut file = File::open(program_path.join("machine-image").join("hash")).unwrap();
        let mut buffer = [0u8; 32];
        file.read_exact(&mut buffer).unwrap();
        buffer
    };

    (
        anvil,
        provider,
        input_box_address,
        consensus_address,
        Digest::from_digest(&initial_hash).unwrap(),
    )
}
