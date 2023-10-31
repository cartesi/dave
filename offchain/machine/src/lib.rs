use async_mutex::Mutex;
use async_trait::async_trait;
use cartesi_machine_json_rpc::client::{
    AccessLogType, AccessType, JsonRpcCartesiMachineClient, MachineRuntimeConfig,
};
use cryptography::Digest;
use sha3::{Digest as Sha3Digest, Keccak256};
use std::sync::Arc;

#[async_trait]
pub trait CartesiMachine {
    type State;

    async fn get_logs(
        path: &str,
        cycle: u64,
        ucycle: u64,
    ) -> Result<String, Box<dyn std::error::Error>>;
    async fn state(&self) -> Result<Self::State, Box<dyn std::error::Error>>;
    async fn run(&mut self, cycle: u64) -> Result<(), Box<dyn std::error::Error>>;
    async fn run_uarch(&mut self, ucycle: u64) -> Result<(), Box<dyn std::error::Error>>;
    async fn increment_uarch(&mut self) -> Result<(), Box<dyn std::error::Error>>;
    async fn ureset(&mut self) -> Result<(), Box<dyn std::error::Error>>;
}

pub struct CanonicalCartesiMachine {
    machine_client: Arc<Mutex<JsonRpcCartesiMachineClient>>,
    cycle: u64,
    ucycle: u64,
    start_cycle: u64,
    initial_hash: Digest,
}

pub const LEVELS: usize = 3;
pub const MAX_CYCLE: u8 = 63;

pub const LOG2STEP: [u32; 3] = [31, 16, 0];
pub const HEIGHTS: [u8; 3] = [32, 15, 16];

pub const LOG2_UARCH_SPAN: u64 = 16;
pub const UARCH_SPAN: u64 = 2 ^ LOG2_UARCH_SPAN - 1;

pub const LOG2_EMULATOR_SPAN: u64 = 47;
pub const EMULATOR_SPAN: u64 = 2 ^ LOG2_EMULATOR_SPAN - 1;

#[async_trait]
impl CartesiMachine for CanonicalCartesiMachine {
    type State = MachineState;

    async fn get_logs(
        path: &str,
        cycle: u64,
        ucycle: u64,
    ) -> Result<String, Box<dyn std::error::Error>> {
        let mut machine = Self::new_from_path(path).await?;
        machine.run(cycle).await?;
        machine.run_uarch(ucycle).await?;

        if ucycle == UARCH_SPAN {
            let _ = machine.run_uarch(UARCH_SPAN).await;
            eprintln!("ureset, not implemented");
        }

        let access_log = AccessLogType {
            annotations: true,
            proofs: true,
        };
        let logs = machine
            .machine_client
            .lock()
            .await
            .step(&access_log, false)
            .await?;

        let mut encoded = Vec::new();

        for a in &logs.accesses {
            assert_eq!(a.log2_size, 3);
            if a.r#type == AccessType::Read {
                encoded.push(a.read_data.clone());
            }

            encoded.push(hex::decode(a.proof.target_hash.clone()).unwrap());

            let decoded_sibling_hashes: Result<Vec<Vec<u8>>, hex::FromHexError> = a
                .proof
                .sibling_hashes
                .iter()
                .map(|hex_string| hex::decode(hex_string))
                .collect();

            let mut decoded = decoded_sibling_hashes?;
            decoded.reverse();
            encoded.extend_from_slice(&decoded.clone());

            assert_eq!(
                ver(
                    hex::decode(a.proof.target_hash.clone()).unwrap(),
                    a.address,
                    decoded.clone()
                ),
                hex::decode(a.proof.root_hash.clone()).unwrap()
            );
        }
        let data: Vec<u8> = encoded.iter().cloned().flatten().collect();

        let hex_data = hex::encode(data);

        Ok(format!("\"{}\"", hex_data))
    }

    async fn state(&self) -> Result<Self::State, Box<dyn std::error::Error>> {
        let root_hash = self.machine_client.lock().await.get_root_hash().await?;
        let halted = self.machine_client.lock().await.read_iflags_h().await?;
        let uhalted = self
            .machine_client
            .lock()
            .await
            .read_uarch_halt_flag()
            .await?;

        Ok(MachineState {
            root_hash: Digest::from_data(&root_hash),
            halted,
            uhalted,
        })
    }

    async fn run(&mut self, cycle: u64) -> Result<(), Box<dyn std::error::Error>> {
        assert!(self.cycle <= cycle);
        let combined_cycle: u128 = u128::from(self.start_cycle) + u128::from(cycle);
        let physical_cycle = u128::min(2 ^ 64 - 1, combined_cycle) as u64;
        let machine_client = Arc::clone(&self.machine_client);
        while !(machine_client.lock().await.read_iflags_h().await?
            || machine_client
                .lock()
                .await
                .read_csr("mcycle".to_string())
                .await?
                == physical_cycle)
        {
            machine_client.lock().await.run(physical_cycle).await?;
        }
        self.cycle = cycle;

        Ok(())
    }

    async fn run_uarch(&mut self, ucycle: u64) -> Result<(), Box<dyn std::error::Error>> {
        assert!(self.ucycle <= ucycle);
        self.machine_client.lock().await.run_uarch(ucycle).await?;
        self.ucycle = ucycle;

        Ok(())
    }

    async fn increment_uarch(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        self.machine_client
            .lock()
            .await
            .run_uarch(self.ucycle + 1)
            .await?;
        self.ucycle = self.ucycle + 1;

        Ok(())
    }

    async fn ureset(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        self.machine_client.lock().await.reset_uarch_state().await?;
        self.cycle += 1;
        self.ucycle = 0;

        Ok(())
    }
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

impl CanonicalCartesiMachine {
    async fn new_from_path(
        path: &str,
    ) -> Result<CanonicalCartesiMachine, Box<dyn std::error::Error>> {
        let machine_client = Arc::new(Mutex::new(
            JsonRpcCartesiMachineClient::new("http://127.0.0.1:50051".into()).await?,
        ));
        machine_client
            .lock()
            .await
            .load_machine(path, &MachineRuntimeConfig::default())
            .await?;
        let start_cycle = machine_client
            .lock()
            .await
            .read_csr("mcycle".into())
            .await?;
        // Machine can never be advanced on the micro arch.
        // Validators must verify this first
        assert_eq!(
            machine_client
                .lock()
                .await
                .read_csr("uarch_cycle".into())
                .await?,
            0
        );
        let root_hash = machine_client.lock().await.get_root_hash().await?;

        Ok(Self {
            machine_client,
            cycle: 0,
            ucycle: 0,
            start_cycle,
            initial_hash: Digest::from_data(&root_hash),
        })
    }
}

pub struct MachineState {
    pub root_hash: Digest,
    pub halted: bool,
    pub uhalted: bool,
}
