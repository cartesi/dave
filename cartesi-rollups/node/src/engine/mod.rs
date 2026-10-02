// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The dispute engine core. The Hero uses the quartet cache in the
//! node database as restartable dispute state.
//!
//! An epoch's computation is a ruler of state transitions indexed by
//! meta-cycle. This module addresses merkle nodes over that ruler by
//! quartet (epoch, log2_stride, height, shift), computes them through a
//! geometry engine that is generic over the state-transition function,
//! and caches them in SQLite. The ruler semantics live in
//! docs/computation-hash.md.
//!
//! Layering, innermost first:
//! - [`stf::Stf`]: the machine operations the ruler needs. Production
//!   uses the Cartesi machine; unit tests use a small scripted machine.
//! - [`ruler::Ruler`]: the geometry engine. Owns every meta-cycle
//!   convention (window boundaries, fused feed transition, big-cycle
//!   closing ureset, fixed-point padding). Written once, exercised by
//!   the toy, reused by the production machine.
//! - [`cache::get_or_compute`]: quartet computation and fanout over
//!   the node's storage.
//! - [`dispute::DisputeSource`]: the hero-facing face. Tournament
//!   coordinates map onto quartets ([`dispute::LevelCoords`]), level 0
//!   is served from the persisted regime-1 material (window-root rows
//!   plus lazy interior folds). It supplies Merkle proofs by sibling
//!   descent and transition witnesses checked against pre/post states.
//!
//! The spec tests compare stepping and sampling against a literal
//! leaf sequence. Cache and proof tests also use trees built from those
//! runs; real-machine differentials live in `tests/engine_machine.rs`.

pub mod cache;
pub mod config;
pub mod constants;
pub mod dispute;
pub mod geometry;
pub mod machine_stf;
pub mod ruler;
pub mod stf;
pub mod structure;

#[cfg(test)]
pub(crate) mod spec;
#[cfg(test)]
pub(crate) mod toy;

pub use config::EngineConfig;
#[cfg(test)]
pub(crate) use dispute::Tail;
pub use dispute::{DisputeSource, LevelCoords, fold_runs};
pub use geometry::{Level, TournamentGeometry};
pub use machine_stf::{Collector, MachineStf, Positioner};
pub use ruler::{Hashing, Ruler, RulerFactory, Run};
pub use stf::Stf;
pub use structure::{InputBoundary, Position, Quartet, Structure};
