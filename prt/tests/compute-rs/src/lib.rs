use alloy::sol_types::private::Address;
use cartesi_prt_core::arena::BlockchainConfig;
use clap::Parser;

const ANVIL_ROOT_TOURNAMENT: &str = "0xa16E02E87b7454126E5E10d957A927A7F5B5d2be";

#[derive(Debug, Clone, Parser)]
#[command(name = "cartesi_compute_config")]
#[command(about = "Configuration for Cartesi Compute")]
pub struct ComputeConfig {
    #[command(flatten)]
    pub blockchain_config: BlockchainConfig,
    /// path to machine config
    #[arg(long, env)]
    pub machine_path: String,
    /// Address of root tournament
    #[arg(long, env, default_value = ANVIL_ROOT_TOURNAMENT)]
    pub root_tournament: Address,
}
