// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::blockchain_reader::AddressBook;
use crate::engine::{Level, Structure, TournamentGeometry};
use crate::storage::{Storage, StorageError};
use alloy::{
    network::EthereumWallet,
    primitives::Address,
    providers::{DynProvider, Provider},
    transports::http::reqwest::Url,
};
use alloy_chains::NamedChain;
use anyhow::{Context, Result, ensure};
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

/// The deepest leaf level the measured dense rate builds within the
/// selected inner timeout (docs/measurements/constants.md). A deeper one
/// may not be defensible in time, so the node says so at startup.
const MEASURED_LEAF_HEIGHT_CAPACITY: u64 = 37;

/// One `tournamentParameters(level)` row: (levels, log2step, height).
type TableRow = (u64, u64, u64);

/// The factory's table, as the node will pin and run it. Every row
/// repeats the level count; a row disagreeing with the count is a
/// broken provider, not a geometry.
fn tournament_geometry_from_rows(
    level_count: u64,
    rows: &[TableRow],
) -> Result<TournamentGeometry> {
    let mut levels = Vec::with_capacity(rows.len());
    for (level, &(row_levels, log2_stride, height)) in rows.iter().enumerate() {
        ensure!(
            row_levels == level_count,
            "level {level} reports {row_levels} levels, but the factory reports {level_count}"
        );
        levels.push(Level {
            log2_stride,
            height,
        });
    }
    TournamentGeometry::new(levels, &Structure::PRODUCTION)
}

fn validate_state_transition_marchid(deployed_marchid: u64) -> Result<()> {
    let required_marchid = u64::from(cartesi_machine::cartesi_machine_sys::CM_MARCHID);
    ensure!(
        deployed_marchid == required_marchid,
        "incompatible state transition MARCHID: deployed {deployed_marchid}, node requires {required_marchid}"
    );
    Ok(())
}

/// Discovers the deployed tournament geometry from the factory the
/// consensus instantiates every epoch's tournament with, and checks the
/// factory's state transition against the linked machine.
async fn discover_deployed_tournament(
    tournament_factory: Address,
    provider: &impl Provider,
) -> Result<TournamentGeometry> {
    let factory = MultiLevelTournamentFactory::new(tournament_factory, provider);
    let level_count = factory
        .tournamentLevelCount()
        .call()
        .await
        .with_context(|| {
            format!("failed to query the level count of tournament factory {tournament_factory}")
        })?;
    // Levels tile the ruler with nonzero heights, so a larger count
    // cannot validate; refuse it before issuing that many calls.
    ensure!(
        (1..=Structure::PRODUCTION.log2_ruler_span()).contains(&level_count),
        "tournament factory {tournament_factory} reports {level_count} levels"
    );
    let mut rows = Vec::new();
    for level in 0..level_count {
        let parameters = factory
            .tournamentParameters(level)
            .call()
            .await
            .with_context(|| {
                format!(
                    "failed to query level {level} parameters from tournament factory {tournament_factory}"
                )
            })?;
        rows.push((parameters.levels, parameters.log2step, parameters.height));
    }
    let geometry = tournament_geometry_from_rows(level_count, &rows)
        .with_context(|| format!("tournament factory {tournament_factory} is incompatible"))?;
    if geometry.leaf_height() > MEASURED_LEAF_HEIGHT_CAPACITY {
        log::warn!(
            "leaf level height {} exceeds the measured capacity {MEASURED_LEAF_HEIGHT_CAPACITY}: \
             leaf commitments may not build within the inner timeout",
            geometry.leaf_height()
        );
    }

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
    })?;
    Ok(geometry)
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
        let geometry =
            discover_deployed_tournament(address_book.tournament_factory, &provider).await?;
        log::info!("deployed tournament geometry (stride/height, top first): {geometry}");
        let ethereum_submit_gateway = args
            .web3_submit_rpc_url
            .unwrap_or_else(|| args.web3_rpc_url.clone());

        let mut storage = Storage::initialize(
            &args.state_dir,
            &args.machine_path,
            address_book.genesis_block_number,
            address_book.app,
            address_book.consensus,
            &geometry,
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
    fn accepts_any_valid_factory_table() {
        let canonical = tournament_geometry_from_rows(3, &[(3, 44, 48), (3, 27, 17), (3, 0, 27)]);
        assert_eq!(canonical.unwrap(), TournamentGeometry::canonical());
        let two_level = tournament_geometry_from_rows(2, &[(2, 37, 55), (2, 0, 37)]);
        assert_eq!(two_level.unwrap(), TournamentGeometry::two_level());
    }

    #[test]
    fn rejects_rows_disagreeing_with_the_level_count() {
        let error =
            tournament_geometry_from_rows(3, &[(3, 44, 48), (2, 27, 17), (3, 0, 27)]).unwrap_err();
        assert!(error.to_string().contains("level 1 reports 2 levels"));
    }

    #[test]
    fn rejects_an_invalid_factory_table() {
        let error =
            tournament_geometry_from_rows(3, &[(3, 44, 47), (3, 27, 17), (3, 0, 27)]).unwrap_err();
        assert!(error.to_string().contains("an epoch spans"));
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
    async fn discovers_the_deployed_tournament_geometry() {
        let state = anvil_state_path();
        let anvil = Anvil::default()
            .args(["--load-state", state.to_str().unwrap()])
            .spawn();
        let provider =
            ProviderBuilder::new().connect_client(rpc_client_with_timeout(anvil.endpoint_url()));

        let geometry = discover_deployed_tournament(
            deployment_address("MultiLevelTournamentFactory"),
            &provider,
        )
        .await
        .unwrap();
        // The devnet bundle serves the table of the geometry profile it was
        // built with (DEVNET_GEOMETRY, canonical by default).
        let expected = match std::env::var("DEVNET_GEOMETRY").as_deref() {
            Ok("two-level") => TournamentGeometry::two_level(),
            _ => TournamentGeometry::canonical(),
        };
        assert_eq!(
            geometry, expected,
            "the devnet bundle serves another geometry than DEVNET_GEOMETRY selects"
        );
    }
}
