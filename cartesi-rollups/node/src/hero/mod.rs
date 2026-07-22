//! The honest validator's dispute actor.
//!
//! One accepted chain observation is projected into the local semantic path,
//! planned without provider or machine access, fulfilled into one owned arena
//! action, and dispatched once. Cleanup planning remains actor-neutral and is
//! considered only when the Hero has no action.

pub mod action;
mod actor;
pub mod context;
pub mod error;
pub mod gc_planner;
pub mod planner;

pub use actor::{Hero, HeroTick, TournamentResult};
