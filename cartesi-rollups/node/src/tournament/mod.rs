//! This module defines the struct [StateReader] that is responsible for the reading the states
//! of tournaments; and the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

mod types;
pub use types::*;

mod reader;
pub use reader::*;

mod sender;
pub use sender::*;

pub mod fold;
