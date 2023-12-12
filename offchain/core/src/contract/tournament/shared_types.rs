///`ClockState(uint64,uint64)`
#[derive(
    Clone,
    ::ethers::contract::EthAbiType,
    ::ethers::contract::EthAbiCodec,
    serde::Serialize,
    serde::Deserialize,
    Default,
    Debug,
    PartialEq,
    Eq,
    Hash,
)]
pub struct ClockState {
    pub allowance: u64,
    pub start_instant: u64,
}
///`Id(bytes32,bytes32)`
#[derive(
    Clone,
    ::ethers::contract::EthAbiType,
    ::ethers::contract::EthAbiCodec,
    serde::Serialize,
    serde::Deserialize,
    Default,
    Debug,
    PartialEq,
    Eq,
    Hash,
)]
pub struct Id {
    pub commitment_one: [u8; 32],
    pub commitment_two: [u8; 32],
}
///`MatchState(bytes32,bytes32,bytes32,uint256,uint64,uint64)`
#[derive(
    Clone,
    ::ethers::contract::EthAbiType,
    ::ethers::contract::EthAbiCodec,
    serde::Serialize,
    serde::Deserialize,
    Default,
    Debug,
    PartialEq,
    Eq,
    Hash,
)]
pub struct MatchState {
    pub other_parent: [u8; 32],
    pub left_node: [u8; 32],
    pub right_node: [u8; 32],
    pub running_leaf_position: ::ethers::core::types::U256,
    pub current_height: u64,
    pub level: u64,
}
