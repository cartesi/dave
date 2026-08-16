# STF upgrade: emulator v0.21, solidity-step, and two levels

Status: ACTIVE (updated 2026-08-12). The original phase ledger remains below;
the execution checkpoint records what changed after the stable releases.

## Goal

Upgrade the state-transition stack end to end - emulator
v0.21.0, machine-solidity-step v0.15.0, our
CartesiStateTransition rewritten on top of it - and ride the
result to a two-level tournament. The solidity-step update is
expected to considerably simplify CartesiStateTransition and fix
the flagged state-transition semantics issues (the halt/exception
protocol gap of docs/dimensioning.md). The emulator update brings
new hash collection APIs, and cartesi-machine.lua itself gains a
command that computes a whole epoch's computation hash (built on
the new API internally - reference material and a release-conformance
frontend, not an independent oracle). The stable release ships a 35-case
computation-hash corpus with templates, inputs, expected hashes, and
boundary cases for accept, reject, exception, halt, unexpected manual yield,
mcycle overflow, uarch limits, padding, and bundling.

## Execution checkpoint (2026-08-10)

- Stable pins are emulator v0.21.0 (`bd095381...`) and solidity-step v0.15.0
  (`23765c88...`). Do not chase unreleased binary-step-log work in this
  upgrade.
- Emulator, bindings, proof producers, solidity-step, and the adapter form one
  green integration milestone. The v0.21 layout and API changes mean an
  emulator-only intermediate state is not expected to stand alone.
- Ordinary accepted and rejected input behavior is preserved. The opening
  boundary is now one send-CMIO log carrying the pre-input revert root. The
  closing boundary is step plus reset; rejected-input substitution lives
  inside reset. Halt, exception, unexpected manual yield, and mcycle overflow
  now have total terminal behavior.
- Hash comparisons are same-version only. v0.20 and v0.21 machine roots are
  expected to differ. The release gate compares Dave's existing collector and
  the v0.21 CLI on identical v0.21 templates and inputs before regenerating
  Dave's v0.21 goldens.
- The new `cm_collect_*` APIs remain deferred. The exact
  `RX_REJECTED`-at-`imcyclemax` boundary is now pinned: the released uarch
  collector keeps the physical overflow state, while step/reset, log-step,
  and the mcycle collector substitute the revert root. Dave's existing path
  follows the deployed step/reset semantics. The mismatch blocks adopting the
  uarch collector, not this old-collector update.
- The release gate passes all 35 cases through the v0.21 CLI and compares
  Dave's existing collector directly with the 17 released mcycle answers. A
  deterministic FFI regression also derives the
  yield program's real rejection-closing slot and replays its step/reset proof
  through `CartesiStateTransition`.
- Tournament reduction from three levels to two remains a later, separately
  measured phase after the v0.21 update is green.

## Post-integration review ledger (2026-08-11)

The release bump is green. The ledger distinguishes the following review and
validation boundaries: cleanup, deployment identity, and snapshot durability.

### Geometry authority (completed 2026-08-11)

- Dave's one-for-one `LOG2_*_SPAN_TO_*` aliases are retired in Rust, Solidity,
  and Lua. The three primitive widths now come directly from the emulator
  bindings, Lua module, and generated `EmulatorConstants`.
- `Structure` and genuinely derived Dave concepts remain: input-window width,
  epoch-ruler width, and counter masks. Operational hardcoded `20`, `48`, and
  `92` values were removed; explanatory values and frozen measurements remain.
- The executable `CartesiStateTransition` bytecode is unchanged. Its full
  bytecode differs only in Solidity's source-metadata digest, so deployment
  artifacts are intentionally regenerated with the following composition
  change rather than twice.

### Solidity composition (completed 2026-08-11)

- `IStateTransition` remains the tournament-facing abstraction, implemented by
  one concrete `CartesiStateTransition`. The adapter explicitly selects input,
  closing-reset, and plain-step leaves, then composes `SendCmioResponse`,
  `UArchStep`, and `UArchReset` in the required order. This keeps Dave's
  transition grammar central while leaving primitive machine semantics in
  solidity-step.
- The `RiscVStateTransition` and `CmioStateTransition` proxy contracts and
  interfaces are removed. The accepted MetaStep-backed build was 13,713 bytes
  of runtime code and 13,739 bytes of initcode. Making the equivalent three
  branches explicit produces 13,824 runtime bytes and 13,850 initcode bytes,
  leaving 10,752 bytes below EIP-170 and 35,302 below EIP-3860. The old three
  contracts totalled 17,179 runtime bytes.
- Every branch now rejects trailing proof bytes at Dave's boundary. Focused
  tests pin that tightening, all three transition shapes, and real
  rejected-input substitution.
- Closing proof producers accept both ordinary halted padding and an unhalted
  uarch-cycle-overflow state. The overflow regression emits a 1,920-byte
  identity step and a 5,216-byte reset, and replays the complete 7,136-byte
  witness through Solidity to the canonical reset root.
- The accepted v0.21 maximum-input proof is 93,964 bytes, 5,760 bytes larger
  than the accepted v0.20 witness. The MetaStep-backed direct composition saved
  95,044 reviewed gas units over the v0.21 proxy split, but the release-driven
  growth still moved the selected `WIN_LEAF_MATCH` subsidy from 4,298,000 to
  4,420,000. The explicit equivalent changes production bytecode but not the
  transition semantics; this form-only refactor does not reopen calibration.
- The `IStateTransition` ABI and Tournament storage layout remain stable. The
  concrete constructor, Cartesi bytecode, gas table, CREATE2 addresses, and
  dependent factories change. The regenerated devnet bundle contains no proxy
  records and passes its self-fingerprint check.

### Solidity STF evidence (completed 2026-08-11)

- FFI fuzzing now constructs the 24-bit input, 48-bit mcycle, and 20-bit
  ucycle fields directly and selects input-opening, big-opening, interior, and
  closing shapes explicitly. It no longer filters a raw 256-bit counter down
  to 92 bits or relies on random values to hit 2^-20 and 2^-68 boundaries.
- A deterministic emulator-backed matrix covers boundary-adjacent counters at
  the first and last uarch spans, input-window transitions, and the epoch tail,
  including the last valid counter `2^92 - 1`. Solidity-only routing tests
  independently cover present and absent final-input openings.
- A three-instruction RV64 fixture reaches zero and nonzero halt, TX exception,
  and unexpected manual yield; a one-instruction loop reaches mcycle overflow.
  Opening vectors cover both halt values and every terminal class; representative
  closing vectors prove reset without rejected-input substitution. Only RX
  rejection substitutes the recorded pre-input root.
- Real combined witnesses are truncated at DA and step/reset seams, rebound to
  a wrong before-root, given a corrupted authenticated payload, and replayed
  across adjacent transition shapes. Each malformed composition fails while
  the canonical witness succeeds. Low-level access-log mutation remains owned
  by the upstream solidity-step suite rather than duplicated here.
- The Lua fixture now proves from its already-positioned machine instead of
  loading and advancing an identical second machine. Representative input,
  ordinary, reset, and rejected-closing witnesses remain byte-identical.

### Computation-hash corpus harness

- Split acquisition from execution. Keep a public
  `download-computation-hash-corpus` recipe and let
  `test-computation-hash-corpus` depend on it as the convenient one-command
  release gate. The lower-level test operation itself consumes an existing
  verified corpus and performs no network access. The corpus is optional and
  does not belong in ordinary `setup`.
- Move the repository-wide release gate from the root justfile into the
  existing `script/` directory as `script/computation-hash-corpus.sh`. The root
  exposes small download, CLI-conformance, Dave-conformance, and aggregate
  recipes. Bash remains appropriate for curl, checksum, tar, cache, and process
  orchestration; this single corpus still does not justify a generic module.
- Pin v0.21.0 and its digest in the script. The two Rust tests pin their roles:
  complete CLI replay of the release manifest, and Dave comparison with the
  released mcycle answers. Recipe parameters suggesting arbitrary release
  compatibility are false flexibility.
- Use unique temporary download and extraction paths, bind the extracted cache
  to the archive digest, and keep the SHA-256 gate.
- Mark both Rust corpus tests ignored in ordinary Cargo runs. The explicit
  script invokes each with `--ignored --exact`; a missing corpus environment
  must fail, not report a skipped body as a passing test.

### Cartesi Machine preparation and source-build invalidation (completed 2026-08-11)

- `machine/justfile` and `machine/script/cartesi-machine-source.sh` now own the
  source-provider lifecycle. They cache and verify the pinned release patch and
  Boost archive outside the submodule, validate all outputs before publication,
  and retain verified downloads across `clean`.
- Release preparation requires the exact v0.21 emulator commit. A separate
  `generate-sources` path runs the upstream generator for any clean
  intermediary commit, using its Docker toolchain unless a compatible native
  toolchain is declared. Both paths feed the same native incremental build.
- `cartesi-machine-sys/build.rs` is network-free. The download, build, and copy
  uarch acquisition features and their environment inputs are retired. The
  build script only selects the provider, generates bindings, invokes Make for
  an already prepared source checkout, stages archives, and links them.
- Any set `LIBCARTESI_PATH` selects an external provider and never falls back;
  `INCLUDECARTESI_PATH` selects its header or the conventional sibling include
  directory is inferred. With the library variable unset, source mode validates
  the prepared inputs and incrementally builds the submodule with `slirp=no`.
- Cargo watches mutable external archives and headers. Source mode watches its
  prepared inputs plus the submodule gitfile and resolved Git index, so a moved
  checkout rechecks Make while an unchanged invocation stays fresh.
- Setup is provider-aware. Nix and packaged providers skip emulator source
  work; source lanes prepare explicitly; package-backed CI exports both paths;
  and Docker consumes its installed archive without first building an unused
  host copy. The root setup recipes remain cross-subsystem entry points, while
  caller-free machine lifecycle aliases are retired in favor of the machine
  module's canonical recipes.

### Justfile boundary and cleanup

- Keep Just as the public, discoverable dependency graph. Recipes that are a
  command or a short pipeline remain inline. Branching, loops, retries,
  checksums, temporary-file cleanup, and nontrivial destructive path selection
  move into scripts beside the subsystem they serve. Preserve root recipes that
  own cross-subsystem orchestration; do not retain pure subsystem aliases with
  no repository callers.
- Keep the five existing subsystem modules, including the machine lifecycle,
  but do not create a generic `test` module or a module merely to hide a
  one-line command.
- Make root `doctor` a one-line wrapper around `script/doctor.sh`, but distribute
  owned checks across focused checker scripts and one-line module recipes. The
  root script checks cross-cutting host and repository state, runs every
  component in a subshell, continues after failures, and reports which
  components failed. A component checker inspects only state produced by its
  setup recipes and never invokes another doctor. Use only an exit contract -
  healthy, diagnosed setup failure, or checker failure - rather than JSON,
  parsed output, shared counters, or a shell framework.
- Bash is intentional bootstrap tooling for every doctor: it must be able to
  report a missing Lua, Python, Rust, or Docker environment rather than require
  one of them to start. Align checks with real build selection: any set
  `LIBCARTESI_PATH` selects the external provider, Docker is required by the
  current full `just check`, and submodule, binding-stamp, header, library, and
  version checks must diagnose the same inputs the build consumes.
- Migrate doctor without a flag day. First extract the current behavior to the
  root script, then refactor it into sections. Move the machine-owned checks
  first now that its module has landed, followed by contracts, programs, and
  E2E one subsystem at a time. Keep the focused E2E preflight separate from the
  exhaustive doctor, and extract shared helpers only after concrete repetition
  remains.
- Root extraction and sectioning are complete. The machine component owns its
  pinned step checkout and library-provider checks behind `machine::doctor`.
  One parameterized contracts checker serves the one-line PRT and Rollups
  module recipes; it verifies each module's effective Soldeer dependency roots
  and binding-stamp freshness without duplicating the implementation. The
  programs component owns its checksum-pinned kernel and rootfs plus the
  required echo, yield, and Honeypot image fingerprints behind
  `programs::doctor`. Each persistent image now has a separate producer script
  and v2 receipt, so unrelated image recipes do not invalidate it. Stress stays
  an explicit Rust measurement fixture outside doctor; the obsolete compute
  image was removed with the Lua measurement redesign. The Rollups E2E
  component owns the complete
  devnet-bundle check, the default-port warning, and current plus legacy E2E
  forensic litter behind `rollups-tests::doctor`; its focused per-test preflight
  stays separate. The system-TMPDIR warning remains at root because it diagnoses
  host-wide Rust-test litter that the E2E sweep does not own. Root diagnosis is
  tiered: `doctor` covers build/check readiness, `doctor-e2e` covers optional
  integration state, and `doctor-all` aggregates both without making every
  ordinary checkout construct expensive E2E fixtures.
- Move worktree report and sweep to `script/worktrees.sh`, and bootstrap to a
  focused script. Parse worktree records without truncating paths, recognize
  both Codex and legacy Claude session worktrees, preserve the current/dirty
  worktree refusals, and propagate cleanup failures instead of printing a
  successful sweep after a failed removal.
- Worktree report and sweep extraction is complete. Both Codex and legacy
  Claude session trees are recognized, NUL-delimited porcelain preserves paths,
  current and dirty worktrees are refused, and measurement or cleanup failures
  make the command fail without claiming a successful sweep. Bootstrap now
  lives in `script/bootstrap-worktree.sh`: it resolves both worktree paths,
  stages and verifies source artifacts before replacing fixed target paths, and
  leaves generation and final diagnosis with the owning subsystem recipes.
- Fix argument forwarding before broader extraction. Recipes already enable
  positional arguments, but several variadic and scalar wrappers interpolate
  `{{ARGS}}`, `{{CASE}}`, `{{TAG}}`, or `{{CMD}}` back into shell source. Pass
  them as `"$@"` or `"$1"` so spaces and shell punctuation remain data. This is
  primarily developer-tool correctness, not an untrusted-input security
  boundary.
- Use one acquisition rule across corpora, program dependencies, emulator
  sources, and retained remote snapshots: reuse a valid cache; download to a
  unique temporary path; verify a pinned digest; atomically publish; and never
  delete the last valid copy before a replacement succeeds. The program
  dependency downloader now follows this rule. The unrevalidated legacy
  Sepolia scripts remain as historical leads, but their unchecked download,
  cleanup, and execution recipes have been removed from the public Just
  surface. Re-enabling them requires semantic revalidation and verified staged
  acquisition as one effort.
- The default program build and clean sets are now symmetric and contain only
  the required lightweight echo and yield fixtures. Stress and Docker-heavy
  Honeypot builds remain explicit measurement and integration fixtures. The
  Lua constants harness uses temporary post-boot stress-ng fixtures instead of
  a persistent compute image.
- The PRT gas-calibration program now lives in
  `prt/contracts/script/measure-gas.sh`, with its reviewed Forge and dependency
  pins passed from the thin Just recipe rather than duplicated. The duplicated
  contract-binding program now lives in one shared script. Its
  module-specific stamp covers the generator, exact Forge arguments and
  effective configuration, Forge binary and version, lockfile, local sources,
  configured dependency roots, and relevant imported PRT and step sources. It
  excludes the surrounding justfiles, compiler caches and output, and its own
  generated bindings. Its exact production filters exclude test contracts and
  fixture factories from the Rust API. Fixed Foundry test and script overrides
  also remove those roots from binding compilation and invalidation. The full
  effective remapping strings remain hashed because they affect embedded
  bytecode metadata, while the unused `prt-contracts-test` target content does
  not.
- The readable E2E scenario dependency matrix remains in Just, while its
  procedural preflight now lives in a bootstrap-safe local shell script. The
  stale Sepolia helpers are quarantined from the runnable Just surface; do not
  restore an entry point without revalidating the full flow, and do not build a
  general E2E cleanup framework.
- The independent emulator constants harness now builds temporary stress-ng
  fixtures after each worker exists and has completed a fixed untimed warmup.
  Runs explicitly select from ten instruction and memory workloads; cheap
  fixture checks validate every active state without starting the long
  benchmark. The harness uses the v0.21 CMIO API, rejects halt and yield
  throughout, and rounds measured capacity down. The obsolete persistent
  compute image and unchecked release-candidate Docker acquisition are gone.
- Review the cleanup by concern: argument forwarding and downloads; corpus and
  machine-source ownership; root script extraction; and binding, program, and
  E2E artifact rules. Re-run fingerprint generation intentionally when producer
  inputs change rather than confusing that expected invalidation with
  v0.20-to-v0.21 state-hash drift.

### Stored-machine boundary (completed 2026-08-11)

- Committed snapshots now load with explicit `SHARING_NONE`, giving them
  private file-backed mappings and OS CoW. Only a unique working clone loads
  with `SHARING_ALL`; immutable loads no longer depend on stored per-range
  sharing flags.
- The runner reads its durable cursor, input count, seal state, and candidate
  payloads from one database transaction. An open tail shorter than the
  configured gap waits unexecuted. Full gaps and the sealed final remainder
  run as publication batches, so a crash can replay at most one complete batch
  (64 inputs by default).
- A batch owns at most one closed, immutable transient rollback checkpoint plus
  one mutable clone. Accepted inputs rotate the clone into that checkpoint;
  rejected inputs discard the poisoned clone and resume from the checkpoint.
  Only the final canonical boundary is retained.
- Thin v0.21 bindings expose the static stored-machine operations. Final
  publication closes and root-verifies the candidate, syncs its stored files,
  renames it into the content-addressed store without replacement, and only
  then registers its boundary and window roots in one database transaction.
  `sync_stored` is a host backing-store barrier, not a guest filesystem sync.
- The filesystem-first order permits an orphan after a crash or database
  failure, but never a row that names an undurable machine. Content-addressed
  publication lets deterministic replay reuse the orphan CAS artifact after
  re-execution. Cleanup remains database-first, so an interrupted best-effort
  removal leaves only an unreferenced directory.
- Normal advance publication follows the configured gap cadence. Dispute-time
  densification may still persist intermediate boundaries needed to construct
  proofs; it uses the same durable publisher.
- One node process exclusively owns a state directory. Multi-process locking,
  hot-load root verification, and a broader recovery subsystem remain outside
  the supported model. The lifecycle invariants and crash seams, rather than a
  pre-implementation microbenchmark, determined this design.

## Verification doctrine for the whole campaign

- The contracts (solidity-step) remain the semantics authority. The release
  corpus is immutable evidence, while the release CLI is a frontend over the
  collect APIs and must not be counted as an independent implementation.
  Independent structure comes from the test-only prototype, Lua client, and
  contract proof evidence where their lineages genuinely differ.
- Collection changes remain characterization-first. The existing collector is
  compared with the released mcycle answers before the switch; during the
  migration it is a temporary differential against the collect-backed path and
  the prototype. It is deleted once the replacement is qualified. The exact
  evidence and removal criteria live in `collect-hashes-migration.md`.
- Fixture regeneration is a mass event this time (template hashes
  change with the machine images): regenerate ONLY after the
  corresponding differential passes, one tier at a time, each a
  reviewed act. The template-hash tripwire firing is the signal,
  not an obstacle.

## Original phase proposal (phases 0-2 superseded)

This ledger is retained as planning provenance. The execution checkpoint
above describes the current design: phases 0-2 landed as one integration
milestone, so their separate intermediate gates and old checkpoint/halt
terminology below are not current specifications. Phases 3 and 4 remain
forward-looking work.

0. RECON, before any bump. Read the v0.21 changelog and the new
   solidity-step; inventory every semantic delta. Specifically:
   - uarch geometry: span (2^20 today), the idle-churn constant
     (exactly 34 usteps/cycle on 0.20 - the toy models it), the
     pristine-uarch reset hash. If the span width changes, the
     meta-cycle layout [input:24][big:48][ucycle:20], Structure,
     and CartesiStateTransition all move together.
   - cmio/checkpoint semantics: the fused feed, the checkpoint
     slot write, send_cmio_response shapes.
   - halt/exception semantics: what the new solidity-step makes
     provable (the halted-feed transition is unprovable on-chain
     today for both parties - dimensioning.md).
   - the collection APIs' contract: span/stride granularity, yield
     and halt behavior at window edges, whether folded subtrees
     come back, and whether the runner's local window-root fold can
     move into the emulator.
   - the cartesi-machine.lua epoch-hash command's SCOPE: does it
     model our conventions (feeds, checkpoints, revert, padding)
     or only raw span collection? Its value as an oracle depends
     on this; its internals are the reference for our own use of
     the new API either way.
   - where the span constants become authoritative: uarch-to-big,
     big-to-input, input-to-epoch are today a replicated
     agreement across components, guarded by tests that parse the
     mirrored source constants. The emulator and
     solidity-step will now EXPORT them - re-source ours from the
     upstream artifacts and repoint (or retire) the hand-mirror
     guards; one authority, not a treaty.
   - the pending explicit file-sync machine API: today the
     boundary store's fs-first/db-second ordering is atomic
     (stage+rename) but not durability-ordered - nothing fsyncs
     the machine store before the SQLite row commits, so power
     loss can in principle commit a row whose directory never
     landed. Adopt the sync call at the store seam when the API
     ships.
   - snapshot/store format: CAS by root hash, hash sidecars,
     clone_stored and SHARING_ALL semantics, destroy-needs-no-
     flush - all verified on 0.20, all to re-verify. Also whether
     the ~130 ms SHARING_ALL load anomaly survives v0.21.
   Output: a recon section in this file, facts with citations.

1. Emulator bump, old collection path. Submodule + bindings on
   v0.21.0, machine images rebuilt, devnet and store pins
   updated (stores wipe: config pins the emulator version).
   Gate: our engine's hashes (old API) match the released answers and the
   independently structured prototype on identical machines and spans, across the transition-shape
   matrix (active, idle, yield, revert, checkpoint windows).
   Then regenerate goldens tier by tier; battery green at the
   CURRENT three levels - contracts untouched in this phase.

2. solidity-step + CartesiStateTransition, with Diego (he owns
   the halt/exception contracts rework - this phase and his work
   are one motion; coordination point below). Then the node side
   the ledger has been holding: re-verify the four revert sites
   named in docs/computation-hash.md; build the exception image
   and the stf_exception scenario; decide the runner's
   halted-window scheduling (the wedge is deliberate today -
   schedule halted windows over the fixed point, or keep the
   wedge); update the Lua oracle the same way, verified against
   the contracts, never against the node.

3. New collection APIs. Qualify and swap the engine's machine STF onto
   `cm_collect_*` under the gates in `collect-hashes-migration.md`; measure
   because collection is a core dispute-time cost, then remove the legacy
   production collector and its migration-only differential.

4. Two levels. Re-run the constants pipeline ON v0.21 and on
   validator hardware (the previous numbers - log2step [37,0],
   heights [55,37] at a 60-min inner timeout - were measured on
   0.20 and are stale the moment the machine changes); walk the
   adoption gates of docs/measurements/constants.md. Level-0
   stride moving 44 -> 37 moves the window-root quartet
   coordinate, the frontier fold's geometry, the drift-guard pins,
   and every client and harness fixture that assumes three
   tournament levels. Clocks and spans re-derive under the
   dimensioning rule: coordinates worst-case, clocks average-case.

## Also in scope (from the standing ledger)

- Revisit transaction revert handling when the phase-2 revert surface
  changes. The stateless lane does not inspect receipts, so decide whether an
  operator-provided revert-protecting endpoint remains sufficient or the node
  should preflight its one selected request or escalate a repeatedly identical
  intent. Also cover the last input slot and last stride.
- Test-shape constants profile (fast e2e disputes): contracts
  side, same territory as phase 4, the deepest e2e-latency lever
  on record. Candidate to land with the two-level change.
- Measurement methodology hardening is complete for the retained Lua
  reference harness: it samples ten selectable stress-ng workloads from a
  verified active post-warmup state, rejects terminal and yielded timing regions, and
  rounds capacity conservatively. The sparse-hash step-size study can ride
  these workloads after the final collect API lands, at Gabriel's call on
  timing.
- CI tranche 2 (build-once + per-scenario matrix, docker layer
  cache) - independent track, can ride between phases.

## Decision points (Gabriel)

- Sequencing vs the external audit of prt/contracts:
  CartesiStateTransition and the tournament constants are audited
  territory; when phases 2 and 4 may land is a coordination
  question, not a technical one.
- Ownership seams with Diego for phase 2 (who lands what).
- Whether the two-level shape re-derived on v0.21 confirms
  [37,0]/[55,37] or moves; the pipeline decides, not the old memo.
- Whether phase 4 carries the test-shape profile with it.

## Known traps carried forward

- Correlated-oracle blindness: node and Lua oracle wrong the same
  way is invisible to e2e; only the contracts arbitrate.
- Fixture regeneration without a passing differential first
  launders bugs into goldens.
- The dev environment moves with the emulator. The cartesi-dev flake now
  provides the v0.21 external library; future pin bumps must keep that package,
  `LIBCARTESI_PATH`, and the repository lifecycle aligned. Local just (1.48)
  versus CI just (pinned 1.57) remains skew worth closing when the flake moves.
