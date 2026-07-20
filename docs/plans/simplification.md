# Simplification survey (written 2026-07-11)

A post-campaign audit of the sling node's shape, written at Gabriel's
request the day fold phase 2 landed, with the whole rewrite fresh in
context. Aggressive by instruction. Every claim cites its evidence;
anything unverified is marked a lead. This is next-campaign seed
material, not a work order - the ranked menu at the end is where to
start arguing.

Ground rules inherited from the campaign: prt/contracts is
audit-frozen; the harness oracle doctrine and the four load-bearing
invariants (collision tripwire, positional finality, idle-churn
convention, nested novelty) are not simplification targets; the fold
is golden and stays.

## Earning their keep (do not disturb)

- The pure fold + overlay split (tournament/fold.rs, reader.rs). The
  module docs carry the why; three batteries and two incidents never
  found a crack in the fold itself. The phase-2 differential pins it
  at every split point.
- Storage's role files + mutation taxonomy + trigger layer. The
  taxonomy tripwire caught this campaign's own additions twice. The
  write-closure idiom keeps callers unable to hold the database
  wrong.
- The quartet coordinate system (LevelCoords/Quartet) and the seed
  tree. One authority, spec-oracled, positional turn-taking made a
  coordinate computation.
- convert.rs's saturating boundary, and now ClockState's saturating
  arithmetic. Degrade-not-crash proved itself on 2026-07-09.
- The Toy machinery (ToyStf/ToyFactory/spec.rs). It priced three
  campaigns' worth of differential oracles and gave the Hero its
  decision-table tests for free.

## Not earning their keep

- The layered error enums. hero/error.rs's ReactError is three
  transparent wrappers around anyhow; NO variant of it is matched
  anywhere (grep: zero non-definition uses of `ReactError::`).
  epoch_manager/error.rs wraps it again. Only StorageError's
  Inconsistent{Input,Epoch}/DataNotFound variants are constructed
  with intent, and even those are matched nowhere - they exist for
  their messages. Aggressive call: collapse worker-level errors to
  anyhow, keep StorageError only if its variants start driving
  behavior; the node is a binary, not a library.
- (fixed 2026-07-11) Arc<Mutex<ArenaSender>> became Arc<AS>: every
  ArenaSender method takes &self, the sender is stateless over an
  alloy provider with filler-managed nonces, and Hero + GC run on
  one thread; the mutex serialized nothing and its ~20 lock().await
  sites were pure ceremony.
- tournament/config.rs: 149 lines (BlockchainConfig, AWSConfig, 40
  anvil private keys) whose only reference outside the file is a
  COMMENTED-OUT unwrap_or in provider.rs. Dead since the crate
  consolidation; `pub use config::*` exports it anyway. Delete.
- The `#[async_recursion]` boxing in hero/mod.rs and gc.rs - a
  symptom, not a cause; see the async question below.

## The wrong abstraction

- Vec<String> as a retry policy. `long_block_range_error_codes`
  (provider-specific RPC error codes, stringly matched via format!
  ("{:?}") substring search) threads through NodeConfig -> lib.rs ->
  EpochManager -> Hero -> StateReader, and separately into
  BlockchainReader -> EventReader. It is configuration for a
  PROVIDER behavior living everywhere except the provider. The right
  home is a provider wrapper (below); the codes then thread through
  zero layers.
- Structure::PRODUCTION duplicates machine/constants.rs's numeric
  spans as literals (24/48/20), with a comment pointing at a path
  that no longer exists ("prt-core/src/machine/constants.rs") and a
  "must stay in agreement" nobody enforces - no guardrail test, in a
  codebase that guardrails emulator/step agreement two files over.
  Either derive PRODUCTION from the constants or assert equality in
  a test; and note rollups_machine.rs derives a THIRD family of
  stride constants from the same numbers.

## Missing abstractions (the real gaps)

- A chain facade. Ranged log fetching with bisection-on-too-large is
  implemented TWICE: blockchain_reader's EventReader +
  "ParitionProvider" (typo in the source) and tournament/reader.rs's
  get_raw_logs, each with its own should_retry_with_partition, both
  descended from state-fold. Pinned point reads, Latest/Finalized
  sampling, and the retry-code policy belong in one wrapper around
  DynProvider. This single move deletes the Vec<String> threading,
  one of the two fetch implementations, and gives transient-error
  policy one home.
- A worker frame. Three workers hand-roll the same loop { tick;
  watch.wait(sleep) } with INCONSISTENT error semantics: the epoch
  manager retries transient errors (the 2026-07-10 fix), while
  blockchain_reader and machine_runner still die through notify_all
  on the first provider hiccup - the exact failure class the retry
  fix was built for, still live in two of three workers. A tiny
  worker harness (tick fn + sleep + watch + retry policy) makes the
  semantics uniform and shrinks lib.rs's three copies of runtime
  spawning.
- The sync-vs-async decision (node-architecture.md debt #8),
  restated with this campaign's evidence: every hot path is blocking
  (machines, SQLite), the only async surface is alloy, and the cost
  is three single-threaded runtimes, async_recursion boxing through
  the whole Hero, and `.await` noise on every arena call. A sync
  node with one thin async edge (the chain facade above, running a
  small runtime internally) deletes an entire dimension of ceremony.
  These three gaps compound: facade -> uniform workers -> sync core
  is one coherent campaign, not three.

## Leaks

- alloy leaks INTO everything: `alloy::sol_types::private::Address`
  imported from a `private` module in reader.rs and sender.rs
  (import path smell; use alloy::primitives), U256 imported as
  ruint::aliases in five files and as alloy's re-export elsewhere.
  Cosmetic but pervasive; one import convention, one sweep.
- Bindings types leak through the sender trait (MerkleProof vs
  Bytes32[] conversions inline per method) and the reader
  (commitment_return._0/._1 tuple field access). The bindings
  generation owns this; the TODO about a shared Match::Id struct in
  tournament.rs is the same story. Lead: a small newtype boundary at
  the bindings edge, or fix the generation.
- storage/rollups_machine.rs is machine semantics (input feeding,
  checkpoint writes, commitment leaf production - the things
  computation-hash.md documents) living in the storage module
  because storage owns snapshots. It even carries its own StoreError
  and stride-constant derivations. It is the machine-runner's
  machine; a machine_runner/ or sling home would put the
  computation-hash reading path in one place. Naming is the seam:
  "storage" should not export a Machine.

## Weird shapes / smell test

- EpochManager.epoch_hero: (Option<Hero>, u64) - the anonymous tuple
  state machine (debt #9), plus Hero::new's seven positional
  arguments behind #[allow(too_many_arguments)]. A HeroSpec struct
  (or building the Hero from &Epoch + &NodeConfig) fixes both.
- The sender's ten near-identical methods: build call, send,
  allow_revert_rethrow_others("name", ...) - 19 repetition sites.
  A helper taking the built call + name halves the file. Also
  allow_revert_rethrow_others lives in tournament/ but is the
  epoch manager's settle-path dependency too; it is the node's
  revert-tolerance policy, another chain-facade tenant.
- notify_all! in lib.rs: a macro to convert worker exits into Watch
  notifications, expanded three times around three hand-built
  runtimes. Dissolves with the worker frame.
- args.rs NodeConfig::setup spins a private tokio runtime to run
  async setup before the three worker runtimes exist - a fourth
  runtime. Same dissolution.

## Hardest to read, and what would help

- hero/mod.rs (594 lines of code): the react_* recursion threads
  five context arguments (match_fold, live, commitment, tournament,
  overlay) through every level. A small `struct Ply<'a>` (one
  level's context bundle) would cut every signature in half. The
  logic itself is fine - it reads like the protocol - but the
  parameter trains obscure it.
- tournament/reader.rs (704 lines): now carries fetching, folding,
  persistence, overlay assembly, the partition fetcher, AND two test
  modules. Split candidates: the fetch layer moves to the chain
  facade; phase2_tests could live beside the fold tests. After the
  facade, reader.rs is ~250 lines of pure assembly.
- storage/advance.rs (879 lines): the batch machinery plus GC plus
  padding math plus proofs. It has grown three campaigns of
  accretions; the role-file idea wants a second pass here (advance
  vs gc as separate roles?). Lead, not a verdict.
- measure.rs (822 lines) is the biggest bin and predates the
  campaign's conclusions; workstream 8 already plans its
  replacement. Do not invest in reading it.

## Duplication

- The two log-fetch/partition implementations (above) - worst
  offender, one deletion away from gone.
- The three span-constant families (machine/constants.rs literals,
  Structure::PRODUCTION literals, rollups_machine.rs derivations) -
  one authority plus derivation, with a test.
- The setup_storage cost: DIAGNOSIS WAS STALE (measured 2026-07-11).
  All 14 setup_storage sites together cost 1.4 s wall; the 23 s
  suite was three blockchain_reader tests waiting out anvil's
  block_time(1) and 1 s polling sleeps. Fixed by making them
  event-driven (automine + explicit anvil_mine to advance finality,
  20 ms polls): lib suite 23.3 s -> 1.8 s. The once-built template
  is NOT worth its shared-state complexity at 1.4 s; dropped.
- Deliberate, keep: Lua client vs Rust node (cross-implementation
  oracle); solidity-step vs emulator (protocol); toy vs machine STF
  (differential).

## The aggressive menu, ranked by leverage-per-risk

1. LANDED (2026-07-11), core scope: src/chain.rs (Chain over
   DynProvider) owns ranged log fetching with an ITERATIVE
   bisection worklist (no async_recursion), the long-range error
   codes, and Latest/Finalized sampling. Deleted: both partition
   fetchers, EventReader, blockchain_reader's error enum, and the
   Vec<String> threading through five constructors (Hero::new lost
   its too_many_arguments allow). Deferred to the worker frame:
   revert tolerance (allow_revert_rethrow_others) stays in
   tournament/ until the sender refactor touches it.
2. LANDED (2026-07-11), the sequencer transcription: ONE runtime
   (four counting args.rs's setup runtime, all gone), ShutdownSignal
   (AtomicBool + Notify + condvar half for the blocking lane)
   replacing Watch's conflation, machine-runner on spawn_blocking,
   biased selects in the async workers, errors through JoinHandles
   with drain-every-handle and Ok-outside-shutdown = stopped
   unexpectedly. The transient-death gap is closed in all three
   workers (warn + retry next tick). notify_all and the catch_unwind
   thread tops dissolved. Adopted the shape, not a Worker trait, as
   the sequencer section below argues.
3. Sync core, async edge. The big one; do it after 1+2 make the
   async surface small enough to see. Deletes async_recursion,
   three runtimes, and .await noise from the entire dispute path.
4. LANDED (2026-07-11), standalone: Arc<AS> everywhere, all
   lock().await ceremony gone (the sender was stateless over
   filler-managed nonces; RecordingArena already recorded through
   &self with its own interior mutex).
5. LANDED (2026-07-11). tournament/config.rs deleted; one import
   convention (alloy::primitives everywhere); the ruint and
   num-traits deps dropped from the node crate.
6. LANDED (2026-07-11). machine/ folded into sling as
   sling/constants.rs (guardrail test moved with it);
   Structure::PRODUCTION now derives from the constants instead of
   duplicating them; stale comment gone.
7. LANDED (2026-07-11), with a corrected diagnosis: setup_storage
   was already cheap (1.4 s across all sites); the real cost was
   three anvil tests gated on wall-clock finality. Those are now
   event-driven (automine + anvil_mine, short polls) and the lib
   suite runs in under 2 s. The once-built template was dropped as
   not earning its keep.
8. Hero ergonomics: HeroSpec construction + Ply context bundle +
   collapse error enums to anyhow. Small-medium, best done inside
   whichever campaign touches the Hero next.
9. rollups_machine.rs rehoming + advance.rs role split. Medium;
   needs a design conversation first (lead).

Deliberately NOT on the menu: the fold, the overlay split, the
storage taxonomy, the oracle doctrine, anything in prt/contracts
while the audit runs, and the sling module name (parked until
increment F retires the reference collector).

## The sequencer's answers (read 2026-07-11, ../sequencer)

The sibling repo already answers menu items 2 and 3 in production
shape; storage v2 transplanted its storage patterns, and its runtime
module is the same-quality reference for ours. What it does, and
what transfers:

One runtime, work-shaped placement. Five workers, one tokio
runtime. The blocking hot path (inclusion lane: SQLite + app
execution) is a single spawn_blocking task - plain sync code, no
async in the loop. Genuinely-async workers (L1 submitter, input
reader, danger detector: chain RPC plus light DB) are tokio tasks
whose SQLite touches go through per-call spawn_blocking. The HTTP
edge is natively async. Transfer: machine-runner and the Hero's
dispute loop are our inclusion lane (machines + SQLite, zero
genuine async except arena sends and the reader fetch) -
spawn_blocking sync loops, which deletes every #[async_recursion]
box; the blockchain reader and a chain facade stay async tasks.
One runtime replaces our three-going-on-four.

Shutdown as a 40-line primitive. ShutdownSignal = AtomicBool +
Notify. Async workers race it: select! { biased; shutdown => exit,
work => ... } - biased so a pending shutdown beats a ready work
step. Blocking workers poll is_shutdown_requested() at the loop
top and reject queued work on the way out. Errors do NOT travel
through the signal: they come back through JoinHandles, and the
runtime races ctrl_c against every handle (select_first_exit),
then requests shutdown and awaits EVERY handle - with an explicit
comment that dropping a JoinHandle detaches the task mid-drain,
the exact abrupt-write case startup hygiene exists to mop up.
Transfer: this dissolves our Watch (which conflates shutdown
signaling with error broadcast) and notify_all!; our workers
return their errors through handles like anyone else.

Tick outcomes as the retry vocabulary. The submitter's loop maps
every tick to Submitted | Idle | Transient, with terminal errors
lifted out explicitly (a wrong-chain RPC never retries). That
three-way outcome is the uniform semantics our epoch-manager
retry gestured at and blockchain_reader/machine_runner still
lack. Also: a worker returning Ok outside shutdown is treated as
StoppedUnexpectedly - silence is a failure, not a success.

Explicitness over the worker-harness abstraction. Their workers
module deliberately does NOT abstract the lifecycle: five fields,
five spawn statements, five select arms, five cleanup entries,
with a doc comment defending it ("each edit is obvious and
local"). The menu's item 2 should follow suit: adopt the SHAPE
(shared signal, biased select, tick outcomes, handles as error
channels), not a generic Worker trait. What we should NOT copy:
five per-worker exit enums with From impls - that ceremony pays
off for their heterogeneous exits (DangerDetected carries state);
our three workers have no such taxonomy, anyhow through the
handle suffices.

Startup hygiene as a ritual. Ordered, commented, individually
tested steps before any worker spawns: reset stale leases, require
the finalized snapshot (fail loud, no silent cold-start), restamp
the crash-window artifact, ensure the structural invariant (open
tip), GC unreferenced rows, sweep orphan directories. We have the
pieces (CAS stage+rename, GC-after-commit, absorbing appends) but
no single startup ritual; the open epoch-scratch-dir GC side quest
is exactly an orphan sweep, and it should land as step one of ours.

Storage: already transplanted, deltas deliberate. Same WAL +
foreign_keys + read/write closure discipline (WS3 took it from
here). synchronous: theirs FULL (commits gate external
broadcasts), ours NORMAL (replay-tolerant by design) - both
documented, both right. Worth adopting: their read-only handles
use a 50ms busy_timeout (observability fails fast instead of
stalling a writer's 5s); ours uses one 10s timeout for everything.

Net effect on the menu: items 2 and 3 stop being design questions
and become transcription with taste - the sequencer is the working
reference implementation of both, one repo over.
