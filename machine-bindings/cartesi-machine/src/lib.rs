#![doc = include_str!("../README.md")]

#[macro_use]
extern crate num_derive;

use std::path::Path;

pub mod configuration;
pub mod errors;
pub mod hash;
pub mod log;
pub mod proof;
mod ffi;

use cartesi_machine_sys::{cm_machine_runtime_config, cm_memory_range_config};
use configuration::{free_cm_memory_range_config_cstr, OwnedMachineConfig};
use configuration::{MachineConfig, RuntimeConfig};
use errors::{ErrorCollector, MachineError};

macro_rules! read_csr {
    ($typ: ty, $name: ident, $flag: ident) => {
        pub fn $name(&self) -> Result<$typ, MachineError> {
            let mut error_collector = ErrorCollector::new();
            let mut value : $typ = Default::default();

            unsafe {
                let result = cartesi_machine_sys::$flag(
                    self.machine,
                    &mut value,
                    &mut error_collector.as_mut_ptr(),
                );

                error_collector.collect(result)?;
            }

            Ok(value)
        }
    };
}

macro_rules! write_csr {
    ($typ: ty, $name: ident, $flag: ident) => {
        pub fn $name(&mut self, value: $typ) -> Result<(), MachineError> {
            let mut error_collector = ErrorCollector::new();

            unsafe {
                let result = cartesi_machine_sys::$flag(
                    self.machine,
                    value,
                    &mut error_collector.as_mut_ptr(),
                );

                error_collector.collect(result)?;
            }

            Ok(())
        }
    };
}

macro_rules! iflags {
    ($name: ident, $flag: ident) => {
        pub fn $name(&mut self) -> Result<(), MachineError> {
            let mut error_collector = ErrorCollector::new();

            unsafe {
                let result = cartesi_machine_sys::$flag(
                    self.machine,
                    &mut error_collector.as_mut_ptr(),
                );

                error_collector.collect(result)?;
            }

            Ok(())
        }
    };
}

/// Reasons for a machine run interruption
pub enum BreakReason {
    Failed = 0,
    Halted,
    YieldedManually,
    YieldedAutomatically,
    ReachedTargetMcycle,
}

impl BreakReason {
    /// Transmute a u8 value to a BreakReason
    #[inline]
    pub unsafe fn from_u8_unchecked(value: u8) -> Self {
        std::mem::transmute(value)
    }

    /// Transforms a u8 value to a BreakReason
    pub fn from_u8(value: u8) -> Self {
        match value {
            0 => BreakReason::Failed,
            1 => BreakReason::Halted,
            2 => BreakReason::YieldedManually,
            3 => BreakReason::YieldedAutomatically,
            4 => BreakReason::ReachedTargetMcycle,
            _ => panic!("Invalid break reason value"),
        }
    }
}

/// Control and Status Registers (CSRs) to use with read_csr and write_csr
#[repr(u8)]
pub enum CSR {
    Pc = 0,
    Fcsr,
    Mvendorid,
    Marchid,
    Mimpid,
    Mcycle,
    Icycleinstret,
    Mstatus,
    Mtvec,
    Mscratch,
    Mepc,
    Mcause,
    Mtval,
    Misa,
    Mie,
    Mip,
    Medeleg,
    Mideleg,
    Mcounteren,
    Menvcfg,
    Stvec,
    Sscratch,
    Sepc,
    Scause,
    Stval,
    Satp,
    Scounteren,
    Senvcfg,
    Ilrsc,
    Iflags,
    ClintMtimecmp,
    HtifTohost,
    HtifFromhost,
    HtifIhalt,
    HtifIconsole,
    HtifIyield,
    UarchPc,
    UarchCycle,
    UarchHaltFlag,
}

/// Return values of uarch_interpret. Reason for the uarch_interpret to break.
#[repr(u8)]
pub enum UarchBreakReason {
    ReachedTargetCycle = 0,
    UarchHalted,
}

/// Machine instance handle
pub struct Machine {
    machine: *mut cartesi_machine_sys::cm_machine,
}

impl Drop for Machine {
    fn drop(&mut self) {
        unsafe {
            cartesi_machine_sys::cm_delete_machine(self.machine);
        }
    }
}

impl Machine {
    /// Create new machine instance from configuration
    pub fn create(
        machine_config: MachineConfig,
        runtime: RuntimeConfig,
    ) -> Result<Self, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut machine = Machine {
            machine: std::ptr::null_mut(),
        };

        unsafe {
            let config = OwnedMachineConfig::from(machine_config);
            let runtime = cm_machine_runtime_config::from(runtime);

            let result = cartesi_machine_sys::cm_create_machine(
                config.as_ref(),
                &runtime,
                &mut machine.machine,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(machine)
    }

    /// Create machine instance from previously serialized directory
    pub fn load(path: &Path, runtime: RuntimeConfig) -> Result<Self, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut machine = Machine {
            machine: std::ptr::null_mut(),
        };

        unsafe {
            let path = path.to_str().unwrap();
            let path = std::ffi::CString::new(path).unwrap();
            let runtime = cm_machine_runtime_config::from(runtime);

            let result = cartesi_machine_sys::cm_load_machine(
                path.as_ptr(),
                &runtime,
                &mut machine.machine,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(machine)
    }

    /// Serialize entire state to directory
    pub fn store(&self, path: &Path) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let path = path.to_str().unwrap();
            let path = std::ffi::CString::new(path).unwrap();

            let result = cartesi_machine_sys::cm_store(
                self.machine,
                path.as_ptr(),
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Runs the machine until mcycle reaches mcycle_end or the machine halts.
    pub fn run(&mut self, mcycle_end: u64) -> Result<BreakReason, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut break_reason = 0;

        unsafe {
            let result = cartesi_machine_sys::cm_machine_run(
                self.machine,
                mcycle_end,
                &mut break_reason,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(unsafe { BreakReason::from_u8_unchecked(break_reason as u8) })
    }

    /// Runs the machine for one micro cycle logging all accesses to the state.
    pub fn log_uarch_step(
        &mut self,
        log_type: log::AccessLogType,
        one_based: bool,
    ) -> Result<log::AccessLog, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut access_log = std::ptr::null_mut();

        unsafe {
            let result = cartesi_machine_sys::cm_log_uarch_step(
                self.machine,
                log_type.into(),
                one_based,
                &mut access_log,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(log::AccessLog::new(access_log))
    }

    /// Checks the internal consistency of an access log
    pub fn verify_uarch_step_log(
        &mut self,
        log: &log::AccessLog,
        runtime: RuntimeConfig,
        one_based: bool,
    ) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let runtime = cm_machine_runtime_config::from(runtime);

            let result = cartesi_machine_sys::cm_verify_uarch_step_log(
                log.as_ptr(),
                &runtime,
                one_based,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Checks the validity of a state transition
    pub fn verify_uarch_step_state_transition(
        &mut self,
        root_hash_before: &hash::Hash,
        log: &log::AccessLog,
        root_hash_after: &hash::Hash,
        runtime: RuntimeConfig,
        one_based: bool,
    ) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let runtime = cm_machine_runtime_config::from(runtime);

            let result = cartesi_machine_sys::cm_verify_uarch_step_state_transition(
                root_hash_before.as_ptr(),
                log.as_ptr(),
                root_hash_after.as_ptr(),
                &runtime,
                one_based,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Checks the validity of a state transition caused by a uarch state reset
    pub fn verify_uarch_reset_state_transition(
        &mut self,
        root_hash_before: &hash::Hash,
        log: &log::AccessLog,
        root_hash_after: &hash::Hash,
        runtime: RuntimeConfig,
        one_based: bool,
    ) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let runtime = cm_machine_runtime_config::from(runtime);

            let result = cartesi_machine_sys::cm_verify_uarch_reset_state_transition(
                root_hash_before.as_ptr(),
                log.as_ptr(),
                root_hash_after.as_ptr(),
                &runtime,
                one_based,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Checks the internal consistency of an access log produced by cm_log_uarch_step
    pub fn verify_uarch_reset_log(
        &mut self,
        log: &log::AccessLog,
        runtime: RuntimeConfig,
        one_based: bool,
    ) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let runtime = cm_machine_runtime_config::from(runtime);

            let result = cartesi_machine_sys::cm_verify_uarch_reset_log(
                log.as_ptr(),
                &runtime,
                one_based,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Obtains the proof for a node in the Merkle tree
    pub fn get_proof(
        &mut self,
        address: u64,
        log2_size: i32,
    ) -> Result<proof::MerkleTreeProof, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut proof = std::ptr::null_mut();

        unsafe {
            let result = cartesi_machine_sys::cm_get_proof(
                self.machine,
                address,
                log2_size,
                &mut proof,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(proof::MerkleTreeProof::new(proof))
    }

    /// Obtains the root hash of the Merkle tree
    pub fn get_root_hash(&mut self) -> Result<hash::Hash, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut hash = [0;32];

        unsafe {
            let result = cartesi_machine_sys::cm_get_root_hash(
                self.machine,
                &mut hash,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(hash::Hash::new(hash))
    }

    /// Verifies integrity of Merkle tree.
    pub fn verify_merkle_tree(&mut self) -> Result<bool, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut result = false;

        unsafe {
            let result = cartesi_machine_sys::cm_verify_merkle_tree(
                self.machine,
                &mut result,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(result)
    }

    /// Write the value of any CSR
    pub fn write_csr(&mut self, csr: CSR, value: u64) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let result = cartesi_machine_sys::cm_write_csr(
                self.machine,
                csr as u32,
                value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Read the value of any CSR
    pub fn read_csr(&mut self, csr: CSR) -> Result<u64, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut value = 0;

        unsafe {
            let result = cartesi_machine_sys::cm_read_csr(
                self.machine,
                csr as u32,
                &mut value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(value)
    }

    /// Gets the address of any CSR
    pub fn get_csr_address(&mut self, csr: CSR) -> u64 {
        unsafe { cartesi_machine_sys::cm_get_csr_address(csr as u32) }
    }

    /// Read the value of a word in the machine state.
    pub fn read_word(&mut self, word_address: u64) -> Result<u64, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut word_value = 0;

        unsafe {
            let result = cartesi_machine_sys::cm_read_word(
                self.machine,
                word_address,
                &mut word_value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(word_value)
    }

    /// Read a chunk of data from the machine memory.
    pub fn read_memory(&mut self, address: u64, length: u64) -> Result<Vec<u8>, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut data = vec![0; length as usize];

        unsafe {
            let result = cartesi_machine_sys::cm_read_memory(
                self.machine,
                address,
                data.as_mut_ptr(),
                length,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(data)
    }

    /// Write a chunk of data to the machine memory.
    pub fn write_memory(&mut self, address: u64, data: &[u8]) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let result = cartesi_machine_sys::cm_write_memory(
                self.machine,
                address,
                data.as_ptr(),
                data.len(),
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Reads a chunk of data from the machine virtual memory.
    pub fn read_virtual_memory(
        &mut self,
        address: u64,
        length: u64,
    ) -> Result<Vec<u8>, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut data = vec![0; length as usize];

        unsafe {
            let result = cartesi_machine_sys::cm_read_virtual_memory(
                self.machine,
                address,
                data.as_mut_ptr(),
                length,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(data)
    }

    /// Writes a chunk of data to the machine virtual memory.
    pub fn write_virtual_memory(
        &mut self,
        address: u64,
        data: &[u8],
    ) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let result = cartesi_machine_sys::cm_write_virtual_memory(
                self.machine,
                address,
                data.as_ptr(),
                data.len(),
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Reads the value of a general-purpose microarchitecture register.
    pub fn read_x(&mut self, i: u32) -> Result<u64, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut value = 0;

        unsafe {
            let result = cartesi_machine_sys::cm_read_x(
                self.machine,
                i as i32,
                &mut value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(value)
    }

    /// Writes the value of a general-purpose microarchitecture register.
    pub fn write_x(&mut self, i: u32, value: u64) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let result = cartesi_machine_sys::cm_write_x(
                self.machine,
                i as i32,
                value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Gets the address of a general-purpose register.
    pub fn get_x_address(&mut self, i: u32) -> u64 {
        unsafe { cartesi_machine_sys::cm_get_x_address(i as i32) }
    }

    /// Gets the address of a general-purpose microarchitecture register.
    pub fn get_uarch_x_address(&mut self, i: u32) -> u64 {
        unsafe { cartesi_machine_sys::cm_get_uarch_x_address(i as i32) }
    }

    /// Reads the value of a floating-point register.
    pub fn read_f(&mut self, i: u32) -> Result<u64, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut value = 0;

        unsafe {
            let result = cartesi_machine_sys::cm_read_f(
                self.machine,
                i as i32,
                &mut value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(value)
    }

    /// Writes the value of a floating-point register.
    pub fn write_f(&mut self, i: u32, value: u64) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();

        unsafe {
            let result = cartesi_machine_sys::cm_write_f(
                self.machine,
                i as i32,
                value,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(())
    }

    /// Gets the address of a floating-point register.
    pub fn get_f_address(&mut self, i: u32) -> u64 {
        unsafe { cartesi_machine_sys::cm_get_f_address(i as i32) }
    }

    /// Returns copy of initialization config.
    pub fn get_initial_config(&mut self) -> Result<MachineConfig, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut config = std::ptr::null();

        unsafe {
            let result = cartesi_machine_sys::cm_get_initial_config(
                self.machine,
                &mut config,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        let new_config: MachineConfig = unsafe { (*config).into() };

        unsafe {
            cartesi_machine_sys::cm_delete_machine_config(config);
        }

        Ok(new_config)
    }

    /// Returns copy of default system config.
    pub fn get_default_config() -> Result<MachineConfig, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut config = std::ptr::null();

        unsafe {
            let result = cartesi_machine_sys::cm_get_default_config(
                &mut config,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        let new_config: MachineConfig = unsafe { (*config).into() };

        unsafe {
            cartesi_machine_sys::cm_delete_machine_config(config);
        }

        Ok(new_config)
    }

    /// Replaces a memory range
    pub fn replace_memory_range(
        &mut self,
        new_range: configuration::MemoryRangeConfig,
    ) -> Result<(), MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut range: cm_memory_range_config = new_range.into();

        unsafe {
            let result = cartesi_machine_sys::cm_replace_memory_range(
                self.machine,
                &mut range,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        free_cm_memory_range_config_cstr(&mut range);

        Ok(())
    }

    /// Verify if dirty page maps are consistent.
    pub fn verify_dirty_page_maps(&mut self) -> Result<bool, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut result = false;

        unsafe {
            let result = cartesi_machine_sys::cm_verify_dirty_page_maps(
                self.machine,
                &mut result,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(result)
    }

    /// Resets the value of the microarchitecture halt flag.
    pub fn log_uarch_reset(
        &mut self,
        log_type: log::AccessLogType,
        one_based: bool,
    ) -> Result<log::AccessLog, MachineError> {
        let mut error_collector = ErrorCollector::new();
        let mut access_log = std::ptr::null_mut();

        unsafe {
            let result = cartesi_machine_sys::cm_log_uarch_reset(
                self.machine,
                log_type.into(),
                one_based,
                &mut access_log,
                &mut error_collector.as_mut_ptr(),
            );

            error_collector.collect(result)?;
        }

        Ok(log::AccessLog::new(access_log))
    }

    iflags!(set_iflags_x, cm_set_iflags_X);
    iflags!(reset_iflags_x, cm_reset_iflags_X);
    iflags!(set_iflags_y, cm_set_iflags_Y);
    iflags!(reset_iflags_y, cm_reset_iflags_Y);
    iflags!(set_iflags_h, cm_set_iflags_H);
    iflags!(set_uarch_halt_flag, cm_set_uarch_halt_flag);
    iflags!(reset_uarch, cm_reset_uarch);

    read_csr!(u64, read_pc, cm_read_pc);
    read_csr!(u64, read_fcsr, cm_read_fcsr);
    read_csr!(u64, read_mvendorid, cm_read_mvendorid);
    read_csr!(u64, read_marchid, cm_read_marchid);
    read_csr!(u64, read_mimpid, cm_read_mimpid);
    read_csr!(u64, read_mcycle, cm_read_mcycle);
    read_csr!(u64, read_icycleinstret, cm_read_icycleinstret);
    read_csr!(u64, read_mstatus, cm_read_mstatus);
    read_csr!(u64, read_menvcfg, cm_read_menvcfg);
    read_csr!(u64, read_mtvec, cm_read_mtvec);
    read_csr!(u64, read_mscratch, cm_read_mscratch);
    read_csr!(u64, read_mepc, cm_read_mepc);
    read_csr!(u64, read_mcause, cm_read_mcause);
    read_csr!(u64, read_mtval, cm_read_mtval);
    read_csr!(u64, read_misa, cm_read_misa);
    read_csr!(u64, read_mie, cm_read_mie);
    read_csr!(u64, read_mip, cm_read_mip);
    read_csr!(u64, read_medeleg, cm_read_medeleg);
    read_csr!(u64, read_mideleg, cm_read_mideleg);
    read_csr!(u64, read_mcounteren, cm_read_mcounteren);
    read_csr!(u64, read_stvec, cm_read_stvec);
    read_csr!(u64, read_sscratch, cm_read_sscratch);
    read_csr!(u64, read_sepc, cm_read_sepc);
    read_csr!(u64, read_scause, cm_read_scause);
    read_csr!(u64, read_stval, cm_read_stval);
    read_csr!(u64, read_satp, cm_read_satp);
    read_csr!(u64, read_scounteren, cm_read_scounteren);
    read_csr!(u64, read_senvcfg, cm_read_senvcfg);
    read_csr!(u64, read_ilrsc, cm_read_ilrsc);
    read_csr!(u64, read_iflags, cm_read_iflags);
    read_csr!(u64, read_htif_tohost, cm_read_htif_tohost);
    read_csr!(u64, read_htif_tohost_dev, cm_read_htif_tohost_dev);
    read_csr!(u64, read_htif_tohost_cmd, cm_read_htif_tohost_cmd);
    read_csr!(u64, read_htif_tohost_data, cm_read_htif_tohost_data);
    read_csr!(u64, read_htif_fromhost, cm_read_htif_fromhost);
    read_csr!(u64, read_htif_ihalt, cm_read_htif_ihalt);
    read_csr!(u64, read_htif_iconsole, cm_read_htif_iconsole);
    read_csr!(u64, read_htif_iyield, cm_read_htif_iyield);
    read_csr!(u64, read_clint_mtimecmp, cm_read_clint_mtimecmp);
    read_csr!(bool, read_iflags_x, cm_read_iflags_X);
    read_csr!(bool, read_iflags_y, cm_read_iflags_Y);
    read_csr!(bool, read_iflags_h, cm_read_iflags_H);
    read_csr!(u64, read_uarch_pc, cm_read_uarch_pc);
    read_csr!(u64, read_uarch_cycle, cm_read_uarch_cycle);
    read_csr!(bool, read_uarch_halt_flag, cm_read_uarch_halt_flag);

    write_csr!(u64, write_pc, cm_write_pc);
    write_csr!(u64, write_fcsr, cm_write_fcsr);
    write_csr!(u64, write_mcycle, cm_write_mcycle);
    write_csr!(u64, write_icycleinstret, cm_write_icycleinstret);
    write_csr!(u64, write_mstatus, cm_write_mstatus);
    write_csr!(u64, write_menvcfg, cm_write_menvcfg);
    write_csr!(u64, write_mtvec, cm_write_mtvec);
    write_csr!(u64, write_mscratch, cm_write_mscratch);
    write_csr!(u64, write_mepc, cm_write_mepc);
    write_csr!(u64, write_mcause, cm_write_mcause);
    write_csr!(u64, write_mtval, cm_write_mtval);
    write_csr!(u64, write_misa, cm_write_misa);
    write_csr!(u64, write_mie, cm_write_mie);
    write_csr!(u64, write_mip, cm_write_mip);
    write_csr!(u64, write_medeleg, cm_write_medeleg);
    write_csr!(u64, write_mideleg, cm_write_mideleg);
    write_csr!(u64, write_mcounteren, cm_write_mcounteren);
    write_csr!(u64, write_stvec, cm_write_stvec);
    write_csr!(u64, write_sscratch, cm_write_sscratch);
    write_csr!(u64, write_sepc, cm_write_sepc);
    write_csr!(u64, write_scause, cm_write_scause);
    write_csr!(u64, write_stval, cm_write_stval);
    write_csr!(u64, write_satp, cm_write_satp);
    write_csr!(u64, write_scounteren, cm_write_scounteren);
    write_csr!(u64, write_senvcfg, cm_write_senvcfg);
    write_csr!(u64, write_ilrsc, cm_write_ilrsc);
    write_csr!(u64, write_iflags, cm_write_iflags);
    write_csr!(u64, write_htif_tohost, cm_write_htif_tohost);
    write_csr!(u64, write_htif_fromhost, cm_write_htif_fromhost);
    write_csr!(u64, write_htif_ihalt, cm_write_htif_ihalt);
    write_csr!(u64, write_htif_iconsole, cm_write_htif_iconsole);
    write_csr!(u64, write_htif_iyield, cm_write_htif_iyield);
    write_csr!(u64, write_clint_mtimecmp, cm_write_clint_mtimecmp);
    write_csr!(u64, write_uarch_pc, cm_write_uarch_pc);
    write_csr!(u64, write_uarch_cycle, cm_write_uarch_cycle);
}

/// Returns packed iflags from its component fields.
pub fn packed_iflags(prv: i32, x: i32, y: i32, h: i32) -> u64 {
    unsafe { cartesi_machine_sys::cm_packed_iflags(prv, x, y, h) }
}