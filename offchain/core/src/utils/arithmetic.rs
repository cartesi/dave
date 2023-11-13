pub const fn max_uint(k: u64) -> u64 {
    assert!(k <= 64);
    (1 << k) - 1
}


pub fn semi_sum(a: u64, b: u64) -> u64 {
    a + (b - a) / 2
}
