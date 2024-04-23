//! Module for configuration of an Arena.

#[derive(Debug, Clone)]
pub struct ArenaConfig {
    pub web3_rpc_url: String,
    pub web3_chain_id: u64,
    pub web3_private_key: String,
}
