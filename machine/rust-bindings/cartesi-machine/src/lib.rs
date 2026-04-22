// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

#![doc = include_str!("../README.md")]

pub mod config;
pub mod constants;
pub mod error;
pub mod machine;
pub mod types;

pub use machine::Machine;

// Reexport inner cartesi-machine-sys
pub use cartesi_machine_sys;

/// Emulator semantic version these bindings were written against, encoded per
/// the convention from `machine-c-api.h`:
/// `(major * 1000000) + (minor * 1000) + patch`.
///
/// The `test_emulator_version_pin` test asserts at build time that the linked
/// `libcartesi` reports this exact version. Bumping the emulator requires
/// bumping this constant and re-running the config round-trip tests — any
/// schema drift will surface there.
pub const EXPECTED_EMULATOR_VERSION: u64 = 20_000; // 0.20.0

/// Formats an emulator version u64 (as returned by `cm_get_version`) as
/// `"major.minor.patch"`.
pub fn format_emulator_version(v: u64) -> String {
    let major = v / 1_000_000;
    let minor = (v / 1_000) % 1_000;
    let patch = v % 1_000;
    format!("{major}.{minor}.{patch}")
}
