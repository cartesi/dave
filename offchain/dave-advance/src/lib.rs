//! Library for creating and advancing a Cartesi Machine instance.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use cartesi_machine_json_rpc::{client, interfaces};
use encode::write_be256;
use std::error::Error;
use std::path::Path;

pub mod encode;

pub use cartesi_machine_json_rpc::client::{ConcurrencyConfig, MachineRuntimeConfig};
pub use cartesi_machine_json_rpc::interfaces::HTIFRuntimeConfig;
pub use ethers::abi::Address;

use crate::encode::encode_string;

pub const HTIF_CMD_MASK: u64 = 0x00FF000000000000;
pub const HTIF_DATA_MASK: u64 = 0x0000FFFFFFFFFFFF;

pub const HTIF_CMD_SHIFT: u64 = 48;
pub const HTIF_DATA_SHIFT: u64 = 0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BreakReason {
    Limit,
    Halt(usize),
    YieldManual(Reason),
    YieldAutomatic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Cmd {
    YieldAutomatic,
    YieldManual,
}

impl TryFrom<u64> for Cmd {
    type Error = ();

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Cmd::YieldAutomatic),
            1 => Ok(Cmd::YieldManual),
            _ => Err(())
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Reason {
    Progress = 0,
    Accepted,
    Rejected,
    Voucher,
    Notice,
    Report,
    Exception
}

impl TryFrom<u64> for Reason {
    type Error = ();

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Reason::Progress),
            1 => Ok(Reason::Accepted),
            2 => Ok(Reason::Rejected),
            3 => Ok(Reason::Voucher),
            4 => Ok(Reason::Notice),
            5 => Ok(Reason::Report),
            6 => Ok(Reason::Exception),
            _ => Err(())
        }
    }
}



/// The metadata of the input to be fed to the machine.
#[derive(Clone, Debug)]

pub struct InputMetadata {
    pub msg_sender: Address,
    pub block_number: u64,
    pub time_stamp: u64,
    pub epoch_index: u64,
    pub input_index: u64,
}

impl InputMetadata {
    /// Encodes the input metadata into a byte vector.
    pub fn encode(&self) -> Vec<u8> {
        let mut encoded_data = Vec::new();

        encoded_data.extend_from_slice(&[0u8; 12]);
        encoded_data.extend_from_slice(&self.msg_sender.0);
        encoded_data.append(&mut write_be256(self.block_number));
        encoded_data.append(&mut write_be256(self.time_stamp));
        encoded_data.append(&mut write_be256(self.epoch_index));
        encoded_data.append(&mut write_be256(self.input_index));

        encoded_data
    }
}

/// The data that is going to be fed to the machine.
#[derive(Clone, Debug)]
pub struct AdvanceInput {
    pub metadata: InputMetadata,
    pub data: Vec<u8>,
}

#[derive(Clone)]
struct RollupConfig {
    pub input_metadata: interfaces::MemoryRangeConfig,
    pub notice_hashes: interfaces::MemoryRangeConfig,
    pub rx_buffer: interfaces::MemoryRangeConfig,
    pub voucher_hashes: interfaces::MemoryRangeConfig,
}

impl RollupConfig {
    pub fn unwrap_from(rollup_config: &interfaces::RollupConfig) -> Result<RollupConfig, String> {
        let input_metadata = rollup_config
            .input_metadata
            .as_ref()
            .ok_or("rollup config does not have input metadata config")?;

        let notice_hashes = rollup_config
            .notice_hashes
            .as_ref()
            .ok_or("rollup config does not have notice hashes")?;

        let rx_buffer = rollup_config
            .rx_buffer
            .as_ref()
            .ok_or("rollup config does not have rx buffer")?;

        let voucher_hashes = rollup_config
            .voucher_hashes
            .as_ref()
            .ok_or("rollup config does not have voucher hashes")?;

        Ok(RollupConfig {
            input_metadata: input_metadata.clone(),
            notice_hashes: notice_hashes.clone(),
            rx_buffer: rx_buffer.clone(),
            voucher_hashes: voucher_hashes.clone(),
        })
    }
}

/// The machine client.
pub struct MachineClient {
    machine: client::JsonRpcCartesiMachineClient,
    rollup: Option<RollupConfig>,
}

impl MachineClient {
    /// Creates a connection with the machine.
    pub async fn connect(host: String, port: u16) -> Result<MachineClient, Box<dyn Error>> {
        let connection_string = format!("{}:{}", host, port);
        let machine = client::JsonRpcCartesiMachineClient::new(connection_string).await?;

        Ok(MachineClient {
            machine,
            rollup: None,
        })
    }

    /// Loads a DApp into the machine from a directory.
    pub async fn load(
        &mut self,
        directory: &Path,
        config: &MachineRuntimeConfig,
    ) -> Result<(), Box<dyn Error>> {
        let directory = directory
            .as_os_str()
            .to_str()
            .ok_or("cannot convert path to string")?;

        self.machine.load_machine(directory, config).await?;

        self.configure().await?;

        Ok(())
    }

    /// Starts the machine client without loading or creating a machine.
    pub async fn configure(&mut self) -> Result<(), Box<dyn Error>> {
        let machine_config = self.machine.get_initial_config().await?;
        let machine_config = interfaces::MachineConfig::from(&machine_config);

        let rollup_config = machine_config
            .rollup
            .ok_or("machine config does not have rollup config")?;

        self.rollup = Some(RollupConfig::unwrap_from(&rollup_config)?);

        Ok(())
    }

    /// Runs the machine feeding it with data.
    pub async fn advance(&mut self, data: AdvanceInput) -> Result<BreakReason, Box<dyn Error>> {
        loop {
            self.machine.reset_iflags_y().await?;
            self.feed_advance_input(data.clone()).await?;
            let result = self.step().await?;
            if let BreakReason::YieldManual(reason) = result {
                if reason == Reason::Rejected {
                    self.rollback().await?;
                }
                self.snapshot().await?;
            } else if BreakReason::YieldAutomatic == result {
                continue
            }
            return Ok(result);
        }
    }

    /// Destroys the machine.
    pub async fn destroy(&mut self) -> Result<(), Box<dyn Error>> {
        self.machine.destroy().await?;
        Ok(())
    }

    /// Shutdown the server
    pub async fn shutdown(&mut self) -> Result<(), Box<dyn Error>> {
        self.machine.shutdown().await?;
        Ok(())
    }
}

impl MachineClient {
    async fn snapshot(&mut self) -> Result<(), Box<dyn Error>> {
        // snapshot method is not defined in the grpc interface!
        Ok(())
    }

    async fn rollback(&mut self) -> Result<(), Box<dyn Error>> {
        // rollback method is not defined in the grpc interface!
        Ok(())
    }

    async fn feed_advance_input(&mut self, data: AdvanceInput) -> Result<(), Box<dyn Error>> {
        let config = self.rollup.clone().ok_or("cannot find rollup config")?;

        self.replace_memory_range(&config.input_metadata).await?;
        self.load_memory_range(&config.input_metadata, data.metadata.encode())
            .await?;

        self.replace_memory_range(&config.rx_buffer).await?;
        self.load_memory_range(&config.rx_buffer, encode_string(data.data))
            .await?;

        self.replace_memory_range(&config.voucher_hashes).await?;
        self.replace_memory_range(&config.notice_hashes).await?;

        Ok(())
    }

    async fn read_htif_tohost_data(&mut self) -> Result<u64, Box<dyn Error>> {
        let tohost = self.machine.read_csr("htif_tohost".to_string()).await?;
        Ok((tohost & HTIF_DATA_MASK) >> HTIF_DATA_SHIFT)
    }

    async fn read_htif_tohost_cmd(&mut self) -> Result<u64, Box<dyn Error>> {
        let tohost = self.machine.read_csr("htif_tohost".to_string()).await?;
        Ok((tohost & HTIF_CMD_MASK) >> HTIF_CMD_SHIFT)
    }

    async fn get_yield_reason(&mut self) -> Result<(Option<Cmd>, Option<Reason>), Box<dyn Error>> {
        let tohost_cmd = self.read_htif_tohost_cmd().await?;
        let tohost_reason = self.read_htif_tohost_data().await? >> 32;
        Ok((Cmd::try_from(tohost_cmd).ok(), Reason::try_from(tohost_reason).ok()))
    }

    async fn step(&mut self) -> Result<BreakReason, Box<dyn Error>> {
        self.machine.run(u64::MAX).await?;

        if self.machine.read_iflags_h().await? {
            let data = self.read_htif_tohost_data().await? >> 1;
            return Ok(BreakReason::Halt(data as usize));
        } else if self.machine.read_iflags_y().await? {
            let reason = self.get_yield_reason().await?.1;
            return Ok(BreakReason::YieldManual(reason.unwrap()));
        } else if self.machine.read_iflags_x().await? {
            return Ok(BreakReason::YieldAutomatic);
        } else {
            return Ok(BreakReason::Limit);
        }
    }

    async fn replace_memory_range(
        &mut self,
        config: &interfaces::MemoryRangeConfig,
    ) -> Result<bool, cartesi_machine_json_rpc::client::Error> {
        self.machine.replace_memory_range(config.clone()).await
    }

    async fn load_memory_range(
        &mut self,
        config: &interfaces::MemoryRangeConfig,
        data: Vec<u8>,
    ) -> Result<bool, cartesi_machine_json_rpc::client::Error> {
        let mut address = config.start.unwrap();
        let chunk_len = 1024 * 1024;
        for chunk in data.chunks(chunk_len) {
            self.machine
                .write_memory(address, STANDARD.encode(chunk.to_vec()))
                .await?;
            address += 1024 * 1024;
        }
        Ok(true)
    }
}
