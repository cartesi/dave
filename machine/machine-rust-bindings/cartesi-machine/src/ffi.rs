//! This module contains functions for converting between Rust and C strings.

use std::ffi::{c_char, CStr};

pub(crate) fn from_cstr(cstr: *const c_char) -> Option<String> {
    if cstr.is_null() {
        None
    } else {
        unsafe { Some(CStr::from_ptr(cstr).to_string_lossy().into_owned()) }
    }
}

pub(crate) fn to_cstr(string: Option<String>) -> *const c_char {
    match string {
        Some(string) => {
            let cstring = std::ffi::CString::new(string).unwrap();
            let ptr = cstring.as_ptr();
            std::mem::forget(cstring);
            ptr
        }
        None => std::ptr::null(),
    }
}

pub(crate) fn free_cstr(string: *const c_char) {
    if !string.is_null() {
        unsafe { drop(std::ffi::CString::from_raw(string as *mut c_char)) }
    }
}