//! Module for communication with the Cartesi machine using RPC.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use cartesi_machine_json_rpc::client::{
    AccessLog, AccessLogType, AccessType, Error, JsonRpcCartesiMachineClient, MachineRuntimeConfig,
};
use sha3::{Digest as Keccak256Digest, Keccak256};

use crate::{machine::constants, merkle::Digest, utils::arithmetic};

#[derive(Debug)]
pub struct MachineState {
    pub root_hash: Digest,
    pub halted: bool,
    pub uhalted: bool,
}

impl std::fmt::Display for MachineState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "{{root_hash = {:?}, halted = {}, uhalted = {}}}",
            self.root_hash, self.halted, self.uhalted
        )
    }
}

pub type MachineProof = Vec<u8>;

pub struct MachineRpc {
    rpc_client: JsonRpcCartesiMachineClient,
    root_hash: Digest,
    start_cycle: u64,
    cycle: u64,
    ucycle: u64,
}

impl MachineRpc {
    pub async fn new(json_rpc_url: &str, snapshot_path: &str) -> Result<Self, Error> {
        let rpc_client = JsonRpcCartesiMachineClient::new(json_rpc_url.to_string()).await?;

        rpc_client
            .load_machine(snapshot_path, &MachineRuntimeConfig::default())
            .await?;

        let root_hash = rpc_client.get_root_hash().await?;
        let start_cycle = rpc_client.read_csr("mcycle".to_string()).await?;

        // Machine can never be advanced on the micro arch.
        // Validators must verify this first
        assert_eq!(rpc_client.read_csr("uarch_cycle".to_string()).await?, 0);

        Ok(MachineRpc {
            rpc_client,
            start_cycle,
            root_hash: Digest::from(root_hash),
            cycle: 0,
            ucycle: 0,
        })
    }

    pub fn root_hash(&self) -> Digest {
        self.root_hash
    }

    // pub async fn get_logs(&self, cycle: u64, ucycle: u64) -> Result<String, Error> {
    pub async fn get_logs(&mut self, cycle: u64, ucycle: u64) -> Result<MachineProof, Error> {
        self.run(cycle).await?;
        self.run_uarch(ucycle).await?;

        if ucycle == constants::UARCH_SPAN {
            self.run_uarch(constants::UARCH_SPAN).await?;
            eprintln!("ureset, not implemented");
        }

        let access_log = AccessLogType {
            annotations: true,
            proofs: true,
        };
        let logs = self.rpc_client.step(&access_log, false).await?;

        // let mut encoded = Vec::new();

        // for a in &logs.accesses {
        //     assert_eq!(a.log2_size, 3);
        //     if a.r#type == AccessType::Read {
        //         encoded.push(a.read_data.clone());
        //     }

        //     encoded.push(STANDARD.decode(a.proof.target_hash.clone()).unwrap());

        //     let decoded_sibling_hashes: Result<Vec<Vec<u8>>, hex::FromHexError> =
        //         a.proof.sibling_hashes.iter().map(STANDARD.decode).collect();

        //     let mut decoded = decoded_sibling_hashes?;
        //     decoded.reverse();
        //     encoded.extend_from_slice(&decoded.clone());

        //     assert_eq!(
        //         ver(
        //             STANDARD.decode(a.proof.target_hash.clone()).unwrap(),
        //             a.address,
        //             decoded.clone()
        //         ),
        //         STANDARD.decode(a.proof.root_hash.clone()).unwrap()
        //     );
        // }
        // let data: Vec<u8> = encoded.iter().flatten().cloned().collect();

        // let hex_data = hex::encode(data);

        // Ok(format!("\"{}\"", hex_data))

        Ok(encode_access_log(&logs))
    }

    pub async fn generate_proof(&mut self, cycle: u64, ucycle: u64) -> Result<MachineProof, Error> {
        self.rpc_client.run(cycle).await?;
        self.rpc_client.run_uarch(ucycle).await?;

        if ucycle == constants::UARCH_SPAN {
            self.rpc_client.run_uarch(constants::UARCH_SPAN).await?;
            // TODO: log warn/error or retrn error.
            eprintln!("ureset, not implemented");
        }

        let log_type = AccessLogType {
            annotations: true,
            proofs: true,
        };
        let log = self.rpc_client.step(&log_type, false).await?;

        Ok(encode_access_log(&log))
    }

    pub async fn run(&mut self, cycle: u64) -> Result<(), Error> {
        assert!(self.cycle <= cycle);

        let physical_cycle = add_and_clamp(self.start_cycle, cycle);

        loop {
            let halted = self.rpc_client.read_iflags_h().await?;
            if halted {
                break;
            }

            let mcycle = self.rpc_client.read_csr("mcycle".to_string()).await?;
            if mcycle == physical_cycle {
                break;
            }

            self.rpc_client.run(physical_cycle).await?;
        }

        self.cycle = cycle;

        Ok(())
    }

    pub async fn run_uarch(&mut self, ucycle: u64) -> Result<(), Error> {
        assert!(
            self.ucycle <= ucycle,
            "{}",
            format!("{}, {}", self.ucycle, ucycle)
        );

        self.rpc_client.run_uarch(ucycle).await?;
        self.ucycle = ucycle;

        Ok(())
    }

    pub async fn increment_uarch(&mut self) -> Result<(), Error> {
        self.rpc_client.run_uarch(self.ucycle + 1).await?;
        self.ucycle += 1;
        Ok(())
    }

    pub async fn ureset(&mut self) -> Result<(), Error> {
        self.rpc_client.reset_uarch_state().await?;
        self.cycle += 1;
        self.ucycle = 0;
        Ok(())
    }

    pub async fn machine_state(&self) -> Result<MachineState, Error> {
        let root_hash = self.rpc_client.get_root_hash().await?;
        let halted = self.rpc_client.read_iflags_h().await?;
        let uhalted = self.rpc_client.read_uarch_halt_flag().await?;

        Ok(MachineState {
            root_hash: Digest::new(root_hash),
            halted,
            uhalted,
        })
    }

    pub async fn write_memory(&self, address: u64, data: String) -> Result<bool, Error> {
        self.rpc_client.write_memory(address, data).await
    }

    pub fn position(&self) -> (u64, u64) {
        (self.cycle, self.ucycle)
    }
}

fn add_and_clamp(x: u64, y: u64) -> u64 {
    if x < arithmetic::max_uint(64) - y {
        x + y
    } else {
        arithmetic::max_uint(64)
    }
}

fn encode_access_log(log: &AccessLog) -> Vec<u8> {
    let mut encoded = Vec::new();

    for a in log.accesses.iter() {
        assert_eq!(a.log2_size, 3);
        if a.r#type == AccessType::Read {
            encoded.push(a.read_data.clone());
        }

        encoded.push(
            STANDARD
                .decode(base64_hash_to_string(&a.proof.target_hash))
                .unwrap(),
        );

        let mut decoded_sibling_hashes: Vec<Vec<u8>> = a
            .proof
            .sibling_hashes
            .iter()
            .map(base64_hash_to_string)
            .map(|s| STANDARD.decode(s).unwrap())
            .collect();

        decoded_sibling_hashes.reverse();
        encoded.extend_from_slice(&decoded_sibling_hashes.clone());

        assert_eq!(
            ver(
                STANDARD
                    .decode(base64_hash_to_string(&a.proof.target_hash))
                    .unwrap(),
                a.address,
                decoded_sibling_hashes.clone()
            ),
            STANDARD
                .decode(base64_hash_to_string(&a.proof.root_hash))
                .unwrap()
        );
    }

    encoded.iter().flatten().cloned().collect()
}

fn base64_hash_to_string(base64_hash: &cartesi_machine_json_rpc::interfaces::Base64Hash) -> String {
    let mut res = base64_hash.clone();

    if res.ends_with('\n') {
        res.pop();
    }

    res
}

fn ver(mut t: Vec<u8>, p: u64, s: Vec<Vec<u8>>) -> Vec<u8> {
    let stride = p >> 3;
    for (k, v) in s.iter().enumerate() {
        if (stride >> k) % 2 == 0 {
            let mut keccak = Keccak256::new();
            keccak.update(&t);
            keccak.update(v);
            t = keccak.finalize().to_vec();
        } else {
            let mut keccak = Keccak256::new();
            keccak.update(v);
            keccak.update(&t);
            t = keccak.finalize().to_vec();
        }
    }
    t
}

#[derive(Clone)]
pub struct MachineFactory {
    rpc_host: String,

    #[allow(dead_code)]
    rpc_port: u32,

    rpc_client: JsonRpcCartesiMachineClient,
}

impl MachineFactory {
    pub async fn new(rpc_host: String, rpc_port: u32) -> Result<Self, Error> {
        let rpc_url = format!("{}:{}", rpc_host, rpc_port);
        let rpc_client = JsonRpcCartesiMachineClient::new(rpc_url).await?;
        Ok(Self {
            rpc_host,
            rpc_port,
            rpc_client,
        })
    }

    pub async fn create_machine(&self, snapshot_path: &str) -> Result<MachineRpc, Error> {
        let fork_rpc_url = self.rpc_client.fork().await?;
        let fork_rpc_port = fork_rpc_url.split(':').last().unwrap();
        let fork_rpc_url = format!("{}:{}", self.rpc_host, fork_rpc_port);
        let machine_rpc = MachineRpc::new(fork_rpc_url.as_str(), snapshot_path).await?;

        Ok(machine_rpc)
    }
}
