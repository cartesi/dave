// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The measurement harness times operations that must fit within dispute
//! deadlines. It regenerates docs/measurements/measurements.md. Run through
//! `just measure`; committing a regenerated table is a reviewed act,
//! fixtures-style.

use anyhow::Result;
use clap::{Parser, ValueEnum};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use alloy::primitives::{Address, U256};
use alloy::sol_types::SolCall;
use cartesi_machine::constants::rollup::LOG2_MAX_UARCH_CYCLES_PER_MCYCLE;
use cartesi_rollups_prt_node::engine::{
    DisputeSource, Hashing, Level, MachineStf, Positioner, Quartet, Stf, Structure,
    TournamentGeometry, constants::LOG2_EPOCH_RULER_SPAN, fold_runs,
};
use cartesi_rollups_prt_node::merkle::Digest;
use cartesi_rollups_prt_node::storage::{
    DEFAULT_SNAPSHOT_GAP_INPUTS, Input as StorageInput, InputId, Storage, Template,
};

/// Five minutes of clock per tree height unit: the inclusion budget each
/// response is discounted by (ClockBudgets; Deployment.s.sol
/// `_getInclusionBudget`). Every replay a bisection move needs must fit well
/// inside this.
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

    /// Include the three-level table's level-1 root replay: a 2^44-ustep
    /// span, potentially minutes of machine time.
    #[arg(long)]
    full: bool,

    /// Derive tournament level constants instead of the baseline report.
    /// Needs a compute-heavy workload (the stress image).
    #[arg(long)]
    constants: bool,

    /// Accepted slowdown of the root-level eager commitment
    /// (docs/dimensioning.md: an aggregate authored by the trusted
    /// app, so priced at average density).
    #[arg(long, default_value_t = 2.0)]
    root_slowdown: f64,

    /// Commitment budgets T (minutes) to derive for: the time every inner
    /// tournament's commitment must build within.
    #[arg(long, value_delimiter = ',', default_values_t = vec![60u64, 30])]
    commitment_budget_minutes: Vec<u64>,

    /// Pragmatic stand-in for a reference machine: measured throughput
    /// is divided by this before any derivation, and the factor is
    /// printed into the output so results carry their caveat.
    #[arg(long, default_value_t = 2.0)]
    hardware_slack: f64,

    /// Time only the two-level leaf build (stride 0, height 37) over the
    /// first input, with the process's peak RSS. A mode of its own keeps
    /// that figure the build's rather than the other benches'.
    #[arg(long)]
    two_level_leaf: bool,

    /// Time a cold leaf join and a deep proof against the emulator doing
    /// the same work in process: the runbook recipe for the node's
    /// no-overhead claim (node-architecture.md, performance stance).
    #[arg(long)]
    node_vs_emulator: bool,

    /// Snapshot gap for --node-vs-emulator. The join targets the gap's
    /// last input, so positioning replays the whole gap.
    #[arg(long, default_value_t = DEFAULT_SNAPSHOT_GAP_INPUTS)]
    gap_inputs: u64,

    /// Leaf-tournament height for --node-vs-emulator: 37 is the
    /// two-level table's; lower it for a quick run.
    #[arg(long, default_value_t = 37)]
    leaf_height: u64,

    /// Internal: runs one --node-vs-emulator row in this process, so its
    /// peak RSS is its own.
    #[arg(long, hide = true)]
    row: Option<String>,
}

fn main() -> Result<()> {
    let args = Args::parse();
    if let Some(row) = &args.row {
        println!("{}", versus::run_row(row)?);
        return Ok(());
    }
    let image = args.machine.canonicalize()?;
    let scratch_root = std::env::temp_dir().join(format!("dave-measure-{}", std::process::id()));
    fs::create_dir_all(&scratch_root)?;

    if args.constants {
        let mut report = String::new();
        constants_report(&mut report, &args, &image, &scratch_root)?;
        let _ = fs::remove_dir_all(&scratch_root);
        return emit(&report, args.out.as_deref());
    }

    if args.node_vs_emulator {
        let mut report = String::new();
        versus::report(&mut report, &args, &image, &scratch_root)?;
        let _ = fs::remove_dir_all(&scratch_root);
        return emit(&report, args.out.as_deref());
    }

    if args.two_level_leaf {
        let mut report = String::new();
        two_level_leaf_report(&mut report, &args, &image, &scratch_root)?;
        let _ = fs::remove_dir_all(&scratch_root);
        return emit(&report, args.out.as_deref());
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
    emit(&report, args.out.as_deref())
}

fn emit(report: &str, out: Option<&Path>) -> Result<()> {
    match out {
        Some(path) => {
            fs::write(path, report)?;
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
        timed(|| MachineStf::load(image, scratch(scratch_root, "snap-load")?, Hashing::Sampled))?;
    let store_path = scratch_root.join("stored-machine");
    let (_, store) = timed(|| stf.store(&store_path))?;
    let (_, resume) = timed(|| {
        MachineStf::resume(
            &store_path,
            scratch(scratch_root, "snap-resume")?,
            Hashing::Sampled,
        )
    })?;
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

/// The CoW clone loop: the per-input cost
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

    writeln!(report, "## The boundary clone loop")?;
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
/// leaf collection: CMIO delivery with the pre-input revert root, then
/// run to the next manual yield.
fn advance_one_input(machine: &mut cartesi_machine::machine::Machine, input: &[u8]) -> Result<()> {
    use cartesi_machine::constants::break_reason;
    use cartesi_machine::types::cmio::CmioResponseReason;

    anyhow::ensure!(machine.iflags_y()?, "machine must be awaiting input");
    let revert_root = machine.root_hash()?;
    machine.send_cmio_response(CmioResponseReason::Advance, input, Some(&revert_root))?;
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
    let mut stf = MachineStf::load(image, scratch(scratch_root, "atoms")?, Hashing::PerStep)?
        .with_inputs(vec![input]);

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
        ("uarch span", 0, LOG2_MAX_UARCH_CYCLES_PER_MCYCLE),
        ("mid stride", 27, 10),
        ("coarse", 44, 4),
        ("level-2 root shape", 0, 27),
    ];
    if full {
        spans.push(("level-1 root shape", 27, 17));
    }

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
        let mut source = two_input_epoch(image, scratch_root, &format!("quartet-{index}"))?;
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

/// A dispute source over a two-input epoch 0 of the workload.
fn two_input_epoch(
    image: &Path,
    scratch_root: &Path,
    tag: &str,
) -> Result<DisputeSource<Positioner>> {
    let inputs = [
        evm_advance_input(0, b"hello dave"),
        evm_advance_input(1, b"hello again, dave"),
    ];
    let mut storage = Storage::initialize(
        &scratch(scratch_root, tag)?,
        &Template::inspect(image)?,
        0,
        Address::ZERO,
        Address::ZERO,
        0,
        &bench_geometry()?,
    )?;
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
    DisputeSource::on_store(storage, 0, scratch(scratch_root, &format!("{tag}-work"))?)
}

/// The two-level leaf a party builds before joining, within the
/// commitment budget T. On the stress workload each input burns about
/// 2^27 dense big cycles, so all 2^17 big cycles of the span execute.
fn two_level_leaf_report(
    report: &mut String,
    args: &Args,
    image: &Path,
    scratch_root: &Path,
) -> Result<()> {
    const T_SECS: f64 = 60.0 * 60.0;
    let mut source = two_input_epoch(image, scratch_root, "two-level-leaf")?;
    let (_, build) = timed(|| source.node(&Quartet::level_root(0, 0, 37)))?;
    let target = T_SECS / args.hardware_slack;

    writeln!(report, "# Two-level leaf build")?;
    writeln!(report)?;
    writeln!(
        report,
        "Generated by `just measure-two-level-leaf` (measure.rs --two-level-leaf).\n\
         One sample. Workload `{}`, first input.",
        args.machine.display(),
    )?;
    writeln!(report)?;
    writeln!(
        report,
        "| quartet | build | peak RSS | target (T / slack {}) |",
        args.hardware_slack
    )?;
    writeln!(report, "|---|---:|---:|---:|")?;
    writeln!(
        report,
        "| r0 h37 | {} | {:.0} MiB | {:.0} min |",
        fmt_duration(build),
        peak_rss_bytes() as f64 / (1u64 << 20) as f64,
        target / 60.0,
    )?;
    writeln!(report)?;
    Ok(())
}

/// Peak resident set size of this process so far.
fn peak_rss_bytes() -> u64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage only writes the struct it is handed.
    let usage = unsafe {
        libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr());
        usage.assume_init()
    };
    let max = u64::try_from(usage.ru_maxrss).unwrap_or(0);
    // macOS reports bytes, Linux kibibytes.
    if cfg!(target_os = "macos") {
        max
    } else {
        max * 1024
    }
}

fn budget(report: &mut String, quartets: &[(String, u64, u64, Duration)]) -> Result<()> {
    writeln!(report, "## Clock budget")?;
    writeln!(report)?;
    writeln!(
        report,
        "responseBudget grants five minutes of clock per height unit\n\
         (ClockBudgets), so a bisection move budgets ~{PER_MOVE_BUDGET_SECS} s.\n\
         Total allowances, C + G + (L - 1)(T + 2G) at T = 30 min: devnet 85 min,\n\
         testnet 9 h 25 min, mainnet 1 week + 85 min.\n\
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
// prt/measure_constants remains a complementary emulator-level
// harness. Measurement invariants
// (docs/dimensioning.md): halt AND yield guarded on every timed
// region, steady-state input-fed sampling instead of boot,
// conservative floor rounding instead of floor+1.
//

const BENCH_LOG2STEP: [u64; 3] = [44, 27, 0];
const BENCH_HEIGHT: [u64; 3] = [
    LOG2_EPOCH_RULER_SPAN - BENCH_LOG2STEP[0],
    BENCH_LOG2STEP[0] - BENCH_LOG2STEP[1],
    BENCH_LOG2STEP[1] - BENCH_LOG2STEP[2],
];

/// The three-level table the span replays pin; they never touch window
/// roots, so only its validity matters.
fn bench_geometry() -> Result<TournamentGeometry> {
    let levels = BENCH_LOG2STEP
        .iter()
        .zip(BENCH_HEIGHT)
        .map(|(&log2_stride, height)| Level {
            log2_stride,
            height,
        })
        .collect();
    TournamentGeometry::new(levels, &Structure::PRODUCTION)
}

/// Steady-state rates plus the hash-cost curve, all measured
/// mid-computation on a fed machine.
struct SteadyAtoms {
    avg_usteps_per_big: f64,
    dense_pairs_per_sec: f64,
    /// (delta in big cycles, median run time, median hash time).
    curve: Vec<(u64, Duration, Duration)>,
}

/// A machine kept in active computation: re-feeds inputs as the
/// workload consumes them, and refuses to let any timed region see an
/// input boundary or terminal state.
struct ActiveMachine {
    stf: MachineStf,
    inputs: Vec<Vec<u8>>,
    next_input: usize,
}

impl ActiveMachine {
    /// Loaded as the dispute loads the work being priced: per-step for
    /// leaf pairs, sampled for the hash-cost curve.
    fn load(image: &Path, scratch_root: &Path, hashing: Hashing) -> Result<Self> {
        let inputs: Vec<Vec<u8>> = (0..16)
            .map(|i| evm_advance_input(i, b"constants"))
            .collect();
        let stf = MachineStf::load(
            image,
            scratch(scratch_root, &format!("constants-{hashing:?}"))?,
            hashing,
        )?
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
            !self.stf.terminal()?,
            "machine became terminal; --constants needs a yielding compute workload"
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
            !self.stf.yielded()? && !self.stf.terminal()?,
            "machine left the active state during {context}; workload too light"
        );
        Ok(())
    }
}

fn measure_steady_atoms(image: &Path, scratch_root: &Path) -> Result<SteadyAtoms> {
    let machine = &mut ActiveMachine::load(image, scratch_root, Hashing::PerStep)?;
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
    let machine = &mut ActiveMachine::load(image, scratch_root, Hashing::Sampled)?;
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
    commitment_budget_minutes: u64,
    /// Top-down, ArbitrationConstants order.
    log2step: Vec<u64>,
    height: Vec<u64>,
    root_slowdown: f64,
}

fn derive(
    atoms: &SteadyAtoms,
    root_slowdown_budget: f64,
    commitment_budget_minutes: u64,
    slack: f64,
) -> Result<Derived> {
    let budget_secs = (commitment_budget_minutes * 60) as f64;

    // Leaf level: the tallest dense build that fits the budget at the
    // measured average density, hardware slack applied, floor rounded.
    let dense_bigs_per_sec = atoms.dense_pairs_per_sec / (atoms.avg_usteps_per_big + 1.0) / slack;
    let n_bigs = dense_bigs_per_sec * budget_secs;
    anyhow::ensure!(
        n_bigs >= 2.0,
        "commitment budget too small for any leaf level"
    );
    let h_leaf = LOG2_MAX_UARCH_CYCLES_PER_MCYCLE + n_bigs.log2().floor() as u64;

    let mut log2step = vec![0u64];
    let mut height = vec![h_leaf];
    let mut stride = h_leaf;

    let root_slowdown_at = |stride: u64| {
        let d = 1u64 << (stride - LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);
        let (run_s, hash_s) = interp_curve(&atoms.curve, d);
        (run_s + hash_s) / run_s
    };

    while root_slowdown_at(stride) > root_slowdown_budget {
        anyhow::ensure!(
            stride < LOG2_EPOCH_RULER_SPAN,
            "no stride within the ruler satisfies the slowdown budget"
        );
        anyhow::ensure!(log2step.len() < 8, "runaway level stack");
        let d = 1u64 << (stride - LOG2_MAX_UARCH_CYCLES_PER_MCYCLE);
        let (run_s, hash_s) = interp_curve(&atoms.curve, d);
        let per_leaf = (run_s + hash_s) * slack;
        let n = budget_secs / per_leaf;
        anyhow::ensure!(
            n >= 2.0,
            "commitment budget too small for a level at stride 2^{stride}"
        );
        let h = (n.log2().floor() as u64).min(LOG2_EPOCH_RULER_SPAN - stride);
        log2step.push(stride);
        height.push(h);
        stride += h;
    }
    anyhow::ensure!(
        stride < LOG2_EPOCH_RULER_SPAN,
        "level stack consumed the whole ruler"
    );

    let root_slowdown = root_slowdown_at(stride);
    log2step.push(stride);
    height.push(LOG2_EPOCH_RULER_SPAN - stride);
    log2step.reverse();
    height.reverse();

    Ok(Derived {
        commitment_budget_minutes,
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
    let atoms = measure_steady_atoms(image, scratch_root)?;

    writeln!(report, "# Tournament constants derivation")?;
    writeln!(report)?;
    writeln!(
        report,
        "Generated by `just measure-level-constants` (measure.rs --constants).\n\
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
            delta.ilog2() as u64 + LOG2_MAX_UARCH_CYCLES_PER_MCYCLE,
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
        "| commitment budget | levels | log2step | height | root slowdown |"
    )?;
    writeln!(report, "|---|---|---|---|---:|")?;
    for &budget in &args.commitment_budget_minutes {
        let d = derive(&atoms, args.root_slowdown, budget, args.hardware_slack)?;
        writeln!(
            report,
            "| {} min | {} | {:?} | {:?} | {:.2}x |",
            d.commitment_budget_minutes,
            d.log2step.len(),
            d.log2step,
            d.height,
            d.root_slowdown,
        )?;
    }
    writeln!(report)?;
    writeln!(
        report,
        "Heights always sum to {LOG2_EPOCH_RULER_SPAN}, so responseBudget's five-minutes-per-\n\
         height-unit total is shape-invariant; level count changes only\n\
         the per-level join and nested-tournament overhead."
    )?;
    writeln!(report)?;

    writeln!(report, "## Coordinated-bump checklist")?;
    writeln!(report)?;
    writeln!(
        report,
        "Constants changes cross the contract-client compatibility boundary.\n\
         Adopt a bump only with coordinated validation of:\n\
         ArbitrationConstants.sol (LEVELS, log2step, height, COMMITMENT_BUDGET);\n\
         docs/computation-hash.md's level table; harness fixtures. The node\n\
         discovers and pins the deployed table, so it carries no stride constant.\n\
         A small test-shape profile would also let e2e disputes run in\n\
         seconds."
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

/// The runbook recipe behind the node's claim that it adds no overhead
/// over the emulator (node-architecture.md, performance stance): two
/// dispute actions at the heaviest placement the snapshot gap allows, each
/// timed against the emulator doing the same work in process.
///
/// - Cold join: the leaf commitment over the last dense leaf of the gap's
///   last input, on a fresh store, so the whole gap replays first, plus the
///   children and last-leaf proof the join posts. The emulator replays the
///   same inputs with cm_run and collects the span with
///   cm_collect_uarch_cycle_root_hashes, one bundle per big cycle. The two
///   roots must agree.
/// - Deep proof: the closing slot at the end of that leaf, from the input
///   boundary the join published. The emulator loads the same snapshot,
///   runs to the slot, and logs the step and the reset.
///
/// Each row runs in its own process, so its peak RSS is its own. Disk is
/// the row's free-space delta on the scratch filesystem (TMPDIR), which
/// should be the node's.
mod versus {
    use super::*;
    use anyhow::{bail, ensure};
    use cartesi_machine::config::runtime::RuntimeConfig;
    use cartesi_machine::constants::break_reason;
    use cartesi_machine::machine::Machine;
    use cartesi_machine::types::{LogType, cmio::CmioResponseReason};
    use cartesi_machine::{EXPECTED_EMULATOR_VERSION, format_emulator_version};
    use cartesi_rollups_prt_node::engine::LevelCoords;
    use serde_json::{Value, json};

    const EPOCH: u64 = 0;
    /// Mcycles per emulator collection call: bounds the result's size.
    const COLLECT_CHUNK: u64 = 4096;

    pub fn report(
        report: &mut String,
        args: &Args,
        image: &Path,
        scratch_root: &Path,
    ) -> Result<()> {
        let structure = Structure::PRODUCTION;
        let c = structure.log2_uarch_span;
        let height = args.leaf_height;
        ensure!(height > c, "the leaf must span whole big cycles");
        ensure!(args.gap_inputs >= 1, "the gap needs an input");
        let input = args.gap_inputs - 1;

        let state = scratch(scratch_root, "state")?;
        let geometry = TournamentGeometry::new(
            vec![
                Level {
                    log2_stride: height,
                    height: structure.log2_ruler_span() - height,
                },
                Level {
                    log2_stride: 0,
                    height,
                },
            ],
            &structure,
        )?;
        let mut storage = Storage::initialize(
            &state,
            &Template::inspect(image)?,
            0,
            Address::ZERO,
            Address::ZERO,
            0,
            &geometry,
        )?;
        let rows: Vec<StorageInput> = (0..args.gap_inputs)
            .map(|i| StorageInput {
                id: InputId {
                    epoch_number: EPOCH,
                    input_index_in_epoch: i,
                },
                data: evm_advance_input(i, b"versus"),
            })
            .collect();
        storage.insert_consensus_data(EPOCH, rows.iter(), std::iter::empty())?;
        drop(storage);

        // A leaf three quarters into the input: deep, and safely inside
        // its computation, since inputs of the same workload vary in
        // length (the stress image's by more than a height-27 leaf).
        let active = input_big_cycles(image)?;
        let leaf_cycles = 1u64 << (height - c);
        let leaf = active / 4 * 3 / leaf_cycles;
        ensure!(
            leaf > 0,
            "an input runs {active} big cycles, too few to fill a height-{height} \
             leaf deep inside it; use the stress image"
        );
        let window_start = U256::from(input) << structure.log2_window_span();
        let base = window_start + (U256::from(leaf) << height);
        let last = base + (U256::from(1) << height) - U256::from(1);

        let state_arg = state.to_string_lossy();
        let emulator_join = spawn(&json!({
            "row": "emulator-join", "state": state_arg, "input": input,
            "base": base.to_string(), "height": height,
        }))?;
        let node_join = spawn(&json!({
            "row": "node-join", "state": state_arg, "base": base.to_string(), "height": height,
        }))?;
        ensure!(
            node_join["root"] == emulator_join["root"],
            "the node's leaf commitment {} differs from the emulator's {}",
            node_join["root"],
            emulator_join["root"]
        );
        let emulator_proof = spawn(&json!({
            "row": "emulator-proof", "state": state_arg, "input": input,
            "position": last.to_string(),
        }))?;
        let node_proof = spawn(&json!({
            "row": "node-proof", "state": state_arg, "position": last.to_string(),
            "pre": emulator_proof["pre"], "post": emulator_proof["post"],
        }))?;

        writeln!(report, "# Node versus emulator")?;
        writeln!(report)?;
        writeln!(
            report,
            "Generated by `just measure-node-vs-emulator` (measure.rs --node-vs-emulator).\n\
             One sample per row, each in its own process. Workload `{}`; snapshot\n\
             gap {} inputs; leaf height {height}; {} {} with {} threads; emulator {}.",
            args.machine.display(),
            args.gap_inputs,
            std::env::consts::OS,
            std::env::consts::ARCH,
            std::thread::available_parallelism().map_or(0, |n| n.get()),
            format_emulator_version(EXPECTED_EMULATOR_VERSION),
        )?;
        let (source, fingerprint) = provenance(image);
        writeln!(report)?;
        writeln!(
            report,
            "Source `{source}`; workload fingerprint `{fingerprint}`."
        )?;
        writeln!(report)?;
        writeln!(
            report,
            "The emulator rows are the baseline: the library in process, cm_run to\n\
             the position, then cm_collect_uarch_cycle_root_hashes bundled per big\n\
             cycle over the leaf (the join) or cm_log_step_uarch and\n\
             cm_log_reset_uarch (the proof). Disk is the row's free-space delta."
        )?;
        writeln!(report)?;
        writeln!(
            report,
            "| action | node | emulator | node / emulator | node peak RSS | emulator peak RSS | node disk |"
        )?;
        writeln!(report, "|---|---:|---:|---:|---:|---:|---:|")?;
        for (action, node, emulator) in [
            ("cold join", &node_join, &emulator_join),
            ("deep proof", &node_proof, &emulator_proof),
        ] {
            let (n, e) = (seconds(node), seconds(emulator));
            writeln!(
                report,
                "| {action} | {} | {} | {:.2}x | {:.0} MiB | {:.0} MiB | {:.1} MiB |",
                fmt_duration(Duration::from_secs_f64(n)),
                fmt_duration(Duration::from_secs_f64(e)),
                n / e,
                node["peak_rss_mib"].as_f64().unwrap_or(f64::NAN),
                emulator["peak_rss_mib"].as_f64().unwrap_or(f64::NAN),
                node["disk_mib"].as_f64().unwrap_or(f64::NAN),
            )?;
        }
        writeln!(report)?;
        writeln!(
            report,
            "Cold join: leaf {leaf}, three quarters into input {input}, the gap's last,\n\
             positioned from the epoch start, so {input} inputs replay first. The\n\
             node's time covers opening the store, positioning (whole inputs on\n\
             copy-on-write clones), the commitment, its children and the last-leaf\n\
             proof. The emulator positioned in {} and collected in {}.\n\
             {} of the leaf's {} big cycles ran active.",
            fmt_duration(Duration::from_secs_f64(
                emulator_join["position_seconds"]
                    .as_f64()
                    .unwrap_or(f64::NAN)
            )),
            fmt_duration(Duration::from_secs_f64(
                emulator_join["collect_seconds"]
                    .as_f64()
                    .unwrap_or(f64::NAN)
            )),
            emulator_join["active_cycles"],
            emulator_join["span_cycles"],
        )?;
        writeln!(report)?;
        writeln!(
            report,
            "Deep proof: the closing slot that ends that leaf, positioned from input\n\
             {input}'s boundary, which the join published."
        )?;
        Ok(())
    }

    /// The source revision (dirty when uncommitted) and the workload's
    /// fingerprint line, so runs can be compared.
    fn provenance(image: &Path) -> (String, String) {
        let source = std::process::Command::new("git")
            .args(["describe", "--always", "--dirty", "--abbrev=8"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .unwrap_or_else(|| "unknown".into());
        let fingerprint = fs::read_to_string(image.with_extension("fingerprint"))
            .map(|text| text.trim().to_string())
            .unwrap_or_else(|_| "unknown".into());
        (source, fingerprint)
    }

    /// Runs one row in a child process and returns its JSON line.
    fn spawn(spec: &Value) -> Result<Value> {
        let output = std::process::Command::new(std::env::current_exe()?)
            .arg("--row")
            .arg(spec.to_string())
            .stderr(std::process::Stdio::inherit())
            .output()?;
        ensure!(output.status.success(), "row {} failed", spec["row"]);
        let stdout = String::from_utf8(output.stdout)?;
        let line = stdout.lines().last().unwrap_or_default();
        Ok(serde_json::from_str(line)?)
    }

    pub fn run_row(spec: &str) -> Result<String> {
        let spec: Value = serde_json::from_str(spec)?;
        let state = PathBuf::from(field(&spec, "state")?.into_owned());
        let u64_of = |key: &str| -> Result<u64> { Ok(field(&spec, key)?.parse()?) };
        let u256_of = |key: &str| -> Result<U256> { Ok(field(&spec, key)?.parse()?) };
        let digest_of =
            |key: &str| -> Result<Digest> { Ok(Digest::from_digest_hex(&field(&spec, key)?)?) };

        let free_before = free_space_kb(&state)?;
        let started = Instant::now();
        let mut out = match field(&spec, "row")?.as_ref() {
            "emulator-join" => emulator_join(
                &state,
                u64_of("input")?,
                u256_of("base")?,
                u64_of("height")?,
            )?,
            "node-join" => node_join(&state, u256_of("base")?, u64_of("height")?)?,
            "emulator-proof" => emulator_proof(&state, u64_of("input")?, u256_of("position")?)?,
            "node-proof" => node_proof(
                &state,
                u256_of("position")?,
                digest_of("pre")?,
                digest_of("post")?,
            )?,
            other => bail!("unknown row {other}"),
        };
        out["seconds"] = json!(started.elapsed().as_secs_f64());
        out["peak_rss_mib"] = json!(peak_rss_bytes() as f64 / (1u64 << 20) as f64);
        out["disk_mib"] = json!((free_before as f64 - free_space_kb(&state)? as f64) / 1024.0);
        Ok(out.to_string())
    }

    /// A spec field as a string; numbers are accepted in either form.
    fn field<'a>(spec: &'a Value, key: &str) -> Result<std::borrow::Cow<'a, str>> {
        match &spec[key] {
            Value::String(text) => Ok(text.as_str().into()),
            Value::Number(number) => Ok(number.to_string().into()),
            _ => bail!("row spec lacks {key}"),
        }
    }

    fn seconds(row: &Value) -> f64 {
        row["seconds"].as_f64().unwrap_or(f64::NAN)
    }

    fn load(path: &Path) -> Result<Machine> {
        Ok(Machine::load(path, &RuntimeConfig::quiet_console())?)
    }

    fn payload(storage: &mut Storage, input: u64) -> Result<Vec<u8>> {
        let id = InputId {
            epoch_number: EPOCH,
            input_index_in_epoch: input,
        };
        Ok(storage
            .input(&id)?
            .ok_or_else(|| anyhow::anyhow!("input {input} missing"))?
            .data)
    }

    /// Delivers an input, recording the pre-input root as its revert root.
    fn feed(machine: &mut Machine, payload: &[u8]) -> Result<()> {
        let root = machine.root_hash()?;
        machine.send_cmio_response(CmioResponseReason::Advance, payload, Some(&root))?;
        Ok(())
    }

    /// Runs the big machine to `mcycle` through automatic yields; a manual
    /// yield or halt short of it is an error.
    fn run_to(machine: &mut Machine, mcycle: u64) -> Result<()> {
        loop {
            match machine.run(mcycle)? {
                break_reason::REACHED_TARGET_MCYCLE => return Ok(()),
                break_reason::YIELDED_AUTOMATICALLY | break_reason::YIELDED_SOFTLY => {}
                reason => bail!("stopped with break reason {reason} short of mcycle {mcycle}"),
            }
        }
    }

    /// Big cycles the workload spends on one input.
    fn input_big_cycles(image: &Path) -> Result<u64> {
        let mut machine = load(image)?;
        let start = machine.mcycle()?;
        advance_one_input(&mut machine, &evm_advance_input(0, b"versus"))?;
        Ok(machine.mcycle()? - start)
    }

    fn emulator_join(state: &Path, input: u64, base: U256, height: u64) -> Result<Value> {
        let structure = Structure::PRODUCTION;
        let c = structure.log2_uarch_span;
        let mut storage = Storage::new(state)?;
        let (_, template) = storage.nearest_boundary_at_or_before(EPOCH, 0)?;
        let payloads = (0..=input)
            .map(|i| payload(&mut storage, i))
            .collect::<Result<Vec<_>>>()?;
        drop(storage);

        let started = Instant::now();
        let mut machine = load(&template)?;
        for payload in &payloads[..input as usize] {
            advance_one_input(&mut machine, payload)?;
        }
        // The idle period of the machine awaiting the input: the revert
        // tail the collector needs.
        let mcycle = machine.mcycle()?;
        let tail = machine
            .collect_uarch_cycle_root_hashes(mcycle, 0, None)?
            .hashes;
        feed(&mut machine, &payloads[input as usize])?;
        let window_start = U256::from(input) << structure.log2_window_span();
        let offset = u64::try_from((base - window_start) >> c)?;
        let first = machine.mcycle()? + offset;
        run_to(&mut machine, first)?;
        let positioned = started.elapsed();

        let cycles = 1u64 << (height - c);
        let end = first + cycles;
        let mut roots: Vec<(Digest, u64)> = vec![];
        let mut push = |root: Digest, count: u64| match roots.last_mut() {
            Some((last, repetitions)) if *last == root => *repetitions += count,
            _ => roots.push((root, count)),
        };
        let mut active = 0u64;
        while active < cycles {
            let before = machine.mcycle()?;
            let part = machine.collect_uarch_cycle_root_hashes(
                end.min(before + COLLECT_CHUNK),
                c as u32,
                Some(&tail),
            )?;
            let ran = machine.mcycle()? - before;
            // Bundled per big cycle, each period's last entry is the big
            // cycle's root.
            let mut periods = part.periods();
            for period in periods.by_ref().take(ran as usize) {
                push(Digest::from(*period.last().expect("a period")), 1);
            }
            active += ran;
            if matches!(
                part.break_reason,
                break_reason::YIELDED_MANUALLY
                    | break_reason::HALTED
                    | break_reason::MCYCLE_OVERFLOW
            ) {
                // A fixed point repeats its period for the rest of the leaf.
                let idle = periods.next().expect("a fixed point reports its period");
                push(
                    Digest::from(*idle.last().expect("a period")),
                    cycles - active,
                );
                break;
            }
            ensure!(ran > 0, "the collector made no progress");
        }
        let collected = started.elapsed() - positioned;
        let root = fold_runs(roots, height - c)?.root_hash();
        Ok(json!({
            "root": root.to_hex(),
            "position_seconds": positioned.as_secs_f64(),
            "collect_seconds": collected.as_secs_f64(),
            "active_cycles": active,
            "span_cycles": cycles,
        }))
    }

    fn node_join(state: &Path, base: U256, height: u64) -> Result<Value> {
        let mut source = DisputeSource::on_store(
            Storage::new(state)?,
            EPOCH,
            state.with_file_name("node-work"),
        )?;
        let level = LevelCoords::new(EPOCH, base, 0, height);
        let root = source.node(&level.root())?;
        source.children(&level.root())?;
        source.prove_last(&level)?;
        Ok(json!({ "root": root.to_hex() }))
    }

    fn emulator_proof(state: &Path, input: u64, position: U256) -> Result<Value> {
        let structure = Structure::PRODUCTION;
        let c = structure.log2_uarch_span;
        let mut storage = Storage::new(state)?;
        let (boundary, snapshot) = storage.nearest_boundary_at_or_before(EPOCH, input)?;
        ensure!(
            boundary.0 == input,
            "the join should have written input {input}'s boundary back"
        );
        let payload = payload(&mut storage, input)?;
        drop(storage);

        let mut machine = load(&snapshot)?;
        feed(&mut machine, &payload)?;
        let offset = position - (U256::from(input) << structure.log2_window_span());
        let slot = u64::try_from(offset & U256::from(structure.big_span() - 1))?;
        ensure!(
            slot == structure.big_span() - 1,
            "the recipe proves a closing slot"
        );
        let first = machine.mcycle()? + u64::try_from(offset >> c)?;
        run_to(&mut machine, first)?;
        // Up to the closing slot the uarch runs to its halt; the slot's
        // ustep is then the identity and the reset closes the cycle.
        machine.run_uarch(u64::MAX)?;
        let pre = Digest::from(machine.root_hash()?);
        machine.log_step_uarch(LogType::default())?;
        machine.log_reset_uarch(LogType::default())?;
        let post = Digest::from(machine.root_hash()?);
        Ok(json!({ "pre": pre.to_hex(), "post": post.to_hex() }))
    }

    fn node_proof(state: &Path, position: U256, pre: Digest, post: Digest) -> Result<Value> {
        let mut source = DisputeSource::on_store(
            Storage::new(state)?,
            EPOCH,
            state.with_file_name("node-work"),
        )?;
        let proof = source.prove_transition(position, pre, post)?;
        Ok(json!({ "proof_bytes": proof.len() }))
    }
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
