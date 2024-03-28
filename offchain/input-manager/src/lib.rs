// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use anyhow::Result;
use ethers::types::Bytes;

pub trait IndexedInput {
    fn get_index(&self) -> u64;
}

pub trait InputManager {
    fn add_input(&mut self, input: Bytes, index: u64) -> Result<()>;
    fn get_input(&self, index: u64) -> Option<&Bytes>;
}

pub struct InMemoryInputManager {
    inputs: Vec<Bytes>,
}

impl InMemoryInputManager {
    pub fn new() -> Self {
        Self { inputs: vec![] }
    }
}

impl InputManager for InMemoryInputManager {
    fn add_input(&mut self, input: Bytes, index: u64) -> Result<()> {
        if index != self.inputs.len() as u64 {
            return Err(anyhow::anyhow!("Input index is not the next one"));
        }
        self.inputs.push(input);
        Ok(())
    }

    fn get_input(&self, index: u64) -> Option<&Bytes> {
        self.inputs.get(index as usize)
    }
}

#[test]

fn test_input_manager() -> Result<(), Box<dyn std::error::Error>> {
    use cartesi_rollups_contracts::input_box::input_box::InputAddedFilter;

    impl IndexedInput for InputAddedFilter {
        fn get_index(&self) -> u64 {
            self.index.as_u64()
        }
    }

    let input_0_bytes = Bytes::from_static(b"hello");
    let input_1_bytes = Bytes::from_static(b"world");

    let mut manager = InMemoryInputManager::new();
    manager.add_input(input_0_bytes.clone(), 0)?;

    manager.add_input(input_1_bytes.clone(), 1)?;

    assert_eq!(
        manager.get_input(0).unwrap(),
        &input_0_bytes,
        "input 0 bytes should match"
    );
    assert_eq!(
        manager.get_input(1).unwrap(),
        &input_1_bytes,
        "input 1 bytes should match"
    );
    assert_eq!(manager.get_input(2), None, "input 2 shouldn't exist");

    assert_eq!(
        manager.add_input(input_0_bytes, 1).is_err(),
        true,
        "duplicate input index should fail"
    );
    assert_eq!(
        manager.add_input(input_1_bytes.clone(), 3).is_err(),
        true,
        "input index should be sequential"
    );
    assert_eq!(
        manager.add_input(input_1_bytes, 2).is_ok(),
        true,
        "add sequential input should succeed"
    );

    Ok(())
}
