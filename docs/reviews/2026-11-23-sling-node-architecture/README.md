# Sling node architecture review, 2026-11-23

A read-only architecture review of the sling node (`cartesi-rollups/node`,
crate `cartesi-sling-node`) as it is set to ship in v3.0.0-alpha.8. No code
was changed. Line-level bug hunting was out of scope: the October 2026 review
did that, and its fixes landed as cartesi/dave#299 and cartesi/dave#300.

Reviewed state: the tip of draft cartesi/dave#307 as fetched on 2026-11-23,
tree `ec7afc62fd9d48ba39676c273ab09a74ab9cdeaf`: main plus the Cartesi Machine
v0.23.0-test3 generation. Later commits on that branch were not chased.

Method. The docs first. Then the storage, engine, hero and epoch-manager core,
read directly. Then thirteen cards written by independent readers from one
template: ten component cards and three evidence cards (appendices). Then a
refutation pass: six other readers tried to break each proposal, the reasoning
of sections 7 and 8, and every citation, against the code and the invariants
the docs defend. Section 4 says how each proposal fared; three were refuted or
demoted and are listed as such, and sections 7 and 8 were rewritten in part
after that pass. Citations are `path:line` in the reviewed
tree; node paths are relative to `cartesi-rollups/node/`. Material outside the
repository (an upstream reply on the emulator's cold reads, the October
hardening catalog, cartesi/dave#304, another repository's watchdog) is named
where used and is not part of this record.

## Conclusions

1. No correctness bug was found. The node fits a small model (section 1), and
   where the code departs from it the departure is placement, not behavior:
   concepts with two homes or none, and three mechanisms that each serve
   several concepts (section 2).
2. The per-input cycle is one of two shapes the emulator API allows, and it
   is unmeasured where it matters. Every figure is macOS, as the docs say.
   Summing the phase figures of an upstream reply for Linux XFS (our
   arithmetic, their hardware and image) gives 22 to 65 ms per input,
   depending on whether their 40 ms cold input applies to our image: it
   cannot yet be placed on either side of the 36 ms threshold the
   dimensioning argues from. The node also pays a per-batch `COUNT(*)` that
   grows with the epoch and that the 256-input benchmark cannot see
   (measured here: 0.23 s per batch at 2^24 inputs, which is 3.6 ms per input
   at the default gap and 230 ms at a gap of one). Section 7 says what to
   measure, what decides, and which change follows from which result.
3. Everything in the store is derivable from the chain and the image, so
   every piece of correctness machinery in it is there to save clock time,
   not truth (section 5). One fingerprint is weaker than the docs say: the
   pinned emulator identity is `major.minor.patch`, which cannot tell a test
   tag from its release (section 6).
4. A detector written in Lua that runs one tick and exits, on the pattern of
   another repository's watchdog, holds up as the leading candidate: it shares
   only the emulator with the node, most of its chassis exists, and Lua gives
   it the emulator's fork, a path the node's bindings do not have. Two things
   the candidate as stated lacks: a rule against acting on one uncorroborated
   replay, since foreclosure is irreversible; and a home for its drills,
   since the Lua end-to-end harness cannot make a fabricated claim win today
   and the node's own harness can (section 8). The node needs to expose
   nothing at run time. One piece of planned advice must change first: with
   sling nodes as the only sentries, a claim that joins in the last block
   before closure and is shared by them leaves no window at all.
5. The node's run-time coupling to the rest of the repository is an address
   and an ABI. The build and test coupling is real and two-way, and four
   small interfaces would cut most of it (section 9). This record does not
   decide extraction.

## 1. The node in one page

The node is a deterministic function from (finalized chain, application image)
to (machine states, commitments), inside a loop that reads the chain and sends
whichever call the honest strategy owes next. Everything it stores is a cache
of that function. The store has correctness machinery only because recomputing
costs clock time, and clock time is what a dispute is lost on.

What it follows.
- The application's finalized `InputAdded` and `EpochSealed` logs: the input
  list and the epoch bounds. This is the only chain data treated as permanent,
  and the node's one finality obligation.
- For the one unfinished epoch: its tournament tree, as an event fold through
  the finalized block (Solid) plus a disposable tail to latest (Foam), and a
  few reads pinned to one block (standings, the engaged match's phase).
- The consensus's settlement views, the application's foreclosure flag, and
  each tournament's bond disposition.

What it computes.
- The machine before every input of every epoch (a boundary), by replay.
- Per input, the level-0 subtree root of its window, at the deployed root
  stride. From them, at the seal: the epoch's commitment, its final state and
  the three-leaf validity proof.
- On a dispute only: any Merkle node of any level's commitment (a quartet),
  bisection openings, and one transition proof.

What it stores (section 6).
- The chain record: `inputs`, `epochs`, the ingestion watermark.
- Computed results written ahead: every gap-th boundary and each epoch start
  as stored machines; window roots; one settlement row per epoch.
- Two cursors: the runner's (its newest boundary) and the completion cursor.
- A cache: quartet nodes computed during disputes.
- Identity: the deployment and versions the directory was built for.

What it sends. One batch per tick, at consecutive nonces from the mined nonce:
at most one dispute action or one cleanup, at most one settlement step, and
every due bond recovery. Each call either advances the protocol or reverts
harmlessly, except a join, which locks a bond behind a claim; so a join's
payload comes from finalized state only.

What it owes, and by when (`docs/dimensioning.md:487-496`).

| Obligation | Deadline | What it needs ready |
|---|---|---|
| Root join | G after the seal; lateness draws on C | the whole epoch computed |
| Child join | T + G after the seal that created it | one cold build of the gap |
| Advance, seal, propagate, timeout claim | G after becoming due | at most gap - 1 inputs replayed, once |
| Leaf proof (and fallback claim) | G after the leaf seal | the disputed input's prefix |
| Cleanup of expired matches | none; delays its own progress | events only |
| Sentry claim | before the staging period ends, to shorten it | the settlement row |
| Stage, accept | none | the settlement row |
| Bond recovery | none; gates the next epoch locally | finalized dispositions |

Three workers exist because three obligations differ in kind: the reader owns
finality, the runner owns machine time, and the manager (with the Hero) owns
deadlines. They share no memory; the SQLite transaction is their interface.

What it trusts: finalized blocks, a complete and truthful RPC endpoint, the
emulator, the deployed contracts, the application developer, and that its
signer is used by no one else.

## 2. Where code and model disagree

No disagreement below changes what the node sends. Each is a place where a
reader of the docs would look in the wrong file, or where one rule lives in
two places and can drift.

Concepts the docs name that have no single home in code.

- Startup validation. "Validate before the first write"
  (`docs/node-architecture.md:25-92`) is spread over three modules: factory
  and geometry discovery and the emulator checks in `src/args.rs:31-160`;
  address discovery, the initial hash, the seed epoch and the watermark in
  `src/blockchain_reader/mod.rs:26-285`; image inspection and the pin
  comparison in `src/storage/open.rs:96-172`, `:478-521`. The reader module is
  `pub` only because of it (`src/lib.rs:4-6`).
- The loop around the per-input rotation. The rotation itself has one home
  (`src/storage/advance.rs:353-436`); the loop that drives it is written
  twice, in the runner (`src/machine_runner/mod.rs:196-258`) and in
  `Positioner::cross` (`src/engine/machine_stf.rs:715-756`), with about ten
  lines in common.
- The epoch's local lifecycle (`docs/epoch-lifecycle.md:49-70`). No type holds
  it. It is read off four tables: an `epochs` row (sealed), a settlement row
  (computed), the next `epochs` row (settled), the completion cursor
  (complete). The manager derives it at `src/epoch_manager/mod.rs:188-204`,
  the runner at `src/storage/advance.rs:175-177`.
- The window-root coordinate. Three formulas for one height:
  `src/storage/rollups_machine.rs:213-215` from a constant, and
  `src/engine/dispute.rs:122`, `:376-378` from the pinned structure. They
  agree only because the production structure is pinned.
- The lane. The doc section does not name its file; it is the second half of
  `src/provider.rs` (`:352-901`).
- G and the gas headroom. Hand copies of deployment values with no check:
  `src/escalation.rs:22`, `src/provider.rs:368-380`.
- "Every machine store, load and clean goes through the boundary store"
  (`src/storage/snapshots.rs:4-5`, `docs/node-architecture.md:292-293`). The
  engine loads on its own at `src/engine/machine_stf.rs:167` and `:314`,
  seeding at `src/storage/open.rs:121` and `:348`, and removals happen in the
  bindings' `Drop` (`machine/rust-bindings/cartesi-machine/src/stored.rs:105-117`).

Concepts that exist only in code.

- The clone chain: `AdvanceBatch` and the rotation verbs, named for the
  runner and also used by dispute positioning with an empty record list
  (`src/storage/advance.rs:487-503`).
- Feeder modes (`src/engine/machine_stf.rs:57-76`). `Scratch` is the
  placeholder `resume` installs and never feeds in production; its feeding
  arms are test and measurement support compiled in, because `tests/` and
  `examples/` are other crates. `Collector::Stepped` is described as the test
  reference and is also the runner's and the crossing's mode
  (`src/engine/machine_stf.rs:228`), where it only skips a collection.
- Missed obligations: four waits that mean the node already failed to take
  part, logged at ERROR every tick (`src/hero/planner.rs:57-70`,
  `src/hero/actor.rs:260-268`). No doc names them.
- The `settled` flag of the runner's plan (`src/storage/advance.rs:41-43`): a
  consensus rule the runner knows, used only by the free-space floor.

Two mechanisms serving one concept.

- Two restores for one rejected input in the runner: the stf reloads the
  checkpoint privately (`src/engine/machine_stf.rs:304-330`), then the
  rotation closes that machine and opens a fresh shared clone
  (`src/storage/advance.rs:416-436`). Two loads; the first serves a few
  reads and is never run.
- Two decoders of the HTIF manual yield: from the live register
  (`src/engine/machine_stf.rs:127-140`) and from a proof's data block
  (`src/storage/rollups_machine.rs:119-129`). The same predicate, "awaits
  input" and "settles", written twice against raw `sys` constants, each
  mirroring a different authority (the step; the consensus's validity proof).
- Two store identities: `node_metadata` and `sling_config`. One guard overlaps
  another: the pinned structure spans are code constants whose change already
  requires a `COMMITMENT_SEMANTICS` bump.
- Two walks of the tournament tree: the reader's fold and the recovery walk
  (`src/epoch_manager/recovery.rs:76-102`). Defended (section 5).
- Two sorts of logs into chain order, with different keys and checks:
  `src/chain.rs:194-203` and `src/tournament/reader.rs:377-383`.

One mechanism serving several concepts. These are where a rule written for
one concept could be applied to another.

- `epoch_snapshot_info` is the runner's cursor (its newest row), the replay
  floors of dispute positioning, each epoch's start state, the padding of the
  level-0 frontier, and the boundaries a crossing publishes. What keeps them
  apart is argued in section 6.
- `sling_nodes` holds the runner's window roots, which settlement needs, and
  the Hero's quartet cache, which nothing needs. A prefix rule tells them
  apart (`src/storage/dispute.rs:54-81`).
- `--snapshot-gap-inputs` is the disk-against-replay knob, the commit batch
  size, and the bound on the open tail a seal leaves
  (`src/machine_runner/mod.rs:13-17`).
- The `sling_config` row's existence is the "seeded" marker
  (`src/storage/open.rs:249-280`).

Doc statements the code does not match.

- `docs/node-architecture.md:87-91` says the root's initial-hash check panics.
  It exits 30 (`src/hero/actor.rs:289-300`), as `:170-172` of the same doc
  says. Only the pinned-table check panics (`src/hero/context.rs:241-258`).
- `docs/node-architecture.md:337-345` lists the rotation as close, clone,
  reload, removal. A rejected input also pays a private load and a root hash.
- `docs/dimensioning.md:243-245` prices a replayed input's overhead at 0.14 to
  0.2 s on macOS, the figure the same file flags elsewhere as due
  re-derivation (`:76-82`), here without the flag.
- `docs/node-architecture.md:173-180` credits the observer with the base-cycle
  and pinned-table checks; they are in `src/hero/context.rs:241-275`.
- `docs/node-architecture.md:469-472`: the Hero "opens its own connection".
  It holds two, and opens one more per positioned ruler
  (`src/epoch_manager/mod.rs:569`, `src/engine/machine_stf.rs:678`, `:813-818`).
- `docs/node-architecture.md:415-424` places every writer "in `storage/`" and
  says the discipline test pins where in-place writes and deletes may appear.
  The `sling_config` writer is `src/engine/config.rs`, and the test scans only
  the top level of `src/storage` (`src/storage/sql/discipline.rs:18`). A blind
  spot, not a violation: that file only inserts and selects.
- `docs/epoch-lifecycle.md:263`: cleanup is proposed when the tick selected no
  Hero action. The code proposes it only on a wait
  (`src/hero/actor.rs:259-274`); a terminal loss in a child while the root
  runs plans none. The lead is recorded at
  `docs/reviews/2026-10-13-prt-cyber-verification/HONEST-NODE-CONTRACT.md:125-130`.
- `README.md:288-290` (node) and `docs/node-architecture.md:84-86`: on
  Arbitrum the node "stops at startup". It exits 1
  (`src/blockchain_reader/mod.rs:274-281`), which the README's own supervisor
  unit restarts forever.
- `src/engine/mod.rs:24-26`, `src/engine/dispute.rs:10-13`, `:89-92`: "lazy
  interior folds" of recorded leaf runs. Runs are never persisted
  (`src/storage/advance.rs:87-89`); below window granularity the machine
  serves.
- `docs/node-architecture.md:599-608` covers an omitted finalized log that
  surfaces in a finalized event. It is silent on one that surfaces in the
  tail: the fold then fails every tick with Solid kept
  (`src/tournament/reader.rs:115-121`) until the event finalizes (`:168-181`),
  up to a finality lag with no Hero action.

## 3. Component interfaces

One row per component; the cards hold what each takes, gives and guarantees.
A boundary is real when it separates trust, crash consistency or concurrency.

| Component | Owns | Boundary | Knows what it should not |
|---|---|---|---|
| blockchain reader | the finalized chain record; sole writer of `inputs`, `epochs`, the watermark | real: trust (finality) | hosts startup discovery and seeding; the dev chain id |
| machine runner | the machine cursor, window roots, settlement capture, GC | real: concurrency and crash consistency against the manager, through the store | a consensus rule, for the disk floor |
| storage | the data directory: SQLite, the content-addressed snapshot store, staging | real: the crash-consistency boundary; the per-role files are a convention | seed-image validation (`src/storage/open.rs:96-172`) |
| engine | commitment geometry, quartet compute and cache policy, proofs | `DisputeSource` real; `Stf`/`Ruler` real for testability; the Positioner's place is reasoned in code (`src/engine/machine_stf.rs:655-659`) and contestable | a `Storage` inside the Stf; the runner's clone rotation |
| tournament | the observed dispute: fold, pinned reads, calldata builders | real: chain-shaped facts against actor-relative decisions | Hero-relative types in `domain.rs` |
| hero | the honest strategy: path, plan, prepare | planner against prepare is real (pure policy against machine work) | names quartets (`src/hero/action.rs:407`) |
| epoch manager | the completion cursor, settlement planning, bond recovery, the batch | real: single writer of the cursor that gates GC | a tuning constant borrowed from the observer |
| provider, chain, lane | RPC policy, head and log policy, stateless submission | lane real; the file split historical | nothing material |
| process shell | flags, startup order, workers, exit codes, the paging rule | exit and shutdown contract real; `args.rs` holding protocol checks is historical | deployment discovery |
| machine bindings | the FFI; the emulator's stored-directory rules as types | real seam | the node decodes HTIF past it, twice |

Historical in full: `src/storage/rollups_machine.rs` (a machine handle, the
validity proof and two geometry helpers in one file named after the
prototype) and `src/arithmetic.rs` (eight lines; one helper is
`saturating_add`).

## 4. Proposals

Each is an argument: premises, evidence, what it buys, what it costs, what
would reopen it. The last sentence of each says what the refutation pass did
to it.

### 4.1 Before the audited release

**B1. Measure the per-input cycle on Linux XFS, and make the benchmark able
to.** Premises: the dimensioning's claim that inputs alone no longer outrun
the root join holds below 36 ms per input (`docs/dimensioning.md:83-97`);
every figure is macOS; a lead says Linux is well above it (section 7).
Evidence: `examples/measure.rs:369-454` times 256 inputs, all accepted or all
rejected, in total only; its all-rejected run never leaves its durable seed,
so it never clones a just-closed directory; its scratch space is
`std::env::temp_dir()` (`examples/measure.rs:130`), which on Linux is `/tmp`
and may copy instead of reflink; its output names no host, filesystem or
emulator. Change: an explicit scratch directory (or a refusal when it is not
on a reflink filesystem), an alternating run, page-fault and block-I/O deltas
from the `getrusage` call it already makes (`examples/measure.rs:666-680`), a
run with a deep `inputs` table, and one header line with host, filesystem and
emulator version. Buys: the number the reference price, the drain and the
default gap follow from, on the platform that ships. Costs: benchmark code
only. Refutation: the benchmark facts were confirmed by two cards; the
measurement list and the decision rule were amended (section 7).

**B2. Replace the runner's per-batch `COUNT(*)` with the dense-log bound.**
Premises: the plan needs only the epoch's input count, and inputs are dense
from zero in every epoch, for every writer, by a checked invariant
(`src/storage/ingest.rs:49-93`), so the count is the last index plus one.
Evidence: `input_count_in` scans the epoch's whole index range
(`src/storage/advance.rs:126-133`); it runs once per batch, once more on every
idle poll and at each roll (`src/storage/advance.rs:154`, `:170`), and nothing
caches it. Measured twice for this review on a table of this shape with 2^24
rows (SQLite 3.54, one laptop, warm cache): 0.23 s per call, against well
under a millisecond for `MAX(input_index_in_epoch)`. The scan is per batch
and counts ingested inputs, so per input it is 0.23 s over the gap: 3.6 ms at
the default 64, a tenth of the threshold; 29 ms at a gap of 8; 230 ms at a
gap of 1, which the flag accepts and the docs recommend to heavy applications
(`docs/dimensioning.md:248-252`). In a flood the reader runs ahead of the
runner, so nearly every batch pays the full scan: about 17 hours over a full
epoch at the default gap. The figure is a warm laptop's; the rotation
competes for the same page cache. The benchmark cannot see any of it: it
runs 256 inputs. Change: `COALESCE(MAX(input_index_in_epoch) + 1, 0)`; the
empty epoch is reachable on every fresh open epoch. The contiguity asserts at
`src/storage/advance.rs:200-215` still catch a hole. `Storage::input_count`
(`src/storage/queries.rs:120-129`) has the same shape. Reopens: if the log
ever stops being dense. Refutation: survived; the `COALESCE` and the wider
list of call sites are the refuter's.

**B3. Make this release's emulator re-pin decide the store's fate.**
Premises: the docs list the emulator among the things a data directory is
refused for (`docs/node-architecture.md:247-248`, node `README.md:368-370`);
the pin is `format_emulator_version(Machine::version())`
(`src/engine/config.rs:56`), which is `major.minor.patch`. The emulator's
compile-time label would not help: the pinned test3 tag carries the label of
test2. What else guards a change inside one version number: the MARCHID and
pristine-uarch checks at every start, which do catch an interpreter change,
since the interpreter is compiled into the pristine uarch. Not caught: a
change in native-only code (delivery, the hash tree, dirty-page tracking, the
collectors), which is what moved between the last two test tags. A stale
window root is then wrong only if the old build was wrong, which is the case
a fix exists for; nothing recomputes it before the join. Exposure: a
directory built on a test tag and kept across the re-pin to the final
v0.23.0. Change: at that re-pin, bump `COMMITMENT_SEMANTICS` unless the diff
between the tags is shown not to touch state; correct the fixture message
that tells an author an emulator change needs only regeneration
(`tests/engine_machine.rs:88-95`); optionally a test that pins the emulator
source commit beside the stamp and fails until its author decides, as
`SCHEMA_PIN` does for the schema (`src/storage/sql/schema.rs:109-123`).
Costs: a decision per re-pin. Reopens: if test tags are never run on kept
directories. Refutation: survived, narrowed; the first draft's "interpreter
change" was wrong, and a separate hash pin over the fixtures was refuted as
mostly false alarms.

**B4. Sharpen the per-input statements in the docs.** The docs already flag
their figures as macOS and due on Linux (`docs/dimensioning.md:76-82`,
`docs/todo.md:18-27`, `:41-46`). Three additions: the flag is missing at
`docs/dimensioning.md:243-245`; the rejected path's extra load is missing at
`docs/node-architecture.md:337-349`; and the Linux lead belongs beside the
threshold, since it says which way the measurement may go. Docs only.
Refutation: survived, reworded; the first draft implied the docs overclaim.

**B5. Detector groundwork, without the tool.** (a) `docs/todo.md:61-66`
plans to tell integrators to run two or more nodes as sentries. With every
sentry slot held by a sling node, a state all sling nodes share is unanimous;
sentries may claim before staging, and a unanimous result is accepted in the
block it is staged (`cartesi-rollups/contracts/src/DaveConsensus.sol:198-221`,
`:254-261`, `:475-477`). What that removes is the staging period, which is
the only window guaranteed against a claim that joins in the last block
before closure; a claim an operator joins early is visible a root allowance
ahead either way. The advice should require one slot not held by a sling
node, and price it: a slot that never claims, like no sentries at all, puts
the whole staging period on every honest epoch, and no sentries also drops
the dissenting vote after a lost root. Whether the detector should hold that
slot is an open question (section 8); it would make the detector a signer.
(b) Write the detector's specification as a living doc section:
what is claimed on chain and where, the alarm classes, the deadline each
protects (section 8). (c) Land the harness test of a second node on another
key settling an epoch the first node won and left. It exists as an
uncommitted patch, no test in the tree runs a second key
(`src/harness/mod.rs:464-469`), and the README's upgrade and signer-change
procedures rest on it (node `README.md:130-132`, `:320-327`). Refutation:
survived; the cost of zero sentries and the README lines are the refuter's.

**B6. Three small operator fixes.** (a) Bound `--polling-interval`
(`src/args.rs:253-256`): at 0 all three workers loop without sleeping, two of
them against the RPC endpoint, and a value near G makes every response late;
no doc gives a range, and the gap flag beside it has one (`src/args.rs:265`).
(b) Say in the README and in `docs/node-architecture.md:84-86` that the
Arbitrum refusal exits 1, or make it terminal. (c) Fix the "panic" wording at
`docs/node-architecture.md:87-91`. Refutation: survived.

### 4.2 When next touched

**N1. Keep the working directory across accepted inputs.** Today an accepted
input closes the working clone, clones it, and continues on the clone
(`src/storage/advance.rs:366-377`): a new inode with nothing in the page
cache. Swap the roles: clone the closed directory to make the checkpoint, and
reopen the directory just closed. Both hold the same closed state. This is
the shape the emulator's own driver uses in its stored revert mode, and the
shape another repository's watchdog copied from it. Checked: no file is
hard-linked between the two and then written (the emulator hard-links only
files without write bits and refuses to map those for writing); the types
allow it; a crash leaves the same staging entries. Buys: an input is cold
only when it is first in its batch or follows a rejection. Costs: about six
lines; the published checkpoint is then a clone nothing has read, and the
rejected path gets colder, because the reload and the next clone both come
from that unread checkpoint, which makes N2 worth more. Take it only if B1
shows cold reads dominate on Linux. Refutation: survived; "cold only when"
stays a lead until measured.

**N2. Drop the private reload on a rejected input in the runner's mode.** In
the runner's and the crossing's mode the revert fires only at the end of the
big-machine run, and afterwards the ruler asks only whether the machine
awaits input, whether it is terminal, and its hash: all known without a
machine. The reload (`src/engine/machine_stf.rs:314-324`) answers them and is
discarded by the rotation. Change: keep the poisoned machine, answer from a
flag, and let the rotation drop it as it already does. Buys: a private load,
two or three root hashes and a destroy off every rejected input, the
adversary's cheapest input. Costs: a mode split (the dispute path keeps the
reload, since leaf builds go on stepping the restored machine); the reload's
check against the revert root goes, and the crossing has no other check after
a rejection; `docs/computation-hash.md:214-216`, `:229-230` say every path
reloads. Measure first. Refutation: survived with these amendments.

**N3. One startup module.** Move deployment discovery, the compatibility
checks and the seed decision out of `args.rs` and `blockchain_reader` (about
410 lines and their tests) into one module; `args.rs` keeps flags and the
call order; image inspection and the pin comparison stay in storage, under
the lock. Buys: a home for "validate before the first write", and one file
that lists the node's whole contract surface, which the extraction question
and the detector's specification both need. Costs: a move. The public
surface moves and does not shrink: the address book is a value the reader
and the manager keep at run time. Refutation: survived, corrected on size
and on the public surface.

**N4. Untangle engine and storage in three small moves.** (a) `Feeder::Store`
takes the payload of the one window it feeds instead of a `Storage` handle
and merges with `Advance` (`src/engine/machine_stf.rs:64-69`, `:395-401`): no
storage inside the Stf layer, one connection per positioning gone. The merged
feeder must carry an optional payload, and its proving path must emit an
empty availability proof for any other window, as `Store` does on padding
windows today. (b) The window-root coordinate moves from
`src/storage/rollups_machine.rs:213-232` into the engine as one helper over
the pinned structure, and `fold_runs` out of `engine/dispute.rs`, which the
ruler imports (`src/engine/ruler.rs:41`), keeping its public path. (c)
`src/engine/config.rs` does SQL on a table whose DDL is storage's; put it
where the discipline test sees it. Refutation: survived with these
amendments.

**N5. One HTIF decode.** One function from (iflags.Y, tohost) to the pending
manual yield's reason, used by `awaits_input`, `terminal_fixed` and
`settles`. The bit layout is the emulator's and could live in the wrapper;
what the predicates mean stays in the node. Buys: "an epoch can start here"
and "this state settles" cannot drift. Reopens: if the step and the
consensus's validity proof ever read the yield differently. Refutation:
survived; the two spellings of the accepted reason are one value by
definition.

**N6. A tripwire for the convention the storage argument rests on.** A Hero
exists only for the cursor's epoch, after the runner rolled it. The second
half is enforced by data (`src/epoch_manager/mod.rs:204`, a row that commits
with the next epoch's start). The first is statement order
(`src/epoch_manager/mod.rs:148-149`): assert that a reused Hero's epoch is
the cursor's (`src/epoch_manager/mod.rs:568`). Three lines. Refutation: half
refuted. A second assert, in `publish_crossing`, that the runner's cursor is
past the batch's epoch, would fire in about fifteen tests and the measurement
example, which cross on stores that never rolled, and it duplicates what the
data already guarantees.

**N7. Move the Hero's types home.** `SemanticSnapshot`, `ParentLink`,
`LocalCommitmentStanding`, `Engagement` and `GcIntent` live in
`src/tournament/domain.rs` and nothing in `tournament/` builds them. Delete
`ParentLink.parent_match` and `parent_side`, which nothing reads, and the
comment that says the planner relies on them (`src/hero/context.rs:126-129`).
Refutation: survived, narrowed; `InnerWinner` stays, since the observer
builds it and validates through it.

**N8. Name the lane.** Its own file (`src/provider.rs:352-901`, with its half
of the test module); rename `SendVerdict::Underpriced`, which is a healthy
wait behind a pending transaction, while `SubmissionErrorKind::Underpriced`
ends as a failure. Refutation: survived.

**N9. Small deletions.** `add_and_clamp`, which is `saturating_add`, and
`max_uint` into the engine's constants, which ends `src/arithmetic.rs`;
`serde_json` to dev-dependencies and the duplicate dev `hex`; the `.part-*`
arm of the startup sweep, whose producer left before this store format
existed; the bindings' `remote_machine` feature, which binds nothing, and the
JSON-RPC archive the build still produces for it; the stale comments of
section 2. Refutation: survived, corrected: the first draft would have
deleted a file that tests and the engine import.

### 4.3 Not worth it

- One verb for both per-input loops, as a prerequisite to N1 and N2. Refuted:
  the rotation already has one home, N1 lives inside one of its verbs and N2
  inside the stf. The loops differ in sampling, recording, payload source,
  shutdown, paging and how they end; a flag would move the branch.
- A hash pin over the commitment fixtures. Refuted: they change with
  encodings, images and new tests far more often than with semantics (ten
  changes against one bump since the stamp exists). B3's message fix is the
  useful part.
- Dropping Solid on any fold error in the Foam tail. Demoted: the error does
  not say where the missing log is, and a reorged tail or disagreeing
  backends, both inside the trust model, produce the same error with Solid
  intact; the change would turn each into a cold refold. A version that waits
  a finality lag would be sound and is not worth its code. The doc gap is
  worth a sentence (section 2).
- Persisting Solid to spare the cold refold on restart. A stated trade-off
  (`docs/node-architecture.md:593-600`): its loss costs reads, and a bad
  prefix does not survive a restart.
- Merging the recovery walk into the reader's fold. Different retention (the
  reader drops resolved children; recovery needs exactly those), and recovery
  must run without a Hero.
- Bounding a settled epoch's recovery walk at the next seal. It would spare a
  directory seeded from the template some log reads; the README already
  gives the remedy for long histories, seeding from the settled state (node
  `README.md:453-458`). Reopens if the walk is measured to matter.
- Not storing, or pruning, inputs below the seed or the completion cursor.
  In production nothing reads them but the reader's own whole-table count
  (`src/storage/queries.rs:111-116`); the end-to-end harness reads them by
  epoch. The bytes were paid for in gas. Reopens with seeded deployments that
  have large histories; needs numbering derived from the last input first.
  That count grows with the application's whole history (0.05 s at 2^24
  rows), off the clock path.
- Splitting `sling_nodes` into window roots and cache. One concept (a Merkle
  node by coordinate); the overlap is a free cross-check of the runner by the
  Hero. Reopens on a second incident with the prefix rule.
- An explicit runner cursor row. The data already keeps a crossing's row from
  sorting newest (section 6).
- Planning bond recoveries only on ticks without a Hero action, to keep the
  scan off the action's path. Priced: the scan grows only with tournaments an
  adversary keeps open, at a bond each.
- Skipping the batch's last rotation. One clone and one load per 64 inputs.
- Probing privately only after a rejection. It keeps both shapes in the code
  and the adversary alternates. The probe taken for every input is a shape
  of its own; it is in section 7, to be measured, and not dismissed here.
- Checkpointing every k inputs and replaying on rejection. Rejection cost
  grows with k and the adversary alternates.
- Snapshot thinning. Recorded decision (`docs/node-architecture.md:349-360`).
- SQL triggers for the mutation classes; turning engine asserts into errors;
  a cargo feature for the scratch feeder or the AWS SDK; structured logs or a
  metrics endpoint in the node; staging after a root lost to a commitment
  with this node's final state; batching every due cleanup into one tick.
  Each is argued in its card.

## 5. Defended mechanisms

Things that look heavy and are justified. Each ends with what would reopen
it.

1. Content-addressed snapshots, published filesystem first, registered by
   write-once rows (`src/storage/snapshots.rs:100-134`, `:388-418`). A crash
   can orphan a directory and can never leave a row naming a missing or
   unverified machine; replay is idempotent, so there is no recovery
   protocol. Reopens if the store stops being content-addressed.
2. `synchronous = FULL` (`src/storage/open.rs:32-38`). A commit gates an
   external effect, the removal of directories. Reopens if GC stops deleting.
3. Panics, not errors, on a write-once disagreement
   (`src/storage/dispute.rs:160-181`, `src/storage/advance.rs:615-625`). The
   tick loops retry an error forever; a silent loop while a clock runs is the
   worst outcome.
4. Three workers on one database, one writer file per role. The boundaries
   are concurrency and crash consistency. Channels would add memory whose
   loss matters.
5. `Volatile` and `Durable` (`machine/rust-bindings/cartesi-machine/src/stored.rs`).
   The emulator's two-part rule (a directory is a machine again after
   destroy, and durable after sync) as ownership: nothing can clone, load or
   sync a directory a machine still maps. Reopens if the emulator gains an
   in-process checkpoint.
6. Solid and Foam, with the join taken from Solid
   (`src/hero/actor.rs:213-245`). The join is the one stale call that is not
   harmless. Reopens if joins gain a cancel path.
7. Refold instead of repair. A restart and a contradiction take one path; no
   reverse-apply code exists. Costs reads on long disputes.
8. The stateless lane with its price retry (`docs/node-architecture.md:721-782`).
   The retry exists because a fresh quote does not move the market tip and a
   pool replaces only on ten percent more of both fees. Reopens if a required
   relay documents same-nonce admission.
9. Validators in front of every chain-reachable engine assert. Checked site
   by site in `cards/engine.md`; the two unfronted asserts are documented
   trust (the root's base cycle, the emulator's per-input budget).
10. The level-0 frontier fold and persisted window roots
    (`src/engine/dispute.rs:148-172`). Nodes above window granularity cross
    the input frontier; nothing else serves them without a whole-epoch replay.
11. `Collector::Stepped` and the toy machine with its literal leaf oracle.
    The independent lineage for the bulk collector and for geometry.
12. The fixed snapshot gap. The adversary chooses the input count, so any
    spacing that widens with it moves cost from disk onto the clock.
13. No migrations: two hand-bumped stamps and a schema hash pin
    (`src/storage/sql/schema.rs:12-20`, `:109-123`).
14. The source-level discipline test. A substring count is a blunt tool; the
    write-once checks themselves live in the writers, and its 95 lines only
    pin where in-place writes and deletes may appear. Its blind spot is in
    section 2.
15. The in-memory recovery tree with pruning
    (`src/epoch_manager/recovery.rs:51-102`, `:173`). A cache whose loss
    costs one walk; its one premise is that a finished tournament creates no
    child.
16. One paging rule with two timers: one per condition, one per planned call
    (`src/escalation.rs`, `src/epoch_manager/mod.rs:643-679`).
17. Startup that validates before it writes, and the exit-code contract.
18. Cleanup planning (`src/hero/gc_planner.rs`). A root finishes only with no
    live matches, so an honest commitment behind expired Sybil matches
    advances only after their elimination.
19. Rebuilding the seed image's hash tree instead of believing it
    (`src/storage/open.rs:189-198`, `:343-355`).
20. Re-observing after machine work (`src/hero/actor.rs:186-200`). A leaf
    build takes tens of minutes; a child may finalize meanwhile.

## 6. The storage schema map

Threads: reader, runner, manager (the Hero runs inside the manager's task),
and setup before the workers start. Every public storage operation is one
transaction (`src/storage/open.rs:426-451`); no transaction spans machine
work or an RPC call.

| Table | Class | Writer, and what shares its transaction | Readers | Invariant it carries | After a crash | Derivable from | Loss costs | Deleted |
|---|---|---|---|---|---|---|---|---|
| `inputs` | append-only log | reader; with `epochs` and the watermark (`src/storage/ingest.rs:21-33`) | runner (payloads, count), Hero (payloads), reader (count, last) | dense from zero in every epoch | whole chunks only | chain | rebuild | never |
| `epochs` | append-only log | reader; same transaction | reader, runner (sealed?), manager | dense from 0; an epoch ends at its bound | whole chunks only | chain | rebuild | never |
| `latest_processed` | monotonic watermark | reader; same transaction; seed | reader | both logs are complete through it | consistent with both logs | chain | rebuild | never |
| `epoch_snapshot_info` | write-once cells, pruned | seed (with the watermark, cursor and pin); runner per batch (with the batch's window roots); runner at the roll (with the settlement row); Hero's crossing (alone) | runner (newest row is its cursor), Hero (floors, epoch start, frontier padding), GC | a row names a directory its first publisher root-verified and synced before the row committed | a directory may lack a row, never the reverse | re-execution | newest row: one batch replay; `(e, 0)` of the manager's epoch: panic | runner GC, epochs below both cursors |
| `sling_nodes` | write-once cells, pruned; two populations | runner per batch (window roots, with the boundary row); Hero (cache fanout) | runner at the roll, Hero | the prefix `shift < inputs` at the root stride is complete | batch rows whole or absent | window roots: re-execution of the epoch; cache: re-execution on demand | window roots: rebuild; cache: clock time | runner GC |
| `settlement_info` | write-once cell per epoch | runner at the roll; with `(e + 1, 0)` (`src/storage/advance.rs:525-539`) | manager | exists exactly when the epoch was rolled; its proof reconstructs its final state | atomic with the next epoch's start | window roots and the final boundary, but only the roll computes it | rebuild | never |
| `epoch_completion` | monotonic cursor | manager (`src/storage/completion.rs:20-41`); seed | manager; runner (GC bound) | every epoch at or above it keeps its rows | - | finalized settlement and bond scan | a reset below collected epochs panics the Hero | never |
| `node_metadata` | write-once identity | setup, with the schema (`src/storage/sql/schema.rs:39-47`) | setup | the binary reads this store format and these semantics | never a schema without a stamp | constants | exit 40 | never |
| `sling_config` | write-once identity; also the seeded marker | setup, last statement of the seed transaction (`src/storage/open.rs:357-363`) | setup; every worker for the stride or chain id | the directory was built for this deployment, emulator and table | absent means unseeded | flags, chain, binary | reseed | never |

Fingerprints.

| What | Set by | Compared | Exit |
|---|---|---|---|
| `STORE_FORMAT` | hand bump; the schema pin forces the question | `src/storage/sql/schema.rs:66-72` | 40 |
| `COMMITMENT_SEMANTICS` | hand bump; a fixture divergence raises the question, a re-pin does not (B3) | `src/storage/sql/schema.rs:73-79` | 40 |
| application, chain id | flags | `src/storage/open.rs:484-500` | 30 |
| initial hash (column `template_hash`) | chain | `src/storage/open.rs:501-511` | 30 |
| consensus, emulator version, geometry, structure | chain, linked library, constant | whole-row equality, `src/storage/open.rs:512-519` | 40 |

The emulator version is the weak one (B3). The column `template_hash` holds
the deployment's initial hash, not the image that seeded the directory; the
name misleads and is worth changing at the next store-format bump.

SQLite and the snapshot directories. Publication: stage a clone under
`.work-<pid>-<seq>`, verify its root against the content key, sync, rename
without replacement, then commit the row (`src/storage/snapshots.rs:100-160`,
`src/storage/advance.rs:447-472`). An existing destination is adopted after a
sync, without rehashing. Collection is the mirror: delete rows and compute
the orphaned states in one transaction, remove directories after it commits
(`src/storage/advance.rs:250-256`, `src/storage/snapshots.rs:424-458`).
Startup sweeps staging under the directory lock, before seeding
(`src/storage/open.rs:306-309`). A row may assume a complete, synced, closed
machine at its path. Only the runner's cursor insists on it and panics;
positioning skips a vanished directory and panics on a root that does not
match its row. A collection interrupted in a removal leaves a torn orphan.
Adoption would not accept it, since its sync opens every file the directory's
configuration names; a state that recurred there would stall publication with
an error that pages. The argument that a collected state never recurs
(`docs/node-architecture.md:443-447`) is what keeps that stall unreachable;
the doc states it for concurrency alone.

What keeps the uses of `epoch_snapshot_info` apart: a Hero for epoch `e`
exists only once `settlement_info(e)` exists, which commits with `(e + 1, 0)`,
so a crossing's rows never sort newest; equal rows absorb; GC takes only
epochs below both cursors, and the manager drops the Hero before advancing
its cursor. All but the last are enforced by data (N6).

Outside readers of the store: the end-to-end harness reads four tables and
one snapshot path through the `sqlite3` tool
(`test/e2e/rollups/dave/node.lua:161-294`), and the node README tells
operators to seed from another node's `snapshots/0x<hash>`. Nothing else.

## 7. The per-input cycle

The cycle. For each input the runner holds one closed checkpoint (the
pre-input state) and one working clone mapped shared and mutated in place.

- An accepted input: a root hash for the revert root; the run, with a root
  hash per active stride chunk and one for the idle tail; one more root hash
  at the record; then close, clone the closed directory, open the clone
  shared. The checkpoint it replaces is removed unless it is the batch's
  durable base.
- A rejected input: the same run, at whose end the stf loads the checkpoint
  privately, drops the poisoned machine and removes its clone, and checks the
  reload's root; the window's remaining samples are hashed on that reload;
  then the rotation closes it, clones the checkpoint and opens the clone
  shared.
- A batch: a clone, a shared load and a verifying root hash at the start; at
  the end the working clone the last rotation opened is dropped unused, and
  the checkpoint, unless every input was rejected, is loaded privately,
  verified, synced and renamed; then one SQLite commit.

Call sites are in `cards/per-input-cycle.md`.

Why a clone per input. Rollups semantics require a rejected input to leave
no trace, so every input needs a rollback point until its outcome is known.
The emulator's C API at the pinned commit has no in-process checkpoint or
rollback; fork exists only for the JSON-RPC remote machine, which the Rust
bindings do not bind (`cards/machine-bindings.md`) and which refuses a
machine with shared backing stores. The emulator's own driver uses that fork
by default and a stored clone otherwise. That leaves the node two rollback
points. A copy-on-write clone of a closed directory keeps an accepted result
and pays filesystem work on every input: today's shape. A private load of
the closed directory changes nothing on disk, so a rejection costs nothing
to undo, and an accepted result must be produced again on a shared load: the
node uses it today only to restore after a rejection. Durability depends on
neither: per-input checkpoints are volatile already, only the gap's boundary
is synced, and a crash replays one batch. The per-input clone buys rollback
and nothing else.

What it costs, and what is known.

| Figure | Value | Source and status |
|---|---|---|
| Whole time per input, accepted and rejected | 24.2 and 21.1 ms; the docs round to 26 and 22 | macOS, APFS, echo, v0.23.0-test3; `docs/measurements/measurements.md:60-63` |
| Rotation alone | about 15 ms | macOS probe; out of tree |
| First input on a fresh clone, cold and warm | about 10 and 2 ms | macOS probe; out of tree |
| Load, first root hash, root hash after the input | 2.2, 3.0, 10.0 ms | upstream, Linux XFS, fresh clones of a template; a lead |
| Processing an input on a fresh clone, cold and warm | about 40 and 10 ms | upstream, XFS and Btrfs; a lead; the text does not say whether root hashes are inside |
| Destroy, removal of the clone | 0.8, 7.2 ms | upstream, XFS; a lead |
| Per-batch input count at 2^24 inputs | 0.23 s per batch: 3.6 ms per input at the default gap, 230 ms at a gap of one | measured here (B2) |

The upstream figures are on unstated hardware, on fresh clones of a clean
template and not on a chain of just-closed directories, and with a build
later than the pin. Added by us, they come to 50 to 65 ms per input, and
that sum is neither a floor nor a ceiling. Not a floor: their input takes
10 ms warm where ours takes 2.3, the same ratio of cold to warm at four
times the scale, while the loads agree; if the scale is their image, our
cold input on XFS is nearer 10 ms and the whole nearer 22 to 36 ms. Not a
ceiling: the sum holds no clone, no write-back of a dirty source, no second
load on a rejection and no per-batch term. They are a reason to measure, not
a result.

Why Linux may differ. The cold clone is not the difference: a clone is a new
inode with an empty page cache on APFS too, and that cost is already inside
the macOS figure. What is specific to Linux is that a reflink first writes
back the source's dirty pages and waits for them, so each accepted input
pays a synchronous write of what the previous one dirtied, and that both
that write and the cold reads go to a device whose I/O a cloud volume
provisions.

The threshold. `(C + G) / 2^24` is 36.07 ms where C is a week (1.73 ms on
the testnets); half the root allowance over 2^24 is 18.27 ms. If Linux
measured about 60 ms: inputs alone outrun the root join again, at about ten
million inputs (about 3.0e11 gas at 30,000 per input); a full epoch drains
11.6 days, more than C; the runner tops out near 17 inputs per second, not
40; and the spill-epoch bound at 18 ms loses its premise. The crossing does
not bind either way: 63 inputs at 60 ms is under four seconds of G.

Alternatives.

| Shape | Per-input filesystem work | Cold inputs | Crash consistency | Complexity | Reading |
|---|---|---|---|---|---|
| Today: continue on the clone | close, clone, load, remove | all | baseline | baseline | keep for alpha.8 |
| Swap roles: reopen the closed directory, the clone is the checkpoint (N1) | same | first of a batch, and after a rejection | same | about six lines; upstream's own stored shape | take if cold reads dominate |
| Also drop the private reload on rejection (N2) | a load, two or three hashes and a destroy fewer per rejection | same | same; one check on a self-made clone goes | a mode split in the stf | measure first |
| Probe every input on a private load of one working directory; re-run an accepted input on a shared load of it, in place, and check its root against the probe's | none per input; one clone per batch | none | same: the directory is volatile and written only by an accepted re-run; a crash or a failed re-run replays the batch | a new runner loop; no rotation and no checkpoint | the second shape: a rejection costs a load and a warm run, an accepted input two of each; measure it in the warm control |
| The same, with a cycle cap past which an input takes today's path | as above for cheap inputs | as above | same | both shapes in the code | bounds a heavy accepted input at today's cost plus the cap |
| Probe privately only after a rejection | none in a rejection run | the input after an accepted one | same | high | not worth it: the adversary alternates |
| Run privately, store the machine whole on acceptance | none on rejections | none in a rejection run | same | medium | not worth it: a full image write per accepted input |
| Checkpoint every k inputs, replay on rejection | 1/k | 1/k | same | medium | not worth it: the adversary alternates |
| The remote machine's fork | none per input; a whole-image store per gap, since a forked machine cannot share its files | none | same durable points | a second process, an API the bindings lack | not for the node: a store is not a reflink, so every boundary would cost a full image of disk |
| A mark the machine can return to, in memory, with shared files | none per input; a clone and sync per gap | none | same durable points; a crash still replays one batch | an emulator feature | the structural fix; an upstream ask, at arm's length |

No scheme built from clones alone makes a run of rejections warm: running
shared needs a fresh inode for every attempt, and a rejection poisons the
inode the attempt just warmed. So N1 warms accepted streams only, N2 trims a
rejection without warming it, and the cheapest dismissal an application
offers is most naturally a rejection.
The private probe is the shape that makes rejections cheap with today's API.
Its price is a second run of every accepted input: warm, and for an input
the rotation dominates cheaper than the rotation it replaces, but for an
input whose own work dominates it doubles that work, which is the
application's throughput contract. The cap bounds that, at the cost of two
shapes in the code.

What must be measured on Linux XFS (`reflink=1`), to decide.

1. The sustained rate, inputs per second over at least 10^6 inputs, for
   accepted, rejected and alternating streams through the production runner,
   on local NVMe and on a cloud volume at baseline provisioning. The
   threshold bounds a sum over an epoch, so the statistic is total time, not
   a median: per-batch terms, burst credits and stalls live in the tail.
   Scratch and data on the measured filesystem (B1); kernel, the
   filesystem's copy-on-write extent size hint, volume class, visible cores
   against the CPU quota and the hash-tree thread settings in the header.
2. The same with the whole epoch already in the `inputs` table, before and
   after B2, at the default gap and at a gap of one.
3. Per phase, on a raw chain that mirrors the rotation: destroy, clone, shared
   load, first root hash, run to the yield, sampled and final root hashes,
   removal; with major faults, bytes read and bytes written per input.
4. Three controls. The floor: one open machine fed in sequence with no
   rotation, which bounds any rollback in memory and says whether any shape
   reaches 18 ms. The warm control: the N1 shape. The private probe.
5. Slope against pages touched and pages dirtied, on an image with a real
   working set and more address ranges than echo: cold reads follow the
   pages an input reads, a clone is three files per range, and echo is the
   floor of both. Report overhead plus slope, so an application can be
   placed.
6. Drift over a long clone chain: time and disk per snapshot at 10^3, 10^4,
   10^5 inputs.
7. Under a memory limit, and while a Hero leaf build shares the cores.
8. The publication's sync at the gap, on the cloud volume.

Decision rule. Take the lowest sustained rate of the three streams on the
cloud volume, under contention, with B2 in, as time per input. Under 18 ms,
nothing here binds and the price follows from the next wall, as the docs
say. Between 18 and 36 ms, a single epoch is safe and the drain is the
price. Above 36 ms, the reference price is again the gas for `(C + G) / t`
inputs, the docs' "no longer outrun" claims go, and the cycle is the binding
constraint. Then: if cold reads dominate and the accepted stream is the
slow one, N1; if the rejected stream is the slow one, no clone shape helps,
and the choice is the private probe or the upstream ask; N2 in either case
if the reload shows in the phases. On the testnets the threshold is 1.73 ms,
below one warm input: no shape passes there, and the docs already say those
deployments have no such price.

## 8. The detector sketch

A design sketch with its open questions, not an implementation. The leading
candidate, tested here and not ruled: a Lua program that runs one tick and
exits, on the pattern of the watchdog another repository ships for its
sequencer; a scheduler runs it, and its memory is on disk.

Purpose. The tournament and the node rest on assumptions: correct contracts,
a correct and live node. If one fails, a wrong claim can win a root. The
answer outside the system is a detector and a fallback, the guardian's
foreclosure inside the claim staging period. The detector is the only part
that can see a fault every sling node shares, so it must not be built from
sling. It never transacts, holds no key, and never opens the node's data
directory.

### 8.1 The candidate, tested

What speaks for it.

- It shares the least. It drives the machine through the emulator's own
  `cartesi` Lua module, so it has in common with the node the emulator and
  nothing else: no Rust FFI crate, no generated bindings, no RPC stack. A
  Rust executable, the first idea here, would have shared all three. The
  language boundary also makes copying node code impossible instead of
  forbidden.
- It needs no commitments. It compares final states, so it has no Merkle
  builder, no strides and no uarch: the part of the Lua client that once
  shared a blind spot with the node has no counterpart in it.
- Most of it exists. The watchdog (about 2,300 lines of Lua, with tests) has
  a reader that proves its view of the InputBox complete, a machine driver
  with accept, reject and terminal semantics tested against the reference
  CLI and against the node's seam machines, atomic checkpoint publication, a
  latch that is set before evidence is collected, a `tick` that exits 0, 1
  or 2, a lock, and a Prometheus text file.
- One tick has no alive-but-stuck state. Its retry is the next tick, and a
  test can run it at a chosen chain state and assert the exit status.
- Lua is already a language of this repository: version 5.4 is required,
  linted in `just check`, and the Lua client's event layouts are pinned
  against the compiled ABI (`justfile:158-175`).
- In Lua the emulator's fork is one call away, which the node's bindings
  cannot reach (8.5).

What it costs.

- A second runtime in the release. The node is one binary; this needs Lua
  5.4, the emulator's Lua module and, as the watchdog does it, two native
  modules for HTTP and the filesystem, on the operator's host or in an image.
  The repository ships no Lua and builds no image today.
- Hand-written topics, selectors and decoders, where Rust would have had
  generated bindings. The pinning mechanism covers it, with its own copy of
  the check: the existing one imports the Lua client and accepts only static
  event words, so `InputAdded` needs another rule.
- The repository's Lua talks to a chain only through `cast` and `jq`
  subprocesses today. An operator tool should not need Foundry, so this is a
  new dependency either way (8.5).
- A port, not a copy, of the machine driver: the watchdog targets emulator
  v0.22, and v0.23 changed five behaviors on its paths (`sync_stored` on a
  mapped directory, `clone_stored` on a refused reflink, the clamp in
  `receive_cmio_request`, the error on a uarch that is not reset, the mode
  of `remove_stored`).

The candidate stands. Its independence is better than a Rust tool's by
construction, and its costs are packaging and a pinned ABI.

### 8.2 What carries over, what changes, what is new

Carries over, as generic code: the JSON-RPC client; the reader's rules
(indices contiguous from the head's count, a failed range halved and a
failed single block failing the tick, logs ordered by block, transaction and
log index, every payload naming the application and the chain); the machine
status classifier and the executor; the trust check on a starting image; the
store with its sync-and-rename publication; the latch, the evidence after
it, and `clear`; the error classes, exit codes, lock and metrics; and the
`replay` command, which attributes a divergence by re-deriving from another
trusted machine.

Changes for epochs.

- The target. Not a digest served for a block, but the upper input bound of
  the sealed epoch, from `EpochSealed`. The state compared is the machine
  root after the last input below that bound.
- Completeness. The bound is itself the chain's count at the seal, so the
  proof is contiguity plus reaching exactly the bound by the seal's block.
- Capped rollover. The tool follows the bounds and holds no cap logic; it
  must never execute past the newest bound, where the watchdog executes on.
- The head tag. Finalized, where the watchdog reads safe: a latch here can
  lead to a foreclosure, which is irreversible.
- The anchor. Every epoch's start is on chain as
  `EpochSealed.initialMachineStateHash`, so a start that is not the template
  is checked against the chain, which the watchdog cannot do for its own.
  The image's root must be hashed from its contents for that check to mean
  anything.
- A terminal application. Not the end of the tool's work: the epoch has a
  defined final state, the fixed point, which the node defends and which the
  tool compares like any other; the condition is reported as the guardian's.
- The budget seams. The same rule as the node's (the step reads only the
  pending yield); the watchdog already tests the node's seam machines, and
  the port must pin them again on v0.23.
- The outputs root. Compare it as well: it is one read of the machine's
  memory, it is the value that pays out, and what binds it to the staged
  state is the consensus's validity-proof library, which this review did not
  read.
- Dropped: the state sources, the sequencer's routes, the digest comparison.

New.

- Reading the claims: every `CommitmentJoined.finalStateHash` in the root
  tournament (in inner tournaments that field is an intermediate state); the
  root winner, from the `tournamentStanding()` view; every sentry's claim,
  which the consensus accepts for any hash and before staging; the staged
  state and outputs root; and the next `EpochSealed`, since acceptance has
  no event of its own.
- Views before logs. A stale event signature matches no logs and fails
  silently, so wherever the contracts offer a view (the staged result, the
  claim counts, the standing) the tool reads the view, and where it must
  read logs (the root's joins) it proves the read complete with the
  tournament's event counters.
- Hashing the compared state from its contents. A loaded machine takes its
  stored hash tree's word for every page it marks clean, in the node and in
  the tool alike, so a page changed without its mark keeps its old hash in
  both. Once per epoch, at the bound, the tool rebuilds the tree from the
  contents before it compares. The node cannot afford that per input; the
  tool can afford it per epoch, and it turns the likeliest shared defect
  into a disagreement.
- Deadlines read from the chain: the root join's own, the root's closure,
  and the staging block plus the period.
- A check of the deployment, at every pass since sentries can be rotated: a
  guardian exists; the staging period is at least a configured floor; every
  sentry slot is in a configured set; the emulator matches the deployed
  step; the application's validator is this consensus.

### 8.3 The tick

1. If latched, exit 2 without work.
2. Read the finalized head and the current sealed epoch with its bounds.
3. The head is the newest checkpoint: the machine after N inputs. If epochs
   settled since, take them in order, each as below.
4. Replay inputs from N toward the epoch's upper bound on a working copy,
   for at most the tick's budget, and publish where it stopped.
5. At the bound, rehash the machine from its contents and compare its root
   and outputs root with every claim on chain. A finalized claim that
   differs latches: an operator's join, the winner, a staged result, a
   sentry claim, or the next epoch's initial state. So does a closed root in
   which no commitment ends in the replayed state.
6. When the chain settles the epoch on the replayed state, the checkpoint
   becomes the baseline of the next epoch.
7. Warnings exit 1: no commitment yet ends in the replayed state; a finished
   root is not staged, or an acceptable result not accepted, past a margin;
   the application is terminal; the replay is behind what the root's closure
   allows.
8. Write the tick's record and the metrics file.

The budget in step 4 is the one departure from the watchdog, which replays
to its target in one tick. An epoch can hold 2^24 inputs, days of replay. A
tick that long cannot check anything else, and one kill loses it all.

### 8.4 What stays on disk, and why

| Kept | Why | If lost |
|---|---|---|
| The configuration | the deployment's identity; a tick must not be pointed elsewhere by accident | run `init` again |
| The baseline: the machine at the start of the current sealed epoch | the one state anchored on chain; everything else is rebuilt from it | `init` from the template or from any machine whose root the chain names |
| The head: the machine after N inputs of that epoch | a cache; without it a killed tick restarts the epoch, and in a flood never finishes | replay from the baseline |
| The latch and its evidence | an alarm must survive the process and be cleared by a person | the next tick latches again if the condition holds |
| The last tick's record and metrics | outputs | rewritten |

Nothing else, and nothing about time. Every duration is computed at each
tick from block numbers on chain, so deleting state can delay an alarm only
by replay time, and a replay that is behind is itself reported. The head is
the one addition to the starting position of "the checkpoint after the last
verified epoch and the latch": that position is right for epochs that replay
in a tick and wrong for the flood, where the checkpoint within the epoch is
what lets the tool finish at all.

### 8.5 Open questions

1. Rollback. Three options. The watchdog's stored executor is the node's
   rotation in its N1 shape, a clone before each input and the machine
   reopened shared: the cheapest start, and it keeps the emulator's clone,
   close and shared-mapping path common to the node and the tool, which is
   where the October review found its one high-severity lead. The private
   probe of section 7, on the tool's own directory: no clone and no second
   process, parity with the node under a flood, and every accepted input
   run on both of the emulator's mapping paths and compared. The emulator's
   fork: the machine in a server process on a private mapping, rollback in
   memory, a directory written only when the tick publishes, so no
   per-input filesystem work and a path the node does not take; its costs
   are a child process inside a one-shot tick, a process fork per input,
   and a whole-image store per publication, which two checkpoints can
   afford. All unmeasured. With the contents rehashed at each bound (8.2),
   the stored-tree defect is covered under any of them, so the choice is
   cost: this review's lean is the stored executor first, since it exists
   and is tested, and the probe when the node takes it.
2. HTTP. Vendor lua-curl and LuaFileSystem as the watchdog does (about ten
   thousand lines of third-party C and a build step), or use the emulator's
   new `cartesi.filesystem` module with a plain `curl` subprocess. The second
   is lighter and unproven.
3. Copy the chassis or share it. Copy. The generic part is about 1,500 of
   its 2,300 lines; the tick, the canonical advance and the start-up are
   specific to each side; sharing means a third repository or a submodule
   in two, and ties two release trains that the extraction question is
   trying to loosen. The cost of the copy is drift: a fix made in one and missed in
   the other. Record the source tree with the copy, and port the test
   vectors that pin the reader's rules. Reopens on a third consumer, or on
   the first fix that had to be made twice.
4. Throughput parity. If the detector can be outrun for less than the node,
   its blindness is the cheaper attack. Replaying only sealed epochs gives
   it the node's adversarial worst case (a backlog that arrives just before
   the seal) plus the staging period.
5. Finalized only, or latest for warnings. A staged state that differs is
   worth a warning before it is final when the staging period is short.
6. Payload integrity. The InputBox keeps each input's hash; checking every
   payload against it is one call per input. A separate provider for the
   detector is the cheaper defense, and an operator duty.
7. Chain-only participation checks (an operator commitment joined in time,
   not eliminated, its clock not near expiry) need a signer list and no
   machine. Start with the root only: its `commitmentStanding` view returns
   joined, final state, clock and deadline in one call, where following the
   operator through child tournaments would need the whole event fold, the
   largest thing the node has that the tool should not rebuild.
8. Whether the detector should hold the sentry slot that B5 asks to keep
   out of sling's hands, claiming only on a match. It would restore the
   short path for honest epochs and make the detector a signer with a key,
   against the rest of this sketch.
9. Whether a plain run to the yield, with a restore on rejection, reproduces
   the node's boundary hash in every terminal case on v0.23. The step says it
   should; the conformance tests must show it.

### 8.6 The no-sharing rule, in Lua terms

It must not `require` anything under `prt/client-lua` or `test/e2e`: the
client's machine driver and commitment builder are the oracle the node is
tested against, and an oracle shared with the detector is no second opinion.
Allowed: the emulator's module, its own namespace, a JSON library, and
whatever carries HTTP. Enforced in tooling: its own directory and module
namespace, a search path that does not reach the client's, and a step in
`just check` that fails on a `require` outside the allowlist. A starting
machine copied by an operator from a node's `snapshots/` is a file handed
over and checked against the chain, not a read of the node's store.

What stays common-mode regardless: the emulator; the semantics both must
implement, whose authority is the step; the image, unless built separately;
the provider, unless separate.

### 8.7 Alarm classes

| Class | Signal | Fallback | Deadline |
|---|---|---|---|
| The operator and the replay disagree | an operator signer's join ends in a state the replay did not compute: the mark of a defect every sling node shares, or of a detector fault | corroborate, then foreclose | before the root finishes, about a root allowance after the join, and then the staging period |
| A wrong state is heading to acceptance | the winner, a staged result or a sentry claim differs from the replay | corroborate, then foreclose | a transaction mined strictly before the staging block plus the period; none when every sentry already agrees |
| The honest claim is absent | no joined commitment ends in the replayed state | a validator online | the root join's own: the seal plus G, and what is left of C; closure is later than that by the refills |
| A wrong state was accepted | the next epoch starts from a state the replay did not compute | foreclosure, to stop deposits | already past |
| Settlement idle | finished and unstaged, or staged and unaccepted | any node with a funded key | none |
| The application is terminal | the replay's machine stops accepting inputs | foreclosure | none; deposits accrue |
| The deployment changed | a sentry slot outside the configured set; a claim before a winner exists | the guardian's judgment | before the root finishes |
| The detector is blind | replay behind what the root's closure allows; stale heads | fix the detector | the same as the class it hides |

The window depends on who joins and when. A claim an operator joins early
is visible about a root allowance before the root can finish. A fabricated
claim can join in the last block before closure, and the root then finishes
by time alone, so against that class the staging period is the only window
there is.

Corroboration. Foreclosure is irreversible, and when the tool and the node
disagree, both ran one emulator over one input list, so the fault is in one
side's own code, and the tool's is the newer. A fact read from the chain
alone (no claim joined, a slot rotated, settlement idle) may page as it
stands. A replay mismatch must not: before anyone acts on it, a second
replay with other code (the emulator's own driver, or the Lua client) must
agree with the tool, or the first boundary at which tool and node differ
must be found. The runbook owns this rule; the latch only says which kind
it is.

### 8.8 Where its tests live

Three layers, the first two in the tool's own directory, as the watchdog has
them: unit tests against fakes, in `just check`; and conformance on the real
emulator against the reference CLI, for accept, reject, exception, halt and
the seam machines.

The third layer is the drills, and the facts here go against the candidate's
starting assumption.

| Drill | Node's anvil harness (Rust) | End-to-end harness (Lua) |
|---|---|---|
| A fabricated claim wins a root | exists (`src/harness/tests.rs:472-511`) | not possible today: every sybil's commitment ends in the honest final state, since only interior leaves are patched |
| The honest node is held out | exists: roll, then do not tick | not possible today: every scenario runs the node and asserts its commitment wins |
| Sentries, a staging period, foreclosure | configurable; a test forecloses | one sentry, the node's; the period is hard-coded |
| A second node | `World::node(key)` | collides on one state directory and one key |
| A stageable fabricated claim | one new adversary and a new scenario, a lead and not run: in an epoch after the first with one accepted input, a tail whose value is that epoch's initial state, staged by the test with the proof in the previous epoch's settlement row. Today's disputes run on an empty first epoch, where that state is the honest one | a sybil patched at its last leaf to that state, and staging code the harness lacks |
| Speed | seconds, deterministic mining | the slow tier; the smoke also fails any scenario whose node log holds an ERROR, which a held-out node writes |

So the drills are cheapest in the node's harness, which would run the tool
as a process against the world's RPC endpoint and assert its exit status;
the price is that `just test-node-harness` then needs the Lua runtime. The
end-to-end harness is the natural home for one scenario: a clean epoch, and
a tick that exits 0. Silence on every honest scenario is the detector's
version of the node harness failing on any honest skip.

### 8.9 What the node must expose or stop doing

Expose nothing at run time: the detector reads the chain. Stop nothing in
code. Two things outside code: the sentry advice (B5 a), and no export of
the node's store, which is what the recovery scripts in cartesi/dave#304 do.
One small thing in code, for the corroboration rule: the runner's line for
each published batch (`src/machine_runner/mod.rs:274-280`) and the roll's
line could carry the boundary's state hash, so that after a latch a person
can find the first boundary where node and tool differ from the node's log,
without opening its store. The class "settlement idle" needs no tool: a
second node with a funded key stages and accepts, since a win is decided by
commitment and not by signer (`src/hero/planner.rs:113`).

## 9. Seams for extraction

Run time. The node takes one application address. Every other address, the
geometry, and the compatibility values are read from the chain at startup;
nothing is compiled in but two hand-copied constants (G, the gas headroom).

| Coupling | Direction | Would a cleaner interface cut it | What stays regardless |
|---|---|---|---|
| Contract bindings generated from Solidity sources by `forge bind` (`script/contract-bindings.sh`) | node on repository, build | yes: the release already ships the contract artifacts; ABI JSON consumed by the node, or a published bindings crate | the ABI of five contracts per generation |
| Node tests that parse Solidity sources (five, in `src/engine/constants.rs`, `src/engine/geometry.rs`, `src/epoch_manager/recovery.rs`) | node on repository, test | yes: one exported constants file per contract generation; ABI JSON alone lacks enum variant names | the cross-check must run on one side |
| Input cap | both | already one emulator constant on both sides, pinned by a node test (`src/engine/constants.rs:272-276`) | emulator and step are one generation |
| Contract tests that read node fixtures (`NodeWitnesses.t.sol`, `NodeProofs.t.sol`) | repository on node, test | partly: fixtures as a node release asset or a copy | the witness and proof formats |
| The end-to-end harness reading the node's SQLite and snapshot paths | repository on node, test | yes, and with no node feature: the node's commitment is on chain as `CommitmentJoined` by submitter | the flags, env names and one log marker |
| The three-level devnet bundle the harness needs | node on repository, test | yes: release it as an asset beside the canonical one | the factory interface used to deploy |
| Machine bindings and the emulator and step submodules | node on machine | partly: a published bindings crate | one emulator generation |
| One workflow, one tag, one changelog | both, release | yes: per-product tags and a stated compatibility | the generation the node requires |
| Protocol docs | both | no | joint by subject |

Three observations for the later decision. First, the end-to-end harness is
the only outside reader of the store, and it needs nothing a chain read
cannot give; cutting it also removes the one argument for a node-side
export. Second, N3 would put the node's whole contract surface in one file,
which is the thing an ABI-only build would be checked against. Third, the
detector, if built here and drilled by the node's harness, is a new coupling
that travels with the node wherever the node goes, and a second Lua tool
whose event layouts are pinned against this repository's ABI.

Two claims in the planning recon were wrong and are corrected in
`cards/extraction-seams.md`, with others: `machine/step` was on a final tag,
and the input cap is tied on both sides.

## 10. Not reviewed, not verified

- Nothing was built, run or tested except one SQLite timing on a synthetic
  table (B2), repeated by a refuter. No figure for the node on Linux exists
  in or out of the tree.
- The upstream figures in section 7 are quoted from a reply outside the
  repository. Their hardware, image and call sequence are unstated.
- Kernel behavior (a reflink writes back its source's dirty pages; a
  reflinked clone starts with an empty page cache; a source keeps its cache
  across a clone) is taken from that reply and general knowledge, not from
  kernel source.
- The contracts were read for interfaces only. The premise that a finished
  tournament creates no child, on which recovery pruning rests, was not
  checked in `Tournament.sol`. Whether the factory's level table can change
  under a fixed consensus was not checked.
- Section 8 rests on a reading of another repository's watchdog and of the
  emulator's Lua driver at the pinned commit. Neither was run. The fork
  option, the `cartesi.filesystem` lead and the stageable-tail drill are
  leads, and so is every figure given for the private probe of section 7:
  it was proposed in the refutation pass and has not been built or timed.
- alloy internals, real relay and pool behavior, and the AWS signer were not
  examined. The harness, the end-to-end tests and the Lua client were read
  only where a card or section 8 cites them.
- The emulator source was read at the pinned commit for `cm.h`, the clone
  and mapping code, cmio delivery and the CLI's revert modes only.
- Line numbers in the cards were written by their authors. Those repeated
  in this file were checked: the 145 of the first draft by a separate
  reader (three corrected), and those added since by hand.

## Appendices

Component cards: [blockchain reader](cards/blockchain-reader.md),
[machine runner](cards/machine-runner.md), [storage](cards/storage.md),
[engine](cards/engine.md), [tournament](cards/tournament.md),
[hero](cards/hero.md), [epoch manager](cards/epoch-manager.md),
[provider and lane](cards/provider-lane.md),
[process shell](cards/process.md),
[machine bindings](cards/machine-bindings.md).

Evidence cards: [the per-input cycle](cards/per-input-cycle.md),
[material for the detector](cards/detector-material.md),
[seams with the repository](cards/extraction-seams.md).

[How the cards were written](cards/README.md): the template and the questions
put to each.
