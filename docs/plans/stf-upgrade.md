# STF upgrade: emulator v0.21, solidity-step, and two levels

Status: DRAFT (2026-07-21) - Gabriel's outline plus the accumulated
ledger, for his review. Decision points are marked. The standing
instruction applies: question and re-evaluate everything here as it
is reached.

## Goal

Upgrade the state-transition stack end to end - emulator
v0.21.0-test6, machine-solidity-step to latest, our
CartesiStateTransition rewritten on top of it - and ride the
result to a two-level tournament. The solidity-step update is
expected to considerably simplify CartesiStateTransition and fix
the flagged state-transition semantics issues (the halt/exception
protocol gap of docs/dimensioning.md). The emulator update brings
new hash collection APIs, and cartesi-machine.lua itself gains a
command that computes a whole epoch's computation hash (built on
the new API internally - reference material for our own usage,
and a cross-check oracle). A FUTURE emulator tag (not test6) will
ship a manifest of computations with their expected hashes - a
vendored conformance fixture to adopt into the verification net
the moment it exists.

## Verification doctrine for the whole campaign

- The contracts (solidity-step) remain the ONLY semantics truth.
  The emulator's Lua collection script is a cross-check oracle,
  never a source: two implementations agreeing means little if
  they share an assumption (the exception-revert lesson).
- Hash-match gates, in Gabriel's sequencing: (1) bump the emulator,
  keep the old collection path, verify our hashes match the Lua
  script's on the same machine; (2) switch to the new collection
  APIs; (3) re-verify the match. Every switch is
  characterization-first.
- Fixture regeneration is a mass event this time (template hashes
  change with the machine images): regenerate ONLY after the
  corresponding differential passes, one tier at a time, each a
  reviewed act. The template-hash tripwire firing is the signal,
  not an obstacle.

## Phases (proposal)

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
     come back (the one-engine amendment bet the runner's
     window-root fold could someday move into the emulator).
   - the cartesi-machine.lua epoch-hash command's SCOPE: does it
     model our conventions (feeds, checkpoints, revert, padding)
     or only raw span collection? Its value as an oracle depends
     on this; its internals are the reference for our own use of
     the new API either way.
   - where the span constants become authoritative: uarch-to-big,
     big-to-input, input-to-epoch are today a replicated
     agreement across components, guarded by parse-the-source
     drift tests (node-audit findings 4 and 9). The emulator and
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
   v0.21.0-test6, machine images rebuilt, devnet and store pins
   updated (stores wipe: config pins the emulator version).
   Gate: our engine's hashes (old API) match the Lua script's on
   identical machines and spans, across the transition-shape
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

3. New collection APIs (old increment F, deliberately last then,
   ripe now). Swap the engine's machine stf onto cm_collect_*;
   the spec oracle and differentials re-gate; re-verify the Lua
   script match; measure (collection was the dispute-time cost
   the resource model priced).

4. Two levels. Re-run the constants pipeline ON v0.21 and on
   validator hardware (the WS8 numbers - log2step [37,0], heights
   [55,37] at a 60-min inner timeout - were measured on 0.20 and
   are stale the moment the machine changes); walk the adoption
   gates of docs/plans/constants.md. Level-0 stride moving 44 ->
   37 moves the window-root quartet coordinate, the frontier
   fold's geometry, the drift-guard pins, and every recording and
   fold fixture (the echo fixture asserts THREE tournament
   levels). Clocks and spans re-derive under the dimensioning
   rule: coordinates worst-case, clocks average-case.

## Also in scope (from the standing ledger)

- Audit round 2 items that open naturally: the settlement revert
  taxonomy (node-audit finding 3; the revert surface changes
  again in phase 2 - decode selectors at the sender, escalate
  non-race classes through the loudness path); gc timeLeft vs
  allowance (finding 8; the tournament module opens in phase 4);
  the reader's overlay assembly vs a mock provider; capacity
  boundary scenarios (last input slot, last stride - owed since
  workstream 2).
- Test-shape constants profile (fast e2e disputes): contracts
  side, same territory as phase 4, the deepest e2e-latency lever
  on record. Candidate to land with the two-level change.
- Measurement methodology hardening (measure.lua STAYS - Gabriel,
  2026-07-21). Coworker review brought three upgrades:
  - Multi-workload benchmarking to kill single-workload bias (our
    stress image is one sha256 burn; the density figure behind
    the constants rests on it). stress-ng ships in the standard
    rootfs; the studied set: nop, crypt, heapsort, tsearch,
    memthrash (dirty pages), matrix-3d (fp + page traffic), tree,
    tlb-shootdown, malloc, randlist (heaviest; tlb + dirty
    pages). `cartesi-machine -- stress-ng --nop 1 --timeout 1m`.
  - VERIFY the boot-skip: the flag is that our measurement may
    not skip the first machine mcycles and thus measures Linux
    boot, not workload. If true it taints the recorded density
    (616 usteps/big) and everything derived from it - check
    before re-deriving constants in phase 4, and sample from
    first yield onward.
  - The sparse-hash step-size study (which log2step tiers pay)
    can ride these workloads - or wait for the final collect API;
    Gabriel's call on timing.
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
- The dev environment moves with the emulator: LIBCARTESI_PATH
  and the cartesi-dev flake need a v0.21 libcartesi; local just
  (1.48) vs CI just (pinned 1.57) is existing skew worth closing
  while the flake is open.
