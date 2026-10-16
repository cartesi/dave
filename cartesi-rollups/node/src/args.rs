// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::blockchain_reader::AddressBook;
use crate::chain::Chain;
use crate::engine::{EngineConfig, Level, Structure, TournamentGeometry};
use crate::fatal::Fatal;
use crate::storage::{Seed, StateDirLock, Storage, StorageError, Template};
use alloy::{
    network::EthereumWallet,
    primitives::{Address, B256},
    providers::{DynProvider, Provider},
    transports::http::reqwest::Url,
};
use alloy_chains::NamedChain;
use anyhow::{Context, Result, ensure};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;
use cartesi_machine::Machine;
use cartesi_prt_contracts::{
    cartesi_state_transition::CartesiStateTransition,
    multi_level_tournament_factory::MultiLevelTournamentFactory,
};
use clap::{ArgGroup, Parser, Subcommand};
use std::{fmt, path::PathBuf, sync::Arc, time::Duration};

use crate::provider::{TransactionLane, create_rpc_provider, create_signer, rpc_provider};

const ANVIL_CHAIN_ID: u64 = 31337;
const POLLING_INTERVAL: u64 = 30;

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
    NamedChain::try_from(chain_id).map_err(|_| {
        Fatal::terminal(format!(
            "--blockchain-id {chain_id} is not a chain this node knows"
        ))
        .into()
    })
}

fn validate_state_transition_marchid(deployed_marchid: u64) -> Result<()> {
    let required_marchid = u64::from(cartesi_machine::cartesi_machine_sys::CM_MARCHID);
    ensure!(
        deployed_marchid == required_marchid,
        Fatal::terminal(format!(
            "incompatible state transition MARCHID: deployed {deployed_marchid}, node requires {required_marchid}"
        ))
    );
    Ok(())
}

/// The deployed step's resets must restore the uarch the node's resets
/// restore: otherwise every big-cycle boundary the node commits to is one
/// the step does not prove.
fn validate_state_transition_uarch(deployed_hash: B256, linked_hash: B256) -> Result<()> {
    ensure!(
        deployed_hash == linked_hash,
        Fatal::terminal(format!(
            "incompatible state transition pristine uarch hash: deployed {deployed_hash}, linked emulator {linked_hash}"
        ))
    );
    Ok(())
}

/// Discovers the deployed tournament geometry from the factory the
/// consensus instantiates every epoch's tournament with, and checks the
/// factory's state transition against the linked machine: its MARCHID and
/// the pristine uarch its resets restore.
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
        Fatal::terminal(format!(
            "tournament factory {tournament_factory} reports {level_count} levels"
        ))
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
    let geometry = tournament_geometry_from_rows(level_count, &rows).map_err(|e| {
        Fatal::terminal(format!(
            "tournament factory {tournament_factory} is incompatible: {e:#}"
        ))
    })?;

    let state_transition = factory.stateTransition().call().await.with_context(|| {
        format!("failed to query state transition from tournament factory {tournament_factory}")
    })?;
    let deployed = CartesiStateTransition::new(state_transition, provider);
    let deployed_marchid = deployed.CM_MARCHID().call().await.with_context(|| {
        format!(
            "failed to query MARCHID from state transition {state_transition} configured by tournament factory {tournament_factory}"
        )
    })?;
    let deployed_uarch_hash = deployed
        .UARCH_PRISTINE_STATE_HASH()
        .call()
        .await
        .with_context(|| {
            format!(
                "failed to query the pristine uarch hash from state transition {state_transition} configured by tournament factory {tournament_factory}"
            )
        })?;
    // Read outside the context below: a local fault must never be reported
    // as an incompatible deployment.
    let linked_uarch_hash = B256::from(Machine::uarch_pristine_hash());

    validate_state_transition_marchid(deployed_marchid)
        .and_then(|()| validate_state_transition_uarch(deployed_uarch_hash, linked_uarch_hash))
        .with_context(|| {
            format!(
                "state transition {state_transition} configured by tournament factory {tournament_factory} is incompatible"
            )
        })?;
    Ok(geometry)
}

/// Whether the signer votes as a sentry, read once at startup (a rotation
/// later is not reported): a node whose operator expects it to vote should
/// say so where they look first.
async fn log_sentry_role(book: &AddressBook, signer: Address, provider: &impl Provider) {
    match DaveConsensus::new(book.consensus, provider)
        .getSentryId(signer)
        .call()
        .await
    {
        Ok(id) if id.is_zero() => log::info!(
            "signer {signer} is not a sentry of consensus {}: it disputes and settles, \
             but casts no sentry claim",
            book.consensus
        ),
        Ok(id) => log::info!(
            "signer {signer} is sentry {id} of consensus {}",
            book.consensus
        ),
        Err(e) => log::warn!("could not read the signer's sentry role: {e}"),
    }
}

#[derive(Clone, Parser)]
#[command(about = "The sling node: a PRT validator for Cartesi Rollups applications")]
// Help never echoes an env value: one can carry a secret (a signer key, an
// RPC URL with an API key).
#[command(
    mut_args = |arg| arg.hide_env_values(true),
    mut_subcommands = |cmd| cmd.mut_args(|arg| arg.hide_env_values(true)),
)]
pub struct PRTArgs {
    /// address of application
    #[arg(long, env = "CARTESI_SLING_APP_ADDRESS")]
    pub app_address: Address,

    /// machine image a new data directory starts from: the application's
    /// template, or the state its current sealed epoch starts from; a seeded
    /// directory does not read it
    #[arg(long, env = "CARTESI_SLING_TEMPLATE_PATH")]
    pub template_path: PathBuf,

    /// blockchain read gateway endpoint URL
    #[arg(long, env = "CARTESI_SLING_BLOCKCHAIN_HTTP_ENDPOINT")]
    pub blockchain_http_endpoint: Url,

    /// raw-transaction submission endpoint URL; defaults to the read gateway
    #[arg(long, env = "CARTESI_SLING_BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT")]
    pub blockchain_http_submit_endpoint: Option<Url>,

    /// blockchain chain id
    #[arg(long, env = "CARTESI_SLING_BLOCKCHAIN_ID")]
    pub blockchain_id: u64,

    #[clap(subcommand)]
    pub signer: SignerArgs,

    /// polling interval in seconds
    #[arg(long, env = "CARTESI_SLING_POLLING_INTERVAL", default_value_t = POLLING_INTERVAL)]
    pub polling_interval: u64,

    /// execute and durably publish open-epoch inputs in batches of N;
    /// 1 processes each input immediately, and sealing flushes a
    /// shorter final batch
    #[arg(
        long,
        env = "CARTESI_SLING_SNAPSHOT_GAP_INPUTS",
        default_value_t = crate::storage::DEFAULT_SNAPSHOT_GAP_INPUTS,
        value_parser = clap::value_parser!(u64).range(1..)
    )]
    pub snapshot_gap_inputs: u64,

    /// node data directory (database and machine snapshots); keep it across
    /// restarts, on a filesystem with reflinks
    #[arg(long, env = "CARTESI_SLING_DATA_DIR")]
    pub data_dir: PathBuf,
}

/// The `pk` signer's key when no key file is given. Never a flag: any local
/// user can read a process's arguments (ps, /proc/<pid>/cmdline). clap reads
/// no argument from the environment alone, so the signer reads it.
pub(crate) const PRIVATE_KEY_ENV: &str = "CARTESI_SLING_AUTH_PRIVATE_KEY";

#[derive(Subcommand, Debug, Clone)]
pub enum SignerArgs {
    /// private-key signer: the key comes from the
    /// CARTESI_SLING_AUTH_PRIVATE_KEY environment variable or a key file,
    /// never from the command line
    Pk {
        /// file whose first line is the private key
        #[arg(long, env = "CARTESI_SLING_AUTH_PRIVATE_KEY_FILE")]
        auth_private_key_file: Option<PathBuf>,
    },

    /// AWS KMS signer
    #[command(group(ArgGroup::new("kms_source").required(true)))]
    AwsKms {
        #[arg(long, env = "CARTESI_SLING_AUTH_AWS_KMS_KEY_ID", group = "kms_source")]
        auth_aws_kms_key_id: Option<String>,

        #[arg(
            long,
            env = "CARTESI_SLING_AUTH_AWS_KMS_KEY_ID_FILE",
            group = "kms_source"
        )]
        auth_aws_kms_key_id_file: Option<PathBuf>,

        // No env: the AWS SDK reads these variables itself, with its own
        // precedence (AWS_ENDPOINT_URL_KMS over AWS_ENDPOINT_URL).
        /// KMS endpoint URL, overriding the one the AWS SDK resolves
        /// (AWS_ENDPOINT_URL_KMS, AWS_ENDPOINT_URL, the profile, FIPS, the
        /// region's partition)
        #[arg(long)]
        aws_endpoint_url: Option<String>,

        /// AWS region, overriding the one the AWS SDK resolves (AWS_REGION,
        /// the profile, instance metadata)
        #[arg(long)]
        aws_region: Option<String>,
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

/// One line: a line-oriented log pipeline splits a multi-line record into
/// lines without a level.
impl fmt::Display for NodeConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.address_book)?;
        write!(f, ", Template path: {}", self.machine_path.display())?;
        write!(f, ", Signer address: {}", self.signer_address)?;
        write!(
            f,
            ", Chain Id: {} ({})",
            self.chain_id, self.chain_id as u64
        )?;
        write!(f, ", Ethereum read gateway: <redacted>")?;
        // The URLs stay redacted, but whether submissions have their own
        // endpoint (a revert-protecting relay) still shows.
        let submit_gateway = if self.ethereum_submit_gateway == self.ethereum_gateway {
            "the read gateway"
        } else {
            "<redacted>"
        };
        write!(f, ", Ethereum submit gateway: {submit_gateway}")?;
        write!(f, ", Data directory: {}", self.state_dir.display())?;
        write!(
            f,
            ", Polling interval: {} seconds",
            self.sleep_duration.as_secs()
        )?;
        write!(f, ", Snapshot gap inputs: {}", self.snapshot_gap_inputs)?;
        Ok(())
    }
}

impl NodeConfig {
    pub fn storage(&self) -> Result<Storage, StorageError> {
        let mut access = Storage::new(&self.state_dir)?;
        access.set_snapshot_gap_inputs(self.snapshot_gap_inputs);
        Ok(access)
    }

    // Setup checked both endpoints' chains, so the workers ask nothing.
    pub fn read_provider(&self) -> Result<DynProvider> {
        rpc_provider(&self.ethereum_gateway, self.chain_id).context("--blockchain-http-endpoint")
    }

    pub fn transaction_lane(&self, read_provider: DynProvider) -> Result<TransactionLane> {
        let submit_provider = rpc_provider(&self.ethereum_submit_gateway, self.chain_id).context(
            "--blockchain-http-submit-endpoint (defaults to --blockchain-http-endpoint)",
        )?;
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
    /// endpoints' chains and the deployment; then, unless a probe that
    /// creates nothing finds the data directory seeded, the --template-path
    /// image against the chain; then, under the state-directory lock, the
    /// directory's pins. A refused endpoint, deployment or image creates
    /// nothing, a refused pin leaves the existing directory untouched, and a
    /// seeded directory never reads its image.
    pub async fn setup_with(args: PRTArgs) -> Result<Self> {
        let chain_id = named_chain(args.blockchain_id)?;

        let provider = create_rpc_provider(&args.blockchain_http_endpoint, chain_id)
            .await
            .context("--blockchain-http-endpoint")?;
        let relay = args
            .blockchain_http_submit_endpoint
            .filter(|url| *url != args.blockchain_http_endpoint);
        match &relay {
            Some(url) => {
                create_rpc_provider(url, chain_id)
                    .await
                    .context("--blockchain-http-submit-endpoint")?;
            }
            // Anvil is the tests' chain, where nobody orders transactions.
            None if args.blockchain_id != ANVIL_CHAIN_ID => log::warn!(
                "no separate --blockchain-http-submit-endpoint: transactions go to the read \
                 endpoint, on a public node its public pool, where an adversary who orders \
                 transactions can land a copy of each honest step first and make the node pay \
                 for its reverted one (up to about 3.76M gas for a leaf proof); in production, \
                 send through a relay that meets the node README's requirements"
            ),
            None => {}
        }
        let ethereum_submit_gateway =
            relay.unwrap_or_else(|| args.blockchain_http_endpoint.clone());
        let (signer_address, wallet) = create_signer(chain_id, &args.signer).await?;
        // Sampled before the deployment blocks are read: it bounds a new
        // directory's watermark (AddressBook::initial_watermark).
        let finalized = Chain::new(provider.clone())
            .finalized_block_number()
            .await
            .context("--blockchain-http-endpoint: failed to read the finalized block")?;
        let address_book = AddressBook::new(args.app_address, &provider)
            .await
            .with_context(|| {
                format!(
                    "--app-address {}: is it a Dave application on chain {}?",
                    args.app_address, args.blockchain_id
                )
            })?;
        log_sentry_role(&address_book, signer_address, &provider).await;
        let geometry =
            discover_deployed_tournament(address_book.tournament_factory, &provider).await?;
        log::info!("deployed tournament geometry (stride/height, top first): {geometry}");
        let seed = if Storage::is_seeded(&args.data_dir)
            .context("could not open the data directory")?
        {
            log::info!(
                "data directory `{}` is seeded; --template-path is not read",
                args.data_dir.display()
            );
            None
        } else {
            let template = Template::inspect(&args.template_path).context("--template-path")?;
            let epoch = address_book
                .seed_epoch(&Chain::new(provider.clone()), template.hash())
                .await?;
            // The engine loads every epoch's initial state as a template awaiting
            // input; from any other one the Hero would only warn every tick.
            ensure!(
                template.awaits_input(),
                Fatal::terminal(format!(
                    "--template-path matches application {}'s template, but the template is not \
                     paused at a manual accepted yield (awaiting input), so no epoch can start from \
                     it: the deployed application's template is unusable for the node",
                    address_book.app,
                ))
            );
            Some(Seed {
                image: template,
                epoch,
                watermark: address_book.initial_watermark(finalized),
            })
        };
        let state_lock = StateDirLock::acquire(&args.data_dir)?;
        let storage = Storage::initialize(
            &args.data_dir,
            seed.as_ref(),
            &EngineConfig::for_deployment(
                chain_id as u64,
                address_book.app,
                address_book.consensus,
                address_book.initial_hash,
                geometry,
            ),
        )
        .context("could not open the data directory")?;

        Ok(Self {
            address_book,
            state_dir: storage.state_dir().to_owned(),
            machine_path: args.template_path,
            chain_id,
            signer_address,
            ethereum_gateway: args.blockchain_http_endpoint,
            ethereum_submit_gateway,
            sleep_duration: Duration::from_secs(args.polling_interval),
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

    /// The flags every start needs.
    const REQUIRED: [&str; 11] = [
        "cartesi-sling-node",
        "--app-address",
        "0x0000000000000000000000000000000000000000",
        "--template-path",
        "/tmp/machine",
        "--blockchain-http-endpoint",
        "http://127.0.0.1:8545",
        "--blockchain-id",
        "31337",
        "--data-dir",
        "/tmp/state",
    ];

    /// [`REQUIRED`], then `rest`.
    fn parse(rest: &[&str]) -> std::result::Result<PRTArgs, clap::Error> {
        PRTArgs::try_parse_from(REQUIRED.iter().chain(rest))
    }

    /// A production start never wants anvil's endpoint or chain.
    #[test]
    fn the_chain_flags_have_no_default() {
        for flag in ["--blockchain-http-endpoint", "--blockchain-id"] {
            let at = REQUIRED.iter().position(|arg| *arg == flag).unwrap();
            let mut args = REQUIRED.to_vec();
            args.drain(at..at + 2);
            args.extend(["pk", "--auth-private-key-file", "/tmp/unread-by-the-parser"]);
            let error = PRTArgs::try_parse_from(args)
                .err()
                .unwrap_or_else(|| panic!("a start without {flag} must not parse"));
            assert_eq!(
                error.kind(),
                clap::error::ErrorKind::MissingRequiredArgument
            );
            assert!(error.to_string().contains(flag), "{error}");
        }
    }

    fn parse_with_snapshot_gap(gap: &str) -> std::result::Result<PRTArgs, clap::Error> {
        parse(&[
            "--snapshot-gap-inputs",
            gap,
            "pk",
            "--auth-private-key-file",
            "/tmp/unread-by-the-parser",
        ])
    }

    /// The process list shows every argument to any local user.
    #[test]
    fn the_private_key_itself_is_no_flag() {
        let error = parse(&["pk", "--auth-private-key", "0x01"])
            .err()
            .expect("a key on the command line must not parse");
        assert_eq!(error.kind(), clap::error::ErrorKind::UnknownArgument);
    }

    #[test]
    fn help_never_echoes_env_values() {
        fn check(cmd: &clap::Command) {
            for arg in cmd.get_arguments().filter(|arg| arg.get_env().is_some()) {
                assert!(
                    arg.is_hide_env_values_set(),
                    "{} would echo its env value",
                    arg.get_id()
                );
            }
            cmd.get_subcommands().for_each(check);
        }
        check(&<PRTArgs as clap::CommandFactory>::command());
    }

    #[test]
    fn an_unknown_chain_id_names_its_flag() {
        assert_eq!(named_chain(31337).unwrap(), NamedChain::AnvilHardhat);
        let error = named_chain(0xdead_beef).unwrap_err();
        assert!(
            error.to_string().contains("--blockchain-id"),
            "unexpected error: {error}"
        );
        assert_eq!(crate::fatal::exit_code(&error), 30);
    }

    #[test]
    fn accepts_snapshot_gap_of_one() {
        let args = parse_with_snapshot_gap("1").unwrap();
        assert_eq!(args.snapshot_gap_inputs, 1);
    }

    #[test]
    fn rejects_zero_snapshot_gap() {
        let error = parse_with_snapshot_gap("0")
            .err()
            .expect("zero snapshot gap should fail argument parsing");
        assert_eq!(error.kind(), clap::error::ErrorKind::ValueValidation);
        assert!(error.to_string().contains("--snapshot-gap-inputs"));
    }

    #[test]
    fn accepts_any_valid_factory_table() {
        let three_level = tournament_geometry_from_rows(3, &[(3, 44, 48), (3, 27, 17), (3, 0, 27)]);
        assert_eq!(three_level.unwrap(), TournamentGeometry::three_level());
        let two_level = tournament_geometry_from_rows(2, &[(2, 38, 54), (2, 0, 38)]);
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
        assert_eq!(crate::fatal::exit_code(&error), 30);
        assert_eq!(
            error.to_string(),
            format!(
                "incompatible state transition MARCHID: deployed {deployed}, node requires {required}"
            )
        );
    }

    #[test]
    fn accepts_the_linked_pristine_uarch() {
        let linked = B256::from(Machine::uarch_pristine_hash());
        validate_state_transition_uarch(linked, linked).unwrap();
    }

    #[test]
    fn rejects_another_pristine_uarch() {
        let linked = B256::from(Machine::uarch_pristine_hash());
        let mut deployed = linked;
        deployed[31] ^= 1;
        let error = validate_state_transition_uarch(deployed, linked).unwrap_err();
        assert_eq!(crate::fatal::exit_code(&error), 30);
        assert_eq!(
            error.to_string(),
            format!(
                "incompatible state transition pristine uarch hash: deployed {deployed}, linked emulator {linked}"
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
        // built with (DEVNET_GEOMETRY, the three-level test table by default).
        let expected = match std::env::var("DEVNET_GEOMETRY").as_deref() {
            Ok("canonical") => TournamentGeometry::checked_in(),
            _ => TournamentGeometry::three_level(),
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
        let key_files = [0, 1].map(|signer| {
            let path = dir.path().join(format!("key-{signer}"));
            std::fs::write(&path, alloy::hex::encode(anvil.keys()[signer].to_bytes())).unwrap();
            path
        });
        let args_for = |app: Address, machine_path: &Path, signer: usize| {
            PRTArgs::try_parse_from([
                "cartesi-sling-node",
                "--app-address",
                &app.to_string(),
                "--template-path",
                machine_path.to_str().unwrap(),
                "--blockchain-http-endpoint",
                &endpoint,
                "--blockchain-id",
                &chain_id,
                "--data-dir",
                state_dir.to_str().unwrap(),
                "pk",
                "--auth-private-key-file",
                key_files[signer].to_str().unwrap(),
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

        // A read endpoint on another chain is a flag to fix: terminal.
        let mut mainnet = args(&image);
        mainnet.blockchain_id = 1;
        let error = NodeConfig::setup_with(mainnet)
            .await
            .map(|_| ())
            .unwrap_err();
        assert_eq!(crate::fatal::exit_code(&error), 30, "{error:#}");
        assert!(
            format!("{error:#}").contains("--blockchain-id"),
            "unexpected error: {error:#}"
        );
        assert!(!state_dir.exists(), "a refused start must not write");

        let wrong = dir.path().join("wrong");
        store_template(&wrong, |_| {});
        let error = NodeConfig::setup_with(args(&wrong))
            .await
            .map(|_| ())
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("--template-path"),
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

        // The startup record: one line, the endpoint redacted.
        let shown = config.to_string();
        assert!(
            !shown.contains('\n') && !shown.contains(&endpoint),
            "{shown}"
        );

        // The restart path: the pinned directory reopens without a re-import.
        drop(config);
        NodeConfig::setup_with(args(&image)).await?;
        // A seeded directory restarts without its image (COMP-3).
        NodeConfig::setup_with(args(&dir.path().join("vanished"))).await?;
        // A submit endpoint that does not answer fails the start, retried by
        // the supervisor. Answering endpoints give workers' clients that are
        // built without asking anything.
        let mut silent_relay = args(&image);
        silent_relay.blockchain_http_submit_endpoint = Some("http://127.0.0.1:1".parse()?);
        let error = NodeConfig::setup_with(silent_relay)
            .await
            .map(|_| ())
            .unwrap_err();
        assert_eq!(crate::fatal::exit_code(&error), 1);
        assert!(
            format!("{error:#}").contains("--blockchain-http-submit-endpoint"),
            "unexpected error: {error:#}"
        );
        let config = NodeConfig::setup_with(args(&image)).await?;
        config.transaction_lane(config.read_provider()?)?;
        drop(config);

        // A new signer reopens the same directory: a previous signer's bonds
        // stay recoverable by anyone, so rotating keys needs no replay.
        NodeConfig::setup_with(args_for(book.app, &image, 1)).await?;
        Ok(())
    }
}
