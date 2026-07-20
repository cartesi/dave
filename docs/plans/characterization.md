# Characterization plan (pre-rewrite)

Status: draft v3, 2026-07-02. Working document, not knowledge base; expect
this file to change and eventually be archived when the work completes.
Companion: `sling-design.md` (the target design; its testing-implications
section drives the tiering below).

## Goal, and the two axes

Pin the prototype node's behavior well enough that the sling rewrite can
proceed bit-by-bit with trustworthy confirmation at every step. Two
different properties are involved, and only one of them gives rewrite
confidence:

- Soundness: does the node compute the right things (commitments,
  proofs, settlements)? This is what must be pinned before rewriting.
  The discipline lives at three tiers, innermost first:
  1. Rust spec tests: the sling core's tree/cache algebra exercised
     against a toy deterministic state-transition function with tiny
     (a, b, c) - fast, exhaustive, no emulator. Requires the design to
     keep the leaf source behind a narrow trait (see sling-design.md).
  2. Golden fixtures against the real emulator (Track A), including
     the new cm_collect_* primitives, which now carry consensus-
     relevant bundle/fixed-point semantics.
  3. E2e with a hardened independent oracle (Track 0), plus old-vs-new
     differential runs during the rewrite (the prototype's leafs table
     maps directly onto the sling triple cache, so the differential is
     a table comparison).
  The e2e tier is the outer net, not the primary soundness instrument.
  Proven necessary on 2026-07-02: increment C's engine and its toy
  oracle shared a wrong assumption about idle uarch spans (see
  sling-design.md, convention correction), invisible to tiers 1-2
  because the differentials and fixtures only covered active and
  coarse spans; the first e2e dispute lost on-chain and exposed it.
  Lesson: tier-2 coverage must include every transition-shape regime
  (active, idle-padding, boundary) at every stride class, because
  tier 1 can only check the conventions it was told about.
- Robustness: does the node survive operation (crashes, restarts,
  provider flakiness)? Extremely important as a property of sling, but
  it does not certify that a rewrite computes correctly. Tools:
  kill/restart scenarios (Track B). These are acceptance criteria for
  sling more than characterization of the prototype.

Non-goals: designing the sling architecture (its design doc is separate
and feeds the "rewrite discipline" below); fixing prototype debts that
tests do not force; RPC-level fault injection (later).

## Track 0 - oracle trust audit and hardening (do this first)

The e2e suite looks independent but partially trusts node output.
Findings from the initial audit (2026-07-02):

- `Env.epoch_settlement` recomputes the epoch commitment in Lua, but it
  starts from the node's own epoch snapshot (`Dave:machine_path`, read
  out of the node's database). For epoch N > 0 the oracle therefore
  verifies leaf construction given node state, not the state itself:
  an error in a previous epoch would be inherited, not caught.
- The one intended chain anchor for that snapshot - comparing it to the
  `EpochSealed` event's `initialMachineStateHash` - was a vacuous
  Lua assert (`assert(a, b)` does not compare). Fixed on this branch,
  and CONFIRMED on a real run (2026-07-02, echo/simple e2e, full
  dispute, honest claim won): the anchor holds with the comparison
  actually executing.
- Sybils are patched clones of the honest Lua builder, so a conceptual
  bug shared by the Rust and Lua builders is invisible except where a
  dispute reaches the on-chain state transition, which happens only at
  the patch positions the tests choose.

Hardening items:

- Self-anchored oracle: DONE (2026-07-02). The Lua oracle carries its
  own machine lineage from the template, replaying only chain inputs;
  the chain anchor is verified every epoch; node snapshot, inputs, and
  commitment are cross-checked subjects; sybils build from oracle
  snapshots.
- Trust-base catalog: DONE (2026-07-02), recorded in
  `docs/test-harness.md` ("Trust bases of the assertions").
- Patch-position coverage: choose sybil patch positions deliberately so
  STF verification hits all three transition shapes plus revert (today
  the choice is per-scenario and undocumented). DONE 2026-07-02 for the
  shapes: the audit confirmed the fear - stf_all's extra patches were
  unaligned and dead, so every epoch verified the same closing-slot
  shape in window 0, which is exactly where both increment-C bugs hid.
  stf_all now drives one shape per epoch via patch chains (idle
  closing slot, active ustep, idle churn ustep, window-1 fused feed);
  mechanics and matrix in docs/test-harness.md. The full revert
  restore followed on 2026-07-03 (stf_revert on the yield program):
  the oracle reports each input's processing length and the chain is
  computed at runtime, closing the last transition shape. All STF
  branches are now e2e-pinned.

## Track A - golden fixtures for the commitment math

Pin the exact outputs of the current implementation on small, fixed
workloads. Machine images come from `test/programs` (echo, yield); the
fixtures record the template machine hash, so an emulator bump
invalidates them loudly, and regeneration becomes a conscious,
reviewable act. The emulator is fast; full trees at all three levels
are expected to be runnable in reasonable test time (sanity-measure
level 2 once, but no fallback plan is needed).

Fixture inventory:

- F1: level-0 leaf runs (hash, repetitions) per input, echo machine,
  a scripted input set that includes at least one rejected input.
- F2: full level-1 and level-2 trees at hand-picked base cycles: an
  input boundary window, a ureset boundary, a mid-big-step stretch, a
  yield/padding span, and a rejected-input (revert) window.
- F3: proof blobs from `MachineInstance::get_logs` at each of the three
  transition shapes plus the revert variant: store the keccak of the
  blob and the expected next-state hash.
- F4: the root commitment and implicit hash for the whole epoch
  (must equal what the Lua oracle computes for the same inputs).
- F5: the template machine hash (the tripwire explaining F1-F4
  invalidation on emulator bumps).

Mechanism: a `#[test]` comparator in `cartesi-rollups/node/tests/`
reading JSON fixtures from a `fixtures/` dir next to it; regeneration
via `UPDATE_FIXTURES=1`. Tests skip with a clear message when the
machine image is absent (built by `just setup-local`). CI: the existing
`build` job already has images.

## Track B - crash/restart scenarios (robustness axis)

Not pure characterization: the prototype has never been tested under
kill/restart, so scenarios will likely surface real bugs. Policy: write
the failure down as a minimal repro, fix now if cheap, otherwise record
it in `docs/node-architecture.md` and mark the scenario expected-fail
with a pointer. Expected-fail scenarios become hard acceptance criteria
for sling.

Plumbing first (small): DONE 2026-07-02.

- `Dave:kill(signal)` and `Dave:respawn()` in
  `prt/tests/rollups/dave/node.lua`; `Dave:new` split so respawn keeps
  `_state/` and appends to one monotonic `dave.log`.
- `Dave:wait_log(pattern, offset)`: block until the log matches past
  an offset; kill points are log lines, not sleeps. Relied-on patterns
  are the stable-marker contract, listed in docs/test-harness.md.

Scenarios, in order of value per effort:

- B1 chaos loop: an existing dispute scenario, but SIGKILL the node
  every T seconds (randomized, seed logged) and respawn throughout.
  Assert the honest commitment still wins and settles. DONE
  2026-07-02 (test_cases/chaos.lua, `just test-rollups-chaos`): five
  consecutive green runs, seeds 1-5, 6-8 kills per dispute, honest
  claim settled every time. No prototype bugs surfaced - the sling
  quartet cache resumed disputes across every kill. Wired into CI
  with a fixed seed (sequencing item 5).
- B2 catch-up kill: kill during initial input processing; assert resume
  produces identical settlement info (cross-check F1/F4).
- B3 commitment-build kill: trigger on the commitment-build log line
  during a dispute; assert the dispute still ends in a win.
- B4 mid-match kill: trigger after join/advance; the sybil keeps
  playing while the node is down; assert win and bounded clock loss.
- B5 settle kill: kill between `canSettle` and the settle transaction;
  assert exactly-once settlement semantics after restart.

B2-B5 implemented 2026-07-02 (test_cases/kill_*.lua, log-triggered via
the stable markers in docs/test-harness.md; `just
rollups-tests::test-kill-all`). All four green on first single runs,
and the qualification sweep's second round delivered the track's first
real catch: the machine-runner commits an input's state hashes before
the snapshot store that marks the input processed (an ordering race;
the store being fast narrows the window but cannot close it), so a
SIGKILL between the two makes the resumed run reprocess the input and
die on the UNIQUE constraint - fatal on every subsequent boot. Fixed with the
verify-on-conflict pattern (identical rows are a legitimate resume,
disagreeing rows stay loud) plus a per-input transaction so partial
inserts cannot exist either. One harness lesson: a blocking log-wait
outside the sybil drive loop must mine its own blocks, or chain time
freezes and the marker never appears (kill_settle). Qualified
2026-07-03: five consecutive green test-kill-all rounds (twenty
scenario runs) after the state-hash fix landed.

Always SIGKILL, never SIGTERM: WAL recovery and half-written state are
the subject. A scenario must pass five consecutive local runs before
entering a suite; CI gets B1 with a modest interval, the rest stay in
the manual suites.

## Track C - harness seam hardening

- `dave/node.lua` stays the only place that touches node internals
  (SQLite schemas, log lines); add a header comment declaring that
  contract. Restart support lives behind the same interface.
- Keep all queries read-only.
- When the sling schema unification lands, this file plus the fixtures
  are the complete migration surface for the harness.

## Rewrite discipline (gates for every sling increment)

To be refined against the sling design doc once it exists, but the
gates are design-independent:

1. Fixtures green (Track A) - unchanged fixtures, not regenerated ones,
   unless the increment explicitly changes commitment semantics (which
   should not happen; that would be a protocol change, not a rewrite).
2. E2e suites green, including Track 0's hardened oracle.
3. Differential run: old node and new node on the same scenario must
   produce the same on-chain behavior and the same settlement info.
   Where schemas still coincide, identical DB contents; after the
   schema unification, on-chain equivalence is the bar.
4. Schema changes land in the same commit as the `dave/node.lua` seam
   update (and fixture regeneration if storage encoding moved).
5. Increments are individually revertable; no opportunistic refactors
   outside the increment's stated scope.
6. Docs stay true: an increment that moves an invariant updates the
   knowledge base in the same change.

## Sequencing

1. Track 0: confirm the fixed chain anchor on a real run; build the
   self-anchored oracle; write the trust-base catalog.
2. Track A: generator + F1/F4/F5, then F2/F3. Add primitive-level
   goldens for cm_collect_* once those land in the machine bindings.
3. Track C plumbing, then B1 chaos loop (parallelizable with A).
4. B2-B5 targeted scenarios.
5. CI wiring: fixtures into the build job, B1 into the e2e job. DONE
   2026-07-02: the build job already runs the fixtures (setup-local
   builds the images, test-rust-workspace includes sling_machine);
   the prt-honeypot job gained an echo build and a chaos step with a
   fixed seed (CI is the regression net; seed exploration stays
   local). Deferred: pointing CI rust builds at the installed
   emulator via LIBCARTESI_PATH - a build-time optimization that
   needs a CI run to validate the /usr/local/lib layout, not worth
   guessing at.

The tier-1 spec tests are not characterization of the prototype - they
are born with the sling core (increment A in sling-design.md's rewrite
topology) and gate every increment from day one; the prototype has no
seam to host them, which is itself the argument for the leaf-source
trait. Relative ordering against the rewrite: fixtures (Track A) and
the self-anchored oracle (Track 0) must exist before the first organ
swap (increment C); the harness plumbing and chaos loop gate nothing
before that and can land whenever convenient.

Done means: the oracle is self-anchored and its trust bases documented;
fixtures pin levels 0/1/2 plus proofs; B1-B5 green or catalogued as
expected-fail with filed debts; existing suites green; the harness
touches node internals only through `dave/node.lua`. Then the rewrite
begins, gated by the discipline above.
