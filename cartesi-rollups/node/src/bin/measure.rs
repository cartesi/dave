// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The measurement harness (docs/plans/node-refactor.md, workstream 1):
//! times the operations dispute deadlines depend on and regenerates
//! docs/measurements/measurements.md. Run through `just measure`; committing a
//! regenerated table is a reviewed act, fixtures-style.

use anyhow::Result;
use clap::{Parser, ValueEnum};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use alloy::primitives::{Address, U256};
use alloy::sol_types::SolCall;
use cartesi_rollups_prt_node::engine::{DisputeSource, MachineStf, Quartet, Stf, fold_runs};
use cartesi_rollups_prt_node::merkle::Digest;
use cartesi_rollups_prt_node::storage::{Input as StorageInput, InputId, Storage};

/// Five minutes of clock per tree height unit: the deployment's
/// matchEffort formula (prt/contracts/script/Deployment.s.sol,
/// _getMatchEffortInSeconds). Every replay a bisection move needs must
/// fit well inside this.
const PER_MOVE_BUDGET_SECS: u64 = 300;

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum BaselineProfile {
    Echo,
    Stress,
}

impl BaselineProfile {
    fn regeneration_command(self, full: bool) -> &'static str {
        match (self, full) {
            (Self::Echo, false) => "just measure",
            (Self::Echo, true) => "just measure --full",
            (Self::Stress, false) => "just measure-stress",
            (Self::Stress, true) => "just measure-stress --full",
        }
    }

    fn caveat(self) -> &'static str {
        match self {
            Self::Echo => {
                "Caveats: the echo workload is idle-dominated (it yields almost\n\
                 immediately), so span replays here exercise the idle-churn path.\n\
                 Use `just measure-stress --full` for the instruction-heavy synthetic\n\
                 sample."
            }
            Self::Stress => {
                "Caveats: the stress workload is a synthetic SHA-256 burn with high\n\
                 instruction density. Its rows are workload-specific samples, not\n\
                 protocol worst cases or a representative application average."
            }
        }
    }
}

#[derive(Parser)]
struct Args {
    /// Machine template image (built by `just setup-local`).
    #[arg(long, default_value = "test/programs/echo/machine-image")]
    machine: PathBuf,

    /// Workload profile used to label baseline report provenance and caveats.
    #[arg(long, value_enum, default_value = "echo")]
    profile: BaselineProfile,

    /// Write the report here instead of stdout.
    #[arg(long)]
    out: Option<PathBuf>,

    /// Include the level-1 root replay: a full 2^44-ustep window span,
    /// potentially minutes of machine time.
    #[arg(long)]
    full: bool,

    /// Derive tournament level constants (workstream 8 of
    /// docs/plans/node-refactor.md) instead of the baseline report.
    /// Needs a compute-heavy workload (the stress image).
    #[arg(long)]
    constants: bool,

    /// Accepted slowdown of the root-level eager commitment
    /// (docs/dimensioning.md: an aggregate authored by the trusted
    /// app, so priced at average density).
    #[arg(long, default_value_t = 2.0)]
    root_slowdown: f64,

    /// Inner tournament timeouts (minutes) to derive for.
    #[arg(long, value_delimiter = ',', default_values_t = vec![60u64, 30])]
    inner_timeout_minutes: Vec<u64>,

    /// Pragmatic stand-in for a reference machine: measured throughput
    /// is divided by this before any derivation, and the factor is
    /// printed into the output so results carry their caveat.
    #[arg(long, default_value_t = 2.0)]
    hardware_slack: f64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let image = args.machine.canonicalize()?;
    let scratch_root = std::env::temp_dir().join(format!("dave-measure-{}", std::process::id()));
    fs::create_dir_all(&scratch_root)?;

    if args.constants {
        let mut report = String::new();
        constants_report(&mut report, &args, &image, &scratch_root)?;
        let _ = fs::remove_dir_all(&scratch_root);
        match args.out {
            Some(path) => {
                fs::write(&path, &report)?;
                eprintln!("wrote {}", path.display());
            }
            None => print!("{report}"),
        }
        return Ok(());
    }

    let mut report = String::new();
    // Reports record the workload path as given, not canonicalized:
    // absolute session-worktree paths rotted in committed baselines.
    preamble(&mut report, &args.machine, args.profile, args.full)?;
    bench_level0_fold(&mut report)?;
    bench_snapshot(&mut report, &image, &scratch_root)?;
    bench_clone_loop(&mut report, &image, &scratch_root)?;
    bench_atoms(&mut report, &image, &scratch_root)?;
    let quartets = bench_quartets(&mut report, &image, &scratch_root, args.full)?;
    budget(&mut report, &quartets)?;

    let _ = fs::remove_dir_all(&scratch_root);
    match args.out {
        Some(path) => {
            fs::write(&path, &report)?;
            eprintln!("wrote {}", path.display());
        }
        None => print!("{report}"),
    }
    Ok(())
}

fn preamble(report: &mut String, image: &Path, profile: BaselineProfile, full: bool) -> Result<()> {
    writeln!(report, "# Measurement baseline")?;
    writeln!(report)?;
    writeln!(
        report,
        "Generated by `{}` (cartesi-rollups/node/src/bin/measure.rs);\n\
         regenerate on the machine that matters and commit the diff. One\n\
         sample per operation - treat entries as order-of-magnitude until\n\
         the harness grows repetitions and percentiles.",
        profile.regeneration_command(full),
    )?;
    writeln!(report)?;
    writeln!(report, "Workload: `{}`.", image.display())?;
    writeln!(report, "{}", profile.caveat())?;
    writeln!(
        report,
        "Not yet measured: get_logs probe, RSS per worker, disk breakdown\n\
         per epoch (logged node-side at roll).{}",
        if full {
            ""
        } else {
            "\nLevel-1 root replay skipped (run with --full)."
        }
    )?;
    writeln!(report)?;
    Ok(())
}

/// Worst-case folds: alternating distinct hashes, no adjacent-run
/// merging, tail-padded to one 2^24-leaf tier - the shape of the
/// frontier's top fold (window roots plus padding) and of the
/// per-window fold the runner pays at each record. The 1M-run row is
/// the OQ9 corner, now amortized one window per input instead of a
/// whole-epoch fold at every Hero construction.
fn bench_level0_fold(report: &mut String) -> Result<()> {
    writeln!(
        report,
        "## Level-0 fold (synthetic runs, one 2^24-leaf tier)"
    )?;
    writeln!(report)?;
    writeln!(report, "| runs | fold time |")?;
    writeln!(report, "|---:|---:|")?;
    const LOG2_LEAVES: u64 = 24; // window interior = top tree = 2^24
    for &count in &[1_000u64, 10_000, 100_000, 1_000_000] {
        let total: u64 = 1 << LOG2_LEAVES;
        let runs = (0..count).map(move |i| {
            let mut bytes = [0u8; 32];
            bytes[..8].copy_from_slice(&i.to_le_bytes());
            bytes[8] = 1;
            let repetitions = if i == count - 1 {
                total - (count - 1)
            } else {
                1
            };
            (Digest::from_digest(&bytes).expect("32 bytes"), repetitions)
        });
        let (_, elapsed) = timed(|| fold_runs(runs, LOG2_LEAVES))?;
        writeln!(report, "| {count} | {} |", fmt_duration(elapsed))?;
    }
    writeln!(report)?;
    Ok(())
}

fn bench_snapshot(report: &mut String, image: &Path, scratch_root: &Path) -> Result<()> {
    let (mut stf, load_template) =
        timed(|| MachineStf::load(image, scratch(scratch_root, "snap-load")?))?;
    let store_path = scratch_root.join("stored-machine");
    let (_, store) = timed(|| stf.store(&store_path))?;
    let (_, resume) =
        timed(|| MachineStf::resume(&store_path, scratch(scratch_root, "snap-resume")?))?;
    let size_mb = dir_size(&store_path)? as f64 / (1024.0 * 1024.0);

    writeln!(report, "## Snapshot store and load")?;
    writeln!(report)?;
    writeln!(report, "| operation | time |")?;
    writeln!(report, "|---|---:|")?;
    writeln!(
        report,
        "| load template | {} |",
        fmt_duration(load_template)
    )?;
    writeln!(report, "| store | {} |", fmt_duration(store))?;
    writeln!(report, "| resume from store | {} |", fmt_duration(resume))?;
    writeln!(report, "| stored size | {size_mb:.1} MB |")?;
    writeln!(report)?;
    Ok(())
}

/// The CoW clone loop (docs/plans/snapshots.md): the per-input cost
/// of clone -> load SHARING_ALL -> advance -> root_hash -> destroy,
/// the physical cost of each kept boundary, and the mapping-mode A/B
/// for the hash-hot sampling loop. Boundary cost is a free-space
/// delta: order of magnitude only (any concurrent writer moves it),
/// but immune to the shared-extent overcounting that breaks du on
/// reflinked files. On a filesystem without reflinks the loop
/// degrades to sparse copies and these rows price exactly that.
fn bench_clone_loop(report: &mut String, image: &Path, scratch_root: &Path) -> Result<()> {
    use cartesi_machine::config::runtime::RuntimeConfig;
    use cartesi_machine::machine::Machine;
    use cartesi_machine::types::SharingMode;

    let chain_root = scratch(scratch_root, "clone-chain")?;
    let boundary = |k: u64| chain_root.join(format!("boundary-{k}"));
    let (_, template_clone) = timed(|| Ok(Machine::clone_stored(image, &boundary(0))?))?;

    writeln!(report, "## The clone loop (docs/plans/snapshots.md)")?;
    writeln!(report)?;
    writeln!(
        report,
        "Chain of clones over echo inputs: clone the previous boundary,\n\
         load SHARING_ALL, advance one input, root_hash (sidecars exact),\n\
         destroy. Boundary cost is the free-space delta of one whole\n\
         iteration - what keeping that boundary physically costs.\n\
         Template clone: {}.",
        fmt_duration(template_clone)
    )?;
    writeln!(report)?;
    writeln!(
        report,
        "| input | clone | load | advance | root_hash | destroy | boundary cost |"
    )?;
    writeln!(report, "|---:|---:|---:|---:|---:|---:|---:|")?;

    const INPUTS: u64 = 4;
    for k in 0..INPUTS {
        let working = chain_root.join("working");
        let free_before = free_space_kb(&chain_root)?;
        let (_, clone) = timed(|| Ok(Machine::clone_stored(&boundary(k), &working)?))?;
        let (machine, load) = timed(|| {
            Ok(Machine::load_with_sharing(
                &working,
                &RuntimeConfig::quiet_console(),
                SharingMode::All,
            )?)
        })?;
        let mut machine = machine;
        let input = evm_advance_input(k, b"measure");
        let (_, advance) = timed(|| advance_one_input(&mut machine, &input))?;
        let (_, hash) = timed(|| Ok(machine.root_hash()?))?;
        let (_, destroy) = timed(|| {
            drop(machine);
            Ok(())
        })?;
        fs::rename(&working, boundary(k + 1))?;
        let free_after = free_space_kb(&chain_root)?;
        let churn_mb = (free_before as i64 - free_after as i64) as f64 / 1024.0;

        writeln!(
            report,
            "| {k} | {} | {} | {} | {} | {} | {churn_mb:.1} MB |",
            fmt_duration(clone),
            fmt_duration(load),
            fmt_duration(advance),
            fmt_duration(hash),
            fmt_duration(destroy),
        )?;
    }
    writeln!(report)?;

    // The hash-hot sampling loop under each mapping mode: does
    // MAP_SHARED slow the ustep + root_hash pair the level-2 collect
    // lives in? A fresh clone per mode (ALL locks and mutates its
    // directory).
    writeln!(report, "| hash-hot pairs (uarch step + root_hash) | rate |")?;
    writeln!(report, "|---|---:|")?;
    for (tag, label, mode) in [
        ("private", "private mapping (CONFIG)", SharingMode::Config),
        ("shared", "shared mapping (ALL)", SharingMode::All),
    ] {
        let dir = chain_root.join(format!("pairs-{tag}"));
        Machine::clone_stored(&boundary(INPUTS), &dir)?;
        let mut machine = Machine::load_with_sharing(&dir, &RuntimeConfig::quiet_console(), mode)?;
        let pairs = 500u64;
        let start = Instant::now();
        for _ in 0..pairs {
            if machine.uarch_halt_flag()? {
                machine.reset_uarch()?;
            } else {
                let ucycle = machine.ucycle()?;
                machine.run_uarch(ucycle + 1)?;
            }
            machine.root_hash()?;
        }
        let elapsed = start.elapsed();
        writeln!(
            report,
            "| {label} | {:.0}/s |",
            pairs as f64 / elapsed.as_secs_f64()
        )?;
    }
    writeln!(report)?;

    Ok(())
}

/// One input through a raw machine, the advance path's shape minus
/// leaf collection: checkpoint write, cmio delivery, run to the next
/// manual yield.
fn advance_one_input(machine: &mut cartesi_machine::machine::Machine, input: &[u8]) -> Result<()> {
    use cartesi_machine::constants::break_reason;
    use cartesi_machine::types::cmio::CmioResponseReason;
    use cartesi_rollups_prt_node::engine::constants::CHECKPOINT_ADDRESS;

    anyhow::ensure!(machine.iflags_y()?, "machine must be awaiting input");
    let checkpoint = machine.root_hash()?;
    machine.write_memory(CHECKPOINT_ADDRESS, &checkpoint)?;
    machine.send_cmio_response(CmioResponseReason::Advance, input)?;
    loop {
        match machine.run(u64::MAX)? {
            break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => continue,
            break_reason::YIELDED_MANUALLY => break Ok(()),
            reason => anyhow::bail!("unexpected break reason {reason}"),
        }
    }
}

/// Available space of the filesystem holding `path`, in KB (df).
fn free_space_kb(path: &Path) -> Result<u64> {
    let out = std::process::Command::new("df")
        .arg("-k")
        .arg(path)
        .output()?;
    anyhow::ensure!(out.status.success(), "df failed");
    let text = String::from_utf8_lossy(&out.stdout);
    let row = text
        .lines()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("df: no data row"))?;
    let avail = row
        .split_whitespace()
        .nth(3)
        .ok_or_else(|| anyhow::anyhow!("df: no available column"))?;
    Ok(avail.parse()?)
}

/// The primitive rates every extrapolation is built from, measured on
/// the real machine: idle churn (the ustep/ureset cycle a yielded
/// machine burns per big cycle), the input feed, active usteps, and
/// the ustep+state_hash pair that level-2 sampling pays per leaf.
fn bench_atoms(report: &mut String, image: &Path, scratch_root: &Path) -> Result<()> {
    let input = evm_advance_input(0, b"measure");
    let mut stf =
        MachineStf::load(image, scratch(scratch_root, "atoms")?)?.with_inputs(vec![input]);

    // Idle churn on the pristine yielded machine. Counts real usteps
    // (ustep is identity once the uarch halts, so drive whole cycles).
    let idle_cycles = 2_000u64;
    let mut idle_usteps = 0u64;
    let start = Instant::now();
    let mut cycles = 0u64;
    while cycles < idle_cycles {
        if stf.uarch_halted()? {
            stf.ureset()?;
            cycles += 1;
        } else {
            stf.ustep()?;
            idle_usteps += 1;
        }
    }
    let idle_elapsed = start.elapsed();
    let idle_per_cycle = idle_usteps as f64 / idle_cycles as f64;

    // One real input feed (the fused transition's expensive half).
    let (_, feed) = timed(|| stf.feed(0))?;

    // Active usteps: the fed input gives the uarch real work.
    let active_usteps = 200_000u64;
    let start = Instant::now();
    let mut done = 0u64;
    while done < active_usteps {
        if stf.uarch_halted()? {
            stf.ureset()?;
        } else {
            stf.ustep()?;
            done += 1;
        }
    }
    let active_elapsed = start.elapsed();

    // The level-2 sampling workload: every ustep dirties state, every
    // sample pays a root hash.
    let pairs = 500u64;
    let start = Instant::now();
    for _ in 0..pairs {
        if stf.uarch_halted()? {
            stf.ureset()?;
        } else {
            stf.ustep()?;
        }
        stf.state_hash()?;
    }
    let pairs_elapsed = start.elapsed();

    writeln!(report, "## Machine atoms")?;
    writeln!(report)?;
    writeln!(report, "| atom | rate |")?;
    writeln!(report, "|---|---:|")?;
    writeln!(
        report,
        "| idle big cycles (churn + ureset) | {:.0}/s ({:.1} usteps/cycle) |",
        idle_cycles as f64 / idle_elapsed.as_secs_f64(),
        idle_per_cycle,
    )?;
    writeln!(report, "| input feed | {} |", fmt_duration(feed))?;
    writeln!(
        report,
        "| active usteps | {:.2} M/s |",
        active_usteps as f64 / active_elapsed.as_secs_f64() / 1e6,
    )?;
    writeln!(
        report,
        "| ustep + state_hash pair | {:.0}/s |",
        pairs as f64 / pairs_elapsed.as_secs_f64(),
    )?;
    writeln!(report)?;
    Ok(())
}

/// Real span replays through the facade's node(), each on a fresh
/// storage and factory (guaranteed miss), then the same quartet
/// again (hit). Returns (label, miss latency) rows for the budget
/// table.
fn bench_quartets(
    report: &mut String,
    image: &Path,
    scratch_root: &Path,
    full: bool,
) -> Result<Vec<(String, u64, u64, Duration)>> {
    let mut spans: Vec<(&str, u64, u64)> = vec![
        ("uarch span", 0, 20),
        ("mid stride", 27, 10),
        ("coarse", 44, 4),
        ("level-2 root shape", 0, 27),
    ];
    if full {
        spans.push(("level-1 root shape", 27, 17));
    }

    let inputs = [
        evm_advance_input(0, b"hello dave"),
        evm_advance_input(1, b"hello again, dave"),
    ];

    let workload = image
        .parent()
        .and_then(|p| p.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown".into());
    writeln!(
        report,
        "## Span replays (get_or_compute, two-input {workload} epoch)"
    )?;
    writeln!(report)?;
    writeln!(report, "| span | quartet | miss | cache hit |")?;
    writeln!(report, "|---|---|---:|---:|")?;

    let mut results = Vec::new();
    for (index, (label, log2_stride, height)) in spans.into_iter().enumerate() {
        let state_dir = scratch(scratch_root, &format!("quartet-{index}"))?;
        let mut storage = Storage::migrate(&state_dir, image, 0, Address::ZERO)?;
        let rows: Vec<StorageInput> = inputs
            .iter()
            .enumerate()
            .map(|(i, data)| StorageInput {
                id: InputId {
                    epoch_number: 0,
                    input_index_in_epoch: i as u64,
                },
                data: data.clone(),
            })
            .collect();
        storage.insert_consensus_data(0, rows.iter(), std::iter::empty())?;
        let mut source = DisputeSource::on_store(
            storage,
            0,
            scratch(scratch_root, &format!("quartet-{index}-work"))?,
        )?;
        let quartet = Quartet::level_root(0, log2_stride, height);

        let (_, miss) = timed(|| source.node(&quartet))?;
        let (_, hit) = timed(|| source.node(&quartet))?;
        writeln!(
            report,
            "| {label} | r{log2_stride} h{height} | {} | {} |",
            fmt_duration(miss),
            fmt_duration(hit),
        )?;
        results.push((label.to_string(), log2_stride, height, miss));
    }
    writeln!(report)?;
    Ok(results)
}

fn budget(report: &mut String, quartets: &[(String, u64, u64, Duration)]) -> Result<()> {
    writeln!(report, "## Clock budget")?;
    writeln!(report)?;
    writeln!(
        report,
        "matchEffort grants five minutes of clock per height unit\n\
         (Deployment.s.sol), so a bisection move budgets ~{PER_MOVE_BUDGET_SECS} s.\n\
         Total allowances: devnet 1 h, testnet 9 h, mainnet 1 week + 1 h.\n\
         Level 0 never replays (seed-served); levels 1 and 2 pay their\n\
         root-shape replay on the first cold descent."
    )?;
    writeln!(report)?;
    writeln!(
        report,
        "| level | root span | measured (this workload) | budget | margin |"
    )?;
    writeln!(report, "|---|---|---:|---:|---:|")?;
    for (level, stride, height) in [(1u64, 27u64, 17u64), (2, 0, 27)] {
        let row = quartets
            .iter()
            .find(|(_, s, h, _)| *s == stride && *h == height);
        let (measured, margin) = match row {
            Some((_, _, _, d)) => {
                let secs = d.as_secs_f64();
                (
                    fmt_duration(*d),
                    format!("{:.0}x", PER_MOVE_BUDGET_SECS as f64 / secs.max(1e-9)),
                )
            }
            None => ("not measured".into(), "-".into()),
        };
        writeln!(
            report,
            "| {level} | 2^{} usteps | {measured} | {PER_MOVE_BUDGET_SECS} s | {margin} |",
            stride + height,
        )?;
    }
    writeln!(report)?;
    Ok(())
}

/// The canonical input encoding (Inputs.sol EvmAdvance), mirroring the
/// differential tests; raw bytes would crash the rollup driver.
fn evm_advance_input(index: u64, payload: &[u8]) -> Vec<u8> {
    alloy::sol! {
        function EvmAdvance(
            uint256 chainId,
            address appContract,
            address msgSender,
            uint256 blockNumber,
            uint256 blockTimestamp,
            uint256 prevRandao,
            uint256 index,
            bytes memory payload
        ) external;
    }
    EvmAdvanceCall {
        chainId: U256::from(31337),
        appContract: Address::ZERO,
        msgSender: Address::ZERO,
        blockNumber: U256::from(1),
        blockTimestamp: U256::from(1),
        prevRandao: U256::from(0),
        index: U256::from(index),
        payload: payload.to_vec().into(),
    }
    .abi_encode()
}

fn timed<T>(f: impl FnOnce() -> Result<T>) -> Result<(T, Duration)> {
    let start = Instant::now();
    let value = f()?;
    Ok((value, start.elapsed()))
}

fn scratch(root: &Path, tag: &str) -> Result<PathBuf> {
    let path = root.join(tag);
    fs::create_dir_all(&path)?;
    Ok(path)
}

fn dir_size(path: &Path) -> Result<u64> {
    let mut total = 0;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let meta = entry.metadata()?;
        total += if meta.is_dir() {
            dir_size(&entry.path())?
        } else {
            meta.len()
        };
    }
    Ok(total)
}

fn fmt_duration(d: Duration) -> String {
    let secs = d.as_secs_f64();
    if secs >= 1.0 {
        format!("{secs:.2} s")
    } else if secs >= 1e-3 {
        format!("{:.1} ms", secs * 1e3)
    } else {
        format!("{:.0} us", secs * 1e6)
    }
}

//
// The constants pipeline (--constants): workstream 8 of
// docs/plans/node-refactor.md. prt/measure_constants remains a
// complementary emulator-level harness. Measurement invariants
// (docs/dimensioning.md): halt AND yield guarded on every timed
// region, steady-state input-fed sampling instead of boot,
// conservative floor rounding instead of floor+1.
//

const LOG2_UARCH: u64 = 20;
const LOG2_RULER: u64 = 92;
const CURRENT_LOG2STEP: [u64; 3] = [44, 27, 0];
const CURRENT_HEIGHT: [u64; 3] = [48, 17, 27];

/// Steady-state rates plus the hash-cost curve, all measured
/// mid-computation on a fed machine.
struct SteadyAtoms {
    avg_usteps_per_big: f64,
    dense_pairs_per_sec: f64,
    /// (delta in big cycles, median run time, median hash time).
    curve: Vec<(u64, Duration, Duration)>,
}

/// A machine kept in active computation: re-feeds inputs as the
/// workload consumes them, and refuses to let any timed region see a
/// yielded or halted state.
struct ActiveMachine {
    stf: MachineStf,
    inputs: Vec<Vec<u8>>,
    next_input: usize,
}

impl ActiveMachine {
    fn load(image: &Path, scratch_root: &Path) -> Result<Self> {
        let inputs: Vec<Vec<u8>> = (0..16)
            .map(|i| evm_advance_input(i, b"constants"))
            .collect();
        let stf = MachineStf::load(image, scratch(scratch_root, "constants")?)?
            .with_inputs(inputs.clone());
        let mut this = Self {
            stf,
            inputs,
            next_input: 0,
        };
        this.ensure_active()?;
        Ok(this)
    }

    /// Feeds the next input if the workload yielded, then skips the
    /// input handler's prologue so sampling sees the workload proper.
    fn ensure_active(&mut self) -> Result<()> {
        anyhow::ensure!(
            !self.stf.halted()?,
            "machine halted; --constants needs a yielding compute workload"
        );
        if self.stf.yielded()? {
            anyhow::ensure!(
                self.next_input < self.inputs.len(),
                "workload too light for --constants (exhausted {} inputs); use the stress image",
                self.inputs.len(),
            );
            let window = self.next_input as u64;
            self.next_input += 1;
            self.stf.feed(window)?;
            let ran = self.stf.run_big(10_000)?;
            anyhow::ensure!(ran == 10_000, "input's compute too small to sample");
        }
        Ok(())
    }

    fn assert_active(&mut self, context: &str) -> Result<()> {
        anyhow::ensure!(
            !self.stf.yielded()? && !self.stf.halted()?,
            "machine left the active state during {context}; workload too light"
        );
        Ok(())
    }
}

fn measure_steady_atoms(machine: &mut ActiveMachine) -> Result<SteadyAtoms> {
    // Density and the dense pair rate: the leaf-level workload (hash
    // after every executed ustep and every reset), over whole big
    // cycles mid-computation.
    machine.ensure_active()?;
    let bigs_target = 500u64;
    let mut usteps = 0u64;
    let mut bigs = 0u64;
    let start = Instant::now();
    while bigs < bigs_target {
        if machine.stf.uarch_halted()? {
            machine.stf.ureset()?;
            bigs += 1;
        } else {
            machine.stf.ustep()?;
            usteps += 1;
        }
        machine.stf.state_hash()?;
    }
    let dense_elapsed = start.elapsed();
    machine.assert_active("the dense sample")?;
    let avg_usteps_per_big = usteps as f64 / bigs as f64;
    let dense_pairs_per_sec = (usteps + bigs) as f64 / dense_elapsed.as_secs_f64();

    // The hash-cost curve: per delta, clear the dirty set with an
    // untimed hash, run delta big cycles, then time one root hash
    // over the accumulated dirt. Samples that hit an input boundary
    // are discarded, never timed short.
    let mut curve = Vec::new();
    for log2_delta in (8..=24u64).step_by(2) {
        let delta = 1u64 << log2_delta;
        let mut runs = Vec::new();
        let mut hashes = Vec::new();
        let mut attempts = 0;
        while runs.len() < 7 {
            attempts += 1;
            anyhow::ensure!(
                attempts <= 24,
                "workload too light to sample delta 2^{log2_delta}"
            );
            machine.ensure_active()?;
            machine.stf.state_hash()?;
            let start = Instant::now();
            let ran = machine.stf.run_big(delta)?;
            let run_time = start.elapsed();
            if ran < delta {
                continue;
            }
            let start = Instant::now();
            machine.stf.state_hash()?;
            hashes.push(start.elapsed());
            runs.push(run_time);
        }
        runs.sort();
        hashes.sort();
        curve.push((delta, runs[3], hashes[3]));
    }

    Ok(SteadyAtoms {
        avg_usteps_per_big,
        dense_pairs_per_sec,
        curve,
    })
}

/// (run seconds, hash seconds) at an arbitrary delta: log-space linear
/// between measured points; run scales linearly below and above; hash
/// is flat below the first point (dirt is at least page-granular) and
/// scales linearly above the last (conservative: real dirt saturates).
fn interp_curve(curve: &[(u64, Duration, Duration)], delta: u64) -> (f64, f64) {
    let pts: Vec<(f64, f64, f64)> = curve
        .iter()
        .map(|(d, r, h)| ((*d as f64).log2(), r.as_secs_f64(), h.as_secs_f64()))
        .collect();
    let x = (delta as f64).log2();
    let (first, last) = (pts[0], pts[pts.len() - 1]);
    if x <= first.0 {
        let ratio = delta as f64 / 2f64.powf(first.0);
        return (first.1 * ratio, first.2);
    }
    if x >= last.0 {
        let ratio = delta as f64 / 2f64.powf(last.0);
        return (last.1 * ratio, last.2 * ratio);
    }
    let i = pts.windows(2).position(|w| x <= w[1].0).unwrap();
    let (a, b) = (pts[i], pts[i + 1]);
    let t = (x - a.0) / (b.0 - a.0);
    (a.1 + t * (b.1 - a.1), a.2 + t * (b.2 - a.2))
}

struct Derived {
    timeout_minutes: u64,
    /// Top-down, ArbitrationConstants order.
    log2step: Vec<u64>,
    height: Vec<u64>,
    root_slowdown: f64,
}

fn derive(
    atoms: &SteadyAtoms,
    root_slowdown_budget: f64,
    timeout_minutes: u64,
    slack: f64,
) -> Result<Derived> {
    let budget_secs = (timeout_minutes * 60) as f64;

    // Leaf level: the tallest dense build that fits the timeout at the
    // measured average density, hardware slack applied, floor rounded.
    let dense_bigs_per_sec = atoms.dense_pairs_per_sec / (atoms.avg_usteps_per_big + 1.0) / slack;
    let n_bigs = dense_bigs_per_sec * budget_secs;
    anyhow::ensure!(n_bigs >= 2.0, "timeout too small for any leaf level");
    let h_leaf = LOG2_UARCH + n_bigs.log2().floor() as u64;

    let mut log2step = vec![0u64];
    let mut height = vec![h_leaf];
    let mut stride = h_leaf;

    let root_slowdown_at = |stride: u64| {
        let d = 1u64 << (stride - LOG2_UARCH);
        let (run_s, hash_s) = interp_curve(&atoms.curve, d);
        (run_s + hash_s) / run_s
    };

    while root_slowdown_at(stride) > root_slowdown_budget {
        anyhow::ensure!(
            stride < LOG2_RULER,
            "no stride within the ruler satisfies the slowdown budget"
        );
        anyhow::ensure!(log2step.len() < 8, "runaway level stack");
        let d = 1u64 << (stride - LOG2_UARCH);
        let (run_s, hash_s) = interp_curve(&atoms.curve, d);
        let per_leaf = (run_s + hash_s) * slack;
        let n = budget_secs / per_leaf;
        anyhow::ensure!(
            n >= 2.0,
            "timeout too small for a level at stride 2^{stride}"
        );
        let h = (n.log2().floor() as u64).min(LOG2_RULER - stride);
        log2step.push(stride);
        height.push(h);
        stride += h;
    }
    anyhow::ensure!(stride < LOG2_RULER, "level stack consumed the whole ruler");

    let root_slowdown = root_slowdown_at(stride);
    log2step.push(stride);
    height.push(LOG2_RULER - stride);
    log2step.reverse();
    height.reverse();

    Ok(Derived {
        timeout_minutes,
        log2step,
        height,
        root_slowdown,
    })
}

fn constants_report(
    report: &mut String,
    args: &Args,
    image: &Path,
    scratch_root: &Path,
) -> Result<()> {
    let mut machine = ActiveMachine::load(image, scratch_root)?;
    let atoms = measure_steady_atoms(&mut machine)?;

    writeln!(report, "# Tournament constants derivation")?;
    writeln!(report)?;
    writeln!(
        report,
        "Generated by `just measure-constants` (measure.rs --constants).\n\
         Model: docs/dimensioning.md - clocks price the trusted app's AVERAGE\n\
         density; coordinates stay worst-case. Every timed region asserts the\n\
         machine is neither yielded nor halted; rounding is floor, never\n\
         floor+1."
    )?;
    writeln!(report)?;
    writeln!(
        report,
        "Workload `{}`; root slowdown budget {}; hardware slack {} (divide-\n\
         measured-throughput stand-in for a reference machine).",
        args.machine.display(),
        args.root_slowdown,
        args.hardware_slack,
    )?;
    writeln!(report)?;

    writeln!(report, "## Steady-state atoms")?;
    writeln!(report)?;
    writeln!(report, "| atom | value |")?;
    writeln!(report, "|---|---:|")?;
    writeln!(
        report,
        "| executed usteps per big cycle (density label) | {:.1} |",
        atoms.avg_usteps_per_big
    )?;
    writeln!(
        report,
        "| dense ustep+hash pairs | {:.0}/s |",
        atoms.dense_pairs_per_sec
    )?;
    writeln!(
        report,
        "| dense big cycles (leaf-level build rate) | {:.0}/s |",
        atoms.dense_pairs_per_sec / (atoms.avg_usteps_per_big + 1.0)
    )?;
    writeln!(report)?;

    writeln!(
        report,
        "## Hash-cost curve (dirt accumulated over delta big cycles)"
    )?;
    writeln!(report)?;
    writeln!(
        report,
        "| delta (bigs) | stride | run | root hash | slowdown |"
    )?;
    writeln!(report, "|---:|---|---:|---:|---:|")?;
    for (delta, run, hash) in &atoms.curve {
        let slowdown = (run.as_secs_f64() + hash.as_secs_f64()) / run.as_secs_f64();
        writeln!(
            report,
            "| 2^{} | 2^{} | {} | {} | {:.2}x |",
            delta.ilog2(),
            delta.ilog2() as u64 + LOG2_UARCH,
            fmt_duration(*run),
            fmt_duration(*hash),
            slowdown,
        )?;
    }
    writeln!(report)?;

    writeln!(report, "## Derivations")?;
    writeln!(report)?;
    writeln!(
        report,
        "| inner timeout | levels | log2step | height | root slowdown |"
    )?;
    writeln!(report, "|---|---|---|---|---:|")?;
    let mut any_tall_root = false;
    for &timeout in &args.inner_timeout_minutes {
        let d = derive(&atoms, args.root_slowdown, timeout, args.hardware_slack)?;
        any_tall_root |= d.height[0] > CURRENT_HEIGHT[0];
        writeln!(
            report,
            "| {} min | {} | {:?} | {:?} | {:.2}x |",
            d.timeout_minutes,
            d.log2step.len(),
            d.log2step,
            d.height,
            d.root_slowdown,
        )?;
    }
    writeln!(
        report,
        "| (current) | 3 | {:?} | {:?} | - |",
        CURRENT_LOG2STEP, CURRENT_HEIGHT
    )?;
    writeln!(report)?;
    writeln!(
        report,
        "Heights always sum to 92, so matchEffort's five-minutes-per-\n\
         height-unit total is shape-invariant; level count changes only\n\
         the per-level join and nested-tournament overhead."
    )?;
    if any_tall_root {
        writeln!(report)?;
        writeln!(
            report,
            "A derived root height exceeds the current 48: verify contract-\n\
             side assumptions before adopting (tree math, position widths)."
        )?;
    }
    writeln!(report)?;

    writeln!(report, "## Coordinated-bump checklist")?;
    writeln!(report)?;
    writeln!(
        report,
        "Constants changes cross the contract-client compatibility boundary.\n\
         Adopt a bump only with coordinated validation of:\n\
         ArbitrationConstants.sol (LEVELS, log2step, height);\n\
         rollups_machine::LOG2_STRIDE (= log2step(0));\n\
         docs/computation-hash.md's level table; harness fixtures.\n\
         Also wanted: a small test-shape profile so e2e disputes run in\n\
         seconds (node-refactor.md, workstream 8)."
    )?;
    writeln!(report)?;
    writeln!(report, "## Caveats")?;
    writeln!(report)?;
    writeln!(
        report,
        "Single-machine, single-run numbers; the density label above is\n\
         this workload's, and clocks dimensioned here inherit the\n\
         trusted-app assumption (docs/dimensioning.md). The root\n\
         slowdown figure interpolates the curve's steepest band, so it\n\
         wobbles run to run - the derived level shape is the stable\n\
         output. Rerun on validator-grade hardware before adopting\n\
         anything."
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn baseline_profile_is_selected_from_the_cli() {
        let args = Args::try_parse_from(["measure", "--profile", "stress"]).unwrap();

        assert_eq!(args.profile, BaselineProfile::Stress);
    }

    #[test]
    fn checked_in_baseline_preambles_match_the_renderer() -> Result<()> {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let fixtures = [
            (
                BaselineProfile::Echo,
                false,
                "test/programs/echo/machine-image",
                "docs/measurements/measurements.md",
            ),
            (
                BaselineProfile::Stress,
                true,
                "test/programs/stress/machine-image",
                "docs/measurements/measurements-stress.md",
            ),
        ];

        for (profile, full, image, fixture) in fixtures {
            let mut expected = String::new();
            preamble(&mut expected, Path::new(image), profile, full)?;
            let actual = fs::read_to_string(root.join(fixture))?;

            assert!(
                actual.starts_with(&expected),
                "{fixture} has stale generated preamble prose"
            );
        }

        Ok(())
    }
}
