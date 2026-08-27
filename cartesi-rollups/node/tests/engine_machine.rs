// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Increment B differentials: the engine reference collector against the
//! prototype's commitment builder, on the real echo machine, plus golden
//! fixtures pinning the roots.
//!
//! The image-backed tests are ignored by generic Cargo runs and exercised by
//! the fail-loud `just test-engine-machine` gate. The fixture file records the
//! template hash: an emulator or image bump invalidates it loudly, and
//! regeneration (UPDATE_FIXTURES=1) is a conscious, reviewable act.

use alloy::primitives::{Address, U256};
use alloy::sol_types::SolCall;
mod common;
use common::prototype::{MachineCommitment, MachineCommitmentBuilder};

use cartesi_rollups_prt_node::engine::{
    DisputeSource, LevelCoords, MachineStf, Positioner, Quartet, Stf, Structure,
};
use cartesi_rollups_prt_node::storage::{Input as StorageInput, InputId, Storage};
use common::epoch_data::EpochData;
use common::instance::MachineInstance;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn required_image(program: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/programs")
        .join(program)
        .join("machine-image");
    path.canonicalize().unwrap_or_else(|error| {
        panic!(
            "{program} machine image is unavailable at {}: {error}; run `just programs::build-{program}`",
            path.display()
        )
    })
}

fn echo_image() -> PathBuf {
    required_image("echo")
}

fn yield_image() -> PathBuf {
    required_image("yield")
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/engine_echo.json")
}

// The canonical input encoding: what InputBox.addInput wraps payloads
// into and what the machine's rollup driver decodes. Signature from
// cartesi-rollups-contracts (Inputs.sol); raw bytes would crash the
// driver and halt the machine.
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

fn encode_inputs(payloads: &[&[u8]]) -> Vec<Vec<u8>> {
    payloads
        .iter()
        .enumerate()
        .map(|(index, payload)| {
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
        })
        .collect()
}

fn echo_inputs() -> Vec<Vec<u8>> {
    encode_inputs(&[&b"hello dave"[..], &b"hello again, dave"[..]])
}

/// The yield program rejects every input; one is enough to reach the
/// revert-carrying closing slot.
fn yield_inputs() -> Vec<Vec<u8>> {
    encode_inputs(&[&b"hello dave"[..]])
}

/// Test scratch: under target/tmp (visible, swept by cargo clean) and
/// cleaned on drop. Never .keep() into the system TMPDIR - nothing
/// sweeps it, and these dirs carry machine stores (806 GB of orphans
/// found there, 2026-07-11). Callers hold the guard for as long as
/// the path is in use.
fn scratch() -> tempfile::TempDir {
    tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap()
}

fn template_hash(image: &Path) -> String {
    let work = scratch();
    let mut stf = MachineStf::load(image, work.path().to_path_buf()).unwrap();
    stf.state_hash().unwrap().to_hex()
}

/// The prototype's answer for a span: its commitment builder, backed
/// by in-memory epoch data.
fn prototype_root(image: &Path, level: u64, log2_stride: u64, log2_stride_count: u64) -> String {
    let dir = scratch();
    let db = EpochData::new(echo_inputs(), dir.path().to_path_buf()).unwrap();
    let mut builder = MachineCommitmentBuilder::new(image.to_str().unwrap().into());
    let commitment = builder
        .build_commitment(U256::ZERO, level, log2_stride, log2_stride_count, &db)
        .unwrap();
    commitment.merkle.root_hash().to_hex()
}

/// A real initialized node database in a temp state dir, the echo
/// inputs ingested through the production path (payloads live in the
/// inputs table; feeders read them there). The guard rides along:
/// the state dir must outlive the Storage.
fn initialized_storage(image: &Path) -> (tempfile::TempDir, Storage) {
    initialized_storage_with(image, echo_inputs())
}

fn initialized_storage_with(image: &Path, inputs: Vec<Vec<u8>>) -> (tempfile::TempDir, Storage) {
    let dir = scratch();
    let mut storage = Storage::initialize(dir.path(), image, 0, Address::ZERO).unwrap();
    let rows: Vec<StorageInput> = inputs
        .into_iter()
        .enumerate()
        .map(|(index, data)| StorageInput {
            id: InputId {
                epoch_number: 0,
                input_index_in_epoch: index as u64,
            },
            data,
        })
        .collect();
    storage
        .insert_consensus_data(0, rows.iter(), std::iter::empty())
        .unwrap();
    (dir, storage)
}

/// The engine answer for the same span, through the facade.
fn engine_root(image: &Path, log2_stride: u64, height: u64) -> String {
    let (guards, mut source) = machine_source(image);
    let quartet = Quartet::level_root(0, log2_stride, height);
    let root = source.node(&quartet).unwrap().to_hex();
    drop(guards);
    root
}

fn engine_root_with_inputs(
    image: &Path,
    inputs: Vec<Vec<u8>>,
    log2_stride: u64,
    height: u64,
) -> String {
    let (state_dir, storage) = initialized_storage_with(image, inputs);
    let work = scratch();
    let mut source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();
    let root = source
        .node(&Quartet::level_root(0, log2_stride, height))
        .unwrap()
        .to_hex();
    drop((state_dir, work));
    root
}

fn computation_hash_corpus() -> (PathBuf, Vec<serde_json::Value>) {
    let corpus_path = std::env::var_os("CARTESI_COMPUTATION_HASH_CORPUS_PATH").expect(
        "CARTESI_COMPUTATION_HASH_CORPUS_PATH must name the extracted v0.21 corpus directory",
    );
    let corpus = PathBuf::from(corpus_path);
    assert!(
        corpus.is_dir(),
        "CARTESI_COMPUTATION_HASH_CORPUS_PATH is not a directory: {}",
        corpus.display()
    );
    let manifest_path = corpus.join("manifest.json");
    let manifest_bytes = std::fs::read(&manifest_path).unwrap_or_else(|error| {
        panic!(
            "failed to read corpus manifest {}: {error}",
            manifest_path.display()
        )
    });
    let manifest: serde_json::Value =
        serde_json::from_slice(&manifest_bytes).unwrap_or_else(|error| {
            panic!(
                "failed to parse corpus manifest {}: {error}",
                manifest_path.display()
            )
        });
    let cases = manifest
        .as_array()
        .expect("corpus manifest must be an array")
        .clone();
    (corpus, cases)
}

fn corpus_cli() -> String {
    std::env::var("CARTESI_MACHINE_CLI").unwrap_or_else(|_| "cartesi-machine".into())
}

fn assert_corpus_cli_version(cli: &str) {
    let version = Command::new(cli).arg("--version").output().unwrap();
    assert!(version.status.success(), "failed to run {cli} --version");
    let version = String::from_utf8_lossy(&version.stdout);
    assert!(
        version
            .lines()
            .next()
            .is_some_and(|line| line == "cartesi-machine 0.21.0"),
        "corpus requires cartesi-machine 0.21.0, found {version:?}"
    );
}

fn corpus_expected_string(value: &serde_json::Value) -> String {
    value
        .as_str()
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| value.to_string())
}

fn run_corpus_cli_case(
    corpus: &Path,
    cli: &str,
    case: &serde_json::Value,
) -> (Output, Option<Vec<u8>>) {
    let id = case["id"].as_str().unwrap();
    let result = case["result"].as_str().unwrap();
    let output_dir = scratch();
    let output_path = output_dir.path().join(format!("{id}.bin"));
    let argv = case["argv"].as_array().unwrap();
    let mut args: Vec<String> = argv
        .iter()
        .skip(1)
        .map(|arg| {
            arg.as_str()
                .unwrap()
                .replace(result, output_path.to_str().unwrap())
        })
        .collect();
    if args.iter().any(|arg| arg == "--remote-spawn") {
        // The corpus process must own the remote server's lifetime.
        // Otherwise it inherits these captured pipes and `output` waits
        // forever after the CLI itself exits.
        args.push("--remote-shutdown".into());
    }

    let output = Command::new(cli)
        .args(&args)
        .current_dir(corpus)
        .output()
        .unwrap_or_else(|error| panic!("{id}: failed to run CLI: {error}"));
    let hash = output_path.exists().then(|| {
        std::fs::read(&output_path)
            .unwrap_or_else(|error| panic!("{id}: failed to read CLI computation hash: {error}"))
    });
    (output, hash)
}

/// Replays the complete release manifest through the installed CLI. This is
/// release-package conformance, not a Dave differential: all mcycle and uarch
/// cases, including nonzero exits and the no-hash failure, belong here.
#[test]
#[ignore = "requires the pinned Cartesi Machine v0.21 computation-hash corpus"]
fn computation_hash_corpus_cli_matches_release_manifest() {
    let (corpus, cases) = computation_hash_corpus();
    let cli = corpus_cli();
    assert_corpus_cli_version(&cli);

    let mut mcycle_count = 0;
    let mut uarch_count = 0;
    for case in &cases {
        let id = case["id"].as_str().unwrap();
        let category = case["expected"]["category"].as_str().unwrap();
        assert!(
            matches!(category, "success-hash" | "nonzero-hash" | "error-no-hash"),
            "{id}: unknown release category {category}"
        );
        let expected_status = case["expected"]["exit_status"].as_i64().unwrap() as i32;
        let (output, cli_hash) = run_corpus_cli_case(&corpus, &cli, case);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(expected_status),
            "{id}: CLI status; stderr:\n{}",
            stderr
        );
        assert_eq!(
            output.status.success(),
            category == "success-hash",
            "{id}: category vs exit status"
        );

        let wants_hash = matches!(category, "success-hash" | "nonzero-hash");
        assert_eq!(cli_hash.is_some(), wants_hash, "{id}: hash-file presence");
        if let Some(cli_hash) = cli_hash {
            assert_eq!(cli_hash.len(), 32, "{id}: CLI hash length");
            let cli_hash_hex = format!("0x{}", hex::encode(&cli_hash));
            let expected = case["expected"]["computation_hash"].as_str().unwrap();
            assert_eq!(cli_hash_hex, expected, "{id}: CLI vs release manifest");
            assert_eq!(
                cli_hash,
                std::fs::read(corpus.join(case["result"].as_str().unwrap())).unwrap(),
                "{id}: CLI vs recorded result"
            );
            let label = if case["level"] == "mcycle" {
                "Mcycle computation hash:"
            } else {
                "Uarch cycle computation hash:"
            };
            let printed = stderr.lines().find_map(|line| {
                line.split_once(label)
                    .and_then(|(_, value)| value.split_whitespace().next())
            });
            assert_eq!(
                printed,
                Some(expected),
                "{id}: stored hash was not printed; stderr:\n{stderr}"
            );
        } else {
            assert!(
                case["expected"].get("computation_hash").is_none(),
                "{id}: no-hash case has a manifest hash"
            );
            assert!(
                !stderr.contains("computation hash:"),
                "{id}: no-hash case printed a hash"
            );
        }

        if let Some(expected) = case["expected"]["stderr_contains"].as_str() {
            assert!(
                stderr.contains(expected),
                "{id}: missing diagnostic {expected:?}; stderr:\n{stderr}"
            );
        }
        if !case["expected"]["terminal_mcycle"].is_null() {
            let actual = stderr
                .lines()
                .filter_map(|line| {
                    line.split_once("Cycles:")
                        .and_then(|(_, value)| value.split_whitespace().next())
                })
                .next_back();
            let expected = corpus_expected_string(&case["expected"]["terminal_mcycle"]);
            assert_eq!(actual, Some(expected.as_str()), "{id}: terminal mcycle");
        }

        match case["level"].as_str().unwrap() {
            "mcycle" => mcycle_count += 1,
            "uarch" => uarch_count += 1,
            level => panic!("{id}: unexpected corpus level {level}"),
        }
        println!("{id}: {category}");
    }
    assert_eq!(mcycle_count, 17, "unexpected v0.21 mcycle corpus size");
    assert_eq!(uarch_count, 18, "unexpected v0.21 uarch corpus size");
}

/// Dave currently consumes the corpus's mcycle geometry only. Compare that
/// supported surface directly with the released answers; the separate CLI
/// conformance test owns replaying the release frontend and all uarch cases.
#[test]
#[ignore = "requires the pinned Cartesi Machine v0.21 computation-hash corpus"]
fn computation_hash_corpus_dave_matches_release_manifest() {
    let (corpus, cases) = computation_hash_corpus();

    let mut checked = 0;
    for case in &cases {
        if case["level"] != "mcycle" {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        let expected = case["expected"]["computation_hash"]
            .as_str()
            .unwrap_or_else(|| panic!("{id}: Dave-supported case has no computation hash"));
        let inputs = case["inputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|path| std::fs::read(corpus.join(path.as_str().unwrap())).unwrap())
            .collect();
        let log2_mcycle_period = case["geometry"]["log2_mcycle_period"].as_u64().unwrap();
        let log2_stride = log2_mcycle_period + Structure::PRODUCTION.log2_uarch_span;
        let height = Structure::PRODUCTION.log2_ruler_span() - log2_stride;
        let engine_hash = engine_root_with_inputs(
            &corpus.join(case["template"].as_str().unwrap()),
            inputs,
            log2_stride,
            height,
        );
        assert_eq!(engine_hash, expected, "{id}: Dave vs release manifest");
        checked += 1;
        println!("{id}: {engine_hash}");
    }
    assert_eq!(checked, 17, "unexpected v0.21 mcycle corpus size");
}

/// Engine vs prototype on identical spans, at three granularities: the
/// uarch span of the fused first big cycle, a mid-stride span, and a
/// coarse span that crosses the first input's yield into padding.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn reference_collector_matches_prototype() {
    let image = echo_image();

    // (label, log2_stride, height): spans all start at position 0 and
    // fit inside window 0, which is all the prototype's machine-backed
    // builder supports (deeper levels never cross windows).
    let spans = [
        ("uarch_span_r0_h20", 0u64, 20u64),
        ("mid_stride_r27_h10", 27, 10),
        ("coarse_r44_h4", 44, 4),
    ];

    for (index, (label, log2_stride, height)) in spans.into_iter().enumerate() {
        let prototype = prototype_root(&image, index as u64, log2_stride, height);
        let engine = engine_root(&image, log2_stride, height);
        assert_eq!(
            engine, prototype,
            "engine and prototype disagree on {label}"
        );
        println!("{label}: {engine}");
    }
}

/// The prototype's whole in-memory commitment for a span.
fn prototype_commitment(
    image: &Path,
    level: u64,
    base_cycle: U256,
    log2_stride: u64,
    log2_stride_count: u64,
) -> MachineCommitment {
    let dir = scratch();
    let db = EpochData::new(echo_inputs(), dir.path().to_path_buf()).unwrap();
    let mut builder = MachineCommitmentBuilder::new(image.to_str().unwrap().into());
    builder
        .build_commitment(base_cycle, level, log2_stride, log2_stride_count, &db)
        .unwrap()
}

/// A dispute source over a freshly initialized state dir: the epoch
/// start is the only stored boundary, i.e. the template-replay
/// behavior - until its own positioning densifies the store.
fn machine_source(image: &Path) -> (Vec<tempfile::TempDir>, DisputeSource<Positioner>) {
    let (state_dir, storage) = initialized_storage(image);
    let work = scratch();
    let source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();
    (vec![state_dir, work], source)
}

/// The increment-C differential: every query shape the Player sends
/// during a dispute (roots, bisection children, seal and join proofs)
/// against the prototype's in-memory tree, on the real machine. Two
/// levels: a mid-stride level at the epoch start, and a uarch-stride
/// level inside window 1, which crosses an input feed during replay.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn dispute_source_matches_prototype_tree() {
    let image = echo_image();

    let spans = [
        ("mid_stride_r27_h10", U256::ZERO, 27u64, 10u64),
        ("window1_uarch_r0_h20", U256::from(1) << 68, 0, 20),
        // The shape that lost the first e2e dispute: a uarch-stride
        // level over pure idle padding (echo yielded long before
        // 2^44), where the leaf material is the idle churn pattern.
        ("idle_padding_r0_h28", U256::from(1) << 44, 0, 28),
    ];

    for (index, (label, base, log2_stride, height)) in spans.into_iter().enumerate() {
        let prototype = prototype_commitment(&image, index as u64, base, log2_stride, height);
        let (_scratch, mut source) = machine_source(&image);
        let level = LevelCoords::new(0, base, log2_stride, height);

        let root = source.node(&level.root()).unwrap();
        assert_eq!(root, prototype.merkle.root_hash(), "{label}: root");

        let (left, right) = source.children(&level.root()).unwrap();
        let (pl, pr) = prototype.merkle.subtrees().unwrap();
        assert_eq!(
            (left, right),
            (pl.root_hash(), pr.root_hash()),
            "{label}: root children"
        );

        // Proof descents at the shapes the strategy sends: the join's
        // last-leaf proof and a mid-tree agree proof. Indices cross
        // fanout strata (heights 10 and 20 both exceed one stratum).
        let last = source.prove_last(&level).unwrap();
        let expected_last = prototype.merkle.prove_last();
        assert_eq!(last.node, expected_last.node, "{label}: last leaf");
        assert_eq!(last.siblings, expected_last.siblings, "{label}: last proof");

        let mid = (U256::from(1) << height) / U256::from(2) - U256::from(1);
        let agree = source.prove_leaf(&level, mid).unwrap();
        let expected_agree = prototype.merkle.prove_leaf(mid);
        assert_eq!(agree.node, expected_agree.node, "{label}: agree leaf");
        assert_eq!(
            agree.siblings, expected_agree.siblings,
            "{label}: agree proof"
        );

        println!("{label}: {}", root.to_hex());
    }
}

/// The increment-D differential: a source answering with a mid-epoch
/// snapshot must produce the same tree material as the template
/// replay, on the query shapes the Player sends. The snapshot is the
/// window-1 boundary, produced the production way: a write-back
/// ruler crosses it and commits it into the store the resumed
/// source reads.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn snapshot_resumed_source_matches_template_replay() {
    let image = echo_image();

    let (_replayed_scratch, mut replayed) = machine_source(&image);
    let (resumed_scratch, mut resumed) = machine_source(&image);

    // Cross boundary 1 with a write-back stf: feed(input 0) commits
    // boundary 0 (absorbed - the epoch start), feed(input 1) commits
    // boundary 1. The post-feed machine is discarded scratch.
    {
        let work = scratch();
        let stf = MachineStf::load(&image, work.path().to_path_buf()).unwrap();
        let mut stf = stf.with_write_back(Storage::new(resumed_scratch[0].path()).unwrap(), 0, 0);
        stf.feed(0).unwrap();
        while stf.run_big(u64::MAX).unwrap() > 0 {}
        assert!(stf.yielded().unwrap());
        stf.feed(1).unwrap();
    }
    let mut check = Storage::new(resumed_scratch[0].path()).unwrap();
    assert_eq!(check.nearest_boundary_at_or_before(0, 1).unwrap().0.0, 1);

    let level = LevelCoords::new(0, U256::from(1) << 68, 0, 20);

    assert_eq!(
        resumed.node(&level.root()).unwrap(),
        replayed.node(&level.root()).unwrap(),
        "root"
    );
    assert_eq!(
        resumed.children(&level.root()).unwrap(),
        replayed.children(&level.root()).unwrap(),
        "children"
    );
    let (a, b) = (
        resumed.prove_last(&level).unwrap(),
        replayed.prove_last(&level).unwrap(),
    );
    assert_eq!(a.node, b.node, "last leaf");
    assert_eq!(a.siblings, b.siblings, "last proof");
    let mid = U256::from(1) << 10;
    let (a, b) = (
        resumed.prove_leaf(&level, mid).unwrap(),
        replayed.prove_leaf(&level, mid).unwrap(),
    );
    assert_eq!(a.node, b.node, "mid leaf");
    assert_eq!(a.siblings, b.siblings, "mid proof");
}

/// Step-5 write-back: positioning that crosses a window boundary
/// commits it into the boundary store, so the next ruler resumes at
/// most one window away - and a boundary regime 1 already recorded
/// absorbs identically (the cross-regime tripwire staying silent on
/// agreement).
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn positioning_writes_back_crossed_boundaries() {
    let image = echo_image();

    let (guards, mut source) = machine_source(&image);
    let mut storage = Storage::new(guards[0].path()).unwrap();

    // A fresh store has only the epoch start.
    let (floor, _) = storage.nearest_boundary_at_or_before(0, 1).unwrap();
    assert_eq!(floor.0, 0);

    // A window-1 quartet: positioning replays across boundary 1.
    let level = LevelCoords::new(0, U256::from(1) << 68, 0, 20);
    source.node(&level.root()).unwrap();

    // The replay fed input 0, so boundary 1 is now stored and the
    // next positioning starts there.
    let (boundary, path) = storage.nearest_boundary_at_or_before(0, 1).unwrap();
    assert_eq!(boundary.0, 1);
    assert!(path.join("config.json").exists());
    assert!(storage.snapshot_hash(0, 1).unwrap().is_some());
}

/// The emulator semantics the ruler's idle replay relies on, pinned
/// executably: stepping the uarch of a yielded machine is not an
/// identity (the emulated interpreter churns its own bookkeeping), the
/// churn sequence is identical on every idle span, and the closing
/// ureset restores the base hash exactly. If an emulator bump breaks
/// any of these, idle regions can no longer be replayed from one
/// stepped span and the convention itself must be revisited.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn idle_spans_are_periodic_and_ureset_restores_the_base() {
    let image = echo_image();

    let work = scratch();
    let mut stf = MachineStf::load(&image, work.path().to_path_buf())
        .unwrap()
        .with_inputs(echo_inputs());
    stf.feed(0).unwrap();
    while stf.run_big(u64::MAX).unwrap() > 0 {}
    assert!(stf.yielded().unwrap());

    let base = stf.state_hash().unwrap();
    let mut spans = vec![];
    for _ in 0..2 {
        let mut hashes = vec![];
        while !stf.uarch_halted().unwrap() {
            stf.ustep().unwrap();
            hashes.push(stf.state_hash().unwrap());
        }
        stf.ureset().unwrap();
        assert_eq!(
            stf.state_hash().unwrap(),
            base,
            "idle ureset must restore the base state"
        );
        spans.push(hashes);
    }
    assert!(!spans[0].is_empty(), "idle churn must be observable");
    assert_ne!(spans[0][0], base, "idle usteps are not identities");
    assert_eq!(spans[0], spans[1], "idle spans must be periodic");
}

/// The full-epoch level-0 commitment shape has no in-crate prototype
/// comparator (the prototype gets those leaves from the node); pin it
/// as a golden fixture instead, along with the differential roots.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn golden_fixtures_hold() {
    let image = echo_image();

    let mut computed = BTreeMap::new();
    computed.insert("template_hash".to_string(), template_hash(&image));
    computed.insert(
        "epoch_root_r44_h48".to_string(),
        engine_root(&image, 44, 48),
    );
    computed.insert("uarch_span_r0_h20".to_string(), engine_root(&image, 0, 20));
    computed.insert(
        "mid_stride_r27_h10".to_string(),
        engine_root(&image, 27, 10),
    );

    let path = fixture_path();
    if std::env::var("UPDATE_FIXTURES").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, serde_json::to_string_pretty(&computed).unwrap()).unwrap();
        println!("fixtures written to {}", path.display());
        return;
    }

    let stored: BTreeMap<String, String> =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap_or_else(|_| {
            panic!(
                "fixture file missing: {}; generate it with UPDATE_FIXTURES=1 \
                 and commit it after review",
                path.display()
            )
        }))
        .unwrap();

    assert_eq!(
        computed, stored,
        "golden fixtures diverged; if the emulator or the echo image \
         changed intentionally, regenerate with UPDATE_FIXTURES=1"
    );
}

/// The workstream-4 differential: the ruler-guided proof path
/// (DisputeSource::machine_at + Ruler::prove_transition) must produce
/// byte-identical chain witnesses to the prototype's get_logs, across
/// the transition shapes reachable on the echo epoch: the fed window
/// start, a plain ustep, a closing slot, and an inputless window
/// start (empty data availability). The revert-carrying closing slot
/// is covered by revert_closing_slot_restores_the_checkpoint below and
/// pinned on-chain by the stf_revert e2e scenario.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn prove_transition_matches_prototype_get_logs() {
    let image = echo_image();

    let structure = Structure::PRODUCTION;
    let inputs = echo_inputs();

    let shapes = [
        ("fed_window_start", U256::ZERO),
        ("plain_ustep", U256::from(1)),
        ("closing_slot", U256::from(structure.big_span() - 1)),
        ("inputless_window_start", structure.window_start(2)),
    ];

    for (label, meta_cycle) in shapes {
        // Both sides position independently from the template.
        // The state dir is a guard: storage lives inside it.
        let (_state_dir, storage) = initialized_storage(&image);
        let work = scratch();
        let mut source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();
        let mut ruler = source.machine_at(meta_cycle).unwrap();
        let agree = ruler.state_hash().unwrap();
        let (new_proof, new_next) = ruler.prove_transition().unwrap();

        let dir = scratch();
        let db = EpochData::new(inputs.clone(), dir.path().to_path_buf()).unwrap();
        let (old_proof, old_next) =
            MachineInstance::get_logs(image.to_str().unwrap(), 0, agree, meta_cycle, &db).unwrap();

        assert_eq!(
            new_proof, old_proof,
            "proof bytes diverge at {label} (position {meta_cycle})"
        );
        assert_eq!(
            new_next, old_next,
            "post-transition hash diverges at {label} (position {meta_cycle})"
        );
        println!("{label}: {} witness bytes agree", new_proof.len());
    }
}

/// The revert-carrying closing slot, on the yield machine (which
/// rejects every input). Three agreements, in dependency order: the
/// plain path's closing leaf must be the restored checkpoint (the
/// pre-feed state - what the chain restores from the shadow slot);
/// the proving path must report that same post-state (the hero's
/// pre-send check compares it against the commitment, so a prover
/// that reports the discarded rejected state instead can never send
/// winLeafMatch and forfeits by clock); and the witness bytes must
/// match the prototype proof path.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn revert_closing_slot_restores_the_checkpoint() {
    let image = yield_image();

    let structure = Structure::PRODUCTION;
    let big_span = U256::from(structure.big_span());
    let inputs = yield_inputs();

    let (_state_dir, storage) = initialized_storage_with(&image, inputs.clone());
    let work = scratch();
    let mut source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();

    // The agreed pre-state of the window: what the feed checkpoints
    // and what the revert must restore.
    let pre_feed = {
        let mut ruler = source.machine_at(U256::ZERO).unwrap();
        ruler.state_hash().unwrap()
    };

    // Find where the reject lands: feed window 0 and run the big
    // machine until the guest yields. The closing slot of that big
    // cycle carries the revert (mirrors stf_revert's oracle-reported
    // processing_bigs).
    let bigs = {
        let ruler = source.machine_at(U256::ZERO).unwrap();
        let mut stf = ruler.into_stf();
        stf.feed(0).unwrap();
        let ran = stf.run_big(u64::MAX).unwrap();
        assert!(stf.yielded().unwrap(), "the yield program must yield");
        assert!(ran > 0, "the guest must run before yielding");
        ran
    };
    let boundary = U256::from(bigs) * big_span;
    assert!(boundary < (U256::ONE << 44), "input overran a level-0 leaf");
    let closing = boundary - U256::ONE;

    // The built leaf, through the plain path.
    let built = {
        let mut ruler = source.machine_at(closing).unwrap();
        let runs = ruler.collect(boundary, 0).unwrap();
        runs.last().unwrap().hash
    };
    assert_eq!(
        built, pre_feed,
        "the revert must restore the pre-feed state"
    );

    // The proving path must report the post-state it just proved the
    // chain would compute.
    let mut ruler = source.machine_at(closing).unwrap();
    let agree = ruler.state_hash().unwrap();
    let (proof, post) = ruler.prove_transition().unwrap();
    assert_eq!(
        post, built,
        "prove_transition post-state diverges from the built leaf at the revert closing slot"
    );

    // Differential: the prototype proof path agrees on bytes and
    // post-state.
    let dir = scratch();
    let db = EpochData::new(inputs, dir.path().to_path_buf()).unwrap();
    let (old_proof, old_post) =
        MachineInstance::get_logs(image.to_str().unwrap(), 0, agree, closing, &db).unwrap();
    assert_eq!(
        proof, old_proof,
        "revert witness bytes diverge from the prototype"
    );
    assert_eq!(
        post, old_post,
        "post-transition hash diverges from the prototype at the revert closing slot"
    );
    println!(
        "revert closing slot at big cycle {bigs}: {} witness bytes agree",
        proof.len()
    );
}
