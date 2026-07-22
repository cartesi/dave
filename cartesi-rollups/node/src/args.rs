// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::blockchain_reader::AddressBook;
use crate::storage::{Storage, StorageError};
use alloy::{
    network::EthereumWallet, primitives::Address, providers::DynProvider,
    transports::http::reqwest::Url,
};
use alloy_chains::NamedChain;
use clap::{ArgGroup, Parser, Subcommand};
use std::{fmt, path::PathBuf, time::Duration};

use crate::provider::{TransactionLane, create_rpc_provider, create_signer};

const ANVIL_CHAIN_ID: u64 = 31337;
const ANVIL_URL: &str = "http://127.0.0.1:8545";
const SLEEP_DURATION: u64 = 30;

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

    /// keep every Nth input-boundary machine snapshot (1 keeps all);
    /// the disk-vs-dispute-replay knob
    #[arg(long, env, default_value_t = crate::storage::DEFAULT_SNAPSHOT_GAP_INPUTS)]
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

    pub async fn setup() -> (Self, Storage) {
        let args = PRTArgs::parse();

        let chain_id = args
            .web3_chain_id
            .try_into()
            .expect("fail to convert chain id");

        let provider = create_rpc_provider(&args.web3_rpc_url, chain_id).await;
        let (signer_address, wallet) = create_signer(chain_id, &args.signer).await;
        let address_book = AddressBook::new(args.app_address, &provider).await;
        let ethereum_submit_gateway = args
            .web3_submit_rpc_url
            .unwrap_or_else(|| args.web3_rpc_url.clone());

        let mut storage = Storage::migrate(
            &args.state_dir,
            &args.machine_path,
            address_book.genesis_block_number,
            address_book.app,
        )
        .expect("could not create `storage`");

        let mut machine = storage
            .snapshot(0, 0)
            .unwrap()
            .expect("epoch zero should always exist");
        assert_eq!(
            machine.state_hash().unwrap(),
            address_book.initial_hash,
            "local machine initial hash doesn't match on-chain"
        );

        (
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
        )
    }
}
