// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::blockchain_reader::AddressBook;
use crate::chain::Chain;
use crate::engine::{Level, Structure, TournamentGeometry};
use crate::storage::{StateDirLock, Storage, StorageError, Template};
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
use std::{fmt, path::PathBuf, sync::Arc, time::Duration};

use crate::provider::{TransactionLane, create_rpc_provider, create_signer};

const ANVIL_CHAIN_ID: u64 = 31337;
const ANVIL_URL: &str = "http://127.0.0.1:8545";
const SLEEP_DURATION: u64 = 30;

/// The deepest leaf level the measured dense rate builds within the
/// selected commitment budget (docs/measurements/constants.md). A deeper one
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

/// Chain ids the node knows by name; any other is refused.
fn named_chain(chain_id: u64) -> Result<NamedChain> {
    NamedChain::try_from(chain_id)
        .map_err(|_| anyhow::anyhow!("--web3-chain-id {chain_id} is not a chain this node knows"))
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
pub(crate) async fn discover_deployed_tournament(
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
             leaf commitments may not build within the commitment budget",
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

    /// node state (database, snapshots, dispute scratch); keep it across
    /// restarts, on a filesystem with reflinks
    #[arg(long, env)]
    pub state_dir: PathBuf,
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
    pub snapshot_gap_inputs: u64,

    // Private signing capability. Read providers remain signerless.
    wallet: EthereumWallet,

    // Every worker holds a clone, so the lock outlives them all.
    _state_lock: Arc<StateDirLock>,
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
        write!(
            f,
            "Sleep duration: {} seconds",
            self.sleep_duration.as_secs()
        )?;
        Ok(())
    }
}

impl NodeConfig {
    pub fn storage(&self) -> Result<Storage, StorageError> {
        let mut access = Storage::new(&self.state_dir)?;
        access.set_snapshot_gap_inputs(self.snapshot_gap_inputs);
        Ok(access)
    }

    pub async fn read_provider(&self) -> Result<DynProvider> {
        create_rpc_provider(&self.ethereum_gateway, self.chain_id)
            .await
            .context("--web3-rpc-url")
    }

    pub async fn transaction_lane(&self, read_provider: DynProvider) -> Result<TransactionLane> {
        let submit_provider = create_rpc_provider(&self.ethereum_submit_gateway, self.chain_id)
            .await
            .context("--web3-submit-rpc-url (defaults to --web3-rpc-url)")?;
        Ok(TransactionLane::new(
            read_provider,
            submit_provider,
            self.chain_id as u64,
            self.wallet.clone(),
        ))
    }

    pub async fn setup() -> Result<Self> {
        Self::setup_with(PRTArgs::parse()).await
    }

    /// Validates everything it can before the first local write: the
    /// deployment, then the template against the chain's initial hash,
    /// then, under the state-directory lock, the directory's pins. A refused
    /// deployment or template creates nothing, and a refused pin leaves the
    /// existing directory untouched.
    pub async fn setup_with(args: PRTArgs) -> Result<Self> {
        let chain_id = named_chain(args.web3_chain_id)?;

        let provider = create_rpc_provider(&args.web3_rpc_url, chain_id)
            .await
            .context("--web3-rpc-url")?;
        let (signer_address, wallet) = create_signer(chain_id, &args.signer).await?;
        // Sampled before the deployment blocks are read: it bounds a new
        // directory's watermark (AddressBook::initial_watermark).
        let finalized = Chain::new(provider.clone())
            .finalized_block_number()
            .await
            .context("--web3-rpc-url: failed to read the finalized block")?;
        let address_book = AddressBook::new(args.app_address, &provider)
            .await
            .with_context(|| {
                format!(
                    "--app-address {}: is it a Dave application on chain {}?",
                    args.app_address, args.web3_chain_id
                )
            })?;
        let geometry =
            discover_deployed_tournament(address_book.tournament_factory, &provider).await?;
        log::info!("deployed tournament geometry (stride/height, top first): {geometry}");
        let template = Template::inspect(&args.machine_path).context("--machine-path")?;
        ensure!(
            *template.hash() == address_book.initial_hash,
            "--machine-path holds template {}, but application {} starts from {}: fix \
             --machine-path, or check --app-address",
            alloy::hex::encode_prefixed(template.hash()),
            address_book.app,
            alloy::hex::encode_prefixed(address_book.initial_hash),
        );
        // The engine loads every epoch's initial state as a template awaiting
        // input; from any other one the Hero would only warn every tick.
        ensure!(
            template.awaits_input(),
            "--machine-path matches application {}'s template, but the template is not paused \
             at a manual accepted yield (awaiting input), so no epoch can start from it: the \
             deployed application's template is unusable for the node",
            address_book.app,
        );
        let ethereum_submit_gateway = args
            .web3_submit_rpc_url
            .unwrap_or_else(|| args.web3_rpc_url.clone());
        // Fail a wrong submit endpoint now, not when the manager starts.
        create_rpc_provider(&ethereum_submit_gateway, chain_id)
            .await
            .context("--web3-submit-rpc-url (defaults to --web3-rpc-url)")?;

        let state_lock = StateDirLock::acquire(&args.state_dir)?;
        let storage = Storage::initialize(
            &args.state_dir,
            &template,
            address_book.initial_watermark(finalized),
            address_book.app,
            address_book.consensus,
            chain_id as u64,
            &geometry,
        )
        .context("could not open the state directory")?;

        Ok(Self {
            address_book,
            state_dir: storage.state_dir().to_owned(),
            machine_path: args.machine_path,
            chain_id,
            signer_address,
            ethereum_gateway: args.web3_rpc_url,
            ethereum_submit_gateway,
            sleep_duration: Duration::from_secs(args.sleep_duration_seconds),
            wallet,
            snapshot_gap_inputs: args.snapshot_gap_inputs,
            _state_lock: Arc::new(state_lock),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blockchain_reader::test_utils::{
        Deploy, anvil_state_path, deploy_app_from, deployment_address, program_path,
        rpc_client_with_timeout, spawn_anvil_and_provider, wallet_provider,
    };
    use crate::storage::sql::test_helper::{store_template, yield_exception};
    use alloy::{node_bindings::Anvil, providers::ProviderBuilder};
    use std::path::Path;

    fn args_with_snapshot_gap(gap: &str) -> Vec<&str> {
        vec![
            "cartesi-rollups-prt-node",
            "--app-address",
            "0x0000000000000000000000000000000000000000",
            "--machine-path",
            "/tmp/machine",
            "--state-dir",
            "/tmp/state",
            "--snapshot-gap-inputs",
            gap,
            "pk",
            "--web3-private-key",
            "unused-by-parser",
        ]
    }

    #[test]
    fn an_unknown_chain_id_names_its_flag() {
        assert_eq!(named_chain(31337).unwrap(), NamedChain::AnvilHardhat);
        let error = named_chain(0xdead_beef).unwrap_err();
        assert!(
            error.to_string().contains("--web3-chain-id"),
            "unexpected error: {error}"
        );
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
        let three_level = tournament_geometry_from_rows(3, &[(3, 44, 48), (3, 27, 17), (3, 0, 27)]);
        assert_eq!(three_level.unwrap(), TournamentGeometry::three_level());
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
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
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
            _ => TournamentGeometry::checked_in(),
        };
        assert_eq!(
            geometry, expected,
            "the devnet bundle serves another geometry than DEVNET_GEOMETRY selects"
        );
    }

    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn setup_validates_before_writing() -> std::result::Result<(), Box<dyn std::error::Error>>
    {
        let (anvil, _provider, book) = spawn_anvil_and_provider().await?;
        let dir = tempfile::tempdir()?;
        let state_dir = dir.path().join("state");
        let endpoint = anvil.endpoint();
        let chain_id = anvil.chain_id().to_string();
        let key = |signer: usize| alloy::hex::encode(anvil.keys()[signer].to_bytes());
        let args_for = |app: Address, machine_path: &Path, signer: usize| {
            PRTArgs::try_parse_from([
                "cartesi-rollups-prt-node",
                "--app-address",
                &app.to_string(),
                "--machine-path",
                machine_path.to_str().unwrap(),
                "--web3-rpc-url",
                &endpoint,
                "--web3-chain-id",
                &chain_id,
                "--state-dir",
                state_dir.to_str().unwrap(),
                "pk",
                "--web3-private-key",
                &key(signer),
            ])
            .unwrap()
        };
        let args = |machine_path: &Path| args_for(book.app, machine_path, 0);
        let image = program_path().join("machine-image");

        // A contract that is not an application: an error, not a panic.
        let error = NodeConfig::setup_with(args_for(book.input_box, &image, 0))
            .await
            .map(|_| ())
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("--app-address"),
            "unexpected error: {error:#}"
        );

        let wrong = dir.path().join("wrong");
        store_template(&wrong, |_| {});
        let error = NodeConfig::setup_with(args(&wrong))
            .await
            .map(|_| ())
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("--machine-path"),
            "unexpected error: {error:#}"
        );
        assert!(!state_dir.exists(), "a refused start must not write");

        // The deployed application's own template, but no epoch can start
        // from it: refused before anything is written.
        let terminal = dir.path().join("terminal");
        store_template(&terminal, yield_exception);
        let terminal_book = deploy_app_from(
            &wallet_provider(&anvil, 0),
            &Deploy {
                sentries: vec![anvil.addresses()[0]],
                claim_staging_period: 1000,
            },
            *Template::inspect(&terminal)?.hash(),
        )
        .await?;
        let error = NodeConfig::setup_with(args_for(terminal_book.app, &terminal, 0))
            .await
            .map(|_| ())
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("template is unusable for the node"),
            "unexpected error: {error:#}"
        );
        assert!(!state_dir.exists(), "a refused start must not write");

        let config = NodeConfig::setup_with(args(&image)).await?;
        let error = NodeConfig::setup_with(args(&image))
            .await
            .map(|_| ())
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("in use by another node process"),
            "unexpected error: {error:#}"
        );

        // The restart path: the pinned directory reopens without a re-import.
        drop(config);
        NodeConfig::setup_with(args(&image)).await?;

        // A new signer reopens the same directory: a previous signer's bonds
        // stay recoverable by anyone, so rotating keys needs no replay.
        NodeConfig::setup_with(args_for(book.app, &image, 1)).await?;
        Ok(())
    }
}
