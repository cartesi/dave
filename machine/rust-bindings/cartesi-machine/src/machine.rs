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

/// Machine instance handle
pub struct Machine {
    pub machine: *mut cartesi_machine_sys::cm_machine,
}

impl Drop for Machine {
    fn drop(&mut self) {
        unsafe {
            cartesi_machine_sys::cm_delete(self.machine);
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

macro_rules! serialize_to_json {
    ($src:expr) => {
        CString::new(serde_json::to_string($src).expect("failed serializing to json"))
            .expect("CString::new failed")
    };
}

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

    /// Returns the default machine config.
    pub fn default_config() -> Result<MachineConfig> {
        let mut config_ptr: *const c_char = ptr::null();
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_default_config(ptr::null(), &mut config_ptr) };
        check_err!(err_code)?;

        let config = parse_json_from_cstring!(config_ptr);

        Ok(config)
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

        let mut machine: *mut cartesi_machine_sys::cm_machine = ptr::null_mut();
        let err_code = unsafe {
            cartesi_machine_sys::cm_create_new(
                config_json.as_ptr(),
                runtime_config_json.as_ptr(),
                &mut machine,
            )
        };
        check_err!(err_code)?;

        Ok(Self { machine })
    }

    /// Loads a new machine instance from a previously stored directory.
    pub fn load(dir: &Path, runtime_config: &RuntimeConfig) -> Result<Self> {
        let dir_cstr = path_to_cstring(dir);
        let runtime_config_json = serialize_to_json!(&runtime_config);

        let mut machine: *mut cartesi_machine_sys::cm_machine = ptr::null_mut();
        let err_code = unsafe {
            cartesi_machine_sys::cm_load_new(
                dir_cstr.as_ptr(),
                runtime_config_json.as_ptr(),
                &mut machine,
            )
        };
        check_err!(err_code)?;

        Ok(Self { machine })
    }

    /// Stores a machine instance to a directory, serializing its entire state.
    pub fn store(&mut self, dir: &Path) -> Result<()> {
        let dir_cstr = path_to_cstring(dir);
        let err_code = unsafe { cartesi_machine_sys::cm_store(self.machine, dir_cstr.as_ptr()) };
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

    /// Gets the machine runtime config.
    pub fn runtime_config(&mut self) -> Result<RuntimeConfig> {
        let mut rc_ptr: *const c_char = ptr::null();
        let err_code =
            unsafe { cartesi_machine_sys::cm_get_runtime_config(self.machine, &mut rc_ptr) };
        check_err!(err_code)?;

        let runtime_config = parse_json_from_cstring!(rc_ptr);

        Ok(runtime_config)
    }

    /// Replaces a memory range.
    pub fn replace_memory_range(
        &mut self,
        start: u64,
        length: u64,
        shared: bool,
        image_path: Option<&Path>,
    ) -> Result<()> {
        let image_cstr = match image_path {
            Some(path) => path_to_cstring(path),
            None => CString::new("").unwrap(),
        };

        let image_ptr = if image_path.is_some() {
            image_cstr.as_ptr()
        } else {
            ptr::null()
        };

        let err_code = unsafe {
            cartesi_machine_sys::cm_replace_memory_range(
                self.machine,
                start,
                length,
                shared,
                image_ptr,
            )
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
            unsafe { cartesi_machine_sys::cm_get_memory_ranges(self.machine, &mut ranges_ptr) };
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
    pub fn proof(&mut self, address: u64, log2_size: u32) -> Result<Proof> {
        let mut proof_ptr: *const c_char = ptr::null();
        let err_code = unsafe {
            cartesi_machine_sys::cm_get_proof(
                self.machine,
                address,
                log2_size as i32,
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
        let mut buffer = vec![0u8; size as usize];
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
        let mut buffer = vec![0u8; size as usize];
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

        // if data is NULL, length will still be set without reading any data.
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

        let mut buffer = vec![0u8; length as usize];

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
        let log_filename_c = path_to_cstring(log_filename);

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
        let log_filename_c = path_to_cstring(log_filename);

        let mut break_reason = BreakReason::default();
        let err_code = unsafe {
            cartesi_machine_sys::cm_verify_step(
                ptr::null(),
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

fn path_to_cstring(path: &Path) -> CString {
    CString::new(path.to_string_lossy().as_bytes()).expect("CString::new failed")
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::{
        config::{
            machine::{DTBConfig, MachineConfig, MemoryRangeConfig, RAMConfig},
            runtime::RuntimeConfig,
        },
        constants,
        error::MachineResult as Result,
        types::cmio::ManualReason,
    };

    fn make_basic_machine_config() -> MachineConfig {
        MachineConfig::new_with_ram(RAMConfig {
            length: 134217728,
            image_filename: "../../../test/programs/linux.bin".into(),
        })
        .dtb(DTBConfig {
            entrypoint: "echo Hello from inside!".to_string(),
            ..Default::default()
        })
        .add_flash_drive(MemoryRangeConfig {
            image_filename: "../../../test/programs/rootfs.ext2".into(),
            ..Default::default()
        })
    }

    fn make_cmio_machine_config() -> MachineConfig {
        MachineConfig::new_with_ram(RAMConfig {
            length: 134217728,
            image_filename: "../../../test/programs/linux.bin".into(),
        })
        .dtb(DTBConfig {
            entrypoint:
                "echo '{\"domain\":16,\"id\":\"'$(echo -n Hello from inside! | hex --encode)'\"}' \
                     | rollup gio | grep -Eo '0x[0-9a-f]+' | tr -d '\\n' | hex --decode; echo"
                    .to_string(),
            ..Default::default()
        })
        .add_flash_drive(MemoryRangeConfig {
            image_filename: "../../../test/programs/rootfs.ext2".into(),
            ..Default::default()
        })
    }

    fn create_machine(config: &MachineConfig) -> Result<Machine> {
        let runtime_config = RuntimeConfig {
            htif: Some(config::runtime::HTIFRuntimeConfig {
                no_console_putchar: Some(true),
            }),
            ..Default::default()
        };
        Machine::create(config, &runtime_config)
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
        let proof: Proof = machine.proof(range.start, u64::BITS - range.length.leading_zeros())?;
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
