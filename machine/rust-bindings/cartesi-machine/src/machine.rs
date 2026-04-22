// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::{
    ffi::{CStr, CString, c_char},
    path::Path,
    ptr,
};

use crate::{
    config::{self, machine::MachineConfig, runtime::RuntimeConfig},
    constants,
    error::{MachineError, MachineResult as Result},
    types::{
        BreakReason, Hash, LogType, Register, UArchBreakReason,
        access_proof::AccessLog,
        cmio::{CmioRequest, CmioResponseReason},
        memory_proof::Proof,
        memory_range::MemoryRangeDescriptions,
    },
};

/// Machine instance handle.
///
/// Owns a `*mut cm_machine` and frees it on `Drop` via `cm_delete`. The raw
/// pointer is kept private — exposing it would let callers clone it and cause
/// a double-free when both `Machine`s get dropped.
///
/// `Machine` is intentionally `!Send + !Sync` (the default, given the raw
/// pointer field). Do not add `unsafe impl Send for Machine` without auditing
/// `cm_get_last_error_message`: the C library threads error messages through
/// thread-local (or global) state with no machine-instance argument, so two
/// `Machine`s running on different threads could scramble each other's
/// `MachineError::message` fields.
pub struct Machine {
    machine: *mut cartesi_machine_sys::cm_machine,
}

impl Drop for Machine {
    fn drop(&mut self) {
        if !self.machine.is_null() {
            unsafe {
                cartesi_machine_sys::cm_delete(self.machine);
            }
        }
    }
}

macro_rules! check_err {
    ($err_code:expr) => {
        if $err_code != constants::error_code::OK {
            Err(Machine::last_error($err_code))
        } else {
            Ok(())
        }
    };
}

/// Both `serde_json::to_string` and `CString::new` below panic on failure
/// *by design*. They can only fail on:
/// - A Rust config type holding non-serializable state. Our types are plain
///   POD with derived `Serialize`, so this is statically impossible.
/// - A JSON string containing an interior NUL byte. `serde_json` escapes NUL
///   as `\u0000`, so the output is guaranteed NUL-free.
///
/// If either panic ever fires, it indicates a bug in this crate or in
/// `serde_json` — there is no recovery, and a panic with a backtrace is more
/// debuggable than a bubbled-up `Result` that crashes at the caller anyway.
macro_rules! serialize_to_json {
    ($src:expr) => {
        CString::new(serde_json::to_string($src).expect("failed serializing to json"))
            .expect("CString::new failed")
    };
}

/// Panics on malformed JSON from the C library. This means either a bug in
/// `libcartesi` or a mismatch between the Rust struct shape and the
/// emulator's JSON schema — the round-trip tests in `config/machine.rs` and
/// `config/runtime.rs` are expected to catch the latter before production.
/// A `Result` return here would force every call site to propagate an error
/// variant for a condition with no meaningful recovery path; panicking gives
/// a clearer stacktrace.
macro_rules! parse_json_from_cstring {
    ($src:expr) => {{
        let cstr = unsafe { CStr::from_ptr($src) };
        let json = cstr.to_string_lossy();
        serde_json::from_str(&json).expect("could not parse json")
    }};
}

impl Machine {
    // -----------------------------------------------------------------------------
    // API functions
    // -----------------------------------------------------------------------------

    /// Returns the emulator semantic version of the linked `libcartesi`, as
    /// returned by `cm_get_version`. Encoded as
    /// `(major * 1000000) + (minor * 1000) + patch`.
    pub fn version() -> u64 {
        unsafe { cartesi_machine_sys::cm_get_version() }
    }

    /// Returns the default machine config as parsed by serde.
    pub fn default_config() -> Result<MachineConfig> {
        let raw = Self::default_config_raw_json()?;
        Ok(serde_json::from_str(&raw)
            .expect("cm_get_default_config returned JSON that does not match MachineConfig"))
    }

    /// Returns the raw JSON string produced by `cm_get_default_config`,
    /// without deserializing into a typed struct. Primarily used by the
    /// round-trip schema test.
    pub fn default_config_raw_json() -> Result<String> {
        let mut config_ptr: *const c_char = ptr::null();
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_default_config(ptr::null(), &mut config_ptr) };
        check_err!(err_code)?;

        let cstr = unsafe { CStr::from_ptr(config_ptr) };
        Ok(cstr.to_string_lossy().into_owned())
    }

    /// Gets the address of any x, f, or control state register.
    pub fn reg_address(reg: Register) -> Result<u64> {
        let mut val: u64 = 0;
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_reg_address(ptr::null(), reg, &mut val) };
        check_err!(err_code)?;
        Ok(val)
    }

    // -----------------------------------------------------------------------------
    // Machine API functions
    // -----------------------------------------------------------------------------

    /// Creates a new machine instance from configuration.
    pub fn create(config: &MachineConfig, runtime_config: &RuntimeConfig) -> Result<Self> {
        let config_json = serialize_to_json!(&config);
        let runtime_config_json = serialize_to_json!(&runtime_config);
        let dir_cstr = CString::new("").unwrap(); // in-memory machine

        let mut machine: *mut cartesi_machine_sys::cm_machine = ptr::null_mut();
        let err_code = unsafe {
            cartesi_machine_sys::cm_create_new(
                config_json.as_ptr(),
                runtime_config_json.as_ptr(),
                dir_cstr.as_ptr(),
                &mut machine,
            )
        };
        check_err!(err_code)?;

        Ok(Self { machine })
    }

    /// Loads a new machine instance from a previously stored directory.
    pub fn load(dir: &Path, runtime_config: &RuntimeConfig) -> Result<Self> {
        let dir_cstr = path_to_cstring(dir)?;
        let runtime_config_json = serialize_to_json!(&runtime_config);

        let mut machine: *mut cartesi_machine_sys::cm_machine = ptr::null_mut();
        let err_code = unsafe {
            cartesi_machine_sys::cm_load_new(
                dir_cstr.as_ptr(),
                runtime_config_json.as_ptr(),
                cartesi_machine_sys::CM_SHARING_CONFIG,
                &mut machine,
            )
        };
        check_err!(err_code)?;

        Ok(Self { machine })
    }

    /// Stores a machine instance to a directory, serializing its entire state.
    /// Uses CM_SHARING_ALL so that the current machine state is written for all
    /// address ranges (required when storing in-memory machines that have no
    /// backing files).
    pub fn store(&mut self, dir: &Path) -> Result<()> {
        let dir_cstr = path_to_cstring(dir)?;
        let err_code = unsafe {
            cartesi_machine_sys::cm_store(
                self.machine,
                dir_cstr.as_ptr(),
                cartesi_machine_sys::CM_SHARING_ALL,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Changes the machine runtime configuration.
    pub fn set_runtime_config(&mut self, runtime_config: &RuntimeConfig) -> Result<()> {
        let runtime_config_json = serialize_to_json!(&runtime_config);
        let err_code = unsafe {
            cartesi_machine_sys::cm_set_runtime_config(self.machine, runtime_config_json.as_ptr())
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Gets the machine runtime config as parsed by serde.
    pub fn runtime_config(&mut self) -> Result<RuntimeConfig> {
        let raw = self.runtime_config_raw_json()?;
        Ok(serde_json::from_str(&raw)
            .expect("cm_get_runtime_config returned JSON that does not match RuntimeConfig"))
    }

    /// Returns the raw JSON string produced by `cm_get_runtime_config`. Used
    /// by the round-trip schema test.
    pub fn runtime_config_raw_json(&mut self) -> Result<String> {
        let mut rc_ptr: *const c_char = ptr::null();
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_runtime_config(self.machine, &mut rc_ptr) };
        check_err!(err_code)?;

        let cstr = unsafe { CStr::from_ptr(rc_ptr) };
        Ok(cstr.to_string_lossy().into_owned())
    }

    /// Replaces a memory range.
    ///
    /// Two intentional simplifications vs. the full JSON schema the C API
    /// accepts:
    ///
    /// - `read_only` is hardcoded to `false`. The C++
    ///   `machine_address_ranges::replace` explicitly rejects both a
    ///   read-only existing range and a replacement config with
    ///   `read_only: true` (see `machine-address-ranges.cpp`), so exposing a
    ///   `read_only` toggle here would always error. If that ever changes,
    ///   widen this API then.
    /// - When `image_path` is `None`, `data_filename` is serialized as the
    ///   empty string. The C++ side treats empty `data_filename` as "no
    ///   backing store" (`backing_store_config::newly_created()` returns
    ///   true when `create || data_filename.empty()`), which is the same
    ///   semantics as the old API's `NULL` pointer: the range is
    ///   zero-filled in-memory.
    pub fn replace_memory_range(
        &mut self,
        start: u64,
        length: u64,
        shared: bool,
        image_path: Option<&Path>,
    ) -> Result<()> {
        let range_config = serde_json::json!({
            "start": start,
            "length": length,
            "read_only": false,
            "backing_store": {
                "data_filename": image_path.map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
                "shared": shared
            }
        });

        let range_json = serialize_to_json!(&range_config);

        let err_code = unsafe {
            cartesi_machine_sys::cm_replace_memory_range(self.machine, range_json.as_ptr())
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Returns the machine config used to initialize the machine.
    pub fn initial_config(&mut self) -> Result<config::machine::MachineConfig> {
        let mut config_ptr: *const c_char = ptr::null();
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_initial_config(self.machine, &mut config_ptr) };
        check_err!(err_code)?;

        let config = parse_json_from_cstring!(config_ptr);

        Ok(config)
    }

    /// Returns a list with all memory ranges in the machine.
    pub fn memory_ranges(&mut self) -> Result<MemoryRangeDescriptions> {
        let mut ranges_ptr: *const c_char = ptr::null();
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_address_ranges(self.machine, &mut ranges_ptr) };
        check_err!(err_code)?;

        let ranges = parse_json_from_cstring!(ranges_ptr);

        Ok(ranges)
    }

    /// Obtains the root hash of the Merkle tree.
    pub fn root_hash(&mut self) -> Result<Hash> {
        let mut hash = Hash::default();
        let err_code = unsafe { cartesi_machine_sys::cm_get_root_hash(self.machine, &mut hash) };
        check_err!(err_code)?;

        Ok(hash)
    }

    /// Obtains the proof for a node in the machine state Merkle tree.
    pub fn proof(
        &mut self,
        address: u64,
        log2_target_size: u32,
        log2_root_size: u32,
    ) -> Result<Proof> {
        let mut proof_ptr: *const c_char = ptr::null();
        let err_code = unsafe {
            cartesi_machine_sys::cm_get_proof(
                self.machine,
                address,
                log2_target_size as ::std::os::raw::c_int,
                log2_root_size as ::std::os::raw::c_int,
                &mut proof_ptr,
            )
        };
        check_err!(err_code)?;

        let proof = parse_json_from_cstring!(proof_ptr);

        Ok(proof)
    }

    // ------------------------------------
    // Reading and writing
    // ------------------------------------

    /// Reads the value of a word in the machine state, by its physical address.
    pub fn read_word(&mut self, address: u64) -> Result<u64> {
        let mut value: u64 = 0;
        let err_code =
            unsafe { cartesi_machine_sys::cm_read_word(self.machine, address, &mut value) };
        check_err!(err_code)?;

        Ok(value)
    }

    /// Reads the value of a register.
    pub fn read_reg(&mut self, reg: Register) -> Result<u64> {
        let mut value: u64 = 0;
        let err_code = unsafe { cartesi_machine_sys::cm_read_reg(self.machine, reg, &mut value) };
        check_err!(err_code)?;

        Ok(value)
    }

    /// Writes the value of a register.
    pub fn write_reg(&mut self, reg: Register, val: u64) -> Result<()> {
        let err_code = unsafe { cartesi_machine_sys::cm_write_reg(self.machine, reg, val) };
        check_err!(err_code)?;

        Ok(())
    }

    /// Reads a chunk of data from a machine memory range, by its physical address.
    pub fn read_memory(&mut self, address: u64, size: u64) -> Result<Vec<u8>> {
        let mut buffer = vec![0u8; u64_to_usize(size)?];
        let err_code = unsafe {
            cartesi_machine_sys::cm_read_memory(self.machine, address, buffer.as_mut_ptr(), size)
        };
        check_err!(err_code)?;

        Ok(buffer)
    }

    /// Writes a chunk of data to a machine memory range, by its physical address.
    pub fn write_memory(&mut self, address: u64, data: &[u8]) -> Result<()> {
        let err_code = unsafe {
            cartesi_machine_sys::cm_write_memory(
                self.machine,
                address,
                data.as_ptr(),
                data.len() as u64,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Reads a chunk of data from a machine memory range, by its virtual memory.
    pub fn read_virtual_memory(&mut self, address: u64, size: u64) -> Result<Vec<u8>> {
        let mut buffer = vec![0u8; u64_to_usize(size)?];
        let err_code = unsafe {
            cartesi_machine_sys::cm_read_virtual_memory(
                self.machine,
                address,
                buffer.as_mut_ptr(),
                size,
            )
        };
        check_err!(err_code)?;

        Ok(buffer)
    }

    /// Writes a chunk of data to a machine memory range, by its virtual address.
    pub fn write_virtual_memory(&mut self, address: u64, data: &[u8]) -> Result<()> {
        let err_code = unsafe {
            cartesi_machine_sys::cm_write_virtual_memory(
                self.machine,
                address,
                data.as_ptr(),
                data.len() as u64,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Translates a virtual memory address to its corresponding physical memory address.
    pub fn translate_virtual_address(&mut self, virtual_address: u64) -> Result<u64> {
        let mut paddr: u64 = 0;
        let err_code = unsafe {
            cartesi_machine_sys::cm_translate_virtual_address(
                self.machine,
                virtual_address,
                &mut paddr,
            )
        };
        check_err!(err_code)?;

        Ok(paddr)
    }

    // ------------------------------------
    // Running
    // ------------------------------------

    /// Returns machine CM_REG_MCYCLE
    pub fn mcycle(&mut self) -> Result<u64> {
        self.read_reg(cartesi_machine_sys::CM_REG_MCYCLE)
    }

    /// Returns machine CM_REG_IFLAGS_Y
    pub fn iflags_y(&mut self) -> Result<bool> {
        Ok(self.read_reg(cartesi_machine_sys::CM_REG_IFLAGS_Y)? != 0)
    }

    /// Returns machine CM_REG_IFLAGS_H
    pub fn iflags_h(&mut self) -> Result<bool> {
        Ok(self.read_reg(cartesi_machine_sys::CM_REG_IFLAGS_H)? != 0)
    }

    /// Returns machine CM_REG_UARCH_CYCLE
    pub fn ucycle(&mut self) -> Result<u64> {
        self.read_reg(cartesi_machine_sys::CM_REG_UARCH_CYCLE)
    }

    /// Returns machine CM_REG_UARCH_HALT_FLAG
    pub fn uarch_halt_flag(&mut self) -> Result<bool> {
        Ok(self.read_reg(cartesi_machine_sys::CM_REG_UARCH_HALT_FLAG)? != 0)
    }

    /// Runs the machine until CM_REG_MCYCLE reaches mcycle_end, machine yields, or halts.
    pub fn run(&mut self, mcycle_end: u64) -> Result<BreakReason> {
        let mut break_reason = BreakReason::default();
        let cm_error =
            unsafe { cartesi_machine_sys::cm_run(self.machine, mcycle_end, &mut break_reason) };
        check_err!(cm_error)?;

        Ok(break_reason)
    }

    /// Runs the machine microarchitecture until CM_REG_UARCH_CYCLE reaches uarch_cycle_end or it halts.
    pub fn run_uarch(&mut self, uarch_cycle_end: u64) -> Result<UArchBreakReason> {
        let mut break_reason = UArchBreakReason::default();
        let err_code = unsafe {
            cartesi_machine_sys::cm_run_uarch(self.machine, uarch_cycle_end, &mut break_reason)
        };
        check_err!(err_code)?;

        Ok(break_reason)
    }

    /// Resets the entire microarchitecture state to pristine values.
    pub fn reset_uarch(&mut self) -> Result<()> {
        let err_code = unsafe { cartesi_machine_sys::cm_reset_uarch(self.machine) };
        check_err!(err_code)?;

        Ok(())
    }

    /// Receives a cmio request.
    pub fn receive_cmio_request(&mut self) -> Result<CmioRequest> {
        let mut cmd: u8 = 0;
        let mut reason: u16 = 0;
        let mut length: u64 = 0;

        // First call with a NULL data pointer: the C API just writes the
        // required length into `length` and returns, without reading any
        // bytes. (See machine-c-api.h: "If NULL, length will still be set
        // without reading any data.")
        let err_code = unsafe {
            cartesi_machine_sys::cm_receive_cmio_request(
                self.machine,
                &mut cmd,
                &mut reason,
                ptr::null_mut(),
                &mut length,
            )
        };
        check_err!(err_code)?;

        // `length` is in-out per the C API contract ("Must be initialized to
        // the size of data buffer"). Sizing the buffer to exactly `length`
        // and then passing the same value back in makes the buffer-size
        // precondition and the required-length output coincide.
        let mut buffer = vec![0u8; u64_to_usize(length)?];

        let err_code = unsafe {
            cartesi_machine_sys::cm_receive_cmio_request(
                self.machine,
                &mut cmd,
                &mut reason,
                buffer.as_mut_ptr(),
                &mut length,
            )
        };
        check_err!(err_code)?;

        Ok(CmioRequest::new(cmd, reason, buffer))
    }

    /// Sends a cmio response.
    pub fn send_cmio_response(&mut self, reason: CmioResponseReason, data: &[u8]) -> Result<()> {
        let err_code = unsafe {
            cartesi_machine_sys::cm_send_cmio_response(
                self.machine,
                reason as u16,
                data.as_ptr(),
                data.len() as u64,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }

    // ------------------------------------
    // Logging
    // ------------------------------------

    /// Runs the machine for the given mcycle count and generates a log of accessed pages and proof data.
    pub fn log_step(&mut self, mcycle_count: u64, log_filename: &Path) -> Result<BreakReason> {
        let mut break_reason = BreakReason::default();
        let log_filename_c = path_to_cstring(log_filename)?;

        let err_code = unsafe {
            cartesi_machine_sys::cm_log_step(
                self.machine,
                mcycle_count,
                log_filename_c.as_ptr(),
                &mut break_reason,
            )
        };
        check_err!(err_code)?;

        Ok(break_reason)
    }

    /// Runs the machine in the microarchitecture for one micro cycle logging all accesses to the state.
    pub fn log_step_uarch(&mut self, log_type: LogType) -> Result<AccessLog> {
        let mut log_ptr: *const c_char = ptr::null();
        let err_code = unsafe {
            cartesi_machine_sys::cm_log_step_uarch(
                self.machine,
                log_type.to_bitflag(),
                &mut log_ptr,
            )
        };
        check_err!(err_code)?;

        let access_log = parse_json_from_cstring!(log_ptr);

        Ok(access_log)
    }

    /// Resets the entire microarchitecture state to pristine values logging all accesses to the state.
    pub fn log_reset_uarch(&mut self, log_type: LogType) -> Result<AccessLog> {
        let mut log_ptr: *const c_char = ptr::null();
        let err_code = unsafe {
            cartesi_machine_sys::cm_log_reset_uarch(
                self.machine,
                log_type.to_bitflag(),
                &mut log_ptr,
            )
        };
        check_err!(err_code)?;

        let access_log = parse_json_from_cstring!(log_ptr);

        Ok(access_log)
    }

    /// Sends a cmio response logging all accesses to the state.
    pub fn log_send_cmio_response(
        &mut self,
        reason: CmioResponseReason,
        data: &[u8],
        log_type: LogType,
    ) -> Result<AccessLog> {
        let mut log_ptr: *const c_char = ptr::null();
        let err_code = unsafe {
            cartesi_machine_sys::cm_log_send_cmio_response(
                self.machine,
                reason as u16,
                data.as_ptr(),
                data.len() as u64,
                log_type.to_bitflag(),
                &mut log_ptr,
            )
        };
        check_err!(err_code)?;

        let access_log = parse_json_from_cstring!(log_ptr);

        Ok(access_log)
    }

    // ------------------------------------
    // Verifying
    // ------------------------------------

    /// Checks the validity of a step log file.
    pub fn verify_step(
        root_hash_before: &Hash,
        log_filename: &Path,
        mcycle_count: u64,
        root_hash_after: &Hash,
    ) -> Result<BreakReason> {
        let log_filename_c = path_to_cstring(log_filename)?;

        let mut break_reason = BreakReason::default();
        let err_code = unsafe {
            cartesi_machine_sys::cm_verify_step(
                root_hash_before,
                log_filename_c.as_ptr(),
                mcycle_count,
                root_hash_after,
                &mut break_reason,
            )
        };
        check_err!(err_code)?;

        Ok(break_reason)
    }

    /// Checks the validity of a state transition produced by cm_log_step_uarch.
    pub fn verify_step_uarch(
        root_hash_before: &Hash,
        log: &AccessLog,
        root_hash_after: &Hash,
    ) -> Result<()> {
        let log_cstr = serialize_to_json!(&log);

        let err_code = unsafe {
            cartesi_machine_sys::cm_verify_step_uarch(
                // Optional `const cm_machine *m`; NULL means "local verification".
                // See machine-c-api.h. (cm_verify_step itself doesn't take this
                // argument — the asymmetry is intentional in the C API.)
                ptr::null(),
                root_hash_before,
                log_cstr.as_ptr(),
                root_hash_after,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Checks the validity of a state transition produced by cm_log_verify_reset_uarch.
    pub fn verify_reset_uarch(
        root_hash_before: &Hash,
        log: &AccessLog,
        root_hash_after: &Hash,
    ) -> Result<()> {
        let log_cstr = serialize_to_json!(&log);
        let err_code = unsafe {
            cartesi_machine_sys::cm_verify_reset_uarch(
                // Optional `const cm_machine *m`; NULL means "local verification".
                // See machine-c-api.h.
                ptr::null(),
                root_hash_before,
                log_cstr.as_ptr(),
                root_hash_after,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }

    /// Checks the validity of a state transition produced by cm_log_send_cmio_response.
    pub fn verify_send_cmio_response(
        reason: CmioResponseReason,
        data: &[u8],
        root_hash_before: &Hash,
        log: &AccessLog,
        root_hash_after: &Hash,
    ) -> Result<()> {
        let log_cstr = serialize_to_json!(&log);

        let err_code = unsafe {
            cartesi_machine_sys::cm_verify_send_cmio_response(
                // Optional `const cm_machine *m`; NULL means "local verification".
                // See machine-c-api.h.
                ptr::null(),
                reason as u16,
                data.as_ptr(),
                data.len() as u64,
                root_hash_before,
                log_cstr.as_ptr(),
                root_hash_after,
            )
        };
        check_err!(err_code)?;

        Ok(())
    }
}

impl Machine {
    fn last_error(code: i32) -> MachineError {
        assert!(code != constants::error_code::OK);

        let msg_p = unsafe { cartesi_machine_sys::cm_get_last_error_message() };
        let cstr = unsafe { std::ffi::CStr::from_ptr(msg_p) };
        let message = String::from_utf8_lossy(cstr.to_bytes()).to_string();

        MachineError { code, message }
    }
}

/// Converts a `u64` byte count (as used by the C API) to a Rust `usize`,
/// erroring out if the value exceeds what the platform can address. Only
/// matters on 32-bit targets — on 64-bit, `usize` and `u64` are the same
/// width and this is a no-op. Guards against silent truncation that would
/// result in an undersized buffer being passed to a C function expecting
/// `size` bytes of space.
fn u64_to_usize(size: u64) -> Result<usize> {
    usize::try_from(size).map_err(|_| MachineError {
        code: constants::error_code::OUT_OF_RANGE,
        message: format!("byte count {size} exceeds usize range on this platform"),
    })
}

/// Converts a `Path` to a `CString` for the C API.
///
/// On Unix, uses the raw `OsStr` bytes so that non-UTF-8 paths (which are
/// legal on the platform) are passed through verbatim instead of being
/// silently corrupted by `to_string_lossy` replacement. On other platforms,
/// falls back to UTF-8 conversion and errors out if the path is not valid
/// UTF-8.
///
/// Returns `CM_ERROR_INVALID_ARGUMENT` on an interior NUL byte or, on
/// non-Unix, on a non-UTF-8 path.
fn path_to_cstring(path: &Path) -> Result<CString> {
    #[cfg(unix)]
    let bytes = {
        use std::os::unix::ffi::OsStrExt;
        path.as_os_str().as_bytes().to_vec()
    };
    #[cfg(not(unix))]
    let bytes = path
        .to_str()
        .ok_or_else(|| MachineError {
            code: constants::error_code::INVALID_ARGUMENT,
            message: format!("path is not valid UTF-8: {}", path.display()),
        })?
        .as_bytes()
        .to_vec();

    CString::new(bytes).map_err(|e| MachineError {
        code: constants::error_code::INVALID_ARGUMENT,
        message: format!("path contains NUL byte ({}): {}", e, path.display()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::{
        config::{
            machine::{BackingStoreConfig, MachineConfig, MemoryRangeConfig, RAMConfig},
            runtime::RuntimeConfig,
        },
        constants,
        error::MachineResult as Result,
        types::cmio::ManualReason,
    };

    fn make_basic_machine_config() -> MachineConfig {
        let mut config = Machine::default_config().expect("failed to get default config");
        config.ram = RAMConfig {
            length: 134217728,
            backing_store: BackingStoreConfig {
                data_filename: "../../../test/programs/linux.bin".into(),
                ..Default::default()
            },
        };
        config.dtb.entrypoint = "echo Hello from inside!".to_string();
        config.flash_drive = vec![MemoryRangeConfig {
            backing_store: BackingStoreConfig {
                data_filename: "../../../test/programs/rootfs.ext2".into(),
                ..Default::default()
            },
            ..Default::default()
        }];
        config
    }

    fn make_cmio_machine_config() -> MachineConfig {
        let mut config = Machine::default_config().expect("failed to get default config");
        config.ram = RAMConfig {
            length: 134217728,
            backing_store: BackingStoreConfig {
                data_filename: "../../../test/programs/linux.bin".into(),
                ..Default::default()
            },
        };
        config.dtb.entrypoint =
            "echo '{\"domain\":16,\"id\":\"'$(echo -n Hello from inside! | hex --encode)'\"}' \
                     | rollup gio | grep -Eo '0x[0-9a-f]+' | tr -d '\\n' | hex --decode; echo"
                .to_string();
        config.flash_drive = vec![MemoryRangeConfig {
            backing_store: BackingStoreConfig {
                data_filename: "../../../test/programs/rootfs.ext2".into(),
                ..Default::default()
            },
            ..Default::default()
        }];
        config
    }

    fn create_machine(config: &MachineConfig) -> Result<Machine> {
        Machine::create(config, &RuntimeConfig::quiet_console())
    }

    #[test]
    fn test_machine_run_halt_root_hash() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let break_reason = machine.run(u64::MAX)?;
        assert_eq!(break_reason, constants::break_reason::HALTED);

        let mcycle_after_halt = machine.mcycle()?;
        let root_hash_before = machine.root_hash()?;

        let break_reason = machine.run(u64::MAX)?;
        assert_eq!(break_reason, constants::break_reason::HALTED);

        let root_hash_after = machine.root_hash()?;
        assert_eq!(root_hash_before, root_hash_after,);

        let mcycle_after_second_run = machine.mcycle()?;
        assert_eq!(mcycle_after_halt, mcycle_after_second_run,);

        Ok(())
    }

    #[test]
    fn test_machine_uarch_reset() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        machine.run(1)?;
        let reference_hash = machine.root_hash()?;
        let initial_config = machine.initial_config()?;
        drop(machine);

        let mut machine = create_machine(&initial_config)?;

        let uarch_break_reason = machine.run_uarch(u64::MAX)?;
        assert_eq!(
            uarch_break_reason,
            constants::uarch_break_reason::UARCH_HALTED
        );

        machine.reset_uarch()?;

        let final_hash = machine.root_hash()?;
        assert_eq!(reference_hash, final_hash,);

        let ucycle = machine.ucycle()?;
        assert_eq!(ucycle, 0);

        Ok(())
    }

    #[test]
    fn test_runtime_config_round_trip() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let original_config = machine.runtime_config()?;
        machine.set_runtime_config(&original_config)?;

        Ok(())
    }

    #[test]
    fn test_log_step() -> Result<()> {
        let tmp_dir = tempfile::tempdir().expect("failed creating a temp dir");
        let log_path = tmp_dir.path().join("machine_step.log");

        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let root_hash_before = machine.root_hash()?;

        machine.log_step(50, &log_path)?;
        let root_hash_after = machine.root_hash()?;

        let verified_break_reason =
            Machine::verify_step(&root_hash_before, &log_path, 50, &root_hash_after)?;
        assert_ne!(verified_break_reason, constants::break_reason::FAILED);

        Ok(())
    }

    #[test]
    fn test_log_step_uarch() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let root_hash_before = machine.root_hash()?;
        let access_log: AccessLog = machine.log_step_uarch(LogType::default().with_large_data())?;
        let root_hash_after = machine.root_hash()?;

        Machine::verify_step_uarch(&root_hash_before, &access_log, &root_hash_after)?;

        Ok(())
    }

    #[test]
    fn test_log_reset_uarch() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let root_hash_before = machine.root_hash()?;
        let reset_log = machine.log_reset_uarch(LogType::default().with_annotations())?;
        let root_hash_after = machine.root_hash()?;

        Machine::verify_reset_uarch(&root_hash_before, &reset_log, &root_hash_after)?;

        Ok(())
    }

    #[test]
    fn test_log_send_cmio_response() -> Result<()> {
        let config = make_cmio_machine_config();
        let mut machine = create_machine(&config)?;

        let break_reason = machine.run(u64::MAX)?;
        assert_eq!(break_reason, constants::break_reason::YIELDED_MANUALLY);

        let root_hash_before = machine.root_hash()?;

        let request = machine.receive_cmio_request()?;
        assert!(matches!(
            request,
            CmioRequest::Manual(ManualReason::GIO { domain: 16, ref data })
            if data == b"Hello from inside!"
        ));
        let response_data = b"Hello from outside!";
        let access_log: AccessLog = machine.log_send_cmio_response(
            CmioResponseReason::Advance,
            response_data,
            LogType::default().with_large_data(),
        )?;

        let root_hash_after = machine.root_hash()?;

        Machine::verify_send_cmio_response(
            CmioResponseReason::Advance,
            response_data,
            &root_hash_before,
            &access_log,
            &root_hash_after,
        )?;

        Ok(())
    }

    #[test]
    fn test_machine_cmio() -> Result<()> {
        let cmio_config = make_cmio_machine_config();
        let mut machine = create_machine(&cmio_config)?;

        let break_reason = machine.run(u64::MAX)?;
        assert_eq!(break_reason, constants::break_reason::YIELDED_MANUALLY);

        let request = machine.receive_cmio_request()?;
        assert!(matches!(
            request,
            CmioRequest::Manual(ManualReason::GIO { domain: 16, ref data })
            if data == b"Hello from inside!"
        ));

        let response = b"Hello from outside!";
        machine.send_cmio_response(CmioResponseReason::Advance, response)?;

        let break_reason = machine.run(u64::MAX)?;
        assert_eq!(break_reason, constants::break_reason::HALTED);

        Ok(())
    }

    #[test]
    fn test_store_and_load_machine() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let break_reason = machine.run(1000)?;
        assert_eq!(break_reason, constants::break_reason::REACHED_TARGET_MCYCLE);
        let root_hash_before_store = machine.root_hash()?;

        let tmp_dir = tempfile::tempdir().expect("failed creating a temp dir");
        let store_path = tmp_dir.path().join("image");
        machine.store(&store_path)?;

        let runtime_config = RuntimeConfig::default();
        let mut machine = Machine::load(&store_path, &runtime_config)?;

        let root_hash_after_load = machine.root_hash()?;
        assert_eq!(root_hash_before_store, root_hash_after_load,);

        Ok(())
    }

    #[test]
    fn test_memory_range() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let ranges_before = machine.memory_ranges()?;
        assert!(!ranges_before.is_empty());

        let range = ranges_before.last().unwrap();

        let mem = machine.read_memory(range.start, range.length)?;
        assert!(mem.iter().any(|x| *x != 0));

        // writes zeroes in range
        machine.replace_memory_range(range.start, range.length, false, None)?;
        let mem = machine.read_memory(range.start, range.length)?;
        assert!(!mem.iter().any(|x| *x != 0));

        // write ones in range
        machine.write_memory(range.start, &vec![1; range.length as usize])?;
        let mem = machine.read_memory(range.start, range.length)?;
        assert!(mem.iter().all(|x| *x == 1));

        let log2_size = u64::BITS - range.length.leading_zeros();
        let proof: Proof = machine.proof(
            range.start,
            u64::BITS - range.length.leading_zeros(),
            constants::machine::HASH_TREE_LOG2_ROOT_SIZE,
        )?;
        assert_eq!(proof.target_address, range.start);
        assert_eq!(proof.log2_target_size, log2_size as u64);

        Ok(())
    }

    #[test]
    fn test_memory_ops() -> Result<()> {
        let config = make_basic_machine_config();
        let mut machine = create_machine(&config)?;

        let reg = cartesi_machine_sys::CM_REG_X1;
        let reg_phys_addr = Machine::reg_address(reg)?;

        let val_via_read_word = machine.read_word(reg_phys_addr)?;
        let val_via_read_reg = machine.read_reg(reg)?;
        assert_eq!(val_via_read_word, val_via_read_reg);

        let new_reg_value = 0x1234_5678_9ABC_DEF0;
        machine.write_reg(reg, new_reg_value)?;
        let val_via_read_word2 = machine.read_word(reg_phys_addr)?;
        assert_eq!(val_via_read_word2, new_reg_value);

        let val_via_read_reg2 = machine.read_reg(reg)?;
        assert_eq!(val_via_read_reg2, new_reg_value);

        Ok(())
    }
}
