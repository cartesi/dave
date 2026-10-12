#![doc = include_str!("../README.md")]
#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

extern crate link_cplusplus;
include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
// include!(concat!(env!("OUT_DIR"), "/htif.rs"));
// include!(concat!(env!("OUT_DIR"), "/pma.rs"));

// libcartesi's pristine uarch state hash, which `cm.h` (all bindgen sees)
// does not export. Declared by hand from the emulator's internal
// `src/uarch-pristine.hpp`, in bindgen's shape for an incomplete array; the
// static archive defines both in `uarch-pristine-hash.o`, and the emulator's
// own Lua module reads them. Temporary: drop these once the C API's
// `cm_get_uarch_pristine_hash()` ships.
unsafe extern "C" {
    pub static uarch_pristine_hash: [::std::os::raw::c_uchar; 0usize];
    pub static uarch_pristine_hash_len: ::std::os::raw::c_uint;
}
