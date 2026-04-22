// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Rust mirror of `cartesi::machine_runtime_config` from the v0.20 cartesi-machine
//! C++ API. Follows the same invariants as `config::machine`:
//!
//! 1. Every struct carries `#[serde(deny_unknown_fields)]` to surface future
//!    schema additions as explicit deserialization failures.
//! 2. No speculative `#[serde(default)]` on fields the C++ `to_json` emits
//!    unconditionally (all of them, here).
//! 3. A round-trip test (`test_runtime_config_schema_stability`) pins the
//!    v0.20 shape so silent drift is impossible.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Console configuration
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::console_output_destination`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConsoleOutputDestination {
    ToNull,
    ToStdout,
    ToStderr,
    ToFd,
    ToFile,
    ToBuffer,
}

impl Default for ConsoleOutputDestination {
    /// Matches the C++ in-struct initializer (`console_output_destination::to_stdout`).
    fn default() -> Self {
        Self::ToStdout
    }
}

/// Mirror of C++ `cartesi::console_flush_mode`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConsoleFlushMode {
    WhenFull,
    EveryChar,
    EveryLine,
}

impl Default for ConsoleFlushMode {
    /// Matches the C++ in-struct initializer (`console_flush_mode::every_line`).
    fn default() -> Self {
        Self::EveryLine
    }
}

/// Mirror of C++ `cartesi::console_input_source`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConsoleInputSource {
    FromNull,
    FromStdin,
    FromFd,
    FromFile,
    FromBuffer,
}

impl Default for ConsoleInputSource {
    /// Matches the C++ in-struct initializer (`console_input_source::from_null`).
    fn default() -> Self {
        Self::FromNull
    }
}

/// Mirror of C++ `cartesi::console_runtime_config`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ConsoleRuntimeConfig {
    pub output_destination: ConsoleOutputDestination,
    pub output_flush_mode: ConsoleFlushMode,
    pub output_buffer_size: u64,
    pub output_fd: i32,
    pub output_filename: String,

    pub input_source: ConsoleInputSource,
    pub input_buffer_size: u64,
    pub input_fd: i32,
    pub input_filename: String,

    pub tty_cols: u16,
    pub tty_rows: u16,
}

impl Default for ConsoleRuntimeConfig {
    /// Matches the in-struct initializers in `machine-runtime-config.h` and the
    /// `os::TTY_DEFAULT_*` constants from v0.20 (`os.h`: cols=80, rows=25).
    fn default() -> Self {
        Self {
            output_destination: ConsoleOutputDestination::default(),
            output_flush_mode: ConsoleFlushMode::default(),
            output_buffer_size: 4096,
            output_fd: -1,
            output_filename: String::new(),

            input_source: ConsoleInputSource::default(),
            input_buffer_size: 4096,
            input_fd: -1,
            input_filename: String::new(),

            tty_cols: 80,
            tty_rows: 25,
        }
    }
}

// ---------------------------------------------------------------------------
// Concurrency and top-level runtime configuration
// ---------------------------------------------------------------------------

/// Mirror of C++ `cartesi::concurrency_runtime_config`. Note: v0.19's
/// `update_merkle_tree` field was renamed to `update_hash_tree` in v0.20.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ConcurrencyRuntimeConfig {
    pub update_hash_tree: u64,
}

/// Mirror of C++ `cartesi::machine_runtime_config`.
///
/// The v0.19 binding had top-level `htif`, `skip_root_hash_check`, and
/// `skip_root_hash_store` fields. None of those exist on the v0.20
/// `machine_runtime_config`. The equivalent of v0.19's
/// `htif.no_console_putchar` is now `console.output_destination = ToNull`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RuntimeConfig {
    pub console: ConsoleRuntimeConfig,
    pub concurrency: ConcurrencyRuntimeConfig,
    pub skip_version_check: bool,
    pub soft_yield: bool,
    pub no_reserve: bool,
}

impl RuntimeConfig {
    /// Convenience for "run the machine without touching the host console" —
    /// replaces the v0.19 pattern of setting `htif.no_console_putchar = true`.
    pub fn quiet_console() -> Self {
        Self {
            console: ConsoleRuntimeConfig {
                output_destination: ConsoleOutputDestination::ToNull,
                input_source: ConsoleInputSource::FromNull,
                ..ConsoleRuntimeConfig::default()
            },
            ..Self::default()
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Static schema-completeness test: pins the v0.20 `machine_runtime_config`
    /// JSON shape directly against `RuntimeConfig`, so drift in either
    /// direction surfaces as a test failure.
    ///
    /// The JSON below is constructed from `src/json-util.cpp::to_json
    /// (machine_runtime_config)` and the default values in
    /// `machine-runtime-config.h` / `os.h` (TTY_DEFAULT_COLS=80,
    /// TTY_DEFAULT_ROWS=25).
    #[test]
    fn test_runtime_config_schema_stability() {
        let v020_json = serde_json::json!({
            "console": {
                "output_destination": "to_stdout",
                "output_flush_mode": "every_line",
                "output_buffer_size": 4096u64,
                "output_fd": -1,
                "output_filename": "",
                "input_source": "from_null",
                "input_buffer_size": 4096u64,
                "input_fd": -1,
                "input_filename": "",
                "tty_cols": 80,
                "tty_rows": 25,
            },
            "concurrency": { "update_hash_tree": 0u64 },
            "skip_version_check": false,
            "soft_yield": false,
            "no_reserve": false,
        });

        let typed: RuntimeConfig = serde_json::from_value(v020_json.clone())
            .expect("v0.20 runtime JSON should parse into RuntimeConfig");
        let reserialized = serde_json::to_value(&typed).expect("re-serialization failed");

        assert_eq!(
            v020_json, reserialized,
            "RuntimeConfig round-trip lost or added data. Schema drift vs the C++ side."
        );
    }

    #[test]
    fn test_runtime_config_default_round_trips() {
        let cfg = RuntimeConfig::default();
        let json = serde_json::to_value(&cfg).expect("serialization should succeed");
        let back: RuntimeConfig =
            serde_json::from_value(json).expect("deserialization should succeed");
        assert_eq!(cfg, back);
    }

    #[test]
    fn test_runtime_config_quiet_console() {
        let cfg = RuntimeConfig::quiet_console();
        assert_eq!(
            cfg.console.output_destination,
            ConsoleOutputDestination::ToNull
        );
        assert_eq!(cfg.console.input_source, ConsoleInputSource::FromNull);
    }

    #[test]
    fn test_runtime_config_unknown_field_rejected() {
        let json = serde_json::json!({
            "console": {
                "output_destination": "to_stdout",
                "output_flush_mode": "every_line",
                "output_buffer_size": 4096u64,
                "output_fd": -1,
                "output_filename": "",
                "input_source": "from_null",
                "input_buffer_size": 4096u64,
                "input_fd": -1,
                "input_filename": "",
                "tty_cols": 80,
                "tty_rows": 25,
            },
            "concurrency": { "update_hash_tree": 0u64 },
            "skip_version_check": false,
            "soft_yield": false,
            "no_reserve": false,
            "something_new": true,
        });
        assert!(
            serde_json::from_value::<RuntimeConfig>(json).is_err(),
            "deny_unknown_fields must reject previously-unseen top-level keys"
        );
    }
}
