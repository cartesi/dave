//! Tools for encoding and decoding stuff that is sent to the Cartesi Machine.

/// Writes a 64-bit big-endian integer to a 32-byte buffer.
pub(crate) fn write_be256(value: u64) -> Vec<u8> {
    let mut buffer = [0; 32];
    buffer[24..].copy_from_slice(&value.to_be_bytes());
    buffer.to_vec()
}

/// Encodes a string putting 32 bytes in front of it and adding the length of the string.
pub(crate) fn encode_string(payload: Vec<u8>) -> Vec<u8> {
    let mut encoded_string = write_be256(32);
    encoded_string.append(&mut write_be256(payload.len() as u64));
    encoded_string.append(&mut payload.clone());
    encoded_string
}
