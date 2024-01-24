# dave-advance

Crate for simplified input feeding to the Cartesi machine.

```rs
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// The advance-state input that we need to change the machine
    let input = AdvanceInput {
        metadata: InputMetadata {
            msg_sender: Address::from_str("0x0000000000000000000000000000000000000000")?,
            block_number: 0,
            time_stamp: 0,
            epoch_index: 0,
            input_index: 0,
        },
        data: "uwu".as_bytes().to_vec(),
    };

    /// Connects to a remote machine.
    let mut machine = MachineClient::connect("http://127.0.0.1".to_string(), 5002).await?;

    /// Loads a machine that is with the `y` flag.
    machine.load(&PathBuf::from("/data/image"), &Default::default()).await?;

    /// Advances the state of the machine until a new [ManualYield]
    machine.advance(input.clone()).await?

    /// Destroys the current machine in order to load a new one
    machine.destroy().await?;

    Ok(())
}
```