# One engine: the sling type redraw (analysis, 2026-07-14)

Status: COMPLETED AND FROZEN - all five section-9 steps LANDED by
2026-07-20 (the src/sling -> src/engine rename was the last); per-step
notes live inline in section 9. Kept in place as the campaign's
reasoning of record: code comments and living docs cite its sections.
Living successor: docs/node-architecture.md. Originally DECIDED by
Gabriel, 2026-07-14.

Gabriel asked
why Ruler/Stf/Structure/Leaf/Run relate the way they do, whether the
Checkpointer and SeedTree are exceptions to machinery that should be
shared, whether get_or_compute should be a method, and whether the
architecture deserves a redraw. This document answers the why first
(from the code and the recorded design history), gives a verdict per
smell, and draws the target. Facts below cite the dependency sweep
run for this analysis and the plan docs; the smells were Gabriel's,
the tracing is this session's.

## 0. Session split

Split along battery boundaries and reviewer-sized diffs; steps that
touch the same files share a session, consensus-critical work gets a
session with nothing else moving:

- Session A (landed): steps 1 + 2 - the facade merge and the
  input provider. Both are semantics-free and touch the same files
  (dispute/cache/machine_stf/ruler/hero); doing them together avoids
  re-touching. One battery at the end.
- Session B (landed): step 3, the frontier persist. Durable-state
  semantics change (the open regime starts writing window-root
  quartet rows), so it moved alone: advance/roll/hero/source, the
  SeedTree retirement, and a measure pass on the seed-fold table.
  Details in the step-3 entry of section 9.
- Session C (landed, same session as B, 2026-07-15): step 4, one
  engine, as amended in section 6. Characterization differential
  FIRST, then the runner schedules collect(), then the second
  implementation and the runs table deleted. Nothing else moved.
  Details in the step-4 entry of section 9.
- Final session: step 5, layout and naming - common-rs fold-in, the
  sling module rename, doc sweeps. Mechanical and churny, so last,
  where the renames cannot pollute substantive diffs.

Step-1 refinements found while planning (recorded before building):
the facade absorbs the PROVER factory too - the Hero's two factories
exist only because tree queries and proof positioning were separate
types; one facade with machine_at() serves both, halving the
store handles and work dirs and deleting the prover concept. The
cache free functions stay as pub(crate) engine primitives (the spec
tests target the cache layer deliberately, with seeds absent); the
facade is the production surface over them. And the per-feed payload
clone in ruler.rs is unnecessary already (disjoint field borrows) -
it dies in step 2 regardless.

## 1. Why the shapes exist

The Stf trait, the toy, and the parameterized Structure are design
decision 1 of sling-design.md - Gabriel's own refinement ("the toy's
state at meta-cycle N is simply N... expected trees become computable
by hand"). They exist because the leaf conventions are the most
arcane, consensus-critical logic in the node, and the only way to
test them exhaustively is a brute-force oracle - which requires
rulers small enough to enumerate (S_SMALL is 128 positions;
production is 2^92). Load carried today: 15 spec tests (the
executable leaf-convention specification, oracle-checked across six
script shapes and three structures), 13 Hero decision-table tests
(chain-free, riding ToyFactory), and the simplification survey's
verdict that the toy "priced three campaigns' worth of differential
oracles". Leaf is a private laziness detail (hash only when a sample
lands); Run is the compressed output the padding geometry demands.

VERDICT: the seam is sound and load-bearing; do not unwind it. The
smell is real but it is not the seam - it is what leaked around it,
below.

## 2. The root smell: two engines for one leaf semantics

Everything Gabriel pointed at traces to one fact: the machine-runner
does not run on the sling engine. RollupsMachine::process_input is a
second, hand-written implementation of the meta-cycle geometry - the
sweep's side-by-side finds seven duplicated responsibilities
(checkpoint slot write, cmio feed, run loop, yield handling, revert
handling, leaf collection, padding), with padding additionally
re-implemented in two more places (epoch_state_hashes' tail padding
and build_commitment_from_hashes). The leaf sequence is
consensus-critical: an honest node that computes it two ways carries
a forever obligation that the two ways agree, checked today only by
the e2e oracle.

Each named smell is a scar of this split:

- The Checkpointer enum exists because the two regimes implement the
  SAME protocol concept (revert to the pre-input boundary) at
  different layers with different mechanics: regime 1 discards a
  poisoned clone at the storage layer; regime 2 reloads a checkpoint
  at the machine layer. One revert, two machineries.
- Run vs CommitmentLeaf are the two engines' output types. (The
  field difference has a domain excuse - U256 repetitions because
  stride-0 runs can exceed u64, u64 suffices for level-0's 2^48 cap
  - but they are one concept, reconciled only inside
  MerkleBuilder::append_repeated.)
- The SeedTree is the adapter that carries regime 1's output into
  regime 2's world, needed only because the regimes do not share a
  representation.

## 3. The redraw: one engine, two schedules

Target: the machine-runner becomes a SCHEDULER of the same engine
the dispute uses. Per input, it runs one window-sized
`collect(window_end, 44)` on the working clone through Ruler +
MachineStf, emits the window's runs as rows, and commits the
boundary between windows exactly as the chain of clones does today.
The dispute path keeps its random-access schedule (position, then
collect a span). What changes is not behavior but authorship: the
leaf semantics are defined once, in the module whose conventions are
spec-oracled, and regime 1 stops owning a private copy.

Dissolves: RollupsMachine::process_input and its run loop (the
outputs proof and the accepted/rejected reason remain as small verbs
- they are storage/settlement concerns, not geometry);
CommitmentLeaf as a separate concept (Run becomes THE run type, with
checked narrowing at the storage row boundary); the Checkpointer
enum (both regimes' revert insurance becomes the boundary store's
verbs - regime 1 already re-clones, regime 2's feed already commits
the boundary; unify on clone-based restore); the third and fourth
padding implementations.

The layering, as Gabriel restated it in verbs (2026-07-14, corrected
the same day: the layers diverge at the consumers, and positioning
belongs inside the engine - the acceptance test for step 4's shape):

- L0 the machine: load/store/clone/run (the bindings).
- L1 the boundary store: checkout/commit/nearest (snapshots.md) -
  and, beneath everything, the durable substrate both regimes share
  (inputs, leaf runs, quartet rows; the write-once collision
  tripwire lives here).
- L2 the engine: Stf (one machine's verbs; feed carries the payload
  lookup and the checkpoint - the Feeder made the engine
  storage-aware, which is why positioning folds in rather than
  sitting above) + Ruler (geometry: advance, collect,
  prove_transition) + positioning (machine_at = nearest + advance +
  write-back). The factory trait remains only as the test seam: the
  toy implements positioned-ruler construction storage-free.
- L3 the consumers, where the regimes diverge. The runner: forward
  schedule, one window at a time, persisting as final, plus the
  epoch lifecycle. The hero: the query facade (seeds/window-roots
  tier, quartet cache, proof descents - tournament vocabulary the
  runner never speaks) plus the react loop, on demand, wherever the
  opponent points.

One opportunistic reuse to consider in steps 3-4: at roll, the
settlement root over a complete epoch is exactly node(level-0 root)
over the persisted window roots - taking it through the facade
would delete build_commitment_from_hashes' separate fold. A verb
borrowed across the divergence, not a shared layer.

Two invariants this framing surfaces, to hold step 4 to:

- The root claim is served from persisted material, machine
  execution only below persisted coverage. "Same machinery" is true
  in the strong sense: the hero reuses the runner's work product,
  not just its code.
- A machine collect never crosses a fed input boundary. Dispute
  levels tile inside one level-0 stride (inside one window); the
  runner's schedule is per-window by construction; the only
  cross-window collects are inputless-epoch level-0 spans, which
  are idle arithmetic with no feeds. Boundary crossing belongs to
  positioning (advance) and idle replay only - which should let the
  collect side of coarse_step_until shed its mid-collect feeding
  support in step 4.

Outside the shared machinery, deliberately: the epoch lifecycle
(roll, settlement derivation, outputs proof, accepted/rejected
recording) is the runner's own, and the react/tournament layer is
the hero's own. Neither is geometry.

Risks and their nets: this is a consensus-critical migration, and it
has the strongest verification net in the codebase - the spec oracle
(conventions), the prototype differential (real machine), the Lua
oracle (every epoch of every e2e), the golden fixtures, and the
battery. Characterization first, per the recon doctrine: pin
process_input's exact outputs as fixtures before touching it. Perf
parity must be measured (the engine's coarse mode runs the same
BIG_STEPS-granularity machine loop; expectation is parity), and the
scheduler must preserve the batch/crash discipline (restart-is-tick,
one transaction per batch) - which lives in storage and does not
move.

## 4. The facade: get_or_compute becomes a method

Gabriel's instinct, confirmed by the sweep: Hero is the only
production caller of DisputeSource; get_or_compute is called
directly only by spec tests and the measure binary;
DisputeSource::structure() has zero callers and factory() one test
caller. The pieces - DisputeSource (orchestration), cache.rs (two
free functions), MachineFactory (positioning), SeedTree (level-0) -
are one concept sliced four ways: "the epoch's computation,
queryable at any coordinate".

Target: one type (naming is Gabriel's; the concept is "the epoch
computation") with the tree verbs (node, children, prove_leaf,
prove_last) and the machine verb Gabriel asked for: machine_at
(position) - today's factory ruler_at, which is also exactly what
entering a nested tournament needs to start producing the nested
computation hash. The cache free functions become private methods;
measure and the spec construct the facade. The seed tree becomes an
invisible serving tier (section 6), not a public type. Dead surface
(structure(), the factory getter) dies.

## 5. Inputs: a provider, not a payload vector

Holding `Vec<Vec<u8>>` in the factory and the Ruler is the wrong
altitude twice over. The sweep counts three clone layers: one
whole-epoch clone per Hero construction (source + prover factories),
one whole-epoch clone PER RULER_AT - every quartet miss and every
prover positioning re-copies every payload of the epoch (a new
finding; at big-input scale this is real memory traffic on the
dispute hot path) - and one per-feed payload clone. Meanwhile the
machine-runner already does it right: one payload at a time from the
inputs table.

The geometry engine does not need payloads; it needs to know WHICH
windows feed (the contiguous-prefix count) - a number. Payloads are
consumed only by feed, and the toy already models this correctly:
ToyStf owns its script and ignores the payload argument. Target: an
input provider owned by the Stf side (count + payload(k),
storage-backed for the real machine, the script for the toy), Ruler
keeps only the fed-window count. Kills all three clone layers and
the resource-model's flagged duplication.

## 6. Seeds: finish increment E (the frontier)

Gabriel's two options are both on record already - the in-memory
SeedTree fold was explicitly labeled "the increment-C stand-in for
the regime-1 frontier handoff; the frontier design (open question 6)
is unchanged as the endgame", and open question 9 sketches the
two-tier lazy seed. The redraw should finish it, in the Q9 shape,
with one pleasing observation: a window's final level-0 subtree root
IS a canonical quartet - (epoch, log2_stride 44, height 24, shift =
window index). Gabriel's "copy the level-0 nodes into sling_nodes"
is therefore not a special export; it is one ordinary cache row per
input, written by the open regime as each window closes (final by
the frontier rule: the window lies entirely left of the input
frontier). This deliberately flips increment E's "the open regime
never writes sling_nodes" - that note itself documents the frontier
rule as the condition under which the flip is sound.

Serving then tiers naturally inside the facade's node(): quartets at
or above window granularity answer from window-root rows plus
padding math; quartets inside one window fold on demand from the
machine_state_hashes runs (a bounded range read); everything else is
the machine, as today. The SeedTree type dissolves. What this buys:
Hero construction stops refolding (O(1) instead of O(runs x 48) per
construction and per restart), roll_epoch's settlement root comes
from the persisted window roots instead of a full refold, and open
question 9's max-tilt corner (minutes of folding, tens of GB
resident) dies structurally. The empty epoch needs no case: no rows,
machine path, iterated initial hash - already spec-pinned.

Alternative if flipping the increment-E decision feels wrong: window
roots in their own small table, cache untouched. Same benefits, one
more table; the quartet-row form is preferred precisely because it
makes level 0 NOT an exception.

AMENDED (Gabriel, 2026-07-15, after step 3 landed): the runs table
dies too. The step-3 shape kept machine_state_hashes as a second
resolution of the same material (leaves in one table, their height-24
fold in another) and grew an adapter layer (the facade's interior
tier) to bridge them. Both go:

- The window-root row is the runner's ONLY level-0 artifact: one
  quartet row per input, folded in memory at collect time. The
  unfolded runs are never persisted (the emulator is a hash machine
  gun, and its next API can hand back folded trees; an unfolded leaf
  stream through SQLite fights that).
- Quartets below window granularity - real or padding windows alike -
  ride the ordinary machine regime (get_or_compute fanout), exactly
  like nested tournaments below their level roots. This leans into
  the design's committed property that replaying one input is cheap,
  and it costs nothing new dimensionally: entering a level-1
  tournament already pays the same window replay. Bonus: dispute-time
  recomputation now collision-checks the runner's fold, closing
  sling-design's old "level 0 is never re-verified" caveat.
- Rows are strict, not self-healing: a missing window-root row below
  the frontier is corruption or version drift and fails loudly
  (compat with pre-flip stores is explicitly not a goal).
- What survives as level-0-specific is irreducible: the frontier
  composition - a dense prefix of window-root rows, then the fixed
  point repeated - for nodes at or above window granularity, whose
  spans cross the frontier and can be served neither by rows alone
  nor by the machine (whole-epoch replay). It folds INSIDE the
  source behind the subtree-returning contract: the module owns the
  storage handle and returns merkle subtrees; whether an answer was
  a row lookup, a frontier fold, or a machine replay is invisible
  provenance. The one if lives there, once.
- Frontier facts come from tables that already carry them: recorded
  window count = the closed epoch's input count (inputs table);
  padding value = the epoch's final boundary hash (snapshot rows).

## 7. The tangent: layout and names

- common-rs: the sweep confirms only the node consumes any of it.
  cartesi-dave-arithmetic is one helper used from two files - fold
  it in. cartesi-dave-merkle is node-pervasive (19 files) and
  node-only - fold it in (if the sling node later extracts to the
  sequencer repo, the merkle code travels inside it, which is the
  correct coupling). cartesi-dave-kms is one integration point;
  fold-in is fine, keeping it a crate is also defensible if it has
  an independent deployment story - Gabriel's call.
- The module named `sling` inside the sling node is redundant.
  Candidate: `engine` for the geometry core (structure, stf, ruler,
  spec), with the facade (today's dispute.rs + cache.rs +
  machine_stf.rs) either beside it or absorbed into it. Naming is
  Gabriel's; the constraint worth keeping is that the spec-oracled
  core stays one visible unit.
- machine/rust-bindings being its own workspace is the separate
  publishing question, already parked.

## 8. Verdicts, one line each

| Smell | Verdict |
|---|---|
| Stf/Toy/Structure injection | Sound, load-bearing; keep |
| Ruler owning payloads | Wrong altitude; provider (sec 5) |
| Leaf | Private laziness detail; fine |
| Run vs CommitmentLeaf | One concept, two types; unify (sec 3) |
| Checkpointer | Scar of the two-engine split; dissolves (sec 3) |
| get_or_compute free fn | Should be the facade's method (sec 4) |
| MachineFactory as separate public type | Absorbed by the facade (sec 4) |
| SeedTree exceptionalism | Finish increment E; dissolves (sec 6) |
| Two leaf engines | THE root smell; one engine (sec 3) |
| common-rs / sling naming | Fold in / rename (sec 7) |

## 9. Sequencing (proposal, each step battery-gated)

1. LANDED (session A). DisputeSource is the one production surface:
   tree verbs plus machine_at (proof positioning and nested entry as
   one verb); the Hero's prover factory deleted; cache free fns
   demoted to pub(crate) engine primitives; measure and the
   differentials ride the facade; structure() gone.
2. LANDED (session A). Stf::feed and log_feed take the window index;
   the Ruler keeps the fed-window count; the Checkpointer grew into
   the Feeder (scratch = explicit vectors for storage-less
   harnesses; store = the inputs table at feed time, the node
   always); the Hero materializes no payloads (input_count); all
   three clone layers dead. The differentials ingest inputs through
   insert_consensus_data - the production data path. Battery 21/0.
3. LANDED (session B). The Q9 two-tier, plus the L2 fold opener
   (MachineFactory dissolved into the engine: DisputeSource::on_store
   assembles the whole working set from storage; the Positioner is
   the residue). The runner folds each record's runs into its
   window-root quartet row inside the batch transaction; the facade
   serves stride >= 44 from a lazy top tree over those rows plus
   per-window interior folds (bounded range reads, memoized);
   SeedTree retired; settlement composes from the same rows.
   Refinements found while building: a missing window-root row
   self-heals (fold runs, insert) so pre-existing stores need no
   migration and the runner's write is a prepayment, not a
   correctness dependency; the padding value comes from the recorded
   material (last run's hash) rather than the machine, and the roll
   asserts the machine's boundary hash agrees - "the last leaf run
   equals the boundary state" went from unchecked convention to
   checked-at-every-roll, closing the one path where settlement
   could diverge from the servable root. The tiling of runs to
   windows is now enforced at the storage boundary (a geometry
   panic), and a drift guard pins the runner's write coordinate to
   the facade's read coordinate. Post-landing review (adversarial
   trace + exhaustive toy simulation) found no defect; two leads
   recorded: the cold top fold reads window roots one point-SELECT
   at a time (2^24 on a full epoch - batch the range read if full
   epochs ever matter), and the height-0-at-coarse-stride coverage
   caveat is now documented at covered().
4. LANDED (session C, same day as the section-6 amendment it
   implements). Characterization-first: a differential pinned
   process_input's (runs, window root, post-state) against a
   window-sized engine collect on the real machine BEFORE the switch,
   and retired with process_input after it. The runner rides the
   engine: per window, the machine moves out of its clone wrapper
   into the advance stf (a third feeder - one window, payload handed
   in, revert restored from the batch's committed boundary directory,
   never a store) and back for the record verbs; batch/crash
   discipline unchanged. The deletions: process_input and its run
   loop, CommitmentLeaf (Run is THE run type, narrowed at the row
   boundary), machine_state_hashes with its triggers and discipline
   tests (its rows also never had a GC - the leak died with the
   table), the facade's interior tier and Level0 adapter. covered()
   narrowed to window granularity; rows strict (the frontier stands
   on the runner's actual material: zero rows = the machine serves
   everything, the engine harnesses' pre-runner store; nonzero must
   equal the input count). Record time now asserts the final run
   carries the machine's boundary state - the settlement-vs-servable
   invariant checked per input. Two incidents worth remembering: the
   engine differentials construct sources over ingested-but-
   unprocessed stores, which forced the rows-are-the-frontier
   decision; and the Lua harness read the runs table to reconstruct
   the node's claim - it now reads settlement_info.computation_hash
   (the claim itself; every caller only ever used the root, and the
   oracle still computes its own commitment independently).
   Superseded along the way: the step-3 self-heal and
   padding-from-runs refinements.
   Post-landing adversarial review: one CRITICAL defect found and
   fixed before the battery. The dispute path legitimately stores
   machine-bought rows AT the window-root coordinate (a descent
   through a padding window's root - which every join's prove_last
   does, rightmost path), and the construction-time
   rows-equal-inputs check counted them, bricking every
   reconstruction after the hero's own join; a restart mid-dispute
   would have forfeited. The strict checks are now bounded to the
   recorded prefix (shift < input count) - rows beyond it are final,
   correct, and inert - and the frontier spec test pins
   reconstruction-after-descents. Two smaller findings landed with
   the fix: a v2 migration drops the runs table on upgraded stores
   (v1 gates by version number, not content), and the harness's
   machine-path query pins input 0 explicitly. One lead recorded: a
   halting input still wedges the runner one window later (parity
   with process_input's panic, but the engine now HAS well-defined
   halted-window semantics that the runner's yielded assert
   forecloses - schedule halted windows over the fixed point, or
   keep the wedge deliberate, when a real image can halt).
   Battery 21/0 with the fix; perf parity confirmed scenario for
   scenario against the pre-switch battery (chaos 116s vs 116s,
   kill_mid_match 124s vs 127s, stf_all 392/395s vs 392/393s - the
   coarse collect runs the same BIG_STEPS-granularity loop, as
   section 3 predicted).
5. LANDED (2026-07-20, after the next/3.0 rebase and the staged
   settlement port). The module rename: src/sling -> src/engine,
   SlingConfig -> EngineConfig, the work-dir and fixture names
   follow; the SQL table names (sling_config, sling_nodes) stay as
   the codename - renaming them buys schema churn for no semantics
   (glossary records the residue). The fold-in: common-rs is gone;
   merkle, arithmetic, and kms (Gabriel: fold it) are node modules -
   the node was their only consumer, and if it ever extracts, they
   travel inside it. kms's testcontainers dependency moved to
   dev-dependencies where it always belonged. Doc sweep rode the
   same change (AGENTS.md map, computation-hash paths, glossary,
   node-architecture). Historical plan docs keep their sling
   vocabulary deliberately.

Steps 1-3 are each independently valuable even if 4 stalls; 4 is
the one that needs the deepest care and pays the largest permanent
dividend (one consensus-critical implementation instead of two).
