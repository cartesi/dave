//! Module for communication with the Cartesi machine using RPC and construction of computation
//! hashes.

#[doc(hidden)]
pub mod constants;

pub mod instance;
pub use instance::*;

mod commitment;
pub use commitment::*;

mod commitment_builder;
pub use commitment_builder::*;
