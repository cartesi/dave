// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Tiny real guests shared by execution and lifecycle regressions.

use anyhow::Result;
use cartesi_machine::{
    cartesi_machine_sys::CM_REG_X19, config::runtime::RuntimeConfig, constants::ar::RAM_START,
    machine::Machine,
};

pub fn manual_yield(reason: u16, data: u32) -> u64 {
    // HTIF_BUILD(yield device, manual command, reason, data).
    (2u64 << 56) | (1u64 << 48) | (u64::from(reason) << 32) | u64::from(data)
}

pub fn halt() -> u64 {
    // Halt data is (exit_code << 1) | 1: the halt bit with exit code zero.
    1
}

pub fn automatic_yield(reason: u16, data: u32) -> u64 {
    // HTIF_BUILD(yield device, automatic command, reason, data).
    (2u64 << 56) | (u64::from(reason) << 32) | u64::from(data)
}

/// Clear fromhost, write each word to tohost, then repeat the last write.
/// The first write is instruction three, so a budget of three reaches a
/// yield exactly at the budget boundary. A tohost word of one halts.
pub fn yield_guest(imcyclemax: u64, words: &[u64]) -> Result<Machine> {
    assert!(
        !words.is_empty() && words.len() <= 13,
        "guest sequence must fit the 13 registers x19..x31"
    );
    let mut config = Machine::default_config()?;
    config.ram.length = 4096;
    config.processor.registers.pc = RAM_START;
    config.processor.registers.imcyclemax = imcyclemax;
    let mut machine = Machine::create(&config, &RuntimeConfig::quiet_console())?;
    let mut program = vec![
        0x4000_82b7u32, // lui t0, 0x40008 (HTIF base)
        0x0002_b423,    // sd zero, 8(t0) (fromhost)
    ];
    for (index, word) in words.iter().enumerate() {
        machine.write_reg(CM_REG_X19 + index as u32, *word)?;
        // sd x(19 + index), 0(t0) (tohost)
        program.push(0x0002_b023 | ((19 + index as u32) << 20));
    }
    program.push(0xffdf_f06f); // j -4
    let bytes: Vec<_> = program.iter().flat_map(|v| v.to_le_bytes()).collect();
    machine.write_memory(RAM_START, &bytes)?;
    machine.run(u64::MAX)?;
    Ok(machine)
}
