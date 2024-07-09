pub const fn max_uint(k: u64) -> u64 {
    assert!(k <= u64::BITS as u64);
    (1u64.wrapping_shl(k as u32)).wrapping_sub(1)
}