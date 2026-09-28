# Two-level sling node

Status: ACTIVE (created 2026-09-28). This plan supersedes phases 3 and 4 of
[stf-upgrade.md](stf-upgrade.md) and re-sequences
[collect-hashes-migration.md](collect-hashes-migration.md). Those documents
keep their evidence requirements; this one owns the order of work and the
decisions below.

## Goal

A working, sound rollup whose disputes run in two levels: log2step [37, 0],
height [55, 37], inner timeout T = 60 min (today: [44, 27, 0] / [48, 17, 27]).
Everything may change - contracts, node, schema, deployments - in service of
that goal.

## Decisions (2026-09-28)

- D1. Authority order. The Solidity step (solidity-step plus Dave's
  `CartesiStateTransition`) is the ultimate authority. The `cartesi-machine`
  CLI computation-hash mode is the reference implementation. The sling node is
  the subject. The triage procedure below makes this order operational.
- D2. Seam 2 follows Solidity. An RX_ACCEPTED yield on the last cycle of the
  input budget (mcycle == imcyclemax) receives the next input. The step reads
  only the pending yield, so halt and overflow are terminal only when no
  manual yield is pending.
- D3. The reference CLI is the released v0.21.0 CLI. Where it disagrees with
  Solidity, the case becomes a named exclusion adjudicated by a Solidity
  vector, until a tagged release carries the fix.
- D4. Emulator pins. Development may pin unreleased upstream commits; anything
  Dave ships links a tagged release. Upstream is arm's length: nothing on the
  critical path waits for an upstream release.
- D5. Epochs with more than 2^24 inputs are out of model. The node must fail
  with a clear error instead of an assert panic or crash loop.
- D6. The two-level node is a new deployment generation. The system is not
  deployed yet, so there is no legacy to serve and no intermediate release.
  The node discovers the geometry and accepts any valid table: it must run the
  current three-level canonical devnet and a two-level deployment alike.
- D10. Two levels are delivered before the canonical switch (2026-09-28). This
  stack makes the node handle a two-level deployment, including the
  height-37 hardening (W4.4, W4.5); a later PR changes the canonical
  constants (W5.1). Until then, a devnet geometry profile provides the
  two-level deployment (W3.8), and a per-PR smoke subset runs e2e on it.
- D7. The leaf-by-leaf collector (`Ruler::collect` over `MachineStf`) stays
  permanently as a test-only oracle. This replaces the deletion rules in
  collect-hashes-migration.md and in stf-upgrade.md's verification doctrine.
- D8. Geometry and height-37 readiness on the current machine API come first.
  The bulk collect APIs follow as margin, not as a prerequisite.
- D9. CLI-backed tests are not ignored. The digest-pinned v0.21.0 corpus
  download moves into setup, and the corpus tests fail loudly when it is
  missing. This supersedes the corpus-harness rule in stf-upgrade.md and the
  acquisition rule in collect-hashes-migration.md.

## Why this order

Evidence from the 2026-09-28 research pass. Line-level pointers are omitted
because they rot; each claim names the code that carries it.

- Collection speed is not the barrier. The [55, 37] selection was derived
  from the legacy per-ustep rate (measure.rs `derive()`: 87,427
  ustep+hash pairs/s at density 616, i.e. 142 dense big cycles/s). One leaf
  commitment spans 2^17 big cycles: about 15 min measured, 31 min at hardware
  slack 2, inside T = 60. h_leaf = 37 holds while the measured dense rate
  stays in [72.8, 145.6) big cycles/s (the bounds already include slack 2).
  The margin is thin toward a larger leaf (2.7% below the flip to 38) and
  about 1.95x toward a smaller one. Numbers were measured on v0.20.
- The height-37 blockers are memory and scheduling. `compute_and_store`
  materializes every run and every Merkle node of the span (estimated
  20-30 GB at stress density for ~81M runs; not measured). The build runs
  inside the epoch-manager task through the hero's `level_material`, so the
  whole manager stalls for the duration (node-architecture.md debt 7).
- Hard-coded geometry is narrow. `rollups_machine::LOG2_STRIDE` and its
  derived constants feed five run-time production sites (the runner collect,
  the window-root fold and quartet, the roll prefix check, `settlement_root`,
  and `DisputeSource::on_store`) plus the startup equality check in args.rs.
  The hero, the tournament reader, the dispute engine and the Lua player
  already take each level's stride and height from on-chain descriptors. The
  factory exposes `tournamentLevelCount()` and `tournamentParameters(level)`;
  the node reads only row 0, in that startup check, and nothing calls
  `tournamentLevelCount()`.
- The two-level geometry is the CLI's own model. The root claim equals the CLI
  mcycle computation hash at log2 period 17 (height 72 - 17 = 55); each leaf
  tournament equals the CLI uarch-cycle computation hash for that
  `mcycle_period_index` (height 37). The three-level middle level has no CLI
  counterpart, so a collect migration under three levels could not be
  CLI-checked at level 1.
- The CLI is not independent of the collectors. It is built on
  `collect_mcycle_root_hashes` / `collect_uarch_cycle_root_hashes`, and
  upstream tests it only against those collectors, never against Solidity.
  After a node collect migration, only the leaf-by-leaf path and the Lua
  client remain independent lineages (hence D7).
- The collect API's problems are mostly ergonomic. On v0.21.0 both calls can
  already produce Dave's root and leaf commitments; the costs are JSON with
  base64 hashes, caller-carried partial bundles, looping through automatic
  yields, and capturing `revert_uarch_tail`. The `feature/prt` bundle helpers
  (0d34b55) are additive conveniences Dave can emulate. The exception is
  semantic: the v0.21.0 uarch collector gets seam 1 wrong.
- The C signatures are identical on every upstream ref after v0.21.0. What
  moved is semantic: commit
  c1280ed4 on the unreleased `feature/prt` branch fixes seam 1 in the uarch
  collector and reorders break-reason precedence (halt, manual yield,
  overflow). It changes no state-transition source and no marchid. It also
  narrows the `cm_send_cmio_response` length to uint32 (a C API break). No
  release after v0.21.0 exists; `v0.21.1-test1` carries two unrelated
  commits. Open PR #390 changes the uarch pristine hash and the proof format
  and is a separate future upgrade.

## Seam 2 (soundness, geometry-independent)

`MachineStf::terminal_fixed` and the Lua client's `status()` treat
mcycle >= imcyclemax as terminal before looking at the pending yield.
`SendCmioResponse` checks only iflags_Y and the RX_ACCEPTED reason, so on-chain
the next input is delivered and the budget renewed. The node therefore pads
where the canonical transition feeds, and its own `prove_transition` logs the
feed, so it cannot prove its own leaf. An adversary's claim that matches the
node up to that leaf, takes the Solidity value there, and is arbitrary
afterwards wins every match against Dave nodes. If a Solidity-faithful party
wins, the honest node's winner-commitment assert crash-loops it.

Reaching the state costs an input that runs exactly 2^48 - 1 cycles before
accepting (days of execution; WFI does not fast-forward), or a template whose
stored imcyclemax or mcycle is preset. The corpus case
`mcycle-at-input-maximum` (template `mcycle-boundary`, input accepting at
MCYCLE_MAX) ends in a seam-2 state on v0.21.0, so vectors are cheap. The
exploit argument is protocol reasoning, not yet a tournament test. Existing
three-level deployments are exposed as well.

Seam 1 (RX_REJECTED at imcyclemax) is already handled: `restore_rejected`
keys only on the rejection reason and runs before the next terminal check.
The v0.21.0 uarch collector and the v0.21.0 CLI still get it wrong.

## Triage procedure

A divergence between any two of {node, CLI, Lua} is settled by Solidity, the
same way a dispute is.

1. Check preconditions before blaming anyone. The CLI silently assumes a
   rolling template stopped at an RX_ACCEPTED fixed point (it boots any other
   template to its first fixed point without hashing), a pristine uarch, and
   keccak256 for the mcycle hash. It fails loudly on a nonzero uarch_cycle or
   iunrep, and aborts on a rejected input without a revert mode. The harness
   asserts all of these up front. The CLI must also be the release named by
   D3; version strings cannot tell v0.21.0, `feature/prt` and PR #390 apart.
2. Localize. The CLI emits roots only, so it cannot say which period
   differs. Find the first differing input by bisecting on epoch prefixes
   (the CLI over inputs 0..k against the node's root for the same k-input
   epoch) or against the Lua tree. Narrow within that input with per-period
   CLI uarch roots (`mcycle_period_index`), then bisect the node's
   `DisputeSource` tree or the Lua tree to the first differing stride-0 leaf
   m.
3. Adjudicate. From the agreed pre-state leaf m-1, generate the transition
   proof and run `CartesiStateTransition.transitionState` through forge FFI.
   The side whose leaf m matches wins.
4. If Solidity itself is suspect, read the hand-written code first:
   `EmulatorCompat`, `AccessLogs`, `Memory`, `MetaStep`, `Buffer`,
   `CartesiStateTransition` and its libraries. `UArchStep`, `UArchReset`,
   `SendCmioResponse` and `EmulatorConstants` are generated from the emulator
   C++, so a mismatch there implicates the C++ and needs an upstream fix plus a
   new solidity-step release.
5. If the decision is to change Solidity rather than the CLI or the node,
   that is a contract change under the contract-change gate and a new
   deployment generation. Until it ships, the deployed Solidity adjudicates
   live disputes and the node must follow it.
6. Record. Every adjudicated case becomes a named vector (FFI, Rust, Lua; the
   CLI when it agrees). A CLI disagreement becomes a named exclusion with its
   Solidity vector, the upstream reference, and a removal condition. Never
   regenerate a golden before the differential passes.

Priors: a node-vs-CLI divergence is most likely a node bug, and a CLI-vs-
Solidity divergence most likely a CLI bug, but neither prior replaces step 3.
Agreement is not evidence either: at seam 2 the node and the v0.21.0 CLI
agree and are both wrong, which is why W2.10 samples agreeing cases against
Solidity.

Initial v0.21.0 CLI exclusions:

- Seam 2 followed by more inputs: the CLI ends the epoch and pads (fixed
  upstream in c1280ed4).
- Seam 1 (rejection at imcyclemax): the uarch hash of the rejecting period
  keeps the physical root at the closing reset, with or without later
  inputs. When more inputs follow, the CLI also ends the epoch and pads with
  the revert root. Both are fixed upstream in c1280ed4.
- Corpus case `uarch-near-limit-tail`: the revert root is captured after
  collector setup, so the released hash does not follow Solidity (fixed
  upstream in 22b4431).
- Uarch cycle overflow and a uarch halting exactly at UARCH_CYCLE_MAX: the
  collector throws where Solidity defines an identity step. Non-pristine uarch
  only; no upstream fix yet.
- Oversized inputs: the host throws where Solidity is a no-op (fixed by
  c1280ed4's host-send hunk). Unreachable from chain (InputBox caps inputs at
  2^16 bytes); synthetic vectors only.

## Workstreams

Sizes are S/M/L. W1, W2, W3 and W4.1-W4.5 have no mutual dependencies and
start now.

This stack (D10), in order: W2.1; W3 including the devnet geometry profile
(W3.8) and the two-level e2e smoke; W4.4 and W4.5; the root CLI gate (W2.11).
It ends with a node that handles a two-level deployment.

Before the canonical switch (W5.1) lands: the stack above, W4.1 (M1
confirms the table), and W4.8 (the full e2e matrix fits CI budgets on two
levels). Before a two-level release is tagged, additionally: W4.2, W4.7, the
D5 guard (W8), W5.2-W5.4, a tagged emulator (D4), and the open decisions on
generation contents and audit timing.

### W1. Seam 2 fix (standalone, now)

1. (S) Solidity vectors first, in `prt/contracts/test/step/proofs.lua`, built
   from emulator log APIs rather than the Lua client's `status()` helpers
   (the generator imports the module being fixed): accepted-at-imcyclemax
   opening with an input (fed state), the same without an input (idle), and
   rejected-at-imcyclemax closing (revert root). Add the saturation variant
   from the corpus `mcycle-boundary` template.
2. (S) Node: terminal means a manual yield other than RX_ACCEPTED/RX_REJECTED,
   or halt or overflow with no manual yield pending. Fix the
   `Stf::terminal` doc and the ruler comments. Test on a machine with preset
   imcyclemax: the window-start leaf equals the FFI post-state and
   `prove_transition` agrees with the collected leaf.
3. (S) Lua client: the same rule in `status()`, with tests.
4. (S) Runner regression: a seam-2 template with two inputs must feed window
   0, and the settlement root must differ from the all-idle root.
5. (S) Store semantics stamp. `node_metadata` stamps a crate version frozen at
   2.0.0, so stores built under old semantics are silently reused. Add a
   semantics version, bump it here, and bump it on every future semantic
   change.
6. (S) Docs: dimensioning.md (an advance response at mcycle overflow is a
   no-op only when no RX_ACCEPTED yield is pending, and overflow is terminal
   only when no manual yield is pending), computation-hash.md, and the seam
   text in collect-hashes-migration.md and stf-upgrade.md, and the vector
   ledger in prt-contract-testing.md.

Exit: vectors pass through `CartesiStateTransition`; node and Lua match them;
the v0.21.0 CLI seam cases are recorded as exclusions.

### W2. Test foundation (now, parallel)

1. (S) E2E steering. `stf_all` and `stf_revert` use 2^28 level-1 links where
   the stride is 27 (since 2025-06), so they likely prove the wrong
   transitions; this is a hand trace, so log the proven transition first. Fix
   the links and make `run_epoch` assert which transition was proven.
2. (S) Un-ignore the real-image `engine_machine` differentials (about 26 s in
   CI). Move the digest-pinned corpus download (912 KB) into setup and
   un-ignore the corpus tests, failing loudly when the corpus is missing
   (D9). The v0.21.0 corpus becomes release-package conformance with the
   named exclusions above.
3. (S) Emulator provenance gate. Check that the linked library's pristine
   uarch hash equals solidity-step's `UARCH_PRISTINE_STATE_HASH` and that
   its marchid equals `CartesiStateTransition.CM_MARCHID`. Check that the
   test CLI is the v0.21.0 release (D3) by package digest or build commit,
   whatever the development library pin (D4). When the library pin is not
   v0.21.0, also check that library and CLI share the state-transition
   sources (interpret.cpp, send-cmio-response.cpp, uarch-step.cpp,
   uarch-reset-state.cpp, uarch/).
4. (S) CLI provisioning: `machine::setup` builds only the static libraries
   today. While the pin is v0.21.0, build the Lua module,
   `cartesi-jsonrpc-machine` and an in-tree CLI wrapper from the same source;
   otherwise use the released v0.21.0 CLI. In external-provider mode use the
   provider's CLI plus the gate above.
5. (M) A CLI adapter in the node's test support: an epoch mcycle root at
   period `log2step(0) - 20`, a single-period uarch root, rejections through
   `--remote-spawn`, and a hash-file parser.
6. (M) A Dave-owned boundary corpus from the corpus CHT1 guest and templates:
   seeded cases over input counts, outcomes, sample-point boundaries and
   strides, plus explicit seam vectors, with expected values adjudicated by
   Solidity where the CLI is excluded. Shrink failures into checked-in
   vectors.
7. (M) Extend Dave-vs-corpus to the uarch cases, minus exclusions. This is
   the first release-answer evidence at stride 0 (height 29 at the corpus
   period 9); height 37 is first checked by period-17 CLI runs.
8. (M) Solidity triage harness: a `proofs.lua` mode taking a template, input
   files and a meta-cycle; a forge FFI test running `CartesiStateTransition`
   on node witnesses (`DisputeSource::prove_transition`) and Lua witnesses,
   with a provider computing the real input Merkle root; and a Rust bisection
   helper.
9. (M) Extend the toy and spec oracle with overflow, exception,
   unexpected-yield and seam behavior.
10. (M) Solidity sampling of agreeing cases. For every item-6 case, prove
    leaf m from leaf m-1 through `CartesiStateTransition` at each shape
    boundary (input opening, closing reset, idle padding, rejection,
    terminal) and at seeded random counters, even when node, Lua and CLI
    agree. This scrutinizes the reference, not only the subject.
11. (M) Root CLI gate in e2e. In `Env.epoch_settlement`, assert that the
    settled computation hash equals the v0.21.0 CLI mcycle hash at period
    `log2step(0) - 20` read from chain (24 today, 17 after W5), and dump a
    repro directory on mismatch. Exclusions apply.

### W3. Geometry discovery (under the current three-level contracts)

Land it as a refactor: settlement roots and goldens must stay byte-identical
under [44, 27, 0].

1. (S) A `TournamentGeometry` type with a validator that mirrors
   `TournamentParameterTableValidator`, plus node bounds (20 <= log2step(0)
   <= 68, leaf stride 0) and a feasibility bound that refuses or warns about
   a leaf span the node cannot build within T.
2. (S) Startup discovery: an ERC-165 check, `tournamentLevelCount()`, every
   `tournamentParameters(level)` row, then validation. This replaces the
   compiled-stride equality check. Any valid table is accepted (D6); the
   feasibility bound is the only extra refusal.
3. (M) Pin the discovered table, the consensus address and the factory
   address in `sling_config`, and refuse drift with a store-wipe error.
   Stability is a trust assumption of the parameters provider, not an
   enforced property, so the pin alone is not enough (see 5).
4. (M) Replace the `LOG2_STRIDE` family with the pinned root stride at the
   five sites. Tighten `DisputeSource::covered()` to stride == run stride:
   today it serves a wrong tree for any stride strictly above the run stride,
   which CLI checks at strides 39 or 44 would hit once the run stride is 37.
5. (S) Tripwires: each epoch's tournament descriptors equal the pinned rows,
   and the hero's root commitment equals the settlement computation hash
   before joining.
6. (S) Rewrite the drift guard in `engine/constants.rs` to validate the
   ArbitrationConstants table, and parametrize the unit tests over [44, 27, 0]
   and [37, 0].
7. (M) Test tree: read the e2e oracle stride from chain; a patch-chain helper
   that takes the geometry and a target transition; rework
   `sealed_leaf_timeout` (root height parity flips from 48 to 55); drop
   `CURRENT_LOG2STEP` from measure.rs.
8. (M) Devnet geometry profile. A test-only table provider (outside src/)
   and a devnet-only deploy path, so `build-devnet` can produce a bundle
   whose factory serves [37, 0] / [55, 37] while production scripts keep the
   canonical provider. A per-PR CI job runs an e2e smoke subset on it (the
   happy path and one leaf-reaching dispute).

### W4. Height-37 readiness on the current API

1. (S) M1: re-run `just measure-constants` on v0.21, on validator-grade
   hardware, and cross-check with the Lua harness. Decision: the measured
   dense rate stays at or above 72.8 big cycles/s. If it reaches 145.6 and
   the generator reads [38, 0] / [54, 38], keep [55, 37]: the smaller leaf is
   the conservative direction.
2. (S) M2: an end-to-end stride-0, height-37 quartet in `bench_quartets`,
   run with peak-RSS capture. Decision: build time within 30 min on dev
   hardware, and the RSS figure that confirms item 4.
3. (S) M3: resolve stride-37 root-level cost. By measure.rs's definition it
   is 1.81x, but the same table implies up to 6.3x lower absolute throughput
   than stride 44; the hash-cost curve has an unexplained hump at 2^16-2^18.
4. (M) Bounded-memory commitment build: fold per depth-8 sub-span, keep only
   the fanout hashes, and insert sub-span roots as they complete. The
   materialized builder stays as a test oracle.
5. (M) Move dispute machine work off the epoch-manager task (debt 7).
6. (M, optional) Sub-window positioning and a parallel sub-span leaf build:
   margin on the current API without the collect path.
7. (S) Declare the per-input compute contract implied by stride 37 in
   dimensioning.md (roughly 2^34 big cycles per input), after M1 and M3.
8. (M) E2E cost: dry-run the e2e matrix on a two-level branch before the
   switch, including the W5.2 leaf gate's CLI runs. A dense leaf build costs
   about 15 min per party at height 37, against today's 15-60 min
   per-scenario step timeouts. Levers: a collect-based inner builder for the
   Lua sybil only (the oracle stays leaf-by-leaf), patch chains aimed at
   light spans, and moving full-period leaf gates to the nightly battery.

### W5. The switch (new deployment generation)

1. (S) ArbitrationConstants to LEVELS = 2, [37, 0] / [55, 37], through the
   contract-change gate. Gas fixtures are already calibrated at [55, 37]
   (2026-08-27), so run a validation pass, not a recalibration. Regenerate
   the devnet bundle.
2. (M) Leaf CLI gate: in leaf-reaching scenarios, the leaf commitment equals
   the CLI uarch hash for the disputed period. The root gate (W2.11) moves to
   period 17 on its own. Exclusions apply; full-period leaf checks may run
   nightly if W4.8 says per-PR budgets break.
3. (S) Docs: the level tables and stride notes in computation-hash.md,
   dispute-game.md, node-architecture.md, test-harness.md, constants.md,
   prt/contracts/AGENTS.md, and dimensioning.md (the "remains planned"
   two-level paragraph and the three-level allowance note).
4. (S) Release notes: a new generation, new addresses and geometry.

Exit: the e2e battery is green on two levels within CI budgets, and the CLI
gates are green.

### W6. Collection speed (margin, after W5)

1. (M) Safe Rust wrappers for both collect calls, keeping hashes, offsets,
   partial bundles, break reasons and error context; wrapper tests.
2. (L) One collection entry point for the runner and `compute_and_store`.
   `Ruler::collect` and `StrideSampler` move behind a test-only gate (D7);
   positioning and proving keep the stepping core in production.
3. (M) Differential: the new runs against legacy runs, CLI roots and Lua,
   over the W2 corpus. Compare runs, not only roots, so failures localize.
4. (S) Seam 1 on v0.21.0: detect a rejected yield at imcyclemax from iflags_Y
   and tohost (the v0.21.0 break reason reports overflow there) and fall back
   to stepping for that mcycle. Remove the fallback when a tagged release
   carries c1280ed4.
5. Known constraints: the uarch collector requires uarch_cycle == 0, so spans
   starting mid big cycle need slicing or stepping; `revert_uarch_tail` is
   required for any start off a fixed point; both collectors stop at
   automatic yields; unbundled JSON output is large, so bundle.
6. Measure against M2 and bank the margin: keep [55, 37] at T = 60.

### W7. Upstream (non-blocking)

Ask for a v0.21.1 carrying c1280ed4's collector, precedence and host-send
no-op hunks (without the length-width break) and the 22b4431 CLI
boundary-capture fix, so every exclusion above has a removal path; corpus
vectors at both seams with later
inputs; a collector assert (or full reset) for a pristine uarch; and
reconciliation of the cmio length width between `feature/prt` and PR #390.
Track PR #390 as its own coordinated upgrade (every state hash and the proof
format change).

### W8. Hygiene

- More than 2^24 inputs (D5): replace the `Ruler::new_at` assert path with a
  clear, non-looping error, and document it in dimensioning.md.
- A terminal final state panics at roll; replace it with an explicit
  dead-app state that keeps serving disputes.
- Doc drift: the `MachineStf` module doc versus D7, the level-0 location
  in computation-hash.md, the future tense in the `RulerFactory` doc, and the
  closed bond-recovery item in collect-hashes-migration.md.

## Open decisions

- The per-input compute contract at stride 37 (after M1 and M3).
- Which root-slowdown definition governs stride 37, and whether a figure
  above 2 raises the root-slowdown budget (keeping two levels). A third
  level falls outside the goal and goes back to Gabriel.
- What rides the new deployment generation (events ABI, a test-shape
  provider, the unmerged safety-gate branch), and its timing against the
  external contracts audit.
- When a tagged emulator release carries c1280ed4 and 22b4431: move the
  reference CLI and drop the corresponding exclusions.

## Leads to verify

- The v0.21.0 CLI's equality with Dave's root claim at period 17 and with
  the leaf commitment per period comes from reading code. Dave has compared
  only the 17 mcycle corpus cases at period 19; W2.7 and W2.11 verify it.
- The e2e mis-steering and the height-37 memory figure also come from
  reading code, not from runs.
- The seam-2 exploit is protocol reasoning, not a tournament test.
- A v0.21 Lua harness run reportedly agrees with [55, 37], but it is not
  recorded in the repository; M1 must not rely on it.
