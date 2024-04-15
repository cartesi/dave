// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use anyhow::Result;

pub trait StateManager {
    fn add_state(&mut self, state: &[u8], index: u64) -> Result<()>;
    fn state(&self, index: u64) -> Option<&Vec<u8>>;
}

pub struct InMemoryStateManager {
    states: Vec<Vec<u8>>,
}

impl InMemoryStateManager {
    pub fn new() -> Self {
        Self { states: vec![] }
    }
}

impl StateManager for InMemoryStateManager {
    fn add_state(&mut self, state: &[u8], index: u64) -> Result<()> {
        if index != self.states.len() as u64 {
            return Err(anyhow::anyhow!("State index is not the next one"));
        }
        self.states.push(state.to_vec());
        Ok(())
    }

    fn state(&self, index: u64) -> Option<&Vec<u8>> {
        self.states.get(index as usize)
    }
}

#[test]

fn test_input_manager() -> Result<(), Box<dyn std::error::Error>> {
    let input_0_bytes = b"hello";
    let input_1_bytes = b"world";

    let mut manager = InMemoryStateManager::new();
    manager.add_state(input_0_bytes, 0)?;

    manager.add_state(input_1_bytes, 1)?;

    assert_eq!(
        manager.state(0).unwrap(),
        &input_0_bytes,
        "input 0 bytes should match"
    );
    assert_eq!(
        manager.state(1).unwrap(),
        &input_1_bytes,
        "input 1 bytes should match"
    );
    assert_eq!(manager.state(2), None, "input 2 shouldn't exist");

    assert_eq!(
        manager.add_state(input_0_bytes, 1).is_err(),
        true,
        "duplicate input index should fail"
    );
    assert_eq!(
        manager.add_state(input_1_bytes, 3).is_err(),
        true,
        "input index should be sequential"
    );
    assert_eq!(
        manager.add_state(input_1_bytes, 2).is_ok(),
        true,
        "add sequential input should succeed"
    );

    Ok(())
}
