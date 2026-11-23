# Card: seams between the node and the repository

Scope: every place where `cartesi-rollups/node` (crate `cartesi-sling-node`)
touches the rest of the repository, at tree `ec7afc62fd9d`. This card lists
couplings and the interface that would cut each; it does not argue for or
against moving the node. Possible correctness bug: none met. Submodule files
(`machine/emulator`, `machine/step`) are cited at their pinned commits, read
with `git show` because they are not checked out here: emulator
`v0.23.0-test3`, step `v0.17.0-test2` (tags on the pinned commits;
`machine/script/cartesi-machine-source.sh:12` names the emulator release).

## Runtime coupling

What the running binary takes from the contracts, all through the ABI:

- Addresses: none compiled in. The only address input is `--app-address`
  (`src/args.rs:226`); everything else is discovered on chain by
  `AddressBook::new` (`src/blockchain_reader/mod.rs:72-112`): the
  application's `getOutputsMerkleRootValidator`, then DaveConsensus
  `getApplicationContract` (checked to point back, :84-92), `getInputBox`,
  `getTournamentFactory`, `getDeploymentBlockNumber`. Called at startup from
  `src/args.rs:457`. Hex addresses in `src/` occur only inside test modules
  (`src/provider.rs:902`, `src/args.rs:542`, `src/storage/ingest.rs:130` open
  them). `ANVIL_CHAIN_ID = 31337` (`src/args.rs:30`) is the only chain
  constant.
- Geometry: not compiled in. `discover_deployed_tournament`
  (`src/args.rs:93-160`) reads `tournamentLevelCount` and each
  `tournamentParameters(level)` from MultiLevelTournamentFactory, validates
  against `Structure::PRODUCTION` (`src/args.rs:52`, :108), and states the
  rule in `src/engine/geometry.rs:7-11`.
- On-chain constants checked against the linked emulator at startup: the
  factory's `stateTransition()`, then CartesiStateTransition `CM_MARCHID()`
  and `UARCH_PRISTINE_STATE_HASH()` (`src/args.rs:133-158`), refused as
  terminal on mismatch (`src/args.rs:64-87`).
- ABI calls used by production code (grep of camelCase calls outside test
  modules): DaveConsensus (`getSentryId`, `getCurrentSealedEpoch`,
  `isForeclosed` at `src/epoch_manager/mod.rs:214`, staging and sentry
  calls such as `canStageTournamentResult`, `stageTournamentResult`,
  `acceptStagedTournamentResult`, `submitSentryClaim`,
  `getLastFinalizedMachineMerkleRoot`), Tournament (`joinTournament`,
  `advanceMatch`, `sealInnerMatchAndCreateInnerTournament`,
  `sealLeafMatch`, `winLeafMatch`, `winInnerTournament`,
  `winMatchByTimeout`, `eliminateMatchByTimeout`, `eliminateInnerTournament`,
  `tryRecoveringBond`, `bondRecovery`, `tournamentStanding`, `bisectingMatch`,
  `sealedMatch`, `readyToSealMatch`, `classifyMatchTimeout`, `bondValue`,
  `tournamentDescriptor`), IInputBox `getNumberOfInputs`, IApplication
  (`src/epoch_manager/mod.rs:199`).
- Events decoded: `InputAdded` (crates.io `cartesi-rollups-contracts`,
  `src/blockchain_reader/mod.rs:21-24`),
  `EpochSealed` (`src/blockchain_reader/mod.rs:20`, :263), and nine
  Tournament events in `src/tournament/reader.rs:389-476` (CommitmentJoined,
  MatchCreated, MatchAdvanced, LeafMatchSealed, NewInnerTournament,
  MatchDeleted, StandingChanged, PartialBondRefund, BondRecovered).
- Revert decoding: custom errors of DaveConsensus, Tournament and
  CartesiStateTransition (`src/provider.rs:848-862`).
- Constants compiled in that the contracts also hold, with no on-chain read:
  1. The input cap. Node: `Structure::PRODUCTION.log2_input_span =
     LOG2_MAX_ADVANCE_STATES_PER_EPOCH` (`src/engine/structure.rs:34`),
     `max_inputs = 1 << log2_input_span` (`src/engine/structure.rs:62-63`),
     taken from the emulator C API
     (`machine/rust-bindings/cartesi-machine/src/constants.rs:25-26`,
     `CM_ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH = 24` at
     `machine/emulator/src/cm.h:61` in the pinned commit). Contract:
     `MAX_INPUTS_PER_EPOCH = 1 << EmulatorConstants.ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH`
     (`cartesi-rollups/contracts/src/DaveConsensus.sol:39`), importing
     `step/src/EmulatorConstants.sol` (DaveConsensus.sol:26), which holds
     `ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH = 24`
     (`machine/step/src/EmulatorConstants.sol:35` in the pinned commit). The
     node test `node_geometry_matches_arbitration_contracts`
     (`src/engine/constants.rs:251-277`, the assertion at :272-276) pins the
     emulator value to step's. One emulator constant feeds both sides; the
     test closes the loop at the step file. At runtime the reader refuses a
     seal that disagrees (`src/blockchain_reader/mod.rs:604-615`, :799-801).
  2. Response window G = 5 min (`src/escalation.rs:12-21`), mirrored from
     `Deployment.s.sol`'s `_getInclusionBudget` by comment only; the comment
     states its reopening condition (:18-20).
  3. Gas headroom `MIN_HEADROOM = 650_000` (`src/provider.rs:368-380`), sized
     from a Sepolia measurement of the contracts' pairing branch; the harness
     test at `src/harness/tests.rs:654-660` exercises the move on Prague, not
     the Sepolia number.
  4. `BondDisposition` variant numbers (mirror checked by a test, see Test).

## Build-time coupling

- Workspace: root `Cargo.toml:3-14` holds both generated binding crates, the
  node, and both machine crates; path dependencies at `Cargo.toml:35-39`;
  one `Cargo.lock`; one `[profile.release] overflow-checks = true`
  (`Cargo.toml:81-82`) for every member. Node deps: `cartesi-machine`,
  `cartesi-dave-contracts`, `cartesi-prt-contracts` (path) and
  `cartesi-rollups-contracts = "=3.0.0-alpha.10"` from crates.io
  (`cartesi-rollups/node/Cargo.toml:14-18`, `Cargo.toml:49`).
- Generated contract bindings:
  - Entry: `just bind` (`justfile:119-121`) calls each module's `bind`
    (`prt/contracts/justfile:102-103`,
    `cartesi-rollups/contracts/justfile:49-50`), both running
    `script/contract-bindings.sh generate prt|rollups`. No build script: the
    only `build.rs` is the machine sys crate's.
  - Tool: `forge bind --force --alloy --alloy-version 2 --select <re>
    --module --bindings-path ./bindings-rs/src/contract --skip-extra-derives`
    (`script/contract-bindings.sh:71-72`), after a forge build of the whole
    project with test and script roots emptied (:34).
  - Selection: `CartesiStateTransition|MultiLevelTournamentFactory|Tournament`
    and `I?DaveConsensus|I?DaveAppFactory` (:22, :26).
  - Inputs hashed into the stamp: the script, both `soldeer.lock`, `forge
    --version`, effective forge config, and every `.sol` under
    `prt/contracts/src`, `cartesi-rollups/contracts/src`, `machine/step/src`
    (:39-54). Compiling needs both projects' soldeer deps (rollups `libs`
    include `../../prt/contracts/dependencies`,
    `cartesi-rollups/contracts/foundry.toml:4`), the `machine/step` submodule
    (`step/=../../machine/step/`, `prt/contracts/foundry.toml:15`,
    `cartesi-rollups/contracts/foundry.toml:18`), solc 0.8.38
    (`prt/contracts/foundry.toml:18`) and Foundry 1.5.1 (`justfile:24`).
  - Output: `<project>/bindings-rs/src/contract` and `.bind-stamp`,
    gitignored (`prt/contracts/bindings-rs/src/.gitignore:1-2`); tracked are
    only `Cargo.toml`, `README.md`, `src/lib.rs` and that `.gitignore`
    (`git ls-files`). `lib.rs` is `pub mod contract; pub use contract::*;`
    (`prt/contracts/bindings-rs/src/lib.rs:1-4`).
  - Consumers: the node only. The node uses ABI items only; no `::deploy` or
    bytecode constant appears in `src`, `tests` or `examples` (grep).
  - Published crates in use: only `cartesi-rollups-contracts` (upstream). The
    same upstream version is also a soldeer dependency
    (`cartesi-rollups/contracts/foundry.toml:45`) and is spelled into a node
    test path (`src/engine/constants.rs:171-184`); the three must move
    together.
  - What the contracts would have to publish for the node to build without
    Solidity: the ABI of the five selected contracts (`abi` arrays from
    `out/*.json`; the release already ships `prt/contracts/out` and
    `cartesi-rollups/contracts/out` as `contract-artifacts.tar.gz`,
    `.github/workflows/build.yml:411-414`), consumed by `alloy::sol!` from
    JSON, or a versioned bindings crate. Options and reasons are a recorded
    open question (`docs/build-system.md:180-204`); not reopened.
- Machine bindings: `machine/rust-bindings/cartesi-machine-sys/build.rs`
  builds from `../../emulator` (:127) and checks a preparation stamp at
  `../../../target/machine-source/prepared-generated-sources` (:12), i.e. the
  root workspace's target dir, unless `LIBCARTESI_PATH` is set (:30-44).
  `machine/rust-bindings/Cargo.toml:1-11` is also a nested workspace
  (version 0.23.0), built from that directory by the release job
  (`build.yml:302-312`).
- Release tag compiled in: `option_env!("CARTESI_SLING_RELEASE")`
  (`src/main.rs:23-26`), set by CI only (`build.yml:314-317`). The workspace
  version `2.0.0` (`Cargo.toml:17`) names no release.

## Test-time coupling

Node tests that read files outside the crate (all run under plain `cargo
test` unless marked ignored):

| Test | Reads | Invariant pinned | Would a constants JSON serve? |
|---|---|---|---|
| `test_emulator_and_step_agree_on_revert_address` `src/engine/constants.rs:92-109` | `machine/step/src/EmulatorConstants.sol` | emulator revert slot == step `REVERT_ROOT_HASH_ADDRESS` | yes |
| `linked_emulator_and_step_agree_on_the_pristine_uarch` :132-164 | same | uarch start, log2 size, `CM_MARCHID`, pristine hash | yes (MARCHID and hash are also checked on chain at startup, `src/args.rs:133-158`) |
| `machine_validity_proof_geometry_matches_solidity` :166-228 | soldeer path `cartesi-rollups/contracts/dependencies/cartesi-rollups-contracts-3.0.0-alpha.10/...solidity-step-0.15.0/src/{EmulatorConstants,Memory}.sol` and `.../src/common/CanonicalMachine.sol` | settlement-proof register addresses, HTIF masks, leaf and memory sizes vs the upstream-vendored step | yes; partly redundant with `NodeProofsTest` which replays the node's proof bytes |
| `node_geometry_matches_arbitration_contracts` :251-277 | `ArbitrationConstants.sol` via `TournamentGeometry::checked_in` (`src/engine/geometry.rs:122-157`) and step `EmulatorConstants.sol` | checked-in table passes the node's validator; uarch, barch and input span widths (the input cap) | yes |
| `bond_disposition_mirror_matches_the_interface` `src/epoch_manager/recovery.rs:302-325` | `prt/contracts/src/ITournament.sol` | enum variant order matches the node's numeric mirror | yes; the ABI JSON alone does not carry variant names |
| `discovers_the_deployed_tournament_geometry` `src/args.rs:755-781` (ignored, harness) | devnet bundle; `checked_in()` when `DEVNET_GEOMETRY=canonical` | bundle serves the expected table | yes |
| `checked_in_baseline_preambles_match_the_renderer` `examples/measure.rs:1633-1662` | `docs/measurements/*.md` | doc preambles match the renderer | docs, not contracts |

Contract tests that read node fixtures (direction node -> contracts):

- `NodeWitnessesTest` reads `../node/tests/fixtures/node_witnesses.json` and
  `node_seam_witnesses.json` (`cartesi-rollups/contracts/test/NodeWitnesses.t.sol:52-53`);
  `NodeProofsTest` reads `node_proofs.json` (`NodeProofs.t.sol:44`); read
  access is granted by `cartesi-rollups/contracts/foundry.toml:28`. They run
  in `just rollups-contracts::test` (`cartesi-rollups/contracts/justfile`
  `test` recipe, `--no-match-contract ".*FfiTest"`), so in `just check` and
  the CI `rollups-contracts` job (`build.yml:73-77`).
- Generators: `node_witness_vectors_hold`
  (`tests/engine_machine.rs:1374-1376`, fixture name :1434) and
  `node_proof_vectors_hold` (:1906-1908, :1967), both ignored (need images,
  `just test-engine-machine`); `seam_witness_vectors_hold`
  (`src/engine/machine_stf.rs:1183-1184`, write at :1267) is NOT ignored.
  All write on `UPDATE_FIXTURES=1` (`tests/engine_machine.rs:78-86`).
- `engine_echo.json` (`tests/engine_machine.rs:786`) and `reference_cli.json`
  (:1030, :1158, :1662, :1910) are node-only; the latter is the emulator
  CLI's answer, not a contract artifact. No Lua or `prt/contracts` file
  reads any node fixture (grep).

The node's anvil harness (`src/harness/`, `src/blockchain_reader/test_utils.rs`)
needs the devnet bundle: `cartesi-rollups/contracts/state.json`,
`deployments/31337/*.txt` and the `state.fingerprint` marker
(`test_utils.rs:21-23`, :39), and `test/programs/echo` (:21). It deploys
apps through `IDaveAppFactory` read from the bundle (`test_utils.rs:147-190`).
The bundle is built by `cartesi-rollups/contracts/script/build-devnet.sh`
(three-level test table unless `DEVNET_GEOMETRY`, :108) and verified by
`script/devnet-fingerprint.sh` (roots :30-48). Tiers: 18 "devnet bundle and
echo image", 4 "devnet bundle", 10 "spawns anvil", 22 "echo and yield
images" (grep of `ignore =` reasons).

E2E reads of node internals, all in `test/e2e/rollups/dave/node.lua`
(declared the one seam file, :1-5; `docs/test-harness.md:180-186`):

- Binary and process: `../../../target/debug/cartesi-sling-node` with env
  `CARTESI_SLING_{TEMPLATE_PATH,APP_ADDRESS,DATA_DIR,AUTH_PRIVATE_KEY}` and
  flags `--polling-interval --snapshot-gap-inputs --blockchain-http-endpoint
  --blockchain-id pk` (`node.lua:31-37`); preflight requires the binary
  (`test/e2e/rollups/script/preflight.sh:47`).
- SQLite (`sqlite3 -readonly ./_state/db.sqlite3`, `node.lua:161`):
  `epochs.epoch_number` (:162-164, sync barrier),
  `settlement_info.computation_hash` (:184-186, the claim),
  `epoch_snapshot_info.state_hash` with `input_number = 0` (:228-230) turned
  into the path `_state/snapshots/0x<hash>` (:244), and
  `inputs.input` ordered by `input_index_in_epoch` (:258-261). Schema at
  `src/storage/sql/schema.sql:13-15`, :33-45, :64-71; the snapshot path rule
  at `src/storage/open.rs:528`.
- Log marker: `processing input <epoch>:<index>`
  (`src/machine_runner/mod.rs:211`), used by `kill_catchup_batched`
  (`scenarios/kill_catchup_batched.lua:24`), a recorded stable-marker
  contract (`docs/test-harness.md:193-198`).
- What e2e needs from those reads: a barrier ("the node rolled epoch N") and
  the node's root commitment to compare with the Lua oracle
  (`test_env.lua:210-220`); the inputs and snapshot checks
  (`test_env.lua:201-215`) localize a failure but are implied by commitment
  equality, since the oracle already checks the chain's initial state
  (`test_env.lua:171-173`) and reads inputs from chain (:154-162).
- Chain-only alternative: the node's root commitment is public once it joins:
  `CommitmentJoined(commitment indexed, finalStateHash, submitter indexed)`
  (`prt/contracts/src/ITournament.sol:363-367`), and `Env.roll_epoch` already
  waits for it on chain (`test_env.lua:101-104`,
  `dave/reader.lua:345-353`). Filtering by the node's wallet would replace
  `root_commitment`; the barrier becomes "joined" instead of "computed".
  Lead to verify: that the node joins every root tournament it settles
  (`src/hero/actor.rs:210-215` gates joins by a decision). No node feature is
  needed; the log marker contract stays.

Lua client: e2e loads it by path (`test/e2e/rollups/setup_path.lua:3`) as the
commitment oracle (`test_env.lua:142-185`; `prt/client-lua/README.md:7-9`)
and as sybil actor. It needs no node artifact and no devnet itself; its unit
test needs the compiled `ITournament` ABI (`justfile:172-175`). Its other
consumers are contract tests (`prt/contracts/test/step/proofs.lua:1`,
`cartesi-rollups/contracts/test/gas/generate-leaf-proof.lua:1`). The Lua
oracle is checked against the node only on the three-level table
(`docs/dispute-game.md:167-168`).

Machine images: `test/programs/justfile` builds yield, echo, stress (:20-34,
`build-programs` = yield + echo, :52) from downloaded `linux.bin` and
`rootfs.ext2`; fingerprints live beside each image at
`test/programs/<p>/machine-image.fingerprint`
(`script/machine-image-fingerprint.sh:182`), gitignored with the images
(`test/programs/.gitignore`). Consumers: node tests and measure recipes
(`justfile:196-281`; `tests/engine_machine.rs:42`;
`src/storage/rollups_machine.rs:390`; `linux.bin` directly at
`src/storage/sql/test_helper.rs:90`), PRT step tests on yield
(`prt/contracts/justfile:48-55`), leaf-gas witnesses
(`cartesi-rollups/contracts/justfile` `test-prt-leaf-gas`), and e2e
(`test/e2e/rollups/justfile` `test`).

## Release and CI coupling

- One workflow, `.github/workflows/build.yml`, no path filters: push to
  `main`, `next/*`, tags `v*`, and every pull request (:5-12). Two composite
  actions: `setup-tools` (Rust 1.94, :8-13) and `cartesi-machine` (0.23.0
  `-test3` package, `.github/actions/cartesi-machine/action.yml:4-11`).
- Jobs: `prt-contracts` (:19-53), `rollups-contracts` (:55-77, reads node
  fixtures), `e2e` (:79-134, both), `build` (:137-248, node-centred but also
  Lua lint, Lua client tests and build-tooling tests; installs both contract
  deps and builds the devnet, :195-201), `build-release-node` (:250-329,
  `just bind` at :291-295), `release-node` (:331-368), `release-contracts`
  (:370-461, not tag-gated), `publish-contracts` (:463-481).
- Cross-gating: `release-node` needs every contract job and
  `release-contracts` (:332); `publish-contracts` needs `e2e`, `build` and
  `build-release-node` (:464). One tag publishes both products.
- Assets: node `cartesi-sling-node-<ver>-<arch>.tar.gz` (:359-365);
  contracts `contract-artifacts` (prt and rollups `out/`, :411-414),
  `deployment-addresses` and `-experimental` (:418-438), and an anvil bundle
  built with `DEVNET_GEOMETRY=canonical` (:440-453). No asset carries the
  three-level bundle the node harness and e2e use.
- CHANGELOG: one file, per-release `Contracts` / `Node` / `For developers`
  sections (`CHANGELOG.md:12`, :30, :70); the node's compatibility statement
  sits in the release preamble (`CHANGELOG.md:5-10`); the addresses table is
  in the contracts part (`CHANGELOG.md:162-173`).

## Documentation and tooling coupling

- Docs that are the node's alone: `docs/node-architecture.md`,
  `docs/runbooks/submit-relay.md`, `docs/plans/provider-requirements.md`,
  `docs/measurements/{measurements,measurements-stress,node-vs-emulator}.md`,
  `cartesi-rollups/node/README.md`.
- Contract-only: `docs/prt-contract-testing.md` (but :262-272 describe the
  node's witness vectors), `docs/prt-delay-bound.md`,
  `docs/prt-refund-accounting.md`, `docs/plans/audit-readiness.md`,
  `docs/runbooks/prt-refund-gas-calibration.md` (cites the node's
  650,000 headroom and funding floor, :234-250, and forbids node edits in a
  calibration commit, :303).
- Joint: `docs/computation-hash.md`, `docs/dimensioning.md`,
  `docs/epoch-lifecycle.md`, `docs/dispute-game.md` (node evidence,
  :160-168), `docs/glossary.md`, `docs/test-harness.md`,
  `docs/build-system.md`, `docs/todo.md` (separate `Node` :76 and
  `Contracts and assurance` :104 sections), `docs/README.md`.
- Node output cited by a production contract:
  `docs/measurements/constants.md`, written by the node's `measure` example
  (`justfile:277-281`), is the derivation `ArbitrationConstants.sol:9-12`
  names (direction node -> contracts).
- AGENTS scopes: no nested `AGENTS.md` for the node; it is governed by the
  root file. `cartesi-rollups/contracts/AGENTS.md:103-105` names the
  input-cap coupling; `machine/AGENTS.md:26` cites
  `src/engine/constants.rs`.
- Justfile: every cargo recipe depends on `bind` (`justfile:177-287`);
  `check` runs contract tests, Lua checks and Rust tests together (:135-142);
  `build` = contracts + Rust (:289); `setup` installs both contract deps
  (:69-75); `e2e`/`e2e-smoke` depend on `build-rust-workspace` (:330-335);
  `doctor` checks tools of both sides (`script/doctor.sh:58`). Node-only
  scripts in shared `script/`: `computation-hash-corpus.sh` runs
  `cargo test -p cartesi-sling-node` (:103), `ensure-docker.sh`.

## Per-coupling table

| Coupling | Direction | Kind | Evidence | Cleaner interface cuts it? | Cost | Stays coupled regardless |
|---|---|---|---|---|---|---|
| ABI calls and events | node depends on repo | runtime | `src/blockchain_reader/mod.rs:72-112`, `src/tournament/reader.rs:389-476`, `src/args.rs:93-160` | no (it is the protocol); build half: see bindings | none | the deployed ABI of five contracts per generation |
| On-chain checks of MARCHID, uarch hash, geometry | node depends on repo | runtime | `src/args.rs:64-158` | already an interface (deployed getters) | none | getter names and semantics |
| Input cap from one emulator constant | both | runtime + test | `src/engine/structure.rs:34`, `DaveConsensus.sol:26,39`, `src/engine/constants.rs:272-276`, `src/blockchain_reader/mod.rs:604-615` | partly: a published constants JSON per step generation | an exporter and a version field | emulator generation == step generation |
| G and gas headroom mirrors | node depends on repo | runtime | `src/escalation.rs:12-21`, `src/provider.rs:368-380` | no: G has no on-chain block time; headroom is a measurement | n/a | re-measurement on gas or clock changes |
| Generated bindings (forge bind from source) | node depends on repo | build | `justfile:119-121`, `script/contract-bindings.sh:20-72`, `Cargo.toml:38-39` | yes: ABI JSON consumed by `sol!`, or a published crate (`docs/build-system.md:188-202`) | a sync step per contract generation | the ABI itself |
| Upstream rollups-contracts pin in three places | node depends on repo | build + test | `Cargo.toml:49`, `cartesi-rollups/contracts/foundry.toml:45`, `src/engine/constants.rs:171-184` | partly: the test could read from a published constants JSON | same exporter | the upstream version the consensus links |
| Node tests parsing Solidity sources | node depends on repo | test | `src/engine/constants.rs:92-277`, `src/engine/geometry.rs:122-157`, `src/epoch_manager/recovery.rs:302-325` | yes: one constants JSON (step values, arbitration table, enum order, vendored-step registers) | an exporter in the contracts build; loses "dumb but loud" source parsing | where the cross-check runs (it must run on one side at each generation) |
| Contract tests reading node fixtures | repo depends on node | test | `NodeWitnesses.t.sol:52-53`, `NodeProofs.t.sol:44`, `foundry.toml:28`, `tests/engine_machine.rs:78-86` | partly: fixtures copied into the contracts' tests, or a node release asset | a manual copy per witness or proof format change; the check leaves the same PR | the witness and proof format |
| Node harness devnet bundle | node depends on repo | test | `src/blockchain_reader/test_utils.rs:21-39`, `build-devnet.sh:108`, `build.yml:440-453` | yes: release the three-level bundle as an asset (canonical one already ships) | one more devnet build per release; bundle keyed to the anvil version (:453) | DaveAppFactory interface used to deploy apps |
| E2E reads node SQLite and data dir | repo depends on node | test | `test/e2e/rollups/dave/node.lua:161-261`, `schema.sql:13-71` | yes: chain-only (CommitmentJoined by submitter) for the claim; no node feature | rewrite three functions; lose failure localization | none from the store |
| E2E process interface | repo depends on node | test | `node.lua:31-37`, `preflight.sh:47`, `src/machine_runner/mod.rs:211` | no (CLI, env, log marker are the interface) | n/a | flags, env names, marker line, binary location |
| Lua oracle vs node commitments | both | test | `test_env.lua:142-220`, `prt/client-lua/README.md:7-9` | no: it is a deliberate cross-implementation check | n/a | commitment construction agreement |
| Test machine images | both | test | `test/programs/justfile:20-52`, `script/machine-image-fingerprint.sh:182`, `prt/contracts/justfile:48-55` | partly: published images or duplicated build scripts | asset pipeline or duplication | image hashes per emulator generation |
| Machine bindings and emulator/step submodules | node depends on machine; contracts on step | build | `Cargo.toml:12-13,35`, `build.rs:12,127`, `prt/contracts/foundry.toml:15` | partly: a published bindings crate with `external_cartesi` | publish per emulator generation | emulator and step must be one generation |
| Workspace, lock, release profile | both | build | `Cargo.toml:3-14,81-82` | yes, by separate workspaces | none beyond the moves above | n/a |
| Justfile and doctor | both | docs/tooling | `justfile:69-75,135-142,177-289,330-335`, `script/doctor.sh:58` | yes, once the build couplings above are cut | recipe split | n/a |
| One CI workflow and cross-gated release | both | release | `build.yml:5-12,332,464` | yes: per-product workflows and tags | lose the "one tag is one tested generation" guarantee | a compatibility statement naming the contracts generation |
| CHANGELOG, compat statement, addresses | both | release | `CHANGELOG.md:5-10,162-173` | partly: node changelog names the generation it requires | cross-references | the generation identity |
| Measured constants cited by ArbitrationConstants | repo depends on node | docs | `ArbitrationConstants.sol:9-12`, `justfile:277-281` | partly: cite a released node measurement | a pinned citation | table validity depends on node throughput |
| Joint docs and AGENTS rules | both | docs | docs lists above; `cartesi-rollups/contracts/AGENTS.md:103-105` | no for joint protocol docs | n/a | the protocol docs are joint by subject |

## Wrong or stale claims in the recon notes

1. `extraction-dave-side.md:383,421-423` says `machine/step` was at
   `v0.16.0-test3`. History has a later change pinning the final emulator
   v0.22.0 and solidity-step v0.16.0 (`git log -- machine/step`). At the
   reviewed state step is `v0.17.0-test2` and the emulator `v0.23.0-test3`.
2. `extraction-dave-side.md:112-114,433-435` says nothing ties
   `Structure::max_inputs` to `MAX_INPUTS_PER_EPOCH`. Both derive from
   `ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH`; the node pins its emulator's
   value to step's in `src/engine/constants.rs:272-276`, and DaveConsensus
   computes its cap from step's (`DaveConsensus.sol:26,39`). See Runtime.
3. `:76-78` says no node code imports CartesiStateTransition or
   MultiLevelTournamentFactory by name: wrong (`src/args.rs:19-22`, :97,
   :135; `src/provider.rs:850-853`).
4. `:111-112` gives `MIN_HEADROOM` 150,000; it is 650,000
   (`src/provider.rs:380`).
5. `:105-108` places the MARCHID check at `src/main.rs:27-31`; that only logs
   it. The check is `src/args.rs:64-87`, :133-158.
6. `:167-169` and `:202` imply the seam witness generator is ignored;
   `seam_witness_vectors_hold` runs in plain `cargo test`
   (`src/engine/machine_stf.rs:1183-1184`).
7. Stale pins and lines: crates.io pin at `Cargo.toml:49` (not :47), release
   profile :81-82 (not :65-68); `machine/rust-bindings` version 0.23.0
   (`machine/rust-bindings/Cargo.toml:11`, not 0.22.0); CI machine package
   0.23.0 `-test3` (`action.yml:7,11`); sequencer note's emulator v0.22.0 at
   `cartesi-machine-source.sh:12` is now v0.23.0-test3; sequencer note's
   `STORE_FORMAT = 1`, `COMMITMENT_SEMANTICS = 2` are now 2 and 3
   (`src/storage/sql/schema.rs:16,20`).
8. Sequencer note says CI uploads `cartesi-sling-node-linux-{amd64,arm64}`:
   that is the workflow artifact (`build.yml:325`); the release asset is
   `cartesi-sling-node-<ver>-<arch>.tar.gz` (:362).
9. The Dave-side note cites repository commit hashes in its history table;
   they do not survive rebase-merges and are not repeated here.

## Not verified

- How Cargo resolves the machine crates being members of the root workspace
  and of the nested `machine/rust-bindings` workspace at once.
- Whether forge's `out/*.json` at this Foundry pin includes the AST, which
  would let an exported artifact carry the `BondDisposition` names.
- Whether the node joins every root tournament (premise of the chain-only
  e2e alternative).
- Whether the crates.io `cartesi-rollups-contracts` package ships Solidity
  sources (it would replace the soldeer path in
  `src/engine/constants.rs:171-184`).
- All sequencer-repository facts in the sequencer note (read only the Dave
  side), including its git-rev dependency on `machine/rust-bindings`.
- The DaveConsensus and Tournament call lists come from a grep of camelCase
  calls outside test modules, not a per-call trace.
