//! Module for communication with the Cartesi machine using RPC and construction of computation 
//! hashes.
 
#[doc(hidden)]
pub mod constants;

pub mod rpc;
pub use rpc::*;

mod commitment;
pub use commitment::*;

mod commitment_builder;
pub use commitment_builder::*;
