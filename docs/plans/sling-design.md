# Sling node - design notes (converging)

Status: COMPLETED AND FROZEN. The design settled and graduated:
docs/node-architecture.md is the living successor, and the node's
engine/hero/tournament modules implement it. Kept in place as the deep
design rationale of record - code comments cite it by increment.
Originally a draft of 2026-07-02 capturing the design as described by
Gabriel; the draft commentary and open questions below are preserved
as written.

## Two regimes

1. Open epoch (eager): an epoch lasts ~7 days; when it closes we must be
   ready to dispute promptly, not start a week of compute. During the
   epoch the node eagerly produces:
   - a series of machine snapshots (per input, or at some cadence;
     possibly leaning on a COW filesystem to make per-input feasible);
   - recorded progress toward the root computation hash.
2. Closed epoch (dispute-serving): all inputs known. The rest of this
   document is about this regime.

When epoch N closes, the module operating over it continues on N + 1
and delegates N to the closed regime: two threads working the two
regimes simultaneously. The open regime must snapshot preemptively so
the closed regime can serve disputes inside their deadlines.

Operating assumptions (2026-07-03), documented because dispute
deadlines and the snapshot cadence math lean on them:

- An epoch carries less than its wall-clock worth of compute: the
  node processes at least as fast as the chain produces (an hour of
  rollup compute per hour; we do not accept more than we can chew).
  This is what makes catch-up and dispute deadlines meetable at all.
- Load is roughly evenly spread across inputs, so input count is a
  valid proxy for compute distance.
- A handful of inputs is processable quickly (the emulator is within
  an order of magnitude of JITed QEMU).
- Machine snapshot store and load are fast (heavily optimized; the
  machine effectively runs from disk via mmap), so snapshot cost is
  disk footprint, not time.

## The ruler

Visualize all state transitions (meta-steps) of an epoch on a ruler
indexed by meta-cycle. It has 2^92 positions, does not fit in memory,
and cannot be computed in reasonable time (if it could, we would build a
dense computation hash and run one-level tournaments). Two facts make it
tractable:

- sparse sampling, using the big architecture as a shortcut for coarse
  strides;
- the ruler is filled with repetitions (fixed points after halts,
  yields, and padding), which must be exploited structurally or the
  merkle root is uncomputable.

## Tree addressing: the triple (height, shift, log2_stride)

Every merkle node of interest is identified by three fields:

- `log2_stride` (r): the sampling rate; one sampled leaf per 2^r
  meta-cycles. Coarse strides (r >= 20) ride the big architecture;
  r = 0 is uarch-level.
- `height` (h) and `shift` (s): the node spans sampled leaves
  [s * 2^h, (s+1) * 2^h), i.e. ruler range
  [s * 2^(h+r), (s+1) * 2^(h+r)) meta-cycles.

Observation (structural vs tuned): the ruler's shape (a, b, c) =
(input span, barch span, uarch span exponents) is structural, fixed by
the state-transition function. Tournament level parameters (log2step,
height per level) are consensus-deployment choices driven by emulator
speed benchmarks. Cache stride choices are node-local performance knobs.
The node core should be parameterized by (a, b, c) only; tournament
shape arrives as queries.

Commentary: this triple unifies three things the prototype represents
separately - level commitments (their roots), bisection answers (inner
nodes navigated via in-memory MerkleTrees), and proof material (a leaf
or last-leaf proof is a chain of sibling nodes, each itself a triple).
Everything the dispute strategy needs becomes triple queries, which is
also what makes the node restartable: the cache is the dispute state,
and it lives in SQLite.

## The two dispute operations

1. children(triple) -> (left hash, right hash): the hard one; drives
   bisection and proof construction.
2. transition proofs at a given meta-cycle (access logs for one
   meta-step): easy given a nearby snapshot.

## The node cache

A SQLite table mapping triple -> hash. The crucial function,
get_or_compute(triple):

- cache hit: return the hash;
- cache miss: compute all sampled leaves in the node's span (machine
  execution from the nearest snapshot at or before the span start - the
  slow part), then, since the same leaves serve the whole subtree,
  compute and store not just the requested node but its descendants 8
  levels down: 256 + 128 + ... + 1 = 511 rows. Numbers arbitrary,
  tunable; caching all inner nodes would trade too much space.

Commentary - amortization math: a descent that misses at height h costs
one span execution; the next miss is 8 levels deeper and costs 1/256 of
that. A full descent costs about span * 1/(1 - 2^-8), i.e. under 0.4%
overhead versus touching each meta-cycle once. The tunable is sound;
storage per miss (511 rows of ~40 bytes) is negligible next to machine
time.

## New emulator primitives

`cm_collect_mcycle_root_hashes` (root hash every mcycle_period, with
phase for boundary misalignment, bundling of 2^k hashes into subtree
roots, back_tree continuation context, fixed-point padding semantics)
and `cm_collect_uarch_cycle_root_hashes` (hash per uarch cycle with
implicit resets, reset_indices, same bundling idea). Leaf collection and
the lowest tree levels move into C: no FFI churn per leaf, small result
arrays when bundling is sized sensibly.

Commentary: the fixed-point semantics in these APIs (bundles completed
by padding; final bundle entirely repetitions) encode exactly the
subtleties that make the prototype arcane. Good - but note these
semantics are consensus-relevant (they define commitment structure) and
now live in a fourth implementation (emulator C, next to node Rust, Lua
oracle, and Solidity). See testing implications below.

## Open questions and suggestions (commentary)

1. Abstract the leaf source (accepted). Define the collectors as a
   narrow trait (span -> bundled hashes + fixed-point signal), with the
   emulator as the production implementation and a toy deterministic
   STF as the test implementation. Gabriel's refinement makes the toy
   maximally transparent: where the real leaf is a machine root hash
   (itself the root of the machine's address-space merkle), the toy's
   state at meta-cycle N is simply N as a bytes32/U256 - expected trees
   become computable by hand in tests. Scripted yields/halts and tiny
   (a, b, c) like (2, 3, 4) cover the boundary geometry. This single seam is what moves the testing
   discipline to the Rust unit level: the whole tree/cache algebra -
   children consistency, padding, fixed-point shortcuts, the 8-level
   precompute, frontier resume - becomes millisecond-fast, exhaustively
   testable logic. It also honors the repo's stated goal of execution-
   environment agnosticism.
2. Fixed points are transient, not stored (resolved: no table). An
   earlier draft suggested persisting fixed-point records; Gabriel
   pointed out they are unnecessary, and this is a major simplification
   of the design. The compute path must exploit repetitions (that is
   what makes computation feasible at all), but only within a single
   get_or_compute call: the collectors signal the fixed point, the
   remaining descendants are iterated-hash math, and the knowledge is
   discarded. Re-deriving it on a later miss is essentially free - the
   nearest snapshot at or before a pure-padding span is already at the
   fixed point, so the machine reports it immediately. And since a
   cache write is at most 511 rows, storing repetition-derived nodes
   costs nothing worth optimizing away. No cross-request state exists
   beyond the cache rows themselves.
3. Convention pinning (increment A did this executably). The
   conventions live in the sling ruler module's doc and its spec tests:
   leaf j at stride r is the post-state of transition (j+1)*2^r - 1;
   the fused feed transition opens fed windows; the closing slot packs
   ustep + ureset + revert. One resolved question of note: an input
   crossing its window boundary is an invariant violation, not a case -
   the (a, b, c) spans are deliberate overestimates (inputs are batched
   bundles, chains cannot carry 2^a of them, gas bounds processing far
   below 2^b big cycles), so the engine panics as a tripwire instead of
   defining a transition shape for it.
4. Latency budget. Worst-case get_or_compute latency per tournament
   level is one span execution at that level's stride; it must fit
   comfortably inside matchEffort. Carry an explicit table (level span,
   measured emulator throughput, resulting latency, clock budget) in
   this document; it is also the principled way to choose the 8-level
   constant and to sanity-check consensus (log2step, height) choices.
5. Cache keying and versioning (resolved: quartet + write-once config
   table). The key is really a quartet - (epoch, height, shift,
   log2_stride) - since one node validates one application and the db
   spans epochs. No per-row versioning: a config table written once at
   db creation and never again pins everything contextual (app address,
   template hash, emulator version, the (a, b, c) structure, chain id);
   on startup the node asserts its own configuration matches. Rows stay
   lean. Determinism makes concurrent recomputes benign
   (last-writer-wins, identical values) - but assert equality on
   collision: a mismatch means nondeterminism or version drift, the
   two things we most want to hear about loudly.
6. Regime-1 handoff. "Work recorded toward the root hash" has a
   concrete shape: the back_tree merkle frontier. Persist (snapshot,
   frontier, phase, fixed points) atomically per input; on epoch close
   the root completes in O(padding), and regime 2 starts warm.
7. Snapshot cadence is a perf knob, not a correctness input: any
   snapshot at or before a span start works; distance bounds re-run
   time. Fixed cadence plus on-demand refinement during a descent
   (store dispute-time snapshots near the contested region, as the
   prototype already does by root hash) may make per-input snapshots
   unnecessary; if per-input proves desirable, COW filesystems make it
   cheap. Worth deferring until the latency table says otherwise.
8. Stride domain. The collectors bundle from big-cycle granularity
   (r >= 20) or uarch granularity (r = 0, bundling up). If tournament
   configurations never use 0 < r < 20, say so and restrict the domain;
   if they might, the uarch collector's bundling already covers it.
9. ANSWERED (2026-07-15, one-engine step 3): built in the two-tier
   shape sketched below - window-root quartet rows written by the
   open regime per input, lazy interior folds, the top tree
   O(inputs x 24) - and the SeedTree type is gone. The max-tilt
   corner now costs one window's fold, on the first descent into
   that window only. Original text follows.

   Seed fold scale. The SeedTree fold is O(runs x 48) in time and
   resident memory, paid at every Player construction and held for the
   dispute's duration. Realistic epochs (evenly spread load) keep runs
   near the input count - milliseconds. A max-tilt epoch allowed by
   the operating assumptions (~2^46 real big cycles) reaches millions
   of runs: minutes of folding and tens of GB resident, re-paid per
   restart, plus roll_epoch's re-fold for settlement_info. The
   priced-later answer is a two-tier lazy seed: the open regime
   persists one window root per input (final data - the frontier rule,
   increment E section), the top tree over window roots is
   O(inputs x 24), and a window's interior folds on first descent into
   it from machine_state_hashes, which the Player can range-read now
   that it holds a node-db connection. Gate on the latency table or a
   capacity-boundary scenario showing the monolithic fold hurting. If
   built, the lazy tier is load-bearing: a positional miss below a
   window root must fall through to a fold of stored runs, never to a
   2^24-big-cycle replay.

## Rewrite topology (settled 2026-07-02)

The rewrite starts inside the dispute module (`prt-core`, at the time
`prt/client-rs`), because
the interface split is already clean: epoch-manager hands it inputs,
level-0 leaves, a snapshot, and a tournament address; it exposes a react
loop; and it owned a private SQLite database (retired at increment E:
the sling tables live in the node database now). Everything inside
that boundary can be cut and hammered while the e2e suite stays green.

- `get_or_compute` and the quartet cache live inside this module. The
  outer node never calls it: regime 1 (open epoch) only produces the
  seeds - snapshots at cadence, level-0 leaf runs, inputs - which map
  onto cache rows at (height 0, shift j, log2_stride 44) plus padding.
- The quartet schema carries the epoch column from day one (constant
  while the DB is per-epoch), so the endgame - merging the dispute
  schema into the main node database - is a table move, and the
  per-epoch-DB debt retires as a side effect. Landed as increment E
  (2026-07-04); the per-epoch database is gone entirely, not just its
  sling tables - see the increment E section.
- The react/strategy layer (join, bisect, seal, timeouts, tournament
  reader/sender) largely survives; it changes what it queries. The
  `refactor/client-rs` branch's reader/tournament reshaping is mineable.
- Increment order: (A) cache + leaf-source trait + toy STF + spec tests,
  unwired (landed 2026-07-02); (B) reference collector on the current
  emulator API plus golden fixtures, differentially compared (landed
  2026-07-02); (C) swap the Player wholesale onto quartet queries,
  absorbing the sibling-chain proofs originally planned as (D) - see
  the increment C scope section below (landed 2026-07-02); (D)
  remainder: transition-proof serving off get_logs, plus the snapshot
  store for ruler positioning; (E) schema merge + harness seam update,
  same commit (landed 2026-07-04); (F) cm_collect_* bindings (emulator 0.21, tag
  v0.21.0-test3) replace the reference collector, differentially
  tested against it - riding the coordinated 0.21 bump (step
  submodule, guard test, fixture regeneration), deliberately last.
  A-E run on emulator 0.20; the reference collector matches the
  prototype's speed, which suffices.
- API choice for B, settled by the validate-after-writing criterion:
  the reference collector implements bulk verbs shaped like the 0.21
  cm_collect_* contract (period, phase, bundling, fixed-point signals)
  but on the 0.20 step-loop API, because 0.20 is the only version with
  oracles to compare against today (prototype tables, Lua, e2e).
  Increment F swaps the implementation under the unchanged shape.
- The write-once config is migration-time state (sling/config.rs):
  the node's migration writes it once; the cache only reads. Landed
  with E: the node migration pins the real app address and template
  hash, the dispute side asserts structure and emulator version
  (config::assert_compatible), and initialize survives as the
  standalone bootstrap for tests.

## Increment C scope (settled 2026-07-02, during implementation)

C moves the Player wholesale onto quartet queries: level roots,
children, and the sibling-chain proofs originally slated for increment
D. The forcing fact: join and seal transactions cannot be sent without
last-leaf and agree-leaf proofs, and serving those from the prototype's
in-memory tree would require keeping the leafs table alive to rebuild
that tree across restarts - the cache's fanout rows cannot reconstruct
a run-compressed tree, only answer node queries. Split differently, C
would either regress restart (recompute a week of leaves) or retire
nothing. What remains of the old D is transition-proof serving
(MachineInstance::get_logs), which stays on the prototype path until
the snapshot store exists.

Decisions pinned by C, with reasons:

- Everything the strategy needs is positional. The Match contract's
  runningLeafPosition is the leftmost leaf offset of the contested
  node, which sits at height currentHeight; so the node the Player
  must open is the quartet (epoch, level stride, currentHeight,
  base_cycle at that granularity plus runningLeafPosition >>
  currentHeight). The tree-search find_child (and its coincidental-
  hash-match wart) dies with the in-memory tree.
- children(quartet) is the second primitive next to get_or_compute,
  per "the two dispute operations". On missing children it recomputes
  the parent's span (one ruler pass, one replay) rather than each
  child separately - half the replays, and the recomputed parent must
  equal the cached row, a free nondeterminism tripwire on every
  stratum descent.
- Proofs are descents: prove_leaf collects the off-path sibling at
  each height, root to leaf, all through children(). After a
  bisection reached the leaf, the path is warm; the agree-leaf branch
  can cost one cold subtree, bounded by half the level span.
- Level 0 is served from the regime-1 seeds, not the machine. The
  epoch manager already hands the Player the level-0 leaf runs it
  computed during the epoch (durable in the state manager's
  machine_state_hashes); the Player folds them into a run-compressed
  in-memory tree at construction, milliseconds, rebuilt on every
  restart from the durable source. No leafs-table copy. Empty seeds
  (no-input epoch) collapse to the iterated initial hash. This is the
  increment-C stand-in for the regime-1 frontier handoff; the frontier
  design (open question 6) is unchanged as the endgame.
- Implicit hashes come from chain state, not replay. An inner
  tournament's initial hash is the sealed parent match's agree state
  (otherParent after sealMatch), which the Player already reads; the
  root tournament's is the epoch snapshot's hash, computed once at
  Player construction. The prototype replayed the machine to
  base_cycle on every react iteration just to recover this value.
- The template-replaying MachineFactory stays for C. The prototype
  also replays from the epoch snapshot for every commitment build and
  every get_logs (its snapshot reuse is commented out), so C is at
  cost parity; strictly better, since quiet react iterations become
  pure cache hits. The snapshot store (nearest-snapshot ruler_at,
  dispute-time snapshot refinement) is the next increment; until
  then, deep proof descents pay one replay per fanout stratum, which
  the latency-budget table (open question 4) must eventually price.
- The prototype builder (machine/commitment*.rs, the leafs SQL) stays
  in the crate as the differential oracle for the sling machine tests;
  it is unwired from the Player. It retires when fixtures alone carry
  the comparison burden.

## Increment D (settled 2026-07-03)

The problem is replay, not span execution or snapshot cost. Span work
is amortized by the cache fanout; snapshots are mmap-fast (see the
operating assumptions). The template-replaying factory re-runs from
the epoch snapshot once per fanout stratum of a proof descent and
once per level build; at production scale each replay from the epoch
start can be hours, and it dominates the latency budget (open
question 4). The fix is preemptive snapshotting by the open regime,
consumed read-only by the closed one:

- The seam (D.1a): a SnapshotSource in the dispute module -
  nearest_at_or_before(position) -> (position, machine directory).
  ruler_at resumes from it and advances the remainder; get_logs
  positions the same way, proof assembly untouched. The trivial
  implementation returns only the epoch-start machine, which is
  exactly current behavior, so the seam lands behavior-identical and
  differential-gated. Snapshot-resumed computations stay covered by
  the cache's collision tripwire wherever they overlap
  template-replayed rows.
- The fill (D.1b): the open regime already stores a snapshot at
  every input boundary and garbage-collects down to the latest
  (advance_accepted / gc_previous_advances). The policy becomes keep
  every Kth input boundary; K = 1 is store-everything, viable where
  a COW filesystem (betrfs-style) absorbs the footprint, and the
  no-dependencies default is a modest gap (64). Storage stays
  content-addressed (machine_state_snapshots) behind the epoch/input
  map (epoch_snapshot_info), so identical states dedup for free.
  Time-gapped cadence was considered and rejected: under the load
  assumption it equals the input gap in the wrong unit, and it fires
  at mid-input positions.
- The handoff: epoch N's snapshot list is static once N closes (the
  open regime moved on to N + 1), so the epoch manager passes the
  list at Player construction like seeds and inputs - no shared
  database handle crosses the module boundary. Input boundary i maps
  to ruler position i * 2^68.
- The bound, under the operating assumptions: repositioning costs at
  most K * (epoch compute / input count) between windows, plus one
  intra-window prefix (at most the disputed input's own compute) per
  miss inside the disputed window.
- Deferred (D.2): boundary snapshots can never help below window
  granularity, and levels 1-2 live entirely inside one window - each
  stratum miss re-pays the same intra-window prefix. Store-at-miss by
  the closed regime, writing through the same seam, collapses that to
  one payment. It matters in the few-heavy-inputs corner (allowed by
  the assumptions) and is deliberately deferred until the latency
  table prices it.
- Gates: the machine differential compares snapshot-resumed rulers
  against template-replayed ones on identical spans (bit-equal roots
  and proofs); fixtures unchanged; e2e green; the write-side crash
  ordering is already covered by the B2 scenario and the
  verify-on-conflict insert.

Convention correction, found by C's first e2e run (the sybil won a
level-2 leaf match on-chain): "a yielded machine repeats until the
next fed window" holds only at big-cycle boundaries. The yield and
halt flags gate the big machine, not the uarch - stepping an idle
machine's uarch churns the emulated interpreter's bookkeeping (~34
usteps on emulator 0.20) until the uarch halts, and the ureset
restores the base hash exactly, making idle spans periodic. The
prototype and the Lua reference encode this as "run one more span
after yield/halt and replicate it"; increment A had encoded the naive
constant instead, in the engine AND in the toy and its spec oracle -
a shared-assumption blind spot the tier-1/tier-2 instruments could
not see (increment B's differentials only covered active and coarse
spans; so do the fixtures, which is why they survive the fix
unchanged). The tier-3 net (the real on-chain state transition in the
e2e) caught it. Consequences pinned executably: the toy models idle
churn (IDLE_CHURN_TICKS), the spec oracle emits it, the ruler steps
one idle span per region and replays it, and the machine suite
guards the emulator semantics (idle periodicity, ureset restoration)
plus a differential at the exact shape that lost the match
(idle_padding_r0_h28).

## Increment E scope (settled 2026-07-04)

The schema merge, and what the discussion around it pinned down.

What landed:

- sling_config and sling_nodes live in the node database. Since the
  consolidation into a single crate there is exactly one migration
  (storage/sql/migrations.sql, sling DDL included) and one DDL path;
  config::pin writes the config row right after it, and tests
  bootstrap through the same migration. Schema changes are breaking
  by policy: wipe the state dir and resync (an old state dir fails
  loudly on version mismatch).
- The per-epoch dispute database is gone entirely. Its inputs table
  was a copy (the main db is the durable source, and the epoch manager
  already passed inputs by value), and its leafs table served only the
  prototype oracle. DisputeStateAccess became EpochData: plain memory
  (inputs, the epoch scratch directory for dispute-time snapshots, the
  oracle's leaf runs). The dispute module's only SQL surface is the
  sling tables.
- Connection story: shared file, disjoint tables, private connections.
  The Player receives its own Storage handle from the epoch manager
  (one connection per thread; WAL is persistent in the file; the same
  10s busy timeout everywhere) and reads the closed epoch's working
  set - inputs, seed runs, snapshot list - through it at construction.
  Since the interface pass the quartet-cache SQL also lives behind
  Storage, making storage the node's only SQL surface; the collision
  tripwire moved with it, semantics unchanged.
- The config row carries real pins now: app address and template hash
  written by the node migration (the per-epoch stand-ins - root
  tournament, epoch snapshot hash - retire), plus emulator version and
  structure. The dispute side asserts structure and emulator version
  only; app and template are node-level facts it cannot derive (the
  epoch snapshot hash differs from the template hash past epoch zero).
- GC: gc_old_epochs also deletes sling_nodes rows at or below the
  epoch before the one just rolled. Sound because DaveConsensus
  settles epoch N before sealing N + 1 ("there is always one sealed
  epoch; prior to it, every epoch has been settled"), so those rows
  belong to finished tournaments. Epoch scratch directories still
  accumulate - pre-existing debt, unchanged by E.

Table ownership - the regime boundary restated for the merged file:
the open regime owns the fact tables (inputs, epochs,
machine_state_hashes, epoch_snapshot_info, machine_state_snapshots,
settlement_info, latest_processed, template_machine); the closed
regime owns sling_nodes; sling_config is migration-time state. The
regimes already shared a database - machine_state_hashes is the open
regime writing its half of the tree, in seed form - so E makes
ownership table-level, never row-level.

Why the open regime never writes sling_nodes (settled in discussion,
2026-07-03): the table's load-bearing invariant is positional
finality, not reachability-from-root. The primary key is the quartet
and the hash is a value column, so a row, once written, is the
eternally correct answer for its coordinate - which is exactly what
makes the collision check a nondeterminism tripwire. An open epoch's
provisional tree violates this: each accepted input changes the
padding fixed point, rewriting nearly the whole right-of-frontier
region under the same keys (reverts excepted - the checkpoint
restores the old fixed point). Provisional rows would either poison
the tripwire or demand mutable rows; worse, stale level-0 rows would
never be re-verified, because level 0 is seed-served and never
machine-recomputed - wrongness with no loud error. The frontier rule,
if incremental materialization is ever wanted: only nodes whose span
lies entirely left of the input frontier are final mid-epoch. Nothing
needs it today - level 0 is deliberately not a table (the
run-compressed seed fold; "no leafs-table copy"), and deep strata are
demand-driven replays.

Addendum (2026-07-15, the one-engine step-3 flip, amended the same
day by section 6's amendment): incremental materialization is now
wanted - one row per input, the window's final level-0 subtree root,
written by the advance commit under exactly the frontier rule above.
The invariant this note protects (positional finality) is untouched:
only final coordinates are ever written, by either regime, and the
tripwire arbitrates. What changes is the ownership framing - from
table-level ("the open regime never writes sling_nodes") to
finality-level (any regime may write a coordinate whose value is
final; provisional values still never land). The window roots are
the only mid-epoch rows; everything right of the frontier stays
unmaterialized. machine_state_hashes died with the amendment: the
window root is the runner's ONLY level-0 artifact, and below window
granularity every quartet rides the machine regime like any nested
level - which also closes this note's old caveat, since a dispute
descent that recomputes a window root's span now collision-checks
the runner's fold with the machine.

The coherence contract: DisputeSource::node/children is the single
lookup interface - quartet in, hash out. The level-0 backend is the
frontier fold (a top tree over the window-root rows plus the fixed
point repeated - one-engine.md section 6); sling_nodes' deeper
strata are its machine backend (each row bought with a replay,
existing only where a dispute walked). One table, one exception: the
frontier composition, folded inside the source behind the
subtree-returning contract - whether an answer was a row lookup, a
fold, or a replay is invisible provenance.

## Testing implications (feeds characterization.md)

- The triple function is pure: (template machine, epoch inputs) ->
  triple -> hash. Ideal oracle target.
- The prototype's dispute db (`leafs` keyed by level/base_cycle) maps
  directly onto triples: level determines r, base_cycle = s * 2^(h+r).
  Old-node-vs-new-primitives differential testing is therefore a table
  comparison, and becomes the bridge that certifies the rewrite.
- Golden fixtures should target the new emulator primitives directly
  (cm_collect_* outputs vs the current node's leaf construction on the
  same workloads), because the primitives now carry consensus-relevant
  semantics.
