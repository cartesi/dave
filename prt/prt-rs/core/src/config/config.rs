use crate::arena::ArenaConfig;
use clap::Parser;
use ethers::types::Address;

const ANVIL_ROOT_TOURNAMENT: &str = "0xcafac3dd18ac6c6e92c921884f9e4176737c052c";

#[derive(Debug, Clone, Parser)]
#[command(name = "cartesi_compute_config")]
#[command(about = "Configuration for Cartesi Compute")]
pub struct ComputeConfig {
    #[command(flatten)]
    pub arena_config: ArenaConfig,

    /// path to machine config
    #[arg(long, env)]
    pub machine_path: String,
    /// Address of root tournament
    #[arg(long, env, default_value = ANVIL_ROOT_TOURNAMENT)]
    pub root_tournament: Address,
}
