// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Increment B differentials: the engine reference collector against the
//! prototype's commitment builder, on the real echo machine, plus golden
//! fixtures pinning the roots, and the eager runner against the reference
//! CLI's answers.
//!
//! The image-backed tests are ignored by generic Cargo runs and exercised by
//! the fail-loud `just test-engine-machine` gate. The fixture files record
//! template hashes: an emulator or image bump invalidates them loudly, and
//! regeneration (UPDATE_FIXTURES=1) is a conscious, reviewable act.

use alloy::primitives::{Address, U256};
use alloy::sol_types::SolCall;
mod common;
use common::prototype::{MachineCommitment, MachineCommitmentBuilder};

use cartesi_machine::config::runtime::RuntimeConfig;
use cartesi_machine::constants::break_reason;
use cartesi_machine::machine::Machine;
use cartesi_machine::types::{Hash, cmio::CmioResponseReason};
use cartesi_rollups_prt_node::engine::{
    Collector, DisputeSource, Hashing, Level, LevelCoords, MachineStf, Positioner, Quartet, Ruler,
    Stf, Structure, TournamentGeometry, fold_runs,
};
use cartesi_rollups_prt_node::machine_runner::MachineRunner;
use cartesi_rollups_prt_node::merkle::{Digest, MerkleProof};
use cartesi_rollups_prt_node::storage::{
    Epoch, Input as StorageInput, InputId, LeafProof, Storage, Template,
};
use cartesi_rollups_prt_node::sync::ShutdownSignal;
use common::epoch_data::EpochData;
use common::instance::MachineInstance;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::Duration;

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

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn read_fixture(path: &Path) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap_or_else(|_| {
        panic!(
            "fixture file missing: {}; generate it with UPDATE_FIXTURES=1 \
             and commit it after review",
            path.display()
        )
    }))
    .unwrap()
}

/// Regeneration (UPDATE_FIXTURES=1) is a conscious, reviewable act;
/// otherwise the computed values must equal the checked-in ones.
fn check_fixture(name: &str, computed: serde_json::Value) {
    let path = fixture_path(name);
    if std::env::var("UPDATE_FIXTURES").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, serde_json::to_string_pretty(&computed).unwrap()).unwrap();
        println!("fixtures written to {}", path.display());
        return;
    }
    assert_eq!(
        computed,
        read_fixture(&path),
        "{name} diverged; if the emulator or an image changed \
         intentionally, regenerate with UPDATE_FIXTURES=1"
    );
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
    let mut stf = MachineStf::load(image, work.path().to_path_buf(), Hashing::Sampled).unwrap();
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

fn geometry(pairs: &[(u64, u64)]) -> TournamentGeometry {
    TournamentGeometry::new(
        pairs
            .iter()
            .map(|&(log2_stride, height)| Level {
                log2_stride,
                height,
            })
            .collect(),
        &Structure::PRODUCTION,
    )
    .unwrap()
}

fn three_level() -> TournamentGeometry {
    geometry(&[(44, 48), (27, 17), (0, 27)])
}

fn two_level() -> TournamentGeometry {
    geometry(&[(37, 55), (0, 37)])
}

/// A real initialized node database in a temp state dir, the echo
/// inputs ingested through the production path (payloads live in the
/// inputs table; feeders read them there). The guard rides along:
/// the state dir must outlive the Storage.
fn initialized_storage(image: &Path) -> (tempfile::TempDir, Storage) {
    initialized_storage_with(image, echo_inputs())
}

/// These differentials sample the machine path, so the pinned run
/// stride only needs to be valid.
fn initialized_storage_with(image: &Path, inputs: Vec<Vec<u8>>) -> (tempfile::TempDir, Storage) {
    initialized_storage_under(image, inputs, &three_level())
}

fn initialized_storage_under(
    image: &Path,
    inputs: Vec<Vec<u8>>,
    geometry: &TournamentGeometry,
) -> (tempfile::TempDir, Storage) {
    let dir = scratch();
    let mut storage = Storage::initialize(
        dir.path(),
        &Template::inspect(image).unwrap(),
        0,
        Address::ZERO,
        Address::ZERO,
        0,
        geometry,
    )
    .unwrap();
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
    geometry: &TournamentGeometry,
    log2_stride: u64,
    height: u64,
) -> String {
    engine_level_root(
        image,
        inputs,
        geometry,
        &LevelCoords::new(0, U256::ZERO, log2_stride, height),
    )
}

/// The facade's root for one level, replayed on a fresh store. A dense
/// level builds both ways, with the production bulk collector and the
/// stepped reference, which must agree: an answer checked here is never
/// the collect API's alone (computation-hash.md).
fn engine_level_root(
    image: &Path,
    inputs: Vec<Vec<u8>>,
    geometry: &TournamentGeometry,
    level: &LevelCoords,
) -> String {
    let collectors: &[Collector] = if level.log2_stride == 0 {
        &[Collector::Bulk, Collector::Stepped]
    } else {
        &[Collector::Bulk]
    };
    let roots: Vec<String> = collectors
        .iter()
        .map(|&collector| {
            let (state_dir, storage) = initialized_storage_under(image, inputs.clone(), geometry);
            let work = scratch();
            let mut source =
                DisputeSource::on_store_with(storage, 0, work.path().to_path_buf(), collector)
                    .unwrap();
            let root = source.node(&level.root()).unwrap().to_hex();
            drop((state_dir, work));
            root
        })
        .collect();
    assert!(
        roots.iter().all(|root| *root == roots[0]),
        "the collectors disagree at {level:?}: {roots:?}"
    );
    roots[0].clone()
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

/// The one corpus case outside Dave's model, with the released hash the
/// exclusion was judged against.
const UARCH_OUT_OF_MODEL: (&str, &str) = (
    "uarch-near-limit-tail",
    "0x8c40a7ed8c6327731bc0444947574e39593c5c1cddcefbeeebdca6461150315b",
);

/// Whether the node refuses a template at startup for lacking the pristine
/// uarch every big-cycle boundary must carry.
fn refused_as_non_pristine(image: &Path) -> bool {
    match Template::inspect(image) {
        Ok(_) => false,
        Err(error) => format!("{error:#}").contains("pristine uarch"),
    }
}

/// Dave against the released answers: every mcycle case as a whole-epoch
/// root, and every uarch case as a stride-0 leaf of height 29 (period 9,
/// the big-cycle-root builder). Two uarch cases are not compared:
/// uarch-overflow-tail has no released hash, and uarch-near-limit-tail is
/// out of model. Its template carries custom uarch code instead of the
/// deployed step's pristine uarch, which Dave, the CLI and Lua all assume
/// at big-cycle boundaries; Solidity, the CLI and Dave give three different
/// roots there (docs/computation-hash.md). Upstream 22b4431 makes it
/// error-no-hash; drop the exclusion when the corpus comes from a release
/// that carries it. The node refuses such a template at startup, and the
/// exclusion asserts that refusal and the released hash, so a changed
/// template or answer forces a revisit.
#[test]
#[ignore = "requires the pinned Cartesi Machine v0.21 computation-hash corpus"]
fn computation_hash_corpus_dave_matches_release_manifest() {
    let (corpus, cases) = computation_hash_corpus();
    let structure = Structure::PRODUCTION;

    let (mut mcycle, mut uarch, mut excluded, mut no_hash) = (0, 0, 0, 0);
    for case in &cases {
        let id = case["id"].as_str().unwrap();
        let image = corpus.join(case["template"].as_str().unwrap());
        let expected = case["expected"]["computation_hash"].as_str();
        if id == UARCH_OUT_OF_MODEL.0 {
            assert!(
                refused_as_non_pristine(&image),
                "{id}: the node no longer refuses this template; compare the case"
            );
            assert_eq!(
                expected,
                Some(UARCH_OUT_OF_MODEL.1),
                "{id}: the released answer changed; revisit the exclusion"
            );
            excluded += 1;
            continue;
        }
        let Some(expected) = expected else {
            assert_eq!(case["expected"]["category"], "error-no-hash", "{id}");
            no_hash += 1;
            continue;
        };
        let inputs = case["inputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|path| std::fs::read(corpus.join(path.as_str().unwrap())).unwrap())
            .collect();
        let geometry = &case["geometry"];
        let log2_period = geometry["log2_mcycle_period"].as_u64().unwrap();
        let level = match case["level"].as_str().unwrap() {
            "mcycle" => {
                mcycle += 1;
                let log2_stride = log2_period + structure.log2_uarch_span;
                LevelCoords::new(
                    0,
                    U256::ZERO,
                    log2_stride,
                    structure.log2_ruler_span() - log2_stride,
                )
            }
            "uarch" => {
                uarch += 1;
                // The CLI numbers periods across the whole epoch.
                let index = geometry["mcycle_period_index"].as_u64().unwrap();
                let per_input = structure.log2_barch_span - log2_period;
                let (input, period) = (index >> per_input, index & ((1 << per_input) - 1));
                let height = log2_period + structure.log2_uarch_span;
                let base = structure.window_start(input) + (U256::from(period) << height);
                LevelCoords::new(0, base, 0, height)
            }
            level => panic!("{id}: unexpected corpus level {level}"),
        };
        let engine_hash = engine_level_root(&image, inputs, &three_level(), &level);
        assert_eq!(engine_hash, expected, "{id}: Dave vs release manifest");
        println!("{id}: {engine_hash}");
    }
    assert_eq!(
        (mcycle, uarch, excluded, no_hash),
        (17, 16, 1, 1),
        "unexpected v0.21 corpus shape"
    );
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
        // The big-cycle-root builder's active branch: the first 2^8 big
        // cycles of window 1 run the input, so every cycle executes.
        ("window1_active_r0_h28", U256::from(1) << 68, 0, 28),
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
        let stf = MachineStf::load(&image, work.path().to_path_buf(), Hashing::Sampled).unwrap();
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

/// Positioning into a later window registers that window's boundary,
/// so the next ruler resumes there - and a boundary regime 1 already
/// recorded absorbs identically (the cross-regime tripwire staying
/// silent on agreement).
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
    let mut stf = MachineStf::load(&image, work.path().to_path_buf(), Hashing::Sampled)
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

    check_fixture("engine_echo.json", serde_json::json!(computed));
}

/// The epochs the runner settles. Echo rejects its third input
/// (`--reject=2`), so its epoch takes both record paths; that input
/// runs about 151k mcycles, so at the two-level period 2^17 one sample
/// falls inside it and the revert shows in the root. Yield rejects
/// every input, so its epoch ends on the state it started from.
fn runner_epochs() -> [(&'static str, PathBuf, Vec<Vec<u8>>); 2] {
    [
        (
            "echo",
            echo_image(),
            encode_inputs(&[&b"zero"[..], b"one", b"two", b"three"]),
        ),
        (
            "yield",
            yield_image(),
            encode_inputs(&[&b"zero"[..], b"one"]),
        ),
    ]
}

/// The CLI samples mcycles; the root stride also spans the uarch.
fn reference_cli_period(geometry: &TournamentGeometry) -> u64 {
    geometry.root_stride() - Structure::PRODUCTION.log2_uarch_span
}

fn reference_cli_key(program: &str, geometry: &TournamentGeometry) -> String {
    format!(
        "{program}/log2_mcycle_period_{}",
        reference_cli_period(geometry)
    )
}

/// Runs the released CLI over the image's epoch with `options` added to
/// its advance-state settings, returning its output and its scratch
/// directory (holding `input-<i>.bin`). It runs a clone in stored revert
/// mode (the default fork mode needs a machine server); outputs, reports
/// and proofs are off unless `options` names them.
fn run_reference_cli(
    cli: &str,
    image: &Path,
    inputs: &[Vec<u8>],
    options: &str,
    flags: &[&str],
) -> (Output, tempfile::TempDir) {
    let dir = scratch();
    for (index, input) in inputs.iter().enumerate() {
        std::fs::write(dir.path().join(format!("input-{index}.bin")), input).unwrap();
    }
    let advance = format!(
        "input:{},input_index_begin:0,input_index_end:{},output:,rejected_output:,\
         output_proof:,report:,outputs_merkle_root:,outputs_merkle_root_proof:,\
         check_outputs_merkle_root:false,{options}",
        dir.path().join("input-%i.bin").display(),
        inputs.len(),
    );
    let output = Command::new(cli)
        .current_dir(dir.path())
        .args(flags)
        .arg("--revert-mode=stored")
        .arg(format!(
            "--load={},clone:{},sharing:all",
            dir.path().join("machine").display(),
            image.display()
        ))
        .arg(format!("--cmio-advance-state={advance}"))
        .output()
        .unwrap_or_else(|error| panic!("failed to run {cli}: {error}"));
    assert!(
        output.status.success(),
        "reference CLI failed; stderr:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    (output, dir)
}

/// One computation hash: `hash` names the CLI's output key and
/// `options` its period settings.
fn reference_cli_hash(
    cli: &str,
    image: &Path,
    inputs: &[Vec<u8>],
    hash: &str,
    options: &str,
) -> String {
    let options = format!("{hash}:computation-hash.bin,{options}");
    let (_, dir) = run_reference_cli(cli, image, inputs, &options, &[]);
    let hash = std::fs::read(dir.path().join("computation-hash.bin"))
        .expect("the reference CLI wrote no computation hash");
    assert_eq!(hash.len(), 32, "malformed reference computation hash");
    format!("0x{}", hex::encode(hash))
}

/// The epoch's end per the CLI: the final machine state (the last
/// `<mcycle>: <hash>` line `--final-hash` prints) and the outputs Merkle
/// root after the last accepted input, if any input was accepted.
fn reference_cli_epoch_end(
    cli: &str,
    image: &Path,
    inputs: &[Vec<u8>],
) -> (String, Option<String>) {
    let options = "outputs_merkle_root:outputs-root-%i.bin,check_outputs_merkle_root:true";
    let (output, dir) = run_reference_cli(cli, image, inputs, options, &["--final-hash"]);
    let printed = [output.stdout, output.stderr].concat();
    let final_state = String::from_utf8_lossy(&printed)
        .lines()
        .filter_map(|line| {
            let (mcycle, hash) = line.split_once(": ")?;
            (mcycle.parse::<u64>().is_ok() && hash.len() == 66 && hash.starts_with("0x"))
                .then(|| hash.to_string())
        })
        .next_back()
        .expect("the reference CLI printed no final hash");
    let outputs_root = (0..inputs.len()).rev().find_map(|index| {
        std::fs::read(dir.path().join(format!("outputs-root-{index}.bin")))
            .ok()
            .map(|root| format!("0x{}", hex::encode(root)))
    });
    (final_state, outputs_root)
}

/// The CLI's epoch root at the table's root stride.
fn reference_cli_root(
    cli: &str,
    image: &Path,
    inputs: &[Vec<u8>],
    geometry: &TournamentGeometry,
) -> String {
    let options = format!(
        "log2_mcycle_computation_hash_period:{}",
        reference_cli_period(geometry)
    );
    reference_cli_hash(cli, image, inputs, "mcycle_computation_hash", &options)
}

/// A leaf commitment the CLI answers independently: its uarch cycle
/// computation hash over one mcycle period is Dave's stride-0
/// commitment under a root leaf at stride `log2_period + 20`.
#[derive(Clone, Copy)]
struct LeafCase {
    program: &'static str,
    log2_period: u64,
    input: u64,
    period: u64,
}

impl LeafCase {
    fn key(&self) -> String {
        format!(
            "{}/uarch/log2_period_{}/input_{}/period_{}",
            self.program, self.log2_period, self.input, self.period
        )
    }

    /// The CLI numbers periods across the whole epoch.
    fn epoch_period_index(&self) -> u64 {
        (self.input << (Structure::PRODUCTION.log2_barch_span - self.log2_period)) | self.period
    }

    fn level(&self) -> LevelCoords {
        let structure = Structure::PRODUCTION;
        let height = self.log2_period + structure.log2_uarch_span;
        let base = structure.window_start(self.input) + (U256::from(self.period) << height);
        LevelCoords::new(0, base, 0, height)
    }
}

/// Period 8 builds from big-cycle roots (height 28, the path a switch to
/// the collect API replaces) and period 7 by plain collection (height 27,
/// the three-level leaf). The periods sit where the leaf semantics
/// change: a fed window start, an accepted yield (echo's input 0 runs
/// 2,224,031 mcycles), a rejection's revert (echo's input 2 runs 151,403
/// and yield's 702,302), a revert crossed while positioning (yield's
/// input 1), and a padding window. Period 17, the two-level leaf, is the
/// same builder at a greater height; the CLI spends about 2 minutes on a
/// mostly idle period-17 leaf and more than 13 on a dense one.
fn leaf_cases() -> Vec<LeafCase> {
    let case = |program, log2_period, input, period| LeafCase {
        program,
        log2_period,
        input,
        period,
    };
    vec![
        case("echo", 8, 0, 0),
        case("echo", 8, 0, 8687),
        case("echo", 8, 2, 591),
        case("echo", 8, 4, 0),
        case("echo", 7, 0, 0),
        case("echo", 7, 0, 17375),
        case("echo", 7, 2, 1182),
        case("yield", 8, 0, 2743),
        case("yield", 7, 1, 5486),
    ]
}

fn reference_cli_leaf(cli: &str, image: &Path, inputs: &[Vec<u8>], case: LeafCase) -> String {
    let options = format!(
        "log2_mcycle_computation_hash_period:{},mcycle_period_index:{}",
        case.log2_period,
        case.epoch_period_index()
    );
    reference_cli_hash(cli, image, inputs, "uarch_cycle_computation_hash", &options)
}

/// The answers behind runner_settles_the_reference_root, computed by
/// the released CLI rather than Dave code. The template hashes pin the
/// images they answer for. Outside the engine gate because it needs
/// that exact CLI; CI runs it where the release package is installed.
#[test]
#[ignore = "requires the released cartesi-machine 0.21.0 CLI; run `just test-reference-cli-goldens`"]
fn reference_cli_goldens_hold() {
    let cli = corpus_cli();
    assert_corpus_cli_version(&cli);

    let mut computed = BTreeMap::new();
    for (program, image, inputs) in runner_epochs() {
        computed.insert(format!("{program}/template_hash"), template_hash(&image));
        let (final_state, outputs_root) = reference_cli_epoch_end(&cli, &image, &inputs);
        computed.insert(format!("{program}/final_state"), final_state);
        if let Some(outputs_root) = outputs_root {
            computed.insert(format!("{program}/outputs_merkle_root"), outputs_root);
        }
        for geometry in [three_level(), two_level()] {
            computed.insert(
                reference_cli_key(program, &geometry),
                reference_cli_root(&cli, &image, &inputs, &geometry),
            );
        }
        for case in leaf_cases()
            .into_iter()
            .filter(|case| case.program == program)
        {
            computed.insert(case.key(), reference_cli_leaf(&cli, &image, &inputs, case));
        }
    }

    check_fixture("reference_cli.json", serde_json::json!(computed));
}

/// One sealed epoch over `inputs`, ready for the runner at the given
/// snapshot gap.
fn sealed_epoch(
    image: &Path,
    inputs: Vec<Vec<u8>>,
    geometry: &TournamentGeometry,
    snapshot_gap: u64,
) -> (tempfile::TempDir, Storage) {
    let input_count = inputs.len() as u64;
    let (state_dir, mut storage) = initialized_storage_under(image, inputs, geometry);
    let sealed = Epoch {
        epoch_number: 0,
        input_index_boundary: input_count,
        root_tournament: Address::ZERO,
        block_created_number: 0,
    };
    storage
        .insert_consensus_data(1, std::iter::empty(), [&sealed].into_iter())
        .unwrap();
    storage.set_snapshot_gap_inputs(snapshot_gap);
    (state_dir, storage)
}

fn process_rollup(storage: Storage, shutdown: ShutdownSignal) {
    MachineRunner::new(storage, Duration::ZERO, shutdown)
        .unwrap()
        .process_rollup()
        .unwrap();
}

/// Runs one sealed epoch through the production runner (advance,
/// record, commit, roll) at the given snapshot gap.
fn run_sealed_epoch(
    image: &Path,
    inputs: Vec<Vec<u8>>,
    geometry: &TournamentGeometry,
    snapshot_gap: u64,
) -> tempfile::TempDir {
    let (state_dir, storage) = sealed_epoch(image, inputs, geometry, snapshot_gap);
    process_rollup(storage, ShutdownSignal::default());
    state_dir
}

/// A stop abandons the runner's batch: the runner checks for it before
/// each input, so a stopped runner commits nothing, and a restarted one
/// replays the batch and settles exactly as a run that never stopped.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn a_stopped_runner_drops_its_batch_and_a_restart_replays_it() {
    let image = echo_image();
    let inputs = runner_epochs()[0].2.clone();
    let input_count = inputs.len() as u64;
    let geometry = three_level();
    let (state_dir, storage) = sealed_epoch(&image, inputs.clone(), &geometry, 3);
    let stopped = ShutdownSignal::default();
    stopped.request();
    process_rollup(storage, stopped);

    let mut check = Storage::new(state_dir.path()).unwrap();
    for input in 1..=input_count {
        assert!(
            check.snapshot_hash(0, input).unwrap().is_none(),
            "a stopped runner published boundary {input}"
        );
    }
    assert!(check.settlement_info(0).unwrap().is_none());

    process_rollup(
        Storage::new(state_dir.path()).unwrap(),
        ShutdownSignal::default(),
    );
    let replayed = check
        .settlement_info(0)
        .unwrap()
        .expect("the restarted runner rolled the epoch");
    let reference = run_sealed_epoch(&image, inputs, &geometry, 3);
    let reference = Storage::new(reference.path())
        .unwrap()
        .settlement_info(0)
        .unwrap()
        .unwrap();
    assert_eq!(
        (replayed.computation_hash, replayed.final_state),
        (reference.computation_hash, reference.final_state)
    );
}

/// The settled root and final state of one runner epoch, and the root
/// the dispute facade serves from the runner's own rows, which the Hero
/// joins with.
fn runner_settlement(
    image: &Path,
    inputs: Vec<Vec<u8>>,
    geometry: &TournamentGeometry,
) -> (String, String, String) {
    // Over echo's four inputs, a gap of 3 makes the rejection reload a
    // transient checkpoint mid-batch and the last input publish as the
    // sealed remainder.
    let state_dir = run_sealed_epoch(image, inputs, geometry, 3);
    let mut storage = Storage::new(state_dir.path()).unwrap();
    let settlement = storage
        .settlement_info(0)
        .unwrap()
        .expect("the runner rolled the sealed epoch");
    let root = &geometry.levels()[0];
    let work = scratch();
    let served = DisputeSource::on_store(storage, 0, work.path().to_path_buf())
        .unwrap()
        .node(&Quartet::level_root(0, root.log2_stride, root.height))
        .unwrap()
        .to_hex();
    drop(state_dir);
    (
        settlement.computation_hash.to_hex(),
        served,
        format!("0x{}", hex::encode(settlement.final_state)),
    )
}

/// The eager runner on a real machine. Under both tables, the root it
/// settles must be the reference CLI's, and the dispute facade must serve
/// that same root both from the runner's rows and by replay on a fresh
/// store.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn runner_settles_the_reference_root() {
    let goldens: BTreeMap<String, String> =
        serde_json::from_value(read_fixture(&fixture_path("reference_cli.json"))).unwrap();
    for (program, image, inputs) in runner_epochs() {
        assert_eq!(
            template_hash(&image),
            goldens[&format!("{program}/template_hash")],
            "{program}: the goldens answer for another image; regenerate them \
             with UPDATE_FIXTURES=1 `just test-reference-cli-goldens`"
        );
        for geometry in [three_level(), two_level()] {
            let label = format!("{program} under {geometry}");
            let (settled, served, final_state) =
                runner_settlement(&image, inputs.clone(), &geometry);
            let root = &geometry.levels()[0];
            let fresh = engine_root_with_inputs(
                &image,
                inputs.clone(),
                &geometry,
                root.log2_stride,
                root.height,
            );
            assert_eq!(
                settled,
                goldens[&reference_cli_key(program, &geometry)],
                "{label}: settled root vs the reference CLI"
            );
            assert_eq!(
                served, settled,
                "{label}: root served from the runner's rows"
            );
            assert_eq!(fresh, settled, "{label}: root replayed on a fresh store");
            assert_eq!(
                final_state,
                goldens[&format!("{program}/final_state")],
                "{label}: final state vs the reference CLI"
            );
            println!("{label}: {settled}");
        }
    }
}

/// The checked proof facade must produce byte-identical chain
/// witnesses to the prototype's get_logs, across
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
        let dir = scratch();
        let db = EpochData::new(inputs.clone(), dir.path().to_path_buf()).unwrap();
        let agree =
            MachineInstance::new_rollups_advanced_until(image.to_str().unwrap(), meta_cycle, &db)
                .unwrap()
                .root_hash()
                .unwrap();
        let (old_proof, old_next) =
            MachineInstance::get_logs(image.to_str().unwrap(), 0, agree, meta_cycle, &db).unwrap();
        let new_proof = source
            .prove_transition(meta_cycle, agree, old_next)
            .unwrap();

        assert_eq!(
            new_proof, old_proof,
            "proof bytes diverge at {label} (position {meta_cycle})"
        );
        println!("{label}: {} witness bytes agree", new_proof.len());
    }
}

/// Where yield's first input is rejected, and the pre-feed state the
/// revert restores: feed window 0 and run the big machine until the
/// guest yields; the closing slot of that big cycle carries the revert
/// (mirrors stf_revert's oracle-reported processing_bigs).
fn yield_revert_closing_slot(image: &Path, inputs: &[Vec<u8>]) -> (Digest, U256) {
    let work = scratch();
    let mut stf = MachineStf::load(image, work.path().to_path_buf(), Hashing::Sampled)
        .unwrap()
        .with_inputs(inputs.to_vec());
    let pre_feed = stf.state_hash().unwrap();
    stf.feed(0).unwrap();
    let bigs = stf.run_big(u64::MAX).unwrap();
    assert!(stf.yielded().unwrap(), "the yield program must yield");
    assert!(bigs > 0, "the guest must run before yielding");
    let boundary = U256::from(bigs) * U256::from(Structure::PRODUCTION.big_span());
    assert!(boundary < (U256::ONE << 44), "input overran a level-0 leaf");
    (pre_feed, boundary - U256::ONE)
}

/// The revert-carrying closing slot, on the yield machine (which
/// rejects every input). Three agreements, in dependency order: the
/// plain path's closing leaf must be the restored checkpoint (the
/// pre-feed state - what the chain restores from the shadow slot);
/// the proof facade must validate that same post-state (reporting the
/// discarded rejected state would prevent winLeafMatch and forfeit
/// the dispute by clock); and the witness bytes must match the
/// prototype proof path.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn revert_closing_slot_restores_the_checkpoint() {
    let image = yield_image();

    let structure = Structure::PRODUCTION;
    let inputs = yield_inputs();

    let (_state_dir, storage) = initialized_storage_with(&image, inputs.clone());
    let work = scratch();
    let mut source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();

    let (pre_feed, closing) = yield_revert_closing_slot(&image, &inputs);
    let boundary = closing + U256::ONE;

    // The built leaf, through the plain path.
    let built = {
        let work = scratch();
        let stf = MachineStf::load(&image, work.path().to_path_buf(), Hashing::Sampled)
            .unwrap()
            .with_inputs(inputs.clone());
        let mut ruler = Ruler::new(stf, structure, inputs.len() as u64);
        ruler.advance(closing).unwrap();
        let runs = ruler.collect(boundary, 0).unwrap();
        runs.last().unwrap().hash
    };
    assert_eq!(
        built, pre_feed,
        "the revert must restore the pre-feed state"
    );

    // Derive the agreed pre-state independently, then require the
    // facade to prove the plain path's restored leaf.
    let dir = scratch();
    let db = EpochData::new(inputs, dir.path().to_path_buf()).unwrap();
    let agree = MachineInstance::new_rollups_advanced_until(image.to_str().unwrap(), closing, &db)
        .unwrap()
        .root_hash()
        .unwrap();
    let (old_proof, old_post) =
        MachineInstance::get_logs(image.to_str().unwrap(), 0, agree, closing, &db).unwrap();
    let proof = source.prove_transition(closing, agree, built).unwrap();
    assert_eq!(
        proof, old_proof,
        "revert witness bytes diverge from the prototype"
    );
    assert_eq!(
        built, old_post,
        "post-transition hash diverges from the prototype at the revert closing slot"
    );
    println!(
        "revert closing slot at position {closing}: {} witness bytes agree",
        proof.len()
    );
}

/// One transition as the Hero proves it: the pre- and post-states from
/// a ruler positioned on the template, and the witness bytes from the
/// dispute facade on a fresh store, which checks both states.
fn node_witness(
    program: &str,
    image: &Path,
    inputs: &[Vec<u8>],
    meta_cycle: U256,
) -> serde_json::Value {
    let (pre_state, post_state) = {
        let work = scratch();
        let stf = MachineStf::load(image, work.path().to_path_buf(), Hashing::Sampled)
            .unwrap()
            .with_inputs(inputs.to_vec());
        let mut ruler = Ruler::new(stf, Structure::PRODUCTION, inputs.len() as u64);
        ruler.advance(meta_cycle).unwrap();
        let pre_state = ruler.state_hash().unwrap();
        let (_, post_state) = ruler.prove_transition().unwrap();
        (pre_state, post_state)
    };
    let (state_dir, storage) = initialized_storage_with(image, inputs.to_vec());
    let work = scratch();
    let proof = DisputeSource::on_store(storage, 0, work.path().to_path_buf())
        .unwrap()
        .prove_transition(meta_cycle, pre_state, post_state)
        .unwrap();
    drop(state_dir);
    serde_json::json!({
        "program": program,
        "meta_cycle": format!("{meta_cycle:#x}"),
        "pre_state": pre_state.to_hex(),
        "post_state": post_state.to_hex(),
        "proof": format!("0x{}", hex::encode(proof)),
    })
}

/// The witness bytes the node sends, pinned for the Solidity step.
/// NodeWitnesses.t.sol in cartesi-rollups/contracts runs every vector
/// through the real CartesiStateTransition, rooting inputs the way
/// DaveConsensus does. The shapes are the ones
/// prove_transition_matches_prototype_get_logs and
/// revert_closing_slot_restores_the_checkpoint cover, plus a second input's
/// opening (a nonzero provider index) and the opening of a maximum-size
/// input.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn node_witness_vectors_hold() {
    let structure = Structure::PRODUCTION;
    // The largest payload whose EvmAdvance encoding fits the InputBox's
    // 2^16-byte input limit: a 4-byte selector and nine head words, then
    // the payload padded to a word (the node harness pins the boundary).
    let big_payload = [0xab; ((1 << 16) - 4 - 9 * 32) / 32 * 32];
    let programs = BTreeMap::from([
        ("echo", (echo_image(), echo_inputs())),
        (
            "echo_big",
            (echo_image(), encode_inputs(&[&big_payload[..]])),
        ),
        ("yield", (yield_image(), yield_inputs())),
    ]);
    let (yield_image, yield_inputs) = &programs["yield"];
    let (_, revert_closing) = yield_revert_closing_slot(yield_image, yield_inputs);
    let cases = [
        ("echo_fed_window_start", "echo", U256::ZERO),
        ("echo_plain_ustep", "echo", U256::ONE),
        (
            "echo_closing_slot",
            "echo",
            U256::from(structure.big_span() - 1),
        ),
        (
            "echo_second_input_opening",
            "echo",
            structure.window_start(1),
        ),
        (
            "echo_inputless_window_start",
            "echo",
            structure.window_start(2),
        ),
        ("echo_big_input_opening", "echo_big", U256::ZERO),
        ("yield_revert_closing_slot", "yield", revert_closing),
    ];

    let mut vectors = serde_json::Map::new();
    for (name, program, meta_cycle) in cases {
        let (image, inputs) = &programs[program];
        vectors.insert(
            name.into(),
            node_witness(program, image, inputs, meta_cycle),
        );
    }
    let inputs: serde_json::Map<_, _> = programs
        .iter()
        .map(|(program, (_, inputs))| {
            let encoded: Vec<_> = inputs
                .iter()
                .map(|input| format!("0x{}", hex::encode(input)))
                .collect();
            (program.to_string(), serde_json::json!(encoded))
        })
        .collect();

    check_fixture(
        "node_witnesses.json",
        serde_json::json!({ "inputs": inputs, "vectors": vectors }),
    );
}

/// The work-count bound the toy cannot show (engine::spec counts the
/// rest): production positioning resumes from the nearest snapshot the
/// runner kept, so it replays at most gap - 1 inputs. A query in window
/// 7 at gap 4 starts from boundary 4, crosses 4 to 6 on clones, and
/// registers boundary 7 alone. The epoch start is hidden, so a replay
/// from below boundary 4 fails.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn positioning_resumes_from_the_nearest_gap_snapshot() {
    let image = echo_image();
    let payloads: Vec<Vec<u8>> = (0..8u8).map(|i| vec![i]).collect();
    let payloads: Vec<&[u8]> = payloads.iter().map(Vec::as_slice).collect();
    let state_dir = run_sealed_epoch(&image, encode_inputs(&payloads), &three_level(), 4);

    let stored = || -> Vec<u64> {
        let mut storage = Storage::new(state_dir.path()).unwrap();
        (0..=8)
            .filter(|&input| storage.snapshot_hash(0, input).unwrap().is_some())
            .collect()
    };
    assert_eq!(stored(), [0, 4, 8], "the runner keeps the gap boundaries");
    let start = Storage::new(state_dir.path())
        .unwrap()
        .snapshot_dir(0, 0)
        .unwrap()
        .unwrap();
    std::fs::rename(&start, state_dir.path().join("start-aside")).unwrap();

    let work = scratch();
    let mut source = DisputeSource::on_store(
        Storage::new(state_dir.path()).unwrap(),
        0,
        work.path().to_path_buf(),
    )
    .unwrap();
    let level = LevelCoords::new(0, Structure::PRODUCTION.window_start(7), 0, 20);
    source.node(&level.root()).unwrap();
    assert_eq!(
        stored(),
        [0, 4, 7, 8],
        "positioning resumed from boundary 4"
    );
}

/// A stride-0 quartet's root replayed from the template on the scratch
/// feeder: no storage, no crossing.
fn scratch_quartet_root(image: &Path, inputs: &[Vec<u8>], level: &LevelCoords) -> Digest {
    let work = scratch();
    let stf = MachineStf::load(image, work.path().to_path_buf(), Hashing::PerStep)
        .unwrap()
        .with_inputs(inputs.to_vec());
    let mut ruler = Ruler::new(stf, Structure::PRODUCTION, inputs.len() as u64);
    ruler.advance(level.base_cycle).unwrap();
    let end = level.base_cycle + (U256::from(1) << level.height);
    let mut builder = cartesi_rollups_prt_node::merkle::MerkleBuilder::default();
    for run in ruler.collect(end, 0).unwrap() {
        builder.append_repeated(run.hash, run.repetitions);
    }
    builder.build().root_hash()
}

/// Read-only files of a stored machine, by name, with their inodes: a
/// clone hard-links them, a full store writes new ones.
fn read_only_inodes(dir: &Path) -> BTreeMap<String, u64> {
    use std::os::unix::fs::MetadataExt;
    std::fs::read_dir(dir)
        .unwrap()
        .map(Result::unwrap)
        .filter(|entry| entry.metadata().unwrap().permissions().readonly())
        .map(|entry| {
            let name = entry.file_name().into_string().unwrap();
            (name, entry.metadata().unwrap().ino())
        })
        .collect()
}

fn staging_leftovers(state_dir: &Path) -> Vec<String> {
    std::fs::read_dir(state_dir.join("snapshots"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name.starts_with(".work-") || name.starts_with(".part-"))
        .collect()
}

/// Positioning crosses whole windows on the runner's clone chain: from
/// the epoch start to window 3 of echo's four inputs (input 2 rejected),
/// it registers boundary 3 alone, as clones of the start, leaves no
/// working clone behind, and serves the scratch replay's root.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn positioning_crosses_windows_on_clones() {
    let image = echo_image();
    let inputs = encode_inputs(&[&b"zero"[..], b"one", b"two", b"three"]);
    let state_dir = run_sealed_epoch(&image, inputs.clone(), &three_level(), 4);
    let mut storage = Storage::new(state_dir.path()).unwrap();
    let rows = |storage: &mut Storage| -> Vec<u64> {
        let snapshots = storage.epoch_snapshots(0).unwrap();
        snapshots.iter().map(|(boundary, _)| boundary.0).collect()
    };
    assert_eq!(rows(&mut storage), [0, 4]);

    let level = LevelCoords::new(0, Structure::PRODUCTION.window_start(3), 0, 20);
    let work = scratch();
    let root = DisputeSource::on_store(
        Storage::new(state_dir.path()).unwrap(),
        0,
        work.path().to_path_buf(),
    )
    .unwrap()
    .node(&level.root())
    .unwrap();
    assert_eq!(root, scratch_quartet_root(&image, &inputs, &level));

    assert_eq!(rows(&mut storage), [0, 3, 4]);
    let start = read_only_inodes(&storage.snapshot_dir(0, 0).unwrap().unwrap());
    let crossed = read_only_inodes(&storage.snapshot_dir(0, 3).unwrap().unwrap());
    assert!(!start.is_empty(), "a stored machine has read-only files");
    assert_eq!(crossed, start, "boundary 3 is a clone, not a store");
    assert_eq!(staging_leftovers(state_dir.path()), Vec::<String>::new());
}

/// A torn snapshot the fallback skips must not come back as a revert
/// checkpoint: the feed that crosses it adopts its content-addressed
/// directory, so the rejection's reload checks the root and fails
/// loudly instead of serving a wrong post-state. Echo at gap 2 keeps
/// boundaries 0, 2 and 4, and rejects input 2.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
#[should_panic(expected = "does not hash to the input's revert root")]
fn a_torn_revert_checkpoint_fails_loudly() {
    let image = echo_image();
    let inputs = encode_inputs(&[&b"zero"[..], b"one", b"two", b"three"]);
    let state_dir = run_sealed_epoch(&image, inputs, &three_level(), 2);
    let mut storage = Storage::new(state_dir.path()).unwrap();
    let start = storage.snapshot_dir(0, 0).unwrap().unwrap();
    let torn = storage.snapshot_dir(0, 2).unwrap().unwrap();
    std::fs::remove_dir_all(&torn).unwrap();
    Machine::clone_stored(&start, &torn).unwrap();

    let level = LevelCoords::new(0, Structure::PRODUCTION.window_start(3), 0, 20);
    let work = scratch();
    let _ = DisputeSource::on_store(storage, 0, work.path().to_path_buf())
        .unwrap()
        .node(&level.root());
}

/// A crossing whose every input is rejected ends on the state it began
/// from, so the target's row reuses the floor's directory.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn positioning_over_rejected_inputs_keeps_the_floor() {
    let image = yield_image();
    let inputs = encode_inputs(&[&b"zero"[..], b"one"]);
    let (state_dir, storage) = initialized_storage_with(&image, inputs.clone());
    let level = LevelCoords::new(0, Structure::PRODUCTION.window_start(2), 0, 20);
    let work = scratch();
    let root = DisputeSource::on_store(storage, 0, work.path().to_path_buf())
        .unwrap()
        .node(&level.root())
        .unwrap();
    assert_eq!(root, scratch_quartet_root(&image, &inputs, &level));

    let mut storage = Storage::new(state_dir.path()).unwrap();
    assert_eq!(
        storage.snapshot_hash(0, 2).unwrap(),
        storage.snapshot_hash(0, 0).unwrap()
    );
    assert_eq!(
        storage.snapshot_dir(0, 2).unwrap(),
        storage.snapshot_dir(0, 0).unwrap()
    );
    assert_eq!(staging_leftovers(state_dir.path()), Vec::<String>::new());
}

/// Leaf commitments on a real machine, dense spans and reverts included,
/// against the released CLI's answers (see leaf_cases). The CLI computes
/// them through the collect API, as the node's bulk collector does, so the
/// stepped reference must match them too, or a regeneration would compare
/// the collect API with itself (computation-hash.md).
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn leaf_commitments_match_the_reference_cli() {
    let goldens: BTreeMap<String, String> =
        serde_json::from_value(read_fixture(&fixture_path("reference_cli.json"))).unwrap();
    let epochs: BTreeMap<_, _> = runner_epochs()
        .into_iter()
        .map(|(program, image, inputs)| (program, (image, inputs)))
        .collect();
    for case in leaf_cases() {
        let (image, inputs) = &epochs[case.program];
        for collector in [Collector::Bulk, Collector::Stepped] {
            let (state_dir, storage) = initialized_storage_with(image, inputs.clone());
            let work = scratch();
            let leaf =
                DisputeSource::on_store_with(storage, 0, work.path().to_path_buf(), collector)
                    .unwrap()
                    .node(&case.level().root())
                    .unwrap()
                    .to_hex();
            drop(state_dir);
            assert_eq!(leaf, goldens[&case.key()], "{} {collector:?}", case.key());
            println!("{} {collector:?}: {leaf}", case.key());
        }
    }
}

/// The bulk collector against the stepped reference at run granularity,
/// so a disagreement names its big cycle: every leaf case's span,
/// positioned by replay from the template, and a period-10 leaf around
/// echo's first automatic yield, whose 1,024 cycles cross the bulk
/// collector's chunks and re-enter it after the yield.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn bulk_and_stepped_leaf_runs_agree() {
    let epochs: BTreeMap<_, _> = runner_epochs()
        .into_iter()
        .map(|(program, image, inputs)| (program, (image, inputs)))
        .collect();
    let (echo, echo_inputs) = &epochs["echo"];
    let (mut probe, _) = awaiting_input(echo, echo_inputs, 0);
    deliver(&mut probe, &echo_inputs[0]);
    let opened = probe.mcycle().unwrap();
    assert_eq!(
        probe.run(u64::MAX).unwrap(),
        break_reason::YIELDED_AUTOMATICALLY
    );
    let output = LeafCase {
        program: "echo",
        log2_period: 10,
        input: 0,
        period: (probe.mcycle().unwrap() - opened) >> 10,
    };
    for case in leaf_cases().into_iter().chain([output]) {
        let (image, inputs) = &epochs[case.program];
        let level = case.level();
        let end = level.base_cycle + (U256::from(1) << level.height);
        let [bulk, stepped] = [Collector::Bulk, Collector::Stepped].map(|collector| {
            let work = scratch();
            let stf = MachineStf::load(image, work.path().to_path_buf(), Hashing::PerStep)
                .unwrap()
                .with_inputs(inputs.clone())
                .with_collector(collector);
            let mut ruler = Ruler::new(stf, Structure::PRODUCTION, inputs.len() as u64);
            ruler.advance(level.base_cycle).unwrap();
            ruler.collect_big_cycle_roots(end).unwrap()
        });
        if let Some(index) =
            (0..bulk.len().max(stepped.len())).find(|&i| bulk.get(i) != stepped.get(i))
        {
            panic!(
                "{}: run {index} differs: bulk {:?}, stepped {:?}",
                case.key(),
                bulk.get(index),
                stepped.get(index)
            );
        }
        println!("{}: {} runs agree", case.key(), bulk.len());
    }
}

/// A machine awaiting `inputs[feed]`, the previous ones processed (all
/// accepted), with its idle period: the revert tail for that input.
fn awaiting_input(image: &Path, inputs: &[Vec<u8>], feed: usize) -> (Machine, Vec<Hash>) {
    let mut machine = Machine::load(image, &RuntimeConfig::quiet_console()).unwrap();
    for payload in &inputs[..feed] {
        deliver(&mut machine, payload);
        run_to_manual_yield(&mut machine);
    }
    let mcycle = machine.mcycle().unwrap();
    let tail = machine
        .collect_uarch_cycle_root_hashes(mcycle, 0, None)
        .unwrap()
        .hashes;
    (machine, tail)
}

fn run_to_manual_yield(machine: &mut Machine) {
    loop {
        match machine.run(u64::MAX).unwrap() {
            break_reason::YIELDED_AUTOMATICALLY => continue,
            reason => return assert_eq!(reason, break_reason::YIELDED_MANUALLY),
        }
    }
}

fn deliver(machine: &mut Machine, payload: &[u8]) {
    let root = machine.root_hash().unwrap();
    machine
        .send_cmio_response(CmioResponseReason::Advance, payload, Some(&root))
        .unwrap();
}

/// Every period from the machine's mcycle to `end` or a fixed point (and
/// the period after it), through automatic yields.
fn uarch_periods(
    machine: &mut Machine,
    end: u64,
    log2_bundle: u32,
    tail: &[Hash],
) -> Vec<Vec<Hash>> {
    let mut periods = vec![];
    loop {
        let part = machine
            .collect_uarch_cycle_root_hashes(end, log2_bundle, Some(tail))
            .unwrap();
        periods.extend(part.periods().map(<[Hash]>::to_vec));
        let fixed = matches!(
            part.break_reason,
            break_reason::YIELDED_MANUALLY | break_reason::HALTED | break_reason::MCYCLE_OVERFLOW
        );
        if fixed || machine.mcycle().unwrap() >= end {
            return periods;
        }
    }
}

/// The root of one period's 2^c leaves from its entries at a bundle size:
/// the execution bundles, the halted-only bundle repeated to fill, then the
/// final bundle, which ends with the reset (unbundled, the entries are the
/// executed leaves, the halted state and the reset).
fn period_root(entries: &[Hash], log2_bundle: u64) -> Digest {
    let c = Structure::PRODUCTION.log2_uarch_span;
    let (last, rest) = entries.split_last().unwrap();
    let (halted, executed) = rest.split_last().unwrap();
    let fill = (1u64 << (c - log2_bundle)) - 1 - executed.len() as u64;
    let runs = executed
        .iter()
        .map(|hash| (Digest::from(*hash), 1))
        .chain([(Digest::from(*halted), fill), (Digest::from(*last), 1)])
        .filter(|&(_, count)| count > 0);
    fold_runs(runs, c - log2_bundle).unwrap().root_hash()
}

/// The collect API's bundling against Dave's Merkle assembly: at every
/// bundle size, each period's entries reduce to the root of its unbundled
/// leaves, the fixed point's padding period included. The spans cover an
/// input's opening, an automatic yield, and a rejection (echo's input 2).
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn uarch_bundles_reduce_to_the_unbundled_leaves() {
    let image = echo_image();
    let inputs = encode_inputs(&[&b"zero"[..], b"one", b"two"]);
    let c = Structure::PRODUCTION.log2_uarch_span;

    let (mut probe, _) = awaiting_input(&image, &inputs, 0);
    deliver(&mut probe, &inputs[0]);
    let opened = probe.mcycle().unwrap();
    assert_eq!(
        probe.run(u64::MAX).unwrap(),
        break_reason::YIELDED_AUTOMATICALLY
    );
    let output = probe.mcycle().unwrap();
    let (mut probe, _) = awaiting_input(&image, &inputs, 2);
    deliver(&mut probe, &inputs[2]);
    run_to_manual_yield(&mut probe);
    let rejected = probe.mcycle().unwrap();

    // (input fed, first mcycle, end mcycle)
    for (feed, start, end) in [
        (0, opened, opened + 6),
        (0, output - 3, output + 3),
        (2, rejected - 3, u64::MAX),
    ] {
        let collect = |log2_bundle: u32| {
            let (mut machine, tail) = awaiting_input(&image, &inputs, feed);
            deliver(&mut machine, &inputs[feed]);
            while machine.mcycle().unwrap() < start {
                let reason = machine.run(start).unwrap();
                assert!(
                    [
                        break_reason::REACHED_TARGET_MCYCLE,
                        break_reason::YIELDED_AUTOMATICALLY
                    ]
                    .contains(&reason),
                    "input {feed} stopped with {reason} short of mcycle {start}"
                );
            }
            uarch_periods(&mut machine, end, log2_bundle, &tail)
        };
        let leaves: Vec<Digest> = collect(0)
            .iter()
            .map(|period| period_root(period, 0))
            .collect();
        assert!(leaves.len() >= 4, "input {feed} from mcycle {start}");
        for log2_bundle in 1..=c {
            let bundled: Vec<Digest> = collect(log2_bundle as u32)
                .iter()
                .map(|period| period_root(period, log2_bundle))
                .collect();
            assert_eq!(
                bundled, leaves,
                "input {feed} from mcycle {start}, bundle 2^{log2_bundle}"
            );
        }
    }
}

fn merkle_proof_vector(root: Digest, height: u64, proof: &MerkleProof) -> serde_json::Value {
    serde_json::json!({
        "root": root.to_hex(),
        "height": height,
        "position": format!("{:#x}", proof.position),
        "leaf": proof.node.to_hex(),
        "siblings": proof.siblings.iter().map(Digest::to_hex).collect::<Vec<_>>(),
    })
}

fn leaf_proof_vector(proof: &LeafProof) -> serde_json::Value {
    serde_json::json!({
        "data_block": format!("0x{}", hex::encode(proof.data_block)),
        "siblings": proof
            .siblings
            .inner()
            .iter()
            .map(|sibling| format!("0x{}", hex::encode(sibling)))
            .collect::<Vec<_>>(),
    })
}

/// The node's commitment proofs and settlement validity proof, pinned for
/// the contracts. NodeProofs.t.sol in cartesi-rollups/contracts opens each
/// commitment proof with the tournament's Commitment library and validates
/// the settlement the way DaveConsensus stages it, requiring the CLI's
/// outputs Merkle root. The root proofs are the joins of a runner epoch
/// under each table (served from the runner's rows); the leaf proofs are a
/// seal's agree-state opening and a join's last leaf at the three-level
/// leaf height.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn node_proof_vectors_hold() {
    let goldens: BTreeMap<String, String> =
        serde_json::from_value(read_fixture(&fixture_path("reference_cli.json"))).unwrap();
    let image = echo_image();
    let inputs = runner_epochs()[0].2.clone();

    let mut commitments = serde_json::Map::new();
    let mut settlement = None;
    for (name, geometry) in [("three_level", three_level()), ("two_level", two_level())] {
        let state_dir = run_sealed_epoch(&image, inputs.clone(), &geometry, 3);
        let mut storage = Storage::new(state_dir.path()).unwrap();
        settlement.get_or_insert(storage.settlement_info(0).unwrap().unwrap());
        let root = &geometry.levels()[0];
        let level = LevelCoords::new(0, U256::ZERO, root.log2_stride, root.height);
        let work = scratch();
        let mut source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();
        let proof = source.prove_last(&level).unwrap();
        let root_hash = source.node(&level.root()).unwrap();
        commitments.insert(
            format!("echo_root_{name}_last"),
            merkle_proof_vector(root_hash, root.height, &proof),
        );
    }

    let (state_dir, storage) = initialized_storage_with(&image, inputs);
    let work = scratch();
    let mut source = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();
    let level = LevelCoords::new(0, U256::ZERO, 0, 27);
    let root_hash = source.node(&level.root()).unwrap();
    let mid = (U256::ONE << 26) + U256::from(12345);
    for (name, proof) in [
        ("echo_leaf_agree", source.prove_leaf(&level, mid).unwrap()),
        ("echo_leaf_last", source.prove_last(&level).unwrap()),
    ] {
        commitments.insert(name.into(), merkle_proof_vector(root_hash, 27, &proof));
    }
    drop((source, state_dir));

    let settlement = settlement.unwrap();
    let final_state = format!("0x{}", hex::encode(settlement.final_state));
    assert_eq!(final_state, goldens["echo/final_state"]);
    let validity = &settlement.machine_validity_proof;
    let settlements = serde_json::json!({
        "echo": {
            "final_state": final_state,
            "outputs_merkle_root": goldens["echo/outputs_merkle_root"],
            "iflags_y": leaf_proof_vector(&validity.iflags_y_proof),
            "htif_tohost": leaf_proof_vector(&validity.htif_tohost_proof),
            "tx_buffer": leaf_proof_vector(&validity.tx_buffer_proof),
        }
    });

    check_fixture(
        "node_proofs.json",
        serde_json::json!({ "commitments": commitments, "settlements": settlements }),
    );
}

/// Recovery from a partially built level: a source that stored part of a
/// level (rows commit per build, all or nothing) and wrote back the
/// boundaries its positioning crossed is dropped between operations; a
/// restarted source over the same state and work directories must serve
/// the level exactly like a fresh store. A build stopped midway is
/// `a_stopped_build_resumes_after_its_stored_spans`; atomicity under
/// injected failure is pinned by the storage tests, and process kills by
/// the retained chaos and kill_catchup_batched e2e scenarios. The level is
/// the big-cycle-root builder's active branch inside window 1.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn restarted_source_resumes_a_half_built_level() {
    let image = echo_image();
    let level = LevelCoords::new(0, U256::from(1) << 68, 0, 28);
    let mid = (U256::ONE << 27) + U256::from(777);

    let (_fresh_guards, mut fresh) = machine_source(&image);
    let root = fresh.node(&level.root()).unwrap();
    let last = fresh.prove_last(&level).unwrap();
    let agree = fresh.prove_leaf(&level, mid).unwrap();

    let (state_dir, storage) = initialized_storage(&image);
    let work = scratch();
    {
        // The killed process: the level's top stratum and one descent
        // along its left edge, so the stored rows are lopsided.
        let mut killed = DisputeSource::on_store(storage, 0, work.path().to_path_buf()).unwrap();
        killed.node(&level.root()).unwrap();
        killed.prove_leaf(&level, U256::ZERO).unwrap();
    }
    let mut check = Storage::new(state_dir.path()).unwrap();
    assert!(
        check.snapshot_hash(0, 1).unwrap().is_some(),
        "the killed process wrote back boundary 1"
    );

    let mut restarted = DisputeSource::on_store(
        Storage::new(state_dir.path()).unwrap(),
        0,
        work.path().to_path_buf(),
    )
    .unwrap();
    assert_eq!(restarted.node(&level.root()).unwrap(), root, "root");
    let resumed = restarted.prove_last(&level).unwrap();
    assert_eq!(
        (resumed.node, resumed.siblings),
        (last.node, last.siblings),
        "last leaf proof"
    );
    let resumed = restarted.prove_leaf(&level, mid).unwrap();
    assert_eq!(
        (resumed.node, resumed.siblings),
        (agree.node, agree.siblings),
        "agree proof"
    );
}

/// A stopped source keeps what it finished. Positioning stops before
/// crossing an input, so nothing is written back. A tall level root
/// (height 28, built span by span over its height-20 stratum) reuses the
/// spans a descent already stored and stops at the first missing one, and
/// a source over the same store then resumes there and serves the level
/// exactly like a fresh store.
#[test]
#[ignore = "requires verified echo and yield machine images; run `just test-engine-machine`"]
fn a_stopped_build_resumes_after_its_stored_spans() {
    let image = echo_image();
    let level = LevelCoords::new(0, U256::from(1) << 68, 0, 28);
    let mid = (U256::ONE << 27) + U256::from(777);
    let (left, _) = level.root().children().unwrap();

    let (_fresh_guards, mut fresh) = machine_source(&image);
    let root = fresh.node(&level.root()).unwrap();
    let last = fresh.prove_last(&level).unwrap();
    let agree = fresh.prove_leaf(&level, mid).unwrap();

    let (state_dir, _storage) = initialized_storage(&image);
    let work = scratch();
    let source = |stopped: bool| {
        let mut source = DisputeSource::on_store(
            Storage::new(state_dir.path()).unwrap(),
            0,
            work.path().to_path_buf(),
        )
        .unwrap();
        if stopped {
            let shutdown = ShutdownSignal::default();
            shutdown.request();
            source.stop_on(shutdown);
        }
        source
    };
    let mut check = Storage::new(state_dir.path()).unwrap();

    let error = source(true).node(&left).unwrap_err();
    assert!(
        format!("{error:#}").contains("before crossing input 0"),
        "{error:#}"
    );
    assert!(
        check.snapshot_hash(0, 1).unwrap().is_none(),
        "crossed input 0"
    );

    // The left child is not tall: one stepped build whose fanout reaches
    // height 20, the left half of the root's bottom stratum.
    source(false).node(&left).unwrap();
    let error = source(true).node(&level.root()).unwrap_err();
    assert!(
        format!("{error:#}").contains("at span 128 of 256"),
        "{error:#}"
    );
    assert!(check.quartet_node(&level.root()).unwrap().is_none());

    let mut resumed = source(false);
    assert_eq!(resumed.node(&level.root()).unwrap(), root, "root");
    let proof = resumed.prove_last(&level).unwrap();
    assert_eq!(
        (proof.node, proof.siblings),
        (last.node, last.siblings),
        "last leaf proof"
    );
    let proof = resumed.prove_leaf(&level, mid).unwrap();
    assert_eq!(
        (proof.node, proof.siblings),
        (agree.node, agree.siblings),
        "agree proof"
    );
}
