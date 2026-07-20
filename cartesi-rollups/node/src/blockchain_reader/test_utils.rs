use super::AddressBook;
use alloy::{
    hex::FromHex,
    network::EthereumWallet,
    node_bindings::{Anvil, AnvilInstance},
    primitives::Address,
    primitives::FixedBytes,
    primitives::U256,
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::client::RpcClient,
    signers::{Signer, local::PrivateKeySigner},
    transports::http::Http,
};
use cartesi_dave_contracts::i_dave_app_factory::IDaveAppFactory::{self, WithdrawalConfig};
use cartesi_machine::{Machine, config::runtime::RuntimeConfig};
use cartesi_rollups_contracts::i_input_box::IInputBox;
use serde::Deserialize;
use std::{fs, path::PathBuf};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const PROGRAM: &str = "../../test/programs/echo/";
const ANVIL_STATE: &str = "../../cartesi-rollups/contracts/state.json";
const DEPLOYMENTS: &str = "../../cartesi-rollups/contracts/deployments/31337";

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

/// A per-request timeout on every test provider: a wedged anvil must
/// fail a test loudly, not hang it forever (observed once under a
/// full disk, 2026-07-11; the production provider carries its own
/// timeout in provider.rs).
pub fn rpc_client_with_timeout(url: alloy::transports::http::reqwest::Url) -> RpcClient {
    let http = alloy::transports::http::reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .expect("failed to build reqwest client");
    RpcClient::builder().transport(Http::with_client(http, url), true)
}

/// Mines `count` blocks on demand. The tests run anvil in automine
/// (a block per transaction, instantly); finality only advances with
/// new blocks, so waits for the finalized tag mine explicitly instead
/// of burning wall-clock seconds on interval mining.
pub async fn mine_blocks(provider: &impl Provider, count: u64) -> Result<()> {
    provider
        .raw_request::<_, serde_json::Value>("anvil_mine".into(), (count,))
        .await?;
    Ok(())
}

pub async fn spawn_anvil_and_provider() -> Result<(AnvilInstance, DynProvider, AddressBook)> {
    let program_path = program_path();

    let anvil = Anvil::default()
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
    let signer_address = signer.address();
    let wallet = EthereumWallet::from(signer);

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_client(rpc_client_with_timeout(anvil.endpoint_url()))
        .erased();
    // Automine confirms instantly; the default 250ms receipt poll
    // would dominate every `.watch()`.
    provider
        .client()
        .set_poll_interval(std::time::Duration::from_millis(10));

    let input_box = deployment_address("InputBox");
    let dave_app_factory = deployment_address("DaveAppFactory");

    // Load the stored machine through the emulator and ask it for the root
    // hash, rather than reading the internal `hash_tree.sht` file directly.
    // The file layout is an emulator implementation detail; going through
    // `cm_load_new` + `cm_get_root_hash` is the only stable API.
    let initial_hash: [u8; 32] = {
        let mut machine = Machine::load(
            &program_path.join("machine-image"),
            &RuntimeConfig::quiet_console(),
        )
        .expect("failed to load stored machine");
        machine
            .root_hash()
            .expect("failed to read machine root hash")
    };

    let claim_staging_period = U256::from(1000);

    let sentry_manager = Address::ZERO;

    let sentries = vec![signer_address];

    let withdrawal_config = WithdrawalConfig {
        guardian: Default::default(),
        log2LeavesPerAccount: Default::default(),
        log2MaxNumOfAccounts: Default::default(),
        accountsDriveStartIndex: Default::default(),
        withdrawalOutputBuilder: Default::default(),
    };

    let salt = FixedBytes::default();

    let dave_app_factory_contract = IDaveAppFactory::new(dave_app_factory, &provider);
    let (app, consensus) = dave_app_factory_contract
        .calculateDaveAppAddress(
            initial_hash.into(),
            claim_staging_period,
            sentry_manager,
            sentries.clone(),
            withdrawal_config.clone(),
            salt,
        )
        .call()
        .await
        .expect("failed to calculate Dave app addresses")
        .into();

    dave_app_factory_contract
        .newDaveApp(
            initial_hash.into(),
            claim_staging_period,
            sentry_manager,
            sentries.clone(),
            withdrawal_config.clone(),
            salt,
        )
        .send()
        .await?
        .watch()
        .await?;

    IInputBox::new(input_box, &provider)
        .addInput(app, "Hello, world!".into())
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
