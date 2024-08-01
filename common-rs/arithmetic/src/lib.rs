pub const fn max_uint(k: u64) -> u64 {
    assert!(k <= u64::BITS as u64);
    (1u64.wrapping_shl(k as u32)).wrapping_sub(1)
}

pub fn add_and_clamp(x: u64, y: u64) -> u64 {
    x.checked_add(y).unwrap_or(u64::MAX)
}
