//! This module defines the trait [Arena] that is responsible for the creation and management of 
//! tournaments and one implementation of this trait using the Ethereum blockchain [EthersArena].

mod config;
pub use config::*;

mod arena;
pub use arena::*;

mod ethers_arena;
pub use ethers_arena::*;

#[doc(hidden)]
mod util;
use util::*;
