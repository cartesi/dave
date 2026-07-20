// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The dispute engine core. As of increment C it is what the Hero
//! runs on: the quartet cache in the node database is the
//! restartable dispute state.
//!
//! An epoch's computation is a ruler of state transitions indexed by
//! meta-cycle. This module addresses merkle nodes over that ruler by
//! quartet (epoch, log2_stride, height, shift), computes them through a
//! geometry engine that is generic over the state-transition function,
//! and caches them in SQLite. The design and its rationale live in
//! docs/plans/sling-design.md; the ruler semantics in
//! docs/computation-hash.md.
//!
//! Layering, innermost first:
//! - [`stf::Stf`]: machine verbs (ustep, ureset, feed, revert). Two
//!   implementations: the toy (here, for spec tests) and the Cartesi
//!   machine (increment B).
//! - [`ruler::Ruler`]: the geometry engine. Owns every meta-cycle
//!   convention (window boundaries, fused feed transition, big-cycle
//!   closing ureset, fixed-point padding). Written once, exercised by
//!   the toy, reused by the production machine.
//! - [`cache::NodeCache`] and [`cache::get_or_compute`]: the quartet
//!   cache with its amortizing fanout.
//! - [`dispute::DisputeSource`]: the hero-facing face. Tournament
//!   coordinates map onto quartets ([`dispute::LevelCoords`]), level 0
//!   is served from the persisted regime-1 material (window-root rows
//!   plus lazy interior folds), and proofs are sibling descents.
//!
//! The spec tests in `spec.rs` compare all of this against an
//! independent brute-force oracle; they are the executable form of the
//! leaf-convention specification.

pub mod cache;
pub mod config;
pub mod constants;
pub mod dispute;
pub mod machine_stf;
pub mod ruler;
pub mod stf;
pub mod structure;

#[cfg(test)]
pub(crate) mod spec;

pub use config::EngineConfig;
pub use dispute::{DisputeSource, LevelCoords, fold_runs};
pub use machine_stf::{MachineStf, Positioner};
pub use ruler::{Ruler, RulerFactory, Run, ToyFactory};
pub use stf::{ProvingStf, Stf, ToyInput, ToyOutcome, ToyStf};
pub use structure::{InputBoundary, Position, Quartet, Structure};
