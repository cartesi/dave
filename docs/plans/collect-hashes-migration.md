# Collect-hashes migration

Status: dense leaves switched to `cm_collect_uarch_cycle_root_hashes` on
2026-10-02 (see the status under the test program). This plan defines the
evidence the switch needed and what remains.

Sequencing and two decisions here are superseded by
[two-level-sling.md](two-level-sling.md) (2026-09-28): the migration now
follows the two-level switch as margin, the leaf-by-leaf collector is kept
permanently as a test-only oracle instead of being deleted (D7), and the
corpus moves into ordinary setup with un-ignored tests (D9). The remaining
evidence requirements below still apply.

## Goal

Use the emulator's bulk collection primitives for commitment construction
without changing the computation hash, rejection semantics, tournament
geometry, or proof bytes. Remove the superseded leaf-by-leaf production
collection path once the new path is qualified.

This is not a tournament-geometry change. Adopt the collect APIs under the
current geometry first; re-dimensioning the tournament remains a separate
decision backed by new measurements.

## Related release acceptance

The intended node follow-up is also expected to close the independent
bond-recovery starvation recorded in
[node-architecture.md](../node-architecture.md#known-debts). Recovery
scheduling is neither an implementation dependency nor semantic evidence for
the collect APIs; keep it in a separate reviewable commit. It is listed here so
the shared release boundary is not declared ready after only the collection
migration passes.

Before that node follow-up is accepted, recovery candidates must still derive
from one coherent finalized view, submission must remain bounded, maintenance
must not delay clock-bearing or settlement work, and older recoverable bonds
must eventually receive service. Keep the multi-sybil harness test's root-balance and
recovery-plan assertions, add the scheduler composition tests specified in the
living node architecture, and rerun the settlement/crash scenarios plus the
full battery.

## Authority and oracle roles

The tests are valuable only if each comparison has a named role. Counting
frontends over the same implementation as independent oracles creates false
confidence.

| Component | Role |
| --- | --- |
| Solidity `CartesiStateTransition` and `machine/step` | Authority for one canonical disputed transition, including the rejected-input reset substitution |
| Emulator collect APIs | Candidate production primitive and subject of the migration |
| `cartesi-machine` computation-hash mode | Release frontend over the collect APIs; useful conformance surface, not an implementation independent of those APIs |
| Released computation-hash corpus | Immutable release answers and a fixed transition-shape matrix; it fixes templates, inputs, and geometry |
| Dave's current `Ruler` collection path | Legacy production subject before the switch and a temporary migration differential afterward; not a permanent oracle |
| Test-only prototype commitment builder | Independently structured variable-geometry differential while it continues to express the same semantics clearly |
| Lua client and proof generator | Cross-implementation commitment and witness evidence required by the dispute harness |

The current corpus gate is intentionally two tests. One replays all released
mcycle and uarch cases through the release CLI. The other compares Dave only
with the released mcycle answers it supports. A failure therefore says whether
the installed release frontend disagrees with its artifact or Dave disagrees
with the released semantics.

## Blocking semantic seam

Resolve the exact `RX_REJECTED` plus `imcyclemax` boundary before routing
production uarch collection through the new API.

At that boundary, the canonical transition is the pre-input revert root. The
mcycle computation-hash path, Lua client, and Solidity reset semantics apply
that substitution. The v0.21 uarch bulk collector can instead retain the
physical mcycle-overflow root because its overflow handling suppresses the
rejected-state substitution.

The boundary has an accepted twin: in the step, an RX_ACCEPTED yield on the
budget's last cycle still takes the next input. Dave's clients follow the step
at both boundaries; the v0.21 CLI's epoch driver instead ends the epoch at
either one whenever later inputs exist. Unreleased upstream commit c1280ed4
fixes both in the emulator (see two-level-sling.md for the exclusions).

The migration needs one explicit resolution, preferably in the emulator:

1. Specify the result at simultaneous rejection and mcycle overflow.
2. Add an upstream collect-hashes vector at the exact boundary.
3. Make local and remote collection agree.
4. Carry the vector in Dave's release conformance and Solidity/Lua parity
   evidence.

Do not hide the difference in Dave's Merkle assembly. If an interim Rust
normalization is unavoidable, name it as compatibility policy, test it against
the canonical transition, and give it a removal condition tied to the fixed
emulator release.

## Test program

### Fixed release conformance

- Replay the complete published manifest through the exact release CLI,
  including nonzero exits, diagnostics, terminal cycles, hash-file presence,
  mcycle cases, and uarch cases.
- Compare Dave's supported mcycle computation hashes directly with the
  published answers.
- Keep acquisition explicit and digest-pinned. The corpus remains outside
  ordinary setup and generic Cargo tests, but is required in CI.

### Variable geometry and inputs

The corpus deliberately fixes its cases. Retain a separate deterministic test
driver that can choose:

- sample periods at zero, one, and both sides of relevant boundaries;
- input counts zero, one, several, and the final legal input;
- accepted, rejected, terminal, and padded windows;
- spans beginning at the epoch root and inside later input windows; and
- local and remote machines where both APIs support the operation.

During migration, run the same generated cases through the new collector, the
legacy collector, and the test-only prototype. The legacy path is a temporary
differential, not a fourth long-term authority. Use recorded seeds and shrink
failing cases to a checked-in boundary vector.

### Bundle and chunk metamorphics

For every valid collection shape, assert properties that do not need a second
semantic implementation:

- Every permitted bundle size produces the same final Merkle root as
  unbundled leaves.
- Reducing each unbundled group manually produces the API's bundled root.
- One collection call and multiple calls split at arbitrary mcycle boundaries
  produce the same ordered hashes, partial-bundle continuation, break reason,
  and final machine state.
- Chunk boundaries immediately before, on, and after a sample point are
  equivalent.
- Uarch `mcycle_hash_offsets` partition the same leaves under one-shot and
  chunked collection.
- Fixed-point padding is independent of chunk and bundle choices.
- Local and remote collection return identical hashes and metadata.

Exercise empty output, a single full bundle, a partial final bundle, more than
one bundle, a terminal fixed point, rejection, and the maximum-cycle tails.

### Integration evidence

- Keep the real echo/yield engine-machine gate fail-loud and explicit.
- Keep proof-byte parity with the prototype and the on-chain STF vectors.
- Run the rejected-input `stf_revert` dispute in CI.
- Re-run snapshot-resume equality so collection from a durable boundary and
  replay from the template produce identical material.
- Measure commitment construction and dispute-time subtree collection on echo
  and instruction-heavy workloads. Record memory as well as elapsed time.

### Status (2026-10-02): switched for dense leaves

The node's dense leaf builds, the one path that hashed per step at scale,
take the active big cycles' roots from `cm_collect_uarch_cycle_root_hashes`
bundled at 2^20. Idle stretches (one captured span), positioning and
sampled strides (`cm_run` between samples), sub-big-cycle strides and
proving keep their paths. The mcycle collector is wrapped but unused: the
node's sampled strides already run the big machine between samples.

Evidence, in `cartesi-rollups/node` unless named otherwise:

- Wrapper (`machine/rust-bindings`): typed results keep hashes, offsets,
  partial bundles, break reasons and console errors, and refuse offsets that
  do not partition the hashes. On the yield image, unbundled uarch periods
  equal hand-stepped ones, mcycle samples equal sampled runs, calls split off
  the sampling grid continue with phase and partial bundle (unbundled and
  bundled), a rejection reports the revert root and then the tail, a missing
  or wrong tail is refused before anything executes, and a collection ending
  at the current mcycle is empty.
- Bundles: `uarch_bundles_reduce_to_the_unbundled_leaves` reduces every
  period at every bundle size from 2^1 to 2^20 to the root of its unbundled
  leaves, over an input's opening, an automatic yield, and a rejection with
  its tail period.
- Ruler integration: the toy's bulk collector drives
  `collect_big_cycle_roots` through one-cycle calls, chunks with declines and
  unbounded calls, against the transition-level oracle on every aligned span.
- The reference (D7): the leaf goldens and every dense corpus leaf are built
  with the bulk collector and the stepped path alike, and
  `bulk_and_stepped_leaf_runs_agree` compares them per big cycle.
- The seam: bulk collection declines the input budget's last cycle and the
  ruler steps it, a named compatibility policy in Rust, as the section above
  allows. The seam witness vectors pin the stepped answer against the step,
  and `bulk_collection_leaves_the_budgets_last_cycle_to_stepping` pins the
  v0.21.0 collector's physical root there: when it fails, the guard goes.
- Unchanged on the bulk path: the runner goldens, witness and proof vectors,
  snapshot resume and half-built-level restart, and the anvil harness's
  disputes. The node uses local machines only, so remote parity does not
  apply.
- Performance: `just measure-node-vs-emulator` times a cold join and a deep
  proof against the emulator doing the same work.

Left: the upstream fix for the seam (W7), which retires the guard. The
stepped dense path stays selectable (`DisputeSource::on_store_with`) as the
reference, never as a runtime fallback; the ruler's stepping core still
serves idle spans, sub-big-cycle strides and the seam's cycle.

## Implementation sequence

1. Expose narrow safe Rust result types for both collect calls. Preserve
   hashes, offsets, partial bundles, break reasons, and error context; do not
   turn the API into a root-only black box.
2. Add direct wrapper tests for ownership, empty vectors, malformed metadata,
   local/remote parity, and chunk continuation.
3. Close the rejection/overflow seam and pin its cross-implementation vector.
4. Implement a collect-backed path behind a test-only selection point. Do not
   add an operator-facing runtime switch.
5. Run fixed corpus, variable differentials, bundle/chunk metamorphics, proof
   parity, snapshot resume, E2E, and measurements.
6. Switch the single production construction path once the evidence passes.
7. Delete the legacy bulk leaf-by-leaf collector and the test selection point.
   Retain positioning and proof code only where it still has a distinct job.
8. Remove migration-only three-way differentials that merely compare the
   deleted implementation. Keep the corpus conformance, metamorphic tests,
   prototype cases that remain genuinely independent, and contract/Lua proof
   evidence.

## Exit criteria

The migration is complete only when:

- the rejection/overflow result is specified and tested across emulator,
  Rust, Lua, and Solidity where applicable;
- all fixed and generated differentials pass for local and remote collection;
- bundle and chunk choices are root-invariant;
- current proof bytes and snapshot-resume behavior are unchanged;
- performance is no worse on the retained workload set, or an explicit
  reviewed tradeoff is recorded; and
- no legacy production collection loop or runtime fallback remains.

Keeping the old path indefinitely would add maintenance and another apparent
oracle while making the chosen production semantics ambiguous. Its useful life
ends when it has qualified the replacement.
