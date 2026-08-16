use super::epoch_data::EpochData;
use super::machine_error::Result;
use cartesi_machine::{
    config::runtime::RuntimeConfig,
    constants::rollup::LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
    machine::Machine,
    types::access_proof::{AccessLog, AccessType},
    types::{LogType, cmio::CmioResponseReason},
};
use cartesi_rollups_prt_node::arithmetic;
use cartesi_rollups_prt_node::engine::constants::{
    BARCH_MASK_TO_INPUT, INPUT_MASK_TO_EPOCH, LOG2_INPUT_WINDOW_SPAN, UARCH_MASK_TO_BARCH,
};
use cartesi_rollups_prt_node::merkle::Digest;
use log::trace;

use alloy::primitives::U256;
use std::path::PathBuf;

#[derive(Debug)]
pub struct MachineState {
    pub root_hash: Digest,
    pub halted: bool,
    pub yielded: bool,
    pub uhalted: bool,
}

impl std::fmt::Display for MachineState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "{{root_hash = {}, halted = {}, yielded = {}, uhalted = {}}}",
            self.root_hash.to_hex(),
            self.halted,
            self.yielded,
            self.uhalted,
        )
    }
}

impl MachineState {
    pub fn from_current_machine_state(machine: &mut MachineInstance) -> Result<MachineState> {
        let root_hash = machine.root_hash()?;
        Ok(MachineState {
            root_hash,
            halted: machine.is_halted()?,
            yielded: machine.is_yielded()?,
            uhalted: machine.is_uarch_halted()?,
        })
    }
}

pub struct MachineInstance {
    machine: Machine,
    _start_cycle: u64,
    pub input_count: u64,
    pub cycle: u64,
    pub ucycle: u64,
    pub snapshot_path: PathBuf,
}

impl MachineInstance {
    pub fn new_from_path(path: &str) -> Result<Self> {
        let runtime_config = RuntimeConfig::quiet_console();
        let path = PathBuf::from(path);
        let mut machine = Machine::load(&path, &runtime_config)?;

        let _start_cycle = machine.mcycle()?;

        // Machine can never be advanced on the micro arch.
        // Validators must verify this first
        assert_eq!(machine.ucycle()?, 0);

        Ok(MachineInstance {
            machine,
            _start_cycle,
            input_count: 0,
            cycle: 0,
            ucycle: 0,
            snapshot_path: path,
        })
    }

    /*
        pub fn take_snapshot(&mut self, base_cycle: u64, db: &EpochData) -> Result<()> {
            let mask = arithmetic::max_uint(
                cartesi_machine::constants::rollup::LOG2_MAX_MCYCLES_PER_ADVANCE_STATE,
            );
            if db.handle_rollups && ((base_cycle & mask) == 0) && !self.is_yielded()? {
                // don't snapshot a machine state that's freshly fed with input without advance
                return Ok(());
            }

            let snapshot_path = db.work_path.join(format!("{}", base_cycle));
            if !snapshot_path.exists() {
                self.machine.store(&snapshot_path)?;
            }
            Ok(())
        }

        // load inner machine with snapshot, update cycle, keep everything else the same
        pub fn load_snapshot(&mut self, snapshot_path: &Path, snapshot_cycle: u64) -> Result<()> {
            debug!("load snapshot from {}", snapshot_path.display());
            let runtime_config = RuntimeConfig::quiet_console();
            let mut machine = Machine::load(Path::new(snapshot_path), &runtime_config)?;

            let cycle = machine.mcycle()?;
            debug!("cycle: {}, start_cycle: {}", cycle, self.start_cycle);

            // Machine can not go backward behind the initial machine
            assert!(cycle >= self.start_cycle);
            self.cycle = snapshot_cycle;

            assert_eq!(machine.ucycle()?, 0);

            self.machine = machine;

            Ok(())
        }
    */

    pub fn advance_rollups(&mut self, meta_cycle: U256, db: &EpochData) -> Result<()> {
        assert!(self.is_yielded()?);

        let input_count = u64::try_from(meta_cycle >> LOG2_INPUT_WINDOW_SPAN)
            .expect("input count too big to fit in u64");
        let cycle = {
            let c =
                (meta_cycle >> LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) & U256::from(BARCH_MASK_TO_INPUT);
            u64::try_from(c).expect("cycle too big to fit in u64")
        };
        let ucycle = u64::try_from(meta_cycle & U256::from(UARCH_MASK_TO_BARCH))
            .expect("ucycle too big to fit in u64");

        let snapshot_path = db.work_path.join(self.root_hash()?.to_hex());
        if !snapshot_path.exists() {
            self.machine.store(&snapshot_path)?;
        }
        self.snapshot_path = snapshot_path;

        while self.input_count < input_count {
            // snapshot the machine state before feeding the input

            self.feed_next_input(db)?;

            loop {
                self.run(u64::MAX)?;
                if self.is_halted()? | self.is_yielded()? {
                    break;
                }
            }
            assert!(!self.is_halted()?);

            self.input_count += 1;

            // `cycle` counts big cycles within the current input window;
            // run(u64::MAX) poisoned it, and the next window starts a
            // fresh count. Without this, any commitment build or proof
            // whose target lies past window 0 overflows the counter.
            self.cycle = 0;
            self.ucycle = 0;
        }
        assert!(self.input_count == input_count);

        if cycle == 0 && ucycle == 0 {
            return Ok(());
        }

        self.feed_next_input(db)?;

        self.run(cycle)?;
        self.run_uarch(ucycle)?;

        Ok(())
    }

    pub fn new_rollups_advanced_until(
        path: &str,
        meta_cycle: U256,
        db: &EpochData,
    ) -> Result<MachineInstance> {
        Self::new_rollups_resumed_until(path, 0, meta_cycle, db)
    }

    /// Advances from a machine stored at input boundary `start_input`
    /// (a snapshot-source answer; 0 is the epoch start) instead of
    /// replaying the whole prefix.
    pub fn new_rollups_resumed_until(
        path: &str,
        start_input: u64,
        meta_cycle: U256,
        db: &EpochData,
    ) -> Result<MachineInstance> {
        let input_count = u64::try_from(meta_cycle >> LOG2_INPUT_WINDOW_SPAN).unwrap();
        assert!(input_count <= INPUT_MASK_TO_EPOCH);
        assert!(start_input <= input_count, "snapshot past the target");

        let mut machine = MachineInstance::new_from_path(path)?;
        assert!(machine.is_yielded()?);
        machine.input_count = start_input;

        machine.advance_rollups(meta_cycle, db)?;
        Ok(machine)
    }

    pub fn feed_next_input(&mut self, db: &EpochData) -> Result<()> {
        assert!(self.is_yielded()?);
        let input = db.input(self.input_count);
        let root_hash = self.root_hash()?;
        let new_snapshot_path = db.work_path.join(root_hash.to_hex());
        if let Some(input_bin) = input {
            if !new_snapshot_path.exists() {
                self.machine.store(&new_snapshot_path)?;
                if self.snapshot_path.exists() {
                    std::fs::remove_dir_all(&self.snapshot_path)?;
                }
            }

            self.snapshot_path = new_snapshot_path;
            let revert_root = root_hash.into();
            self.machine.send_cmio_response(
                CmioResponseReason::Advance,
                &input_bin,
                Some(&revert_root),
            )?;
        }
        Ok(())
    }

    pub fn state(&mut self) -> Result<MachineState> {
        MachineState::from_current_machine_state(self)
    }

    pub fn root_hash(&mut self) -> Result<Digest> {
        Ok(self.machine.root_hash()?.into())
    }

    pub fn is_halted(&mut self) -> Result<bool> {
        Ok(self.machine.iflags_h()?)
    }

    pub fn is_yielded(&mut self) -> Result<bool> {
        Ok(self.machine.iflags_y()?)
    }

    pub fn is_uarch_halted(&mut self) -> Result<bool> {
        Ok(self.machine.uarch_halt_flag()?)
    }

    pub fn physical_cycle(&mut self) -> Result<u64> {
        Ok(self.machine.mcycle()?)
    }

    pub fn restore_rejected(&mut self) -> Result<()> {
        // A reset log substitutes the canonical root, but the physical
        // machine must still be reloaded from its pre-input snapshot.
        assert!(self.is_yielded()?);

        // we check if the request is accepted
        // REJECTED only: exceptions and other terminal yields keep their
        // state.
        if self.machine.receive_cmio_request()?.reason()
            == cartesi_machine::constants::cmio::tohost::manual::RX_REJECTED
        {
            trace!("Reject input,revert to previous snapshot");
            let runtime_config = RuntimeConfig::quiet_console();

            self.machine = Machine::load(&self.snapshot_path, &runtime_config)?;
        }
        Ok(())
    }

    pub fn run_uarch(&mut self, ucycle: u64) -> Result<()> {
        assert!(
            self.ucycle <= ucycle,
            "{}",
            format!("{}, {}", self.ucycle, ucycle)
        );

        self.machine.run_uarch(ucycle)?;
        self.ucycle = ucycle;

        Ok(())
    }

    // Runs to the `cycle` directly and returns the machine state after the run
    pub fn run(&mut self, cycle: u64) -> Result<MachineState> {
        assert!(self.cycle <= cycle);

        let target_physical_cycle =
            arithmetic::add_and_clamp(self.physical_cycle()?, cycle - self.cycle);

        loop {
            self.machine.run(target_physical_cycle)?;

            let halted = self.is_halted()?;
            if halted {
                panic!("run break with halt");
            }

            if self.is_yielded()? {
                trace!("run break with yield");
                // if it is not reverted, we store the new snapshot and remove the old one
                self.restore_rejected()?;

                break;
            }

            if self.physical_cycle()? == target_physical_cycle {
                trace!("run break with meeting physical cycle");
                break;
            }
        }

        self.cycle = cycle;

        self.state()
    }

    pub fn increment_uarch(&mut self) -> Result<MachineState> {
        self.machine.run_uarch(self.ucycle + 1)?;
        self.ucycle += 1;
        self.state()
    }

    pub fn ureset(&mut self) -> Result<MachineState> {
        self.machine.reset_uarch()?;
        self.cycle += 1;
        self.ucycle = 0;
        if self.is_yielded()? {
            self.restore_rejected()?;
        }
        self.state()
    }

    fn encode_access_logs(logs: Vec<&AccessLog>) -> Vec<u8> {
        let mut encoded: Vec<Vec<u8>> = Vec::new();

        for log in logs.into_iter() {
            for a in log.accesses.iter() {
                if a.log2_size == 3 {
                    encoded.push(
                        a.read
                            .clone()
                            .expect("word access must carry its read value"),
                    );
                } else if matches!(&a.r#type, AccessType::Read) {
                    let read = a
                        .read
                        .clone()
                        .expect("region read must carry its raw value");
                    assert_eq!(read.len(), 32, "chain region reads are one bytes32 value");
                    encoded.push(read);
                    encoded.push(a.read_hash.to_vec());
                } else {
                    encoded.push(a.read_hash.to_vec());
                }

                let decoded_siblings: Vec<Vec<u8>> = a
                    .sibling_hashes
                    .clone()
                    .unwrap()
                    .iter()
                    .map(|h| h.to_vec())
                    .collect();
                encoded.extend_from_slice(&decoded_siblings);
            }
        }

        encoded.iter().flatten().cloned().collect()
    }

    fn encode_da(input_bin: &[u8]) -> Vec<u8> {
        let input_size_be = (input_bin.len() as u64).to_be_bytes().to_vec();
        let mut da_proof = input_size_be;
        da_proof.extend_from_slice(input_bin);
        da_proof
    }

    fn get_logs_rollups(
        path: &str,
        start_input: u64,
        agree_hash: Digest,
        meta_cycle: U256,
        db: &EpochData,
    ) -> Result<(Vec<u8>, Digest)> {
        let input_mask = (U256::ONE << LOG2_INPUT_WINDOW_SPAN) - U256::ONE;
        let big_step_mask = UARCH_MASK_TO_BARCH;

        assert!(((meta_cycle >> LOG2_INPUT_WINDOW_SPAN) & !input_mask).is_zero());

        let meta_cycle_u128 =
            u128::try_from(meta_cycle).expect("meta_cycle is too large to fit in u128");
        let input_count = (meta_cycle_u128 >> LOG2_INPUT_WINDOW_SPAN) as u64;

        let mut logs = Vec::new();

        let mut machine =
            MachineInstance::new_rollups_resumed_until(path, start_input, meta_cycle, db)?;
        assert_eq!(machine.state()?.root_hash, agree_hash);

        if (meta_cycle & input_mask).is_zero() {
            let input = db.input(input_count);
            let da_proof;
            let cmio_log;

            if let Some(input_bin) = input {
                let revert_root = machine.machine.root_hash()?;
                cmio_log = machine.machine.log_send_cmio_response(
                    CmioResponseReason::Advance,
                    &input_bin,
                    &revert_root,
                    LogType::default(),
                )?;

                logs.push(&cmio_log);
                da_proof = Self::encode_da(&input_bin);
            } else {
                da_proof = Self::encode_da(&[]);
            }

            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);

            let cmio_step_proof = Self::encode_access_logs(logs);
            let proof = [da_proof, cmio_step_proof].concat();
            Ok((proof, machine.state()?.root_hash))
        } else if ((meta_cycle_u128 + 1) & (big_step_mask as u128)) == 0 {
            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);
            let ureset_log = machine.machine.log_reset_uarch(LogType::default())?;
            logs.push(&ureset_log);
            let step_reset_proof = Self::encode_access_logs(logs);

            // The proven transition ends on the restored checkpoint;
            // report that state, not the discarded rejected one.
            if machine.is_yielded()? {
                machine.restore_rejected()?;
            }

            Ok((step_reset_proof, machine.state()?.root_hash))
        } else {
            let uarch_step_log = machine.machine.log_step_uarch(LogType::default())?;
            logs.push(&uarch_step_log);
            Ok((Self::encode_access_logs(logs), machine.state()?.root_hash))
        }
    }

    /// `path` and `start_input` come from the snapshot source: the
    /// nearest input-boundary machine at or before the disputed cycle.
    pub fn get_logs(
        path: &str,
        start_input: u64,
        agree_hash: Digest,
        meta_cycle: U256,
        db: &EpochData,
    ) -> Result<(Vec<u8>, Digest)> {
        let (proofs, next_hash);

        let result = Self::get_logs_rollups(path, start_input, agree_hash, meta_cycle, db)?;
        proofs = result.0;
        next_hash = result.1;

        Ok((proofs, next_hash))
    }

    pub fn position(&mut self) -> Result<(u64, u64)> {
        Ok((self.cycle, self.ucycle))
    }
}
