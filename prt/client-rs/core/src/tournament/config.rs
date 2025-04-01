//! Module for configuration of an Arena.
use clap::{Args, Parser};

const ANVIL_CHAIN_ID: u64 = 31337;
const ANVIL_URL: &str = "http://127.0.0.1:8545";
const ANVIL_KEY_1: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

#[derive(Debug, Clone, Parser)]
#[command(name = "blockchain_config")]
#[command(about = "Configuration for Blockchain Access")]
pub struct BlockchainConfig {
    /// url to blockchain endpoint
    #[arg(long, env, default_value = ANVIL_URL)]
    pub web3_rpc_url: String,
    /// chain id of the blockchain
    #[arg(long, env, default_value_t = ANVIL_CHAIN_ID)]
    pub web3_chain_id: u64,
    /// private key of player's wallet
    #[arg(
        long,
        env,
        default_value = ANVIL_KEY_1
    )]
    pub web3_private_key: String,
    #[command(flatten)]
    pub aws_config: AWSConfig,
}

#[derive(Args, Debug, Clone)]
#[group()]
pub struct AWSConfig {
    /// aws kms key id
    #[arg(long, env)]
    pub aws_kms_key_id: Option<String>,
    /// aws endpoint url
    #[arg(long, env, default_value = "http://localhost:4566")]
    pub aws_endpoint_url: String,
    /// aws region
    #[arg(long, env, default_value = "us-east-1")]
    pub aws_region: String,
}
