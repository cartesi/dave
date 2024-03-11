//! Logging utilities for Cartesi Machine.

use crate::{ffi, hash::Hash};

/// Type of state access
pub enum AccessType {
    /// Read operation
    Read = 0,
    /// Write operation
    Write,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
/// Type of access log
pub struct AccessLogType {
    /// Includes proofs
    pub proofs: bool,
    /// Includes annotations
    pub annotations: bool,
    /// Includes data bigger than 8 bytes
    pub large_data: bool,
}

impl From<AccessLogType> for cartesi_machine_sys::cm_access_log_type {
    fn from(log_type: AccessLogType) -> Self {
        unsafe { std::mem::transmute(log_type) }
    }
}

impl From<cartesi_machine_sys::cm_access_log_type> for AccessLogType {
    fn from(log_type: cartesi_machine_sys::cm_access_log_type) -> Self {
        unsafe { std::mem::transmute(log_type) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
/// Bracket type
pub enum BracketType {
    /// Start of scope
    Begin = 0,
    /// End of scope
    End,
}

/// Bracket Note
pub struct BracketNote<'a> {
    ptr: *const cartesi_machine_sys::cm_bracket_note,
    phantom: std::marker::PhantomData<&'a ()>,
}

impl<'a> BracketNote<'a>  {
    fn new(ptr: *const cartesi_machine_sys::cm_bracket_note) -> Self {
        Self {
            ptr,
            phantom: std::marker::PhantomData,
        }
    }

    pub fn kind(&self) -> BracketType {
        unsafe { std::mem::transmute((*self.ptr).type_) }
    }

    pub fn r#where(&self) -> u64 {
        unsafe { (*self.ptr).where_ }
    }

    pub fn text(&self) -> String {
        unsafe { ffi::from_cstr((*self.ptr).text) }.unwrap()
    }
}

/// Record of an access to the machine state
pub struct Access<'a> {
    ptr: *const cartesi_machine_sys::cm_access,
    phantom: std::marker::PhantomData<&'a ()>,
}

impl<'a>  Access<'a> {
    fn new(ptr: *const cartesi_machine_sys::cm_access) -> Self {
        Self {
            ptr,
            phantom: std::marker::PhantomData,
        }
    }

    /// Type of access
    pub fn access_type(&self) -> AccessType {
        unsafe { std::mem::transmute((*self.ptr).type_ as u8) }
    }

    /// Address of access
    pub fn address(&self) -> u64 {
        unsafe { (*self.ptr).address }
    }

    /// Log2 of size of access
    pub fn log2_size(&self) -> i32 {
        unsafe { (*self.ptr).log2_size }
    }

    /// Hash of data before access
    pub fn read_hash(&self) -> Hash {
        Hash::new(unsafe { (*self.ptr).read_hash })
    }

    /// Data before access
    pub fn read_data(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts((*self.ptr).read_data, (*self.ptr).read_data_size) }
    }

    /// Hash of data after access (if writing)
    pub fn written_hash(&self) -> Hash {
        Hash::new(unsafe { (*self.ptr).written_hash })
    }

    /// Data after access (if writing)
    pub fn written_data(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts((*self.ptr).written_data, (*self.ptr).written_data_size) }
    }

    /// Sibling hashes towards root
    pub fn sibling_hashes(&self) -> Vec<Hash> {
        let sibling_hashes = unsafe { *(*self.ptr).sibling_hashes };
        let sibling_hashes = unsafe { std::slice::from_raw_parts(sibling_hashes.entry, sibling_hashes.count) };

        sibling_hashes.iter().map(|hash| Hash::new(*hash)).collect()
    }
}

/// Log of state accesses
pub struct AccessLog(*mut cartesi_machine_sys::cm_access_log);

impl Drop for AccessLog {
    fn drop(&mut self) {
        unsafe { cartesi_machine_sys::cm_delete_access_log(self.0) };
    }
}

impl AccessLog {
    pub(crate) fn new(ptr: *mut cartesi_machine_sys::cm_access_log) -> Self {
        Self(ptr)
    }

    pub(crate) fn as_ptr(&self) -> &cartesi_machine_sys::cm_access_log {
        unsafe { &*self.0 }
    }

    pub fn accesses(&self) -> Vec<Access> {
        let accesses = unsafe { (*self.0).accesses };
        let accesses = unsafe { std::slice::from_raw_parts(accesses.entry, accesses.count) };

        accesses.iter().map(|access| Access::new(access)).collect()
    }

    pub fn brackets(&self) -> Vec<BracketNote> {
        let brackets = unsafe { (*self.0).brackets };
        let brackets = unsafe { std::slice::from_raw_parts(brackets.entry, brackets.count) };

        brackets.iter().map(|bracket| BracketNote::new(bracket)).collect()
    }

    pub fn notes(&self) -> Vec<String> {
        let notes = unsafe { (*self.0).notes };
        let notes = unsafe { std::slice::from_raw_parts(notes.entry, notes.count) };

        notes.iter().map(|note| ffi::from_cstr(*note).unwrap()).collect()
    }

    pub fn log_type(&self) -> AccessLogType {
        unsafe { std::mem::transmute((*self.0).log_type) }
    }
}