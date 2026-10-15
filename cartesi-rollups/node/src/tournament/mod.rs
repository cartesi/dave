//! Tournament integration boundary: an event-derived dispute tree, narrow
//! pinned point reads, wire-independent domain values, and the arena request
//! builders the Hero executor hands to the transaction lane.

pub mod dispute;
pub mod domain;
pub mod observer;
pub use domain::MatchID;

mod reader;
pub use reader::*;

pub mod sender;
