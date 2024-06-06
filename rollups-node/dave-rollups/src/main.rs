use anyhow::Result;
use dave_rollups::{
    create_blockchain_reader_task, create_epoch_manager_task, create_machine_runner_task,
    DaveParameters,
};
use ethers::types::Address;
use log::info;
use rollups_blockchain_reader::AddressBook;

#[tokio::main]
async fn main() -> Result<()> {
    info!("Hello from Dave Rollups!");

    // TODO: use proper configuration file
    let parameters = DaveParameters::new()?;
    let address_book = AddressBook::new(Address::zero(), Address::zero(), Address::zero());

    let blockchain_reader_task = create_blockchain_reader_task(&parameters, address_book);
    let epoch_manager_task = create_epoch_manager_task(&parameters);
    let machine_runner_task = create_machine_runner_task(&parameters);

    let (_blockchain_reader_res, _epoch_manager_res, _machine_runner_res) = futures::join!(
        blockchain_reader_task,
        epoch_manager_task,
        machine_runner_task
    );

    Ok(())
}
