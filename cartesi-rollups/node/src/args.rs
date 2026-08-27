// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::blockchain_reader::AddressBook;
use crate::engine::Structure;
use crate::storage::rollups_machine::LOG2_STRIDE;
use crate::storage::{Storage, StorageError};
use alloy::{
    network::EthereumWallet,
    primitives::Address,
    providers::{DynProvider, Provider},
    transports::http::reqwest::Url,
};
use alloy_chains::NamedChain;
use anyhow::{Context, Result, anyhow, ensure};
use cartesi_prt_contracts::{
    cartesi_state_transition::CartesiStateTransition,
    multi_level_tournament_factory::MultiLevelTournamentFactory,
};
use clap::{ArgGroup, Parser, Subcommand};
use std::{fmt, path::PathBuf, time::Duration};

use crate::provider::{TransactionLane, create_rpc_provider, create_signer};

const ANVIL_CHAIN_ID: u64 = 31337;
const ANVIL_URL: &str = "http://127.0.0.1:8545";
const SLEEP_DURATION: u64 = 30;

fn validate_root_tournament_geometry(log2step: u64, height: u64) -> Result<()> {
    let deployed_span = log2step
        .checked_add(height)
        .ok_or_else(|| anyhow!("root tournament span overflows u64: {log2step} + {height}"))?;

    ensure!(
        log2step == LOG2_STRIDE,
        "incompatible root tournament stride: deployed log2step {log2step}, node requires {LOG2_STRIDE}"
    );

    let expected_span = Structure::PRODUCTION.log2_ruler_span();
    ensure!(
        deployed_span == expected_span,
        "incompatible root tournament span: deployed log2step + height is {deployed_span}, node requires {expected_span}"
    );

    Ok(())
}

fn validate_state_transition_marchid(deployed_marchid: u64) -> Result<()> {
    let required_marchid = u64::from(cartesi_machine::cartesi_machine_sys::CM_MARCHID);
    ensure!(
        deployed_marchid == required_marchid,
        "incompatible state transition MARCHID: deployed {deployed_marchid}, node requires {required_marchid}"
    );
    Ok(())
}

async fn validate_deployed_tournament_configuration(
    tournament_factory: Address,
    provider: &impl Provider,
) -> Result<()> {
    let factory = MultiLevelTournamentFactory::new(tournament_factory, provider);
    let parameters = factory
        .tournamentParameters(0)
        .call()
        .await
        .with_context(|| {
            format!("failed to query root parameters from tournament factory {tournament_factory}")
        })?;

    validate_root_tournament_geometry(parameters.log2step, parameters.height)
        .with_context(|| format!("tournament factory {tournament_factory} is incompatible"))?;

    let state_transition = factory.stateTransition().call().await.with_context(|| {
        format!("failed to query state transition from tournament factory {tournament_factory}")
    })?;
    let deployed_marchid = CartesiStateTransition::new(state_transition, provider)
        .CM_MARCHID()
        .call()
        .await
        .with_context(|| {
            format!(
                "failed to query MARCHID from state transition {state_transition} configured by tournament factory {tournament_factory}"
            )
        })?;

    validate_state_transition_marchid(deployed_marchid).with_context(|| {
        format!(
            "state transition {state_transition} configured by tournament factory {tournament_factory} is incompatible"
        )
    })
}

#[derive(Clone, Parser)]
#[command(name = "cartesi_prt_args")]
#[command(about = "Arguments of Cartesi PRT")]
pub struct PRTArgs {
    /// address of application
    #[arg(long, env)]
    pub app_address: Address,

    /// path to machine template image
    #[arg(long, env)]
    pub machine_path: PathBuf,

    /// blockchain read gateway endpoint URL
    #[arg(long, env, default_value = ANVIL_URL)]
    pub web3_rpc_url: Url,

    /// raw-transaction submission endpoint URL; defaults to the read gateway
    #[arg(long, env)]
    pub web3_submit_rpc_url: Option<Url>,

    /// blockchain chain id
    #[arg(long, env, default_value_t = ANVIL_CHAIN_ID)]
    pub web3_chain_id: u64,

    #[clap(subcommand)]
    pub signer: SignerArgs,

    /// polling sleep interval
    #[arg(long, env, default_value_t = SLEEP_DURATION)]
    pub sleep_duration_seconds: u64,

    /// execute and durably publish open-epoch inputs in batches of N;
    /// 1 processes each input immediately, and sealing flushes a
    /// shorter final batch
    #[arg(
        long,
        env,
        default_value_t = crate::storage::DEFAULT_SNAPSHOT_GAP_INPUTS,
        value_parser = clap::value_parser!(u64).range(1..)
    )]
    pub snapshot_gap_inputs: u64,

    #[arg(long, env, default_value_os_t = std::env::temp_dir())]
    pub state_dir: PathBuf,

    /// error codes to retry `get_logs` with shorter block range
    #[arg(long, env, default_values = &["-32005", "-32600", "-32602", "-32616"])]
    // -32005 Infura
    // -32600, -32602 Alchemy
    // -32616 QuickNode
    pub long_block_range_error_codes: Vec<String>,
}

#[derive(Subcommand, Debug, Clone)]
pub enum SignerArgs {
    /// private-key signer
    #[command(
        group(
            ArgGroup::new("pk_source")
                .required(true)
                .args(&["web3_private_key", "web3_private_key_file"])
        )
    )]
    Pk {
        #[arg(long, env, group = "pk_source")]
        web3_private_key: Option<String>,

        #[arg(long, env, group = "pk_source")]
        web3_private_key_file: Option<PathBuf>,
    },

    /// AWS KMS signer
    #[command(
        group(
            ArgGroup::new("kms_source")
                .required(true)
                .args(&["aws_kms_key_id", "aws_kms_key_id_file"])
        )
    )]
    AwsKms {
        #[arg(long, env, group = "kms_source")]
        aws_kms_key_id: Option<String>,

        #[arg(long, env, group = "kms_source")]
        aws_kms_key_id_file: Option<PathBuf>,

        /// aws endpoint url
        #[arg(long, env)]
        aws_endpoint_url: Option<String>,

        /// aws region
        #[arg(long, env, default_value = "us-east-1")]
        aws_region: String,
    },
}

#[derive(Clone)]
pub struct NodeConfig {
    // App
    pub address_book: AddressBook,
    pub machine_path: PathBuf,

    // Provider
    pub chain_id: NamedChain,
    pub ethereum_gateway: Url,
    pub ethereum_submit_gateway: Url,
    pub signer_address: Address,

    // State
    pub state_dir: PathBuf,

    // Misc
    pub sleep_duration: Duration,
    pub long_block_range_error_codes: Vec<String>,
    pub snapshot_gap_inputs: u64,

    // Private signing capability. Read providers remain signerless.
    wallet: EthereumWallet,
}

impl fmt::Display for NodeConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.address_book)?;
        writeln!(f, "Machine path: {}", self.machine_path.display())?;
        writeln!(f, "Signer address: {}", self.signer_address)?;
        writeln!(f, "Chain Id: {} ({})", self.chain_id, self.chain_id as u64)?;
        writeln!(f, "Ethereum read gateway: <redacted>")?;
        writeln!(f, "Ethereum submit gateway: <redacted>")?;
        writeln!(f, "State directory: {}", self.state_dir.display())?;
        writeln!(
            f,
            "Sleep duration: {} seconds",
            self.sleep_duration.as_secs()
        )?;
        write!(f, "Long block range error codes: [")?;
        for (i, item) in self.long_block_range_error_codes.iter().enumerate() {
            if i > 0 {
                write!(f, ", ")?;
            }
            write!(f, "{}", item)?;
        }
        write!(f, "]")?;
        Ok(())
    }
}

impl NodeConfig {
    pub fn storage(&self) -> Result<Storage, StorageError> {
        let mut access = Storage::new(&self.state_dir)?;
        access.set_snapshot_gap_inputs(self.snapshot_gap_inputs);
        Ok(access)
    }

    /// For workers that only read through their own handle (the
    /// epoch manager; the dispute Hero opens its own read-write
    /// Storage). Fails fast under write pressure instead of stalling.
    pub fn storage_read_only(&self) -> Result<Storage, StorageError> {
        Storage::open_read_only(&self.state_dir)
    }

    pub async fn read_provider(&self) -> DynProvider {
        create_rpc_provider(&self.ethereum_gateway, self.chain_id).await
    }

    pub async fn transaction_lane(&self, read_provider: DynProvider) -> TransactionLane {
        let submit_provider =
            create_rpc_provider(&self.ethereum_submit_gateway, self.chain_id).await;
        let lane = TransactionLane::new(
            read_provider,
            submit_provider,
            self.chain_id as u64,
            self.wallet.clone(),
        );
        assert_eq!(
            lane.signer_address(),
            self.signer_address,
            "transaction lane signer does not match configured signer"
        );
        lane
    }

    pub async fn setup() -> Result<(Self, Storage)> {
        let args = PRTArgs::parse();

        let chain_id = args
            .web3_chain_id
            .try_into()
            .expect("fail to convert chain id");

        let provider = create_rpc_provider(&args.web3_rpc_url, chain_id).await;
        let (signer_address, wallet) = create_signer(chain_id, &args.signer).await;
        let address_book = AddressBook::new(args.app_address, &provider).await;
        validate_deployed_tournament_configuration(address_book.tournament_factory, &provider)
            .await?;
        let ethereum_submit_gateway = args
            .web3_submit_rpc_url
            .unwrap_or_else(|| args.web3_rpc_url.clone());

        let mut storage = Storage::initialize(
            &args.state_dir,
            &args.machine_path,
            address_book.genesis_block_number,
            address_book.app,
        )
        .context("could not create `storage`")?;

        let mut machine = storage
            .snapshot(0, 0)
            .unwrap()
            .expect("epoch zero should always exist");
        assert_eq!(
            machine.state_hash().unwrap(),
            address_book.initial_hash,
            "local machine initial hash doesn't match on-chain"
        );

        Ok((
            Self {
                address_book,
                state_dir: storage.state_dir().to_owned(),
                machine_path: args.machine_path,
                chain_id,
                signer_address,
                ethereum_gateway: args.web3_rpc_url,
                ethereum_submit_gateway,
                sleep_duration: Duration::from_secs(args.sleep_duration_seconds),
                wallet,
                long_block_range_error_codes: args.long_block_range_error_codes,
                snapshot_gap_inputs: args.snapshot_gap_inputs,
            },
            storage,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blockchain_reader::test_utils::{
        anvil_state_path, deployment_address, rpc_client_with_timeout,
    };
    use alloy::{node_bindings::Anvil, providers::ProviderBuilder};

    fn args_with_snapshot_gap(gap: &str) -> Vec<&str> {
        vec![
            "cartesi-rollups-prt-node",
            "--app-address",
            "0x0000000000000000000000000000000000000000",
            "--machine-path",
            "/tmp/machine",
            "--snapshot-gap-inputs",
            gap,
            "pk",
            "--web3-private-key",
            "unused-by-parser",
        ]
    }

    #[test]
    fn accepts_snapshot_gap_of_one() {
        let args = PRTArgs::try_parse_from(args_with_snapshot_gap("1")).unwrap();
        assert_eq!(args.snapshot_gap_inputs, 1);
    }

    #[test]
    fn rejects_zero_snapshot_gap() {
        let error = PRTArgs::try_parse_from(args_with_snapshot_gap("0"))
            .err()
            .expect("zero snapshot gap should fail argument parsing");
        assert_eq!(error.kind(), clap::error::ErrorKind::ValueValidation);
        assert!(error.to_string().contains("--snapshot-gap-inputs"));
    }

    #[test]
    fn accepts_canonical_root_tournament_geometry() {
        validate_root_tournament_geometry(44, 48).unwrap();
    }

    #[test]
    fn rejects_wrong_root_tournament_stride() {
        let error = validate_root_tournament_geometry(43, 49).unwrap_err();
        assert!(error.to_string().contains("deployed log2step 43"));
    }

    #[test]
    fn rejects_wrong_root_tournament_span() {
        let error = validate_root_tournament_geometry(44, 47).unwrap_err();
        assert!(error.to_string().contains("log2step + height is 91"));
    }

    #[test]
    fn rejects_root_tournament_span_overflow() {
        let error = validate_root_tournament_geometry(u64::MAX, 1).unwrap_err();
        assert!(error.to_string().contains("span overflows u64"));
    }

    #[test]
    fn accepts_linked_machine_marchid() {
        validate_state_transition_marchid(u64::from(
            cartesi_machine::cartesi_machine_sys::CM_MARCHID,
        ))
        .unwrap();
    }

    #[test]
    fn rejects_wrong_machine_marchid() {
        let required = u64::from(cartesi_machine::cartesi_machine_sys::CM_MARCHID);
        let deployed = required ^ 1;
        let error = validate_state_transition_marchid(deployed).unwrap_err();
        assert_eq!(
            error.to_string(),
            format!(
                "incompatible state transition MARCHID: deployed {deployed}, node requires {required}"
            )
        );
    }

    #[tokio::test]
    async fn accepts_deployed_factory_state_transition_and_machine() {
        let state = anvil_state_path();
        let anvil = Anvil::default()
            .args(["--load-state", state.to_str().unwrap()])
            .spawn();
        let provider =
            ProviderBuilder::new().connect_client(rpc_client_with_timeout(anvil.endpoint_url()));

        validate_deployed_tournament_configuration(
            deployment_address("MultiLevelTournamentFactory"),
            &provider,
        )
        .await
        .unwrap();
    }
}
