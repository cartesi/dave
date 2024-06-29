// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! This module contains functions for converting between Rust and C strings.

use std::ffi::{c_char, CStr};

pub(crate) fn from_cstr(cstr: *const c_char) -> Option<String> {
    if cstr.is_null() {
        None
    } else {
        unsafe { Some(CStr::from_ptr(cstr).to_string_lossy().into_owned()) }
    }
}
