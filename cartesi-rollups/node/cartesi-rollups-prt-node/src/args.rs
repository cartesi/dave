// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::{primitives::Address, providers::DynProvider, transports::http::reqwest::Url};
use alloy_chains::NamedChain;
use clap::{ArgGroup, Parser, Subcommand};
use rollups_blockchain_reader::AddressBook;
use rollups_state_manager::{
    StateAccessError, StateManager, persistent_state_access::PersistentStateAccess,
};
use std::{fmt, path::PathBuf, time::Duration};

use crate::provider::create_provider;

const CANNON_CHAIN_ID: u64 = 13370;
const ANVIL_URL: &str = "http://127.0.0.1:8545";
const SLEEP_DURATION: u64 = 30;

#[derive(Clone, Parser)]
#[command(name = "cartesi_prt_args")]
#[command(about = "Arguments of Cartesi PRT")]
pub struct PRTArgs {
    /// addresss of application
    #[arg(long, env)]
    pub app_address: Address,

    /// path to machine template image
    #[arg(long, env)]
    pub machine_path: PathBuf,

    /// blockchain gateway endpoint url
    #[arg(long, env, default_value = ANVIL_URL)]
    pub web3_rpc_url: Url,

    /// blockchain chain id
    #[arg(long, env, default_value_t = CANNON_CHAIN_ID)]
    pub web3_chain_id: u64,

    #[clap(subcommand)]
    pub signer: SignerArgs,

    /// polling sleep interval
    #[arg(long, env, default_value_t = SLEEP_DURATION)]
    pub sleep_duration_seconds: u64,

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
    /// private‐key signer
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
pub struct PRTConfig {
    // App
    pub address_book: AddressBook,
    pub machine_path: PathBuf,

    // Provider
    pub chain_id: NamedChain,
    pub ethereum_gateway: Url,
    pub signer_address: Address,

    // State
    pub state_dir: PathBuf,

    // Misc
    pub sleep_duration: Duration,
    pub long_block_range_error_codes: Vec<String>,

    // private
    signer: SignerArgs,
}

impl fmt::Display for PRTConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.address_book)?;
        writeln!(f, "Machine path: {}", self.machine_path.display())?;
        writeln!(f, "Signer address: {}", self.signer_address)?;
        writeln!(f, "Chain Id: {} ({})", self.chain_id, self.chain_id as u64)?;
        writeln!(f, "Ethereum gateway: <redacted>")?;
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

impl PRTConfig {
    pub fn setup() -> (Self, PersistentStateAccess) {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("`PRTConfig::setup` runtime build failure");
        rt.block_on(async move { Self::_setup().await })
    }

    pub fn state_access(&self) -> Result<PersistentStateAccess, StateAccessError> {
        PersistentStateAccess::new(&self.state_dir)
    }

    pub async fn provider(&self) -> DynProvider {
        create_provider(&self.ethereum_gateway, self.chain_id, &self.signer)
            .await
            .1
    }

    async fn _setup() -> (Self, PersistentStateAccess) {
        let args = PRTArgs::parse();

        let chain_id = args
            .web3_chain_id
            .try_into()
            .expect("fail to convert chain id");

        let (signer_address, provider) =
            create_provider(&args.web3_rpc_url, chain_id, &args.signer).await;
        let address_book = AddressBook::new(args.app_address, &provider).await;

        let mut state_manager = PersistentStateAccess::migrate(
            &args.state_dir,
            &args.machine_path,
            address_book.genesis_block_number,
        )
        .expect("could not create `state_manager`");

        let mut machine = state_manager
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
                state_dir: state_manager.state_dir().to_owned(),
                machine_path: args.machine_path,
                chain_id,
                signer_address,
                ethereum_gateway: args.web3_rpc_url,
                sleep_duration: Duration::from_secs(args.sleep_duration_seconds),
                signer: args.signer,
                long_block_range_error_codes: args.long_block_range_error_codes,
            },
            state_manager,
        )
    }
}
