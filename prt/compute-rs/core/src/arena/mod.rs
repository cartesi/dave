//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments; and the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

mod arena;
pub use arena::*;

mod config;
pub use config::*;

mod reader;
pub use reader::*;

mod sender;
pub use sender::*;
