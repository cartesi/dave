# PRT contract-client interface decision log

FROZEN 2026-08-04 as campaign provenance. The campaign closed on the
interface-ossification branch: the deferred raw-getter retirement was
executed, the aggregate-view question was declined by measurement, and the
living specification is docs/dispute-game.md plus docs/node-architecture.md.
The D023 same-head watch remains open and is tracked by the Lua actor's
bounded observation retry.

Status: ACTIVE DECISION RECORD (updated 2026-07-25). The
[campaign plan](prt-client-interface.md) records the implemented Campaign 1
slice. One non-reproduced same-head contradiction remains a fail-closed
empirical watch. This document preserves the alternatives, reasoning, failed
reductions, evidence, and reopening conditions that produced the
implementation.

The code remains the source of truth for current behavior. No entry here is an
implementation specification unless the campaign plan marks it as current and
the relevant transition table has been validated against the Solidity state
machine.

## Status vocabulary

- `SETTLED`: an implementation constraint unless new evidence reopens it.
- `FAVORED`: the current choice, still subject to a named review or experiment.
- `OPEN`: deliberately unsettled.
- `DEFERRED`: outside the current campaign and not a blocker.
- `PARKED`: explored seriously but currently dominated; includes a reopening
  condition.
- `SUPERSEDED`: retained historical direction that is no longer current.

Historical `AGREED`, `LEADING`, and `OPEN` labels in the preserved exploration
at the end of this file describe that discussion at that time. They do not
override the current records below.

## Current decision index

| ID | Status | Decision or question |
| --- | --- | --- |
| D001 | SETTLED | Design the Rust domain and transition table before the Solidity ABI. |
| D002 | SETTLED | Retain the existing structural fold in Campaign 1. |
| D003 | SETTLED | Use one natural authority per fact: fold for enumeration, views for contract-local interpretation, planner for actor policy. |
| D004 | SETTLED | Stage the semantic boundary with small typed point views before considering an aggregate snapshot. |
| D005 | SETTLED | Make each typed projection return `(actualPhase, payload)`; do not add a standalone phase view without a demonstrated consumer. |
| D006 | SETTLED | Accept multiple point reads when they are pinned to one sampled block hash. |
| D007 | PARKED | Personalized latest-update and schedule events. |
| D008 | PARKED | Store pointer indexes or the full ordinary match identity to make Hero history-free. |
| D009 | DEFERRED | Dynamic keyed latest-state streams, including GC schedules. |
| D010 | DEFERRED | Enrich the structural event vocabulary after Campaign 1 evidence exists. |
| D011 | SETTLED | Use orthogonal hash-keyed phase payloads plus one full-ID, disposition-only timeout view. |
| D012 | SETTLED | Land contract plus Rust first, then migrate Lua independently in the same campaign. |
| D013 | SETTLED | Keep separate Hero and multi-intent GC planners; give Hero same-observation priority and consume at most one deterministic GC intent. |
| D014 | SETTLED | Measure full deployed runtime size for every concrete ABI prototype. |
| D015 | SETTLED | Let each tournament's immutable descriptor own its geometry and base cycle; let the fold own child provenance. |
| D016 | SETTLED | Use one current-only tagged tournament-standing view, including explicit joinability and canonical inactive payloads. |
| D017 | SETTLED | Use one exclusive-signer, replaceable slot at the `latest` mined account nonce; do not wait for receipts or allocate from pending state. |
| D018 | SETTLED | Keep supported commitment heights and row extents strictly below 256. |
| D019 | SETTLED | Plan submitted GC only after Hero returns Wait, or Won with settlement idle, for the same accepted observation. |
| D020 | SETTLED | Keep legacy raw-getter differential sampling off the deadline-sensitive action path. |
| D021 | SETTLED | Keep honest fulfillment strict; require an explicit test-adversary opt-in for deliberately invalid claims. |
| D022 | SETTLED | Remove the superseded Lua actor cluster while retaining the low-level reader for harness and differential use. |
| D023 | SETTLED | Fail closed on any cross-view phase contradiction; never retry it into apparent coherence. |
| D024 | SETTLED | Persist the finalized fold independently, rebuild the live tail with bounded range queries, and treat all unfinalized work as disposable. |

## D001: domain model before wire ABI

Status: SETTLED.

### Context

Solidity generated types are wire values, while the Hero needs rich sum types.
Starting with an ABI encourages tuples whose optional fields mirror storage or
one client's current control flow.

### Options considered

1. Design Solidity functions first and wrap the generated structs.
2. Define Rust domain variants and the Hero one-intent transition table first,
   then choose the smallest ABI that can construct them.

### Decision and rationale

Use option 2. Rust enum variants may contain arbitrary associated data, so the
domain can express absent, bisecting, ready-to-seal leaf, ready-to-delegate,
sealed leaf, awaiting-child, timeout, result, and elimination states without
boolean soup.

The domain model is also the meeting point for the fold and views. Defining it
first prevents the accidental assumption that `SemanticSnapshot` must be one
Solidity call.

### Consequences

- Generated DTOs stop at one strict adapter.
- The transition table can be reviewed without RPC, sender, or machine effects.
- ABI design is judged by whether it constructs one unambiguous domain value.

### Reopen condition

Only if a second consumer demonstrates a protocol concept the Rust-first model
cannot express without client-specific coupling.

## D002: retain and lean on the fold

Status: SETTLED for Campaign 1.

### Context

Some historical discovery index is inevitable for the current full validator
because GC must discover all active matches and nested tournaments, not only
the honest commitment's path. The current fold also supplies useful indexes the
contract deliberately does not store.

Moving most facts into views while replaying the same history could create two
partially overlapping regimes without removing either one.

### Facts the fold represents naturally

- tournament and child discovery;
- joined commitment enumeration;
- full ordered match identities;
- match creation, deletion, and live-set membership;
- commitment-to-current-engagement lookup; and
- parent-match-to-child-tournament lookup.

These are historical, enumerable relationships. Replacing them with views
would require new storage pointers or active collections.

### Decision and rationale

Keep the fold and use it deliberately. Campaign 1 is not a project to reduce it
to an address book.

The fold exposes the relationships Hero and GC actually need.
`MatchAdvanced` remains part of the accepted structural stream and must target
a known live match, but its count and frontier breadcrumbs are not retained in
production state. They duplicate phase-view facts without becoming
authoritative: equal child hashes can make the event breadcrumb insufficient
to recover live position.

### Consequences

- Finalized-prefix replay and disposable live-tail behavior remains.
- Existing recordings remain useful for structural equivalence.
- GC coverage does not depend on a new event or storage index.
- The new design problem is the explicit fold/view join, not fold removal.

### Reopen condition

Campaign 1's retention decision does not need reopening. Its later
responsibilities may be reshaped if D009 or D010 materially simplifies Hero or
GC while retaining a smaller structural discovery fold. Removing the discovery
index still requires a product change or a safe replacement for both Hero and
GC history.

## D003: the Goldilocks ownership split

Status: SETTLED for Campaign 1.

### Question

How should the fold and views share responsibility without duplicating protocol
logic?

### Alternatives considered

1. Fold almost everything that logs can reconstruct.
2. Make views describe nearly the whole current dispute.
3. Assign each fact according to its natural authority.

### Decision

Use option 3:

```text
events enumerate
views interpret contract-local facts
the planner decides for this actor
mutators authorize
```

The split is based on the fact, not on a desire to make one side small:

- history and relationship directions absent from contract lookup belong in the
  fold;
- overloaded storage, parity, clocks, current time, and validity rules belong
  in views;
- local identity, proof availability, traversal, and action priority belong in
  the planner; and
- mutators revalidate at execution.

### Evidence

- Match position cannot always be reconstructed from `MatchAdvanced`.
- Clock allowance changes cannot be attributed from the current event payloads.
- The timeout-alignment campaign found real risk in reimplementing
  `MatchClocks.classifyTimeoutAt` off chain.
- Commitment engagement and child discovery have no equivalent enumerable
  contract index.

### Consequences

The domain snapshot is assembled off chain from both authorities. Some facts
are current without belonging in a view: for example, current live membership
is the result of a complete create/delete fold.

### Reopen condition

Reassign an individual fact when implementation shows that its proposed owner
must duplicate another authority or cannot validate it independently.

## D004: point views before an aggregate snapshot

Status: SETTLED for Campaign 1.

### Context

A view-dominant design can return a single rich match or tournament snapshot.
It reduces calls and client composition, but freezes a large optional DTO into
the ABI and risks computing fold-owned facts twice.

A point-view design uses one method per typed fact or variant. It requires
several pinned reads, which the current reader already performs successfully.

### Options considered

1. Small total point views only.
2. One large tagged snapshot, possibly batched.
3. Add point DTOs first and later aggregate those exact DTOs if measured need
   justifies it.

### Decision

Use option 3, leaning toward option 1 in Campaign 1.

The minimum coherent point interface still includes contract-authoritative
timeout and result facts. An interface that only prettifies `Match.State` while
Rust continues to classify clocks would preserve the most dangerous semantic
duplication.

### Consequences

- Contract additions stay small and independently testable.
- Multiple scalar calls remain acceptable.
- JSON-RPC batching may be used without defining a custom contract batch.
- An aggregate remains an optimization over the same DTOs rather than a second
  domain model.

### Reopen condition

Add an aggregate only after the scalar interface is stable and measurements
show material latency, provider, or consistency benefit.

## D005: total typed projections

Status: SETTLED.

### Question

How should a Solidity ABI represent a sum type without making ordinary view
probing revert?

### Options considered

1. One phase tag followed by one `try...` method per variant.
2. One method per variant returning `(actualPhase, payload)`, with an optional
   standalone phase method only for a demonstrated phase-only consumer.
3. One method per variant returning `(bool, actualPhase, payload)`.
4. One tagged union with zero-filled inactive payloads.
5. A separate method per variant that reverts on the wrong phase.

### Decision

Use option 2:

- `actualPhase` distinguishes absence from every other live variant;
- the payload is meaningful only when `actualPhase` names the requested
  variant;
- every other phase returns a byte-exact canonical zero payload; and
- impossible invariant contradictions revert only after the requested phase
  has been established.

A boolean would repeat information already carried by `actualPhase`. A
mandatory phase call would make every adapter perform a prerequisite read even
though the timeout view and selected projection already need to report their
observed phase. Reverting on an ordinary wrong-phase probe is unnecessarily
hostile for an observer method. A tagged union remains a possible later
aggregate over the same payloads.

### Consequences

The timeout view and projection are separate calls and must belong to the same
pinned observation. The adapter requires their phases to agree and never
decodes a payload from the wrong phase. Canonical inactive zero payloads remain
a contract-interface guarantee with exhaustive Solidity coverage; the
production adapter does not redundantly inspect those fields after the phase
has already made the whole projection unusable. A standalone phase method is
an optimization, not a correctness prerequisite.

### Reopen condition

Add a standalone phase call only if a concrete phase-only consumer or measured
batching benefit justifies the selector and runtime bytes.

## D006: multiple reads and one observation

Status: SETTLED.

### Context

Multiple point reads are not themselves a correctness problem. Mixed block
state is. The current reader already pins calls to one sampled height after an
unpinned clock read caused a real inconsistent observation.

### Decision and rationale

Allow multiple reads. Represent an observation with a block number and hash.
Pin every semantic point read to the sampled latest hash `H`. This prevents the
clock and phase projections within one adapter pass from silently advancing
between calls. A mixed phase projection or unavailable historical hash rejects
that volatile observation.

An earlier implementation also proved that sampled finalized `F` belonged to
`H`'s parent-hash ancestry, fetched each live-tail block by exact hash, and
rechecked `H` before persisting or returning. That stronger log-acquisition
policy is retained as design provenance, but D024 supersedes it. Log history
and point reads now have deliberately different consistency requirements.

### Consequences

- One-call batching is not a correctness requirement.
- Retry the volatile observation on unavailable pinned state.
- The adapter may rely on timeout-status and projection phase coherence only
  among point calls pinned to the same hash.
- Dynamically discovered child streams must be replayed with their parents in
  one global event order; address-discovery order is not fold order.

### Reopen condition

Only if supported providers cannot serve point state at a recently sampled
hash.

## D007: personalized latest-update schedules

Status: PARKED, not rejected.

### Motivation

An event such as `BisectRequested(commitmentToAct, ...)` or
`TimeoutRequested(commitmentIdle, dueAt)` tells a Hero what the next useful
move is, rather than only recording the previous transition. With the subject
commitment in topic1, a Hero can query its own stream.

This design is attractive because one latest value plus current time can
replace a transition fold for a consumer that knows the stream key.

### What the exploration established

- Every affected subject needs a final projection after all state mutations.
- Winner resolution can re-pair a survivor in the same transaction, so helper
  event order is not automatically final-state order.
- Schedules are revocable projections. A later response or pre-close join can
  supersede an immutable earlier log.
- Time crossings emit no event, so a schedule must carry its boundaries and a
  wakeup must revalidate.
- A match action still needs the full ordered identity.
- Standard JSON-RPC filters a key but does not return "the latest log for this
  key" without scanning a range or relying on an external indexer.
- GC still needs unrelated keys and nested-tournament discovery.

### Why it is parked

The current full validator already performs the global structural fold for GC.
A second personalized regime would add:

- another event allowlist and decoder;
- subject-specific final-projection rules;
- more hot-path logs;
- supersession and tombstone semantics;
- another reorg and cold-start path; and
- Rust/Lua conformance over both structural and personalized streams.

Campaign 1 can remove the raw-state ergonomic problems without paying that
cost.

### Reopen condition

Reopen when a GC-less cold Hero or watchtower is a concrete product
requirement, or when measurements show that typed pinned reads are an
unacceptable bottleneck. Compare against storage pointers and an external
indexer, not only against the current reader.

The full personalized-event proposal, query forms, transition table, and
schedule boundaries are preserved later in this document.

## D008: on-chain identity and pointer indexes

Status: PARKED.

### Options explored

1. Store the full `Match.Id` beside ordinary match state.
2. Add commitment-to-current-match and match-to-child pointers.
3. Add enumerable active arrays or pages.
4. Keep identity and the missing relationship directions in the event fold.

### Current leaning

Use option 4 in Campaign 1.

The current event stream already supplies the full ordered ID and child address.
Ordinary match storage is keyed by the ID hash, while child settlement stores
the child-tournament-to-parent-match relationship. Adding
commitment-to-current-match or parent-match-to-child-tournament pointers would
make Hero views easier, but every mutation would maintain a second consensus
invariant under adversarial population.

Storing only the full ID does not make mappings enumerable and does not by
itself remove the fold.

### Reopen condition

Reopen if history-free Hero startup becomes mandatory. Prefer the smallest
pointer set that satisfies a measured lookup requirement; do not start with
full on-chain enumeration.

## D009: dynamic keyed latest-state streams

Status: DEFERRED until after Campaign 1.

### The distinct fold category

Not every fold reconstructs state by applying all historical transitions. A
different design has many keyed streams whose reducer is simply:

```text
latest[key] = last recognized update for key
```

Possible keys include:

- `(tournament, commitment)` for a Hero position;
- `(tournament, match_id_hash)` for match status and elimination;
- `tournament` for result or no-winner status; and
- a parent match or child address for recursive cleanup.

A GC-oriented value might be:

```text
MatchEliminationScheduled(
    match_id_hash,
    eliminate_at
)
```

and a later advance or resolution would supersede it for that key. The latest
value plus current block could be simpler than replaying every semantic
transition.

### What this can improve

- Reducer logic per known key is trivial.
- A value can carry the next silent time boundary.
- Hero and GC may share a normalized scheduling vocabulary.
- Tombstones can remove completed keys from the active projection.

### The dynamic-key problem

The keys themselves appear over time:

- joins introduce commitments;
- matches introduce match streams;
- sealing introduces child tournament addresses;
- recursive tournaments introduce more matches; and
- deletion or settlement terminates streams.

Therefore a latest-value design still needs one of:

1. a structural discovery fold;
2. on-chain enumerable pointers;
3. an external indexer; or
4. a discovery meta-stream whose own history is folded.

A tournament-keyed stream alone cannot represent several concurrent matches.
A commitment-keyed stream cannot enumerate unrelated GC work. A match-keyed
stream cannot be queried until the client discovers the match key.

### Silent time and supersession

Deadlines do not produce transactions or logs. Each latest value must carry all
relevant future boundaries, and a wakeup must be revalidated because another
transaction may have superseded the schedule.

The design also needs:

- a final projection after same-transaction re-pairing;
- tombstones for deletion and child settlement;
- rules for duplicate delivery and same-block ordering;
- restart and reorg semantics;
- a generation story if a logical key can be reused; and
- a clear distinction between a wakeup hint and transaction authorization.

### Why it comes after Campaign 1

Campaign 1 produces exactly the artifacts needed to judge this design:

- rich domain variants;
- a unique planner transition table;
- semantic point views as an independent oracle;
- realistic recorded and live traces; and
- measurements of actual RPC and cold-start behavior.

The experiment can then compare:

```text
latest keyed values + current time
    ==
fold + typed point views
    ==
domain planner intent
```

at every event prefix and relevant block between events.

### Reopen condition and evidence

Reopen only after naming a real consumer or bottleneck. Require:

- a complete key-discovery model;
- measurable improvement after counting discovery history;
- standard-provider filter and range behavior;
- zero Hero-intent and GC-action mismatches;
- exact deadline, supersession, nested-tournament, restart, and reorg traces;
- on-chain topic, byte, code-size, and mutation-path cost; and
- an independent second reducer that does not share the first transition table.

If the post-Campaign-1 experiment shows that the keyed streams do not materially
simplify Hero or GC, change this record from `DEFERRED` to `PARKED`.

## D010: enriched structural events

Status: DEFERRED.

### Motivation

The current events could name useful facts more directly even if they do not
become personalized schedules. Enrichment might simplify a fold, eliminate a
point read, or improve diagnostics.

### Why it follows Campaign 1

Changing events before the domain boundary is clear risks optimizing the
current imperative reader. Campaign 1 lets us identify a precise missing
enumeration fact or measured bottleneck.

### Entry gate

Before adding an event:

1. Name the exact fact or bottleneck.
2. Show why the fold, scalar views, JSON-RPC batching, caching, or an aggregate
   view does not solve it more simply.
3. Declare the improvement required for success.
4. Add a versioned event rather than silently changing an existing signature.
5. Differentially compare old and enriched folds at every prefix.

Hot `MatchAdvanced` enrichment requires especially strong evidence because it
occurs at every bisection level.

### Reopen condition

Campaign 1 measurements identify a material operational or correctness problem
that is naturally solved by immutable transition data.

## D011: exact typed-view boundary

Status: SETTLED.

### Questions

- Which facts live in each match variant?
- Does timeout live inside a match projection or in a separate full-ID view?
- Does a timeout view return current disposition only or also future
  boundaries?
- Does tournament standing return the dangling candidate, even though complete
  event history may reconstruct it?

### Constraints already established

- A view that needs both commitment clocks must accept the full supplied
  `Match.Id`. The match mapping stores only its hash and cannot recover the two
  commitment roots.
- Supplying the ID does not require storing it.
- A total clock model needs an absent or uninitialized variant as well as
  paused, live-running, and expired-running variants.
- Exact deadline equality must be representable without a contradictory pair
  of `remaining` and `overdue` fields.
- Result propagation and child elimination are mutually exclusive at one
  observation.
- A no-candidate elimination and an expired-winner elimination should remain
  distinguishable even if they currently share one mutation.

### Current choice

Use orthogonal payloads:

- each hash-keyed phase projection returns `(actualPhase, payload)`;
- one separate timeout-status view accepts the full `Match.Id` and returns
  `(actualPhase, outcome, deferredCharge)`;
- a standalone phase view is not required unless a real phase-only consumer
  justifies it; and
- the strict adapter calls the timeout view, selects one phase projection, and
  requires the two returned phases to agree at one pinned observation.

The timeout view reports only the current disposition:

- `NONE`;
- `ONE_WINS`;
- `TWO_WINS`; or
- `ELIMINATE_BOTH`.

`deferredCharge` is meaningful only for one-winner outcomes and is otherwise
canonical zero. The outcome names commitment sides, not the caller, because
settlement is permissionless.

The current node is a poller, so Campaign 1 does not add future claim or
elimination boundaries. If a later wake-driven consumer needs a boundary, the
contract must supply it. The planner must never reconstruct that boundary from
typed clocks. In particular, corrected sealed-leaf semantics use the shorter
and longer clock deadlines; there is no valid midpoint transition.

The same disposition-only rule applies to planner-facing tournament standing.
It reports whether a root result, child propagation, or child elimination is
usable now. It does not report a future wake time. Explanatory diagnostic
methods may be considered separately, but their times do not enter the polling
planner.

An optional total clock observer may expose diagnostic state, but it is not a
Hero or GC strategy input and cannot become a second timeout authority.

### Totality and invariants

- Absent or deleted matches return `(UNINITIALIZED, NONE, 0)` from timeout status
  before historical clock slots are interpreted.
- A wrong-phase projection returns the actual phase and a byte-exact canonical
  zero payload.
- A matching projection decodes its legal phase-owned storage shape.
- Impossible contradictions after the requested phase has been established
  revert.
- Timeout status delegates to the same `MatchClocks.classifyTimeoutAt`
  authority used by mutators.

### Candidate identity at the fold/view seam

The fold can potentially derive a dangling candidate from the complete join,
pairing, deletion, and re-pairing history. The contract also stores the current
candidate and uses it directly in result validity.

The implemented total tournament-standing view includes candidate identity
while the fold remains authority for the enumerable live-match set. The strict
adapter derives the candidate from join, pairing, deletion, survivor, and
re-pairing history and requires both authorities to agree.

### Reopen condition

Reopen the disposition-only decision only for a wake-driven consumer or a
measured polling bottleneck. Consider an aggregate only as an optimization over
these DTOs after scalar adapter measurements exist.

## D012: Rust and Lua migration boundary

Status: SETTLED: contract plus Rust first, followed immediately by an
independent Lua slice in the same campaign.

### Context

The immediate implementation target was the contract-node interface. The Lua
client remains a reference implementation and test actor, and the pre-campaign
path duplicated raw clock and timeout interpretation.

Unchanged events and retained getters let Rust migrate first, but they preserve
Lua parsing rather than semantic agreement.

### Options

1. Migrate contract views, Rust Hero, Rust GC, and Lua together.
2. Land a contract-plus-Rust slice, retain legacy getters, then migrate Lua in
   the next reviewable slice.

### Trade-off

Option 1 closes the semantic duplication at once but broadens the first diff.
Option 2 keeps the node campaign smaller but leaves named cross-implementation
debt and requires the contract to carry both observer APIs temporarily.

### Decision and outcome

Use option 2. It created a clean contract-plus-Rust review boundary, followed by
an independent Lua semantic reader, fold, adapter, context, planner, fulfiller,
dispatcher, and production actor.

The acting Rust and Lua paths no longer interpret raw match slots or clock
sentinels. The retained raw getters now serve harness assertions and
differential inspection, not a migration dependency. Removing those getters
remains a separate ABI compatibility decision, and timeout-alignment retains
its own end-to-end acceptance work.

### Reopen condition

This sequencing decision is complete. Reopen only if a future coordinated ABI
campaign demonstrates that cross-language slices cannot be independently
reviewed without leaving an unsafe intermediate state.

## D013: Hero and GC planner scope

Status: SETTLED for planner scope, same-observation ordering, and the D017
submission boundary.

### Context

The one-intent property was designed for Hero strategy: one observation should
not cause a timeout transaction followed by a phase transaction.

The pre-campaign GC behavior was different. One tick walked every reachable
match and child and could submit several cleanup transactions. An earlier
cleanup could make later intents from the same observation stale.

### Options

1. Keep separate pure planners:

   ```text
   plan_hero(&SemanticSnapshot) -> HeroDecision
   plan_gc(&fold, &observations) -> Vec<GcIntent>
   ```

   Execute the GC list in a defined order and revalidate or tolerate reverts.
2. Use one priority planner that returns at most one Hero or GC intent, then
   refresh before choosing again.

### Current choice

Use option 1 for planning:

```text
plan_hero(&SemanticSnapshot) -> HeroDecision
plan_gc(&fold, &observations) -> Vec<GcIntent>
```

The GC vector describes every eligible cleanup in deterministic
global innermost-first order while preserving fold creation order within one
depth. It is useful for coverage, throughput accounting, and pure planner
tests. After Hero policy returns Wait, or terminal Won without an arena action,
the actor retains at most the first intent from that exact observation for the
executor. Settlement gets the first write attempt after Won.

Do not interpret the vector as permission to submit an unbounded queue. The
executor must:

1. submit an eligible Hero action before new GC work;
2. consume only a configured or structurally bounded GC prefix;
3. isolate a GC submission failure from the Hero decision;
4. tolerate stale cleanup through mutator revalidation; and
5. submit through the exclusive-signer slot at the account nonce read from
   `latest` mined state.

This qualification follows from the transaction executor, not only abstract
planner design. The implemented order prevents a new cleanup from preceding a
Hero action selected from the same accepted state, and the one-intent prefix
bounds stale work from that observation. D017's replaceable slot makes an
unmined cleanup and a later Hero attempt use the same nonce `n` until the mined
account nonce advances.

Legacy GC timeout actions are not the correctness oracle: its off-chain
classifier is one of the semantics being replaced. Whichever planner is chosen
must be checked against contract-authoritative timeout views and independent
boundary tables.

### Reopen condition

Reopen the separate-planner choice only if measured single-slot behavior cannot
preserve Hero priority without collapsing all work into one planner.

## D014: deployed-runtime size gate

Status: SETTLED.

### Context

`Tournament` is the implementation behind ERC-1167 clones and its deployed
runtime must remain below the EIP-170 ceiling. Typed point views and struct
returns add dispatcher and implementation bytecode even when they do not add
storage.

On 2026-07-24, fresh `direnv exec . forge build --force --sizes` measurements
from `prt/contracts` established:

- baseline deployed runtime: 13,832 bytes;
- implemented observer runtime: 16,622 bytes;
- runtime delta: 2,790 bytes, or approximately 20.17%;
- implemented initcode: 16,648 bytes; and
- EIP-170 runtime margin: 7,954 bytes out of the 24,576-byte ceiling.

The semantic storage-layout hash remained exactly
`952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`.
The recorded compatibility witnesses for the implemented observer-bearing
Tournament are:

```text
Tournament ABI sha256:
c7b75c2b036a4e71c180cc2d18176c8a949f4a44c9b0ea6e7690c6cae70c79f0

Tournament runtime bytecode without metadata sha256:
c12ddfef8bdd83deeaacaf56e928340599eb15e64595e602303d834ca4250d44

semantic storage-layout sha256:
952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
```

The ABI and runtime hashes changed as expected from adding six observer
methods; the semantic storage-layout hash did not.

This is deployment compatibility, not only a build-time ABI detail. Migrated
clients require an observer-bearing `Tournament` implementation, so release
manifests must version-pair client binaries and generated bindings with that
implementation even though the storage layout and structural events are
unchanged.

### Decision

Run the full deployed-runtime measurement for every concrete ABI prototype and
record both the delta and remaining margin before signatures freeze. A
metadata-stripped compatibility hash is not the deployment-size measurement.

If size becomes material, first trim DTO fields and duplicated helpers. A
separate viewer is not a free semantic escape hatch: ordinary external
contracts cannot read another contract's storage directly, so a viewer would
depend on core accessors or a generation-specific raw getter ABI. Immutable
clone arguments are the limited exception because they can be read from code.

### Reopen condition

Only if the final implementation approaches the project-selected release
headroom, in which case compare DTO trimming, internal factoring, and a
version-paired periphery explicitly.

## D015: immutable tournament descriptor ownership

Status: SETTLED.

### Context

The current reader obtains child level geometry from the child but derives the
child base cycle from the parent live match. That mixes a child's immutable
facts with a fold-and-view relationship.

Each tournament clone already carries the commitment arguments needed to
interpret its matches: initial hash, start cycle, stride, height, level, and
total levels.

### Decision

Expose one total immutable tournament descriptor. The child descriptor is
authoritative for:

- initial hash;
- base cycle, represented on chain as `startCycle`;
- stride;
- commitment height;
- level and total levels; and
- the derived Leaf versus NonLeaf kind.

The fold remains authoritative for parent-to-child discovery, provenance, and
reachability. While a parent match remains live, the adapter validates that
the child's base cycle agrees with the disputed cycle in the sealed parent
match.

This distinction matters because the factory is permissionless. A directly
created orphan may have a perfectly valid descriptor without being reachable
from the root dispute.

### Reopen condition

Only if immutable argument decoding cannot be exposed without duplicating or
weakening the clone's existing validation.

## D016: one current-only tournament-standing view

Status: SETTLED.

### Context

Root settlement, inner propagation, and inner elimination previously required
different calls with kind-sensitive false or revert behavior. The planner also
needs to distinguish active matches, a pre-closure dangling candidate, root
failure, and the two reasons an inner tournament can be eliminated.

### Decision

Expose one total tagged `tournamentStanding()` projection with these
dispositions:

- matches active;
- awaiting closure;
- root winner;
- root failure;
- inner winner;
- inner eliminable without a candidate; and
- inner eliminable because its winner expired.

The payload includes explicit `acceptsJoins`, candidate presence and identity,
the root final state only for a root winner, and the parent commitment only for
an inner winner. Every inactive field is canonical zero.

`acceptsJoins` is exactly `!isClosed()`. This is independent of the standing
tag because a tournament may be closed while matches remain active. The view
reports current dispositions only; it does not expose future settlement or
elimination times.

### Rationale

One tag makes mutually exclusive result and elimination states explicit without
turning the contract into an enumerable database. Candidate identity remains a
small contract-local fact, while the fold still owns the active match set and
derives the same candidate independently for adapter validation.

### Reopen condition

Split the method only if a measured consumer or runtime constraint shows that
the tagged projection is materially worse than kind-specific total methods.
Future times remain governed by D009 and require a wake-driven consumer.

## D017: replaceable nonce slot and submission ownership

Status: SETTLED and implemented.

### Context

Hero arena mutations, cleanup mutations, and epoch settlement currently share
one signer-bearing provider inside the epoch-manager task. The implemented loop
gives Hero same-observation priority and broadcasts at most one retained
cleanup intent from a Hero-checked observation.

All PRT mutators revalidate current contract state. Duplicate, stale, or
otherwise inapplicable calldata cannot create an incorrect transition: the
call either performs a transition that is still legal or reverts. A reorg may
therefore make a submitted transaction stale, and a competing transaction may
win the race, without creating an off-chain recovery obligation. The direct
cost is wasted gas when a public transaction is included and reverts.

This trust model removes any need to wait for a receipt or confirmation before
the next Hero loop. It does not remove Ethereum's sequential nonce constraint.
If the mined account nonce is `n`, submitting at `n` makes a normal pending
query return `n + 1`. Using that value on the next loop does not resubmit the
first mutation: it queues another transaction behind it. If transaction `n`
never lands, every later Hero, cleanup, and settlement transaction is stranded.
With revert protection, stale duplicates at `n + 1`, `n + 2`, and later may
never be included to consume those nonces.

An isolated no-mining Anvil check on 2026-07-24 confirmed the distinction.
After accepting transactions at nonces 0 and 1, the latest account nonce
remained 0 while the pending nonce became 2. Another transaction at nonce 0
with unchanged fees was rejected as replacement-underpriced; increasing the
fee replaced it. The test establishes nonce and replacement mechanics, not a
specific private relay's policy.

Before D017, the node used Alloy's default cached nonce filler. It fetched a
pending nonce once and then incremented its local value for later sends. A
nonce could therefore advance locally even when estimation or submission
failed. The old sender already dropped the pending-transaction handle after
RPC acceptance and did not wait for inclusion; fire-and-forget receipt
handling was not the missing behavior.

### Decision and implementation

Use one replaceable nonce slot owned by an exclusive node signer:

1. Plan and prepare at most one highest-priority mutation.
2. Read the account nonce with `eth_getTransactionCount(..., "latest")`, never
   from pending state.
3. Estimate EIP-1559 fees through the read provider.
4. Fully specify and sign the transaction with that nonce and an explicit gas
   limit.
5. Submit the raw bytes through a bounded submit-provider RPC call.
6. Discard receipt and confirmation state, then repeat from fresh chain state.

Until a transaction is included, the account nonce at latest remains `n`, so
every loop rebroadcasts or replaces `n`; it never allocates `n + 1` merely
because a provider has `n` pending. Once any transaction at `n` is included,
whether successful or reverted, the chain advances naturally to `n + 1`. A
reorg rolls the account nonce back and the next observation resubmits.

The implemented in-memory slot retains the nonce, intent fingerprint, signed
bytes, and fee floor. Identical work exactly rebroadcasts retained bytes while
the market quote does not exceed their fees. Changed work or a higher quote
replaces at a monotonic floor; an explicit underpriced response bumps and
retries the same nonce. Persistence is necessary only if deterministic
public-mempool replacement across restart is a promised property; it is not
required merely to avoid waiting for receipts. Expected submission outcomes
are:

- `already known`: benign;
- `nonce too low`: re-observe latest state;
- `replacement underpriced`: bump the fee and retry the same nonce; and
- an ambiguous timeout after submission: retry the same nonce from the next
  observation.

Hero, cleanup, and epoch settlement share the same `Arc<TransactionLane>`. The
epoch write plan admits at most one category per loop, and every settlement
eligibility call reads `latest`, not pending state. A newer Hero intent may
replace older cleanup or settlement work at the same nonce without observing a
pending prerequisite as completed. The signer must be exclusive to one node
instance; another process using the same key can replace the node's transaction
or create a nonce gap that no stateless policy can resolve.

The tournament reader already plans from latest `H`; finalized `F` is its
durable event-prefix anchor, not its action head. A separate entry seam remains
to inspect: newly sealed epochs are currently discovered through the
finalized-only blockchain reader and database. If immediate joining after
sealing is required, latest-head discovery must be added without making
unfinalized inputs durable.

### Read and submit providers

Chain reads and raw transaction submission are distinct capabilities. The
reader needs historical state, logs, and EIP-1898 block-hash calls. The submit
side needs only `eth_chainId` during provider construction plus bounded
`eth_sendRawTransaction` calls during operation, and may use an
operator-selected private relay. The chain-ID check prevents signing for one
chain while submitting to another.

Operators can configure `--web3-submit-rpc-url` separately from
`--web3-rpc-url`; it defaults to the read endpoint. Flashbots Protect, or a
comparable builder interface, can reduce wallet drain by withholding reverting
transactions. Relay-specific retry, cancellation, fanout, authentication, and
privacy rules remain outside Campaign 1 and must not leak into the generic Hero
planner or transaction lane.

As of 2026-07-24, Flashbots Protect documents that standard submissions are
retried for 25 blocks and reverting transactions are not included. It also
documents that private transactions affect `eth_getTransactionCount(...,
"pending")` only for a specially authenticated request. The generic node must
therefore not infer a private relay's queue from its read provider or depend on
pending-count visibility. Reverify these external policies before production
configuration:

- https://docs.flashbots.net/flashbots-protect/settings-guide
- https://docs.flashbots.net/flashbots-protect/nonce-management

### Constraints and required evidence

- repeated loops with automining disabled must never allocate `n + 1` while
  the mined account nonce remains `n`;
- a pending cleanup at `n` must not strand a newly eligible Hero action;
- ambiguous RPC acceptance and `already known` must remain safe to retry;
- an underpriced replacement must bump the fee without allocating a later
  nonce;
- inclusion followed by reorg must return naturally to the chain nonce;
- separate read and private-submit endpoints must not assume shared pending
  state;
- restart behavior must be tested if public-mempool fee replacement across
  restart is promised; and
- the chosen policy must preserve the pure `plan_gc` ordering independently
  from broadcast scheduling.

The passing `gc_match` and `gc_tournament` scenarios do not close this record.
`gc_match` asserts a `TIMEOUT/NONE` match deletion. `gc_tournament` asserts a
child `TIMEOUT/NONE` deletion followed by the parent
`CHILD_TOURNAMENT/NONE` deletion. These scenarios therefore establish the
intended cleanup semantics, not merely eventual victory, but the harness still
does not assert single-slot nonce reuse or replacement.

### Evidence and reopening

The disabled-automining Anvil test submits at nonce 0, exactly rebroadcasts the
same intent without growing the pending nonce, replaces it with changed
calldata at the same nonce and higher fees, mines it, observes nonce 1, then
reverts the chain snapshot and naturally submits again at nonce 0. Focused unit
tests cover fee-floor reset, quote-driven rebroadcast choice, and recognized
already-known, nonce-too-low, and underpriced responses. The node library
suite, all-target check, and clippy gate pass with Hero, GC, and all three
settlement mutations routed through the shared lane.

The final end-to-end pass also completed `multi_sybil`, `gc_match`,
`gc_tournament`, `kill_mid_match`, and `kill_settle`. The restart scenarios
observed a real SIGKILL and respawn. The `kill_settle` node trace submitted
`submitSentryClaim`, `stageTournamentResult`, and
`acceptStagedTournamentResult` through consecutive lane-owned nonces before
surviving the injected settlement interruption. These scenarios exercise the
shared production wiring and restart behavior; the disabled-automining test
remains the direct same-nonce replacement oracle.

Reopen if a supported submit provider requires a different replacement policy,
if a second signer user becomes an operational requirement, or if production
evidence shows that the in-memory fee floor cannot recover adequately across
restart. Receipt tracking and confirmation waiting are explicitly not part of
the current contract.

## D018: commitment height and the 256-bit coordinate boundary

Status: SETTLED.

### Context

The test-only Solidity parameter-table validator accepted a commitment height
of 256 when the stride was zero. The Rust and Lua semantic descriptor
constructors rejected it. The adapters also accepted a row extent of exactly
256 when the height itself was smaller. These were not just wire
discrepancies: the Rust commitment engine computes full spans as
`1 << (height + log2_stride)` in a 256-bit integer. Either shape therefore
wraps the span to zero and makes later coordinate arithmetic invalid.

The canonical production geometry already requires every height to be strictly
below 256. Its complete root extent is much smaller today, but the generic
table validator is intended to describe every geometry the cross-language
implementation can actually execute.

### Decision and rationale

Require `1 <= height < 256` and `height + log2_stride < 256` in Solidity test
validation and both clients. This preserves every fully representable span
while avoiding the unrepresentable one-past-end coordinate `2^256`.

Supporting height 256 would require a wider span representation and coordinated
changes throughout commitment construction, proof bounds, Hero preparation,
and both reference clients. Permitting it only in a test helper would advertise
a contract configuration for which no honest client can safely participate.

### Consequences

- the test-only table validator and the semantic descriptor adapters enforce
  the same boundary;
- generated tables fail before deployment-oriented tests if they exceed the
  client coordinate model; and
- the largest supported row extent is 255.

### Reopen condition

Reopen only with a wider cross-language span abstraction and differential
tests covering commitment construction, bisection, proof bounds, and recursive
tournament seams at a commitment height or total row extent of 256.

## D019: Hero and GC must share one accepted observation

Status: SETTLED.

### Context

The first bounded executor ran `Hero::tick()` against observation `H`. If Hero
waited, `Hero::gc_tick()` sampled a newer observation `H'`, planned only GC, and
could submit it without running Hero policy on `H'`.

A deadline or opponent move can make a Hero action eligible between `H` and
`H'`. The cleanup would then be submitted before an action that Hero would have
selected from the same fresh state. With a shared signer, it could also take
the earlier nonce. Same-tick method ordering therefore did not establish the
intended Hero priority.

### Options considered

1. Plan GC from the already Hero-checked observation `H`.
2. Re-observe as `H'`, but rerun the entire Hero planning and fulfillment gate
   before considering GC.

### Decision and rationale

Use option 1. When Hero policy returns Wait, or terminal Won without an arena
action, compute the exhaustive GC vector from the same fold and semantic
observations, retain only its first intent, and carry that value through the
epoch write plan. After Won, settlement gets the first write attempt and cleanup
is considered only when settlement is idle. The GC submission method accepts
the retained intent and performs no observation.

This gives one accepted state one clear priority decision and avoids a second
RPC pass. A cleanup may become stale before mining, which is already tolerated
by contract mutator revalidation. Sampling a fresher state only for lower
priority work is not a valid freshness improvement.

### Consequences

- an eligible Hero action always outranks new GC work from the same accepted
  observation;
- the executor cannot silently substitute a GC-only re-observation;
- at most one cleanup locator crosses the actor-to-epoch boundary; and
- the shared D017 lane reuses the mined nonce, so cleanup from a previous tick
  cannot create an `n + 1` queue in front of a later Hero.

### Reopen condition

Reopen only if a later executor re-observes before cleanup. Every fresher state
must pass the Hero gate before any cleanup is admitted.

## D020: legacy differential sampling is not action-path work

Status: SETTLED.

### Context

The initial cutover kept the superseded raw-getter overlay as a diagnostic
shadow. Although its result could not alter semantic state, the reader awaited
it before returning. The overlay performs sequential calls for each reachable
tournament, live match, and joined commitment. An adversarial population or a
slow provider could therefore delay an already accepted Hero action by the
entire old reader cost.

### Options considered

1. Keep synchronous sampling because failures are non-authoritative.
2. Add a fixed timeout to the synchronous shadow.
3. Remove live shadow sampling from the action product and retain focused
   differential tests.
4. Build a separately owned background diagnostic worker with bounded
   concurrency and explicit telemetry.

### Decision and rationale

Use option 3 for Campaign 1. Non-authoritative error handling does not make
deadline delay harmless, and an arbitrary timeout still spends part of the
Hero budget. The accepted `DisputeState` now contains only the sampled head,
structural fold, and semantic observations. Legacy overlay types and
comparisons remain test scaffolding.

Option 4 is valid future observability work, but it needs its own ownership,
backpressure, and provider-budget design. It is not required to choose an arena
action.

### Consequences

- no raw getter RPC can delay semantic planning or dispatch;
- the acting state cannot accidentally acquire a second runtime authority;
- the legacy clock classifier and raw overlay types are compiled only for
  tests, so production code cannot import them accidentally;
- same-block differential fixtures remain available during migration; and
- any future live comparison must run out of band and report the exact sampled
  head.

### Reopen condition

Reopen only with a bounded diagnostic worker whose failure, latency, and
backpressure cannot affect the Hero task.

## D021: strict fulfillment and deliberately invalid test actors

Status: SETTLED.

### Context

The `multi_sybil` harness deliberately patches commitments so an adversary can
claim a final state that the real local machine does not produce. The semantic
fulfiller correctly rejected that mismatch. Globally weakening its check would
make the honest reference actor accept inconsistent local material merely to
preserve a dishonest test fixture.

### Options considered

1. Let every actor fulfill a claimed state even when local computation
   disagrees.
2. Bypass the semantic fulfiller for dishonest test actors.
3. Keep one fulfiller strict by default and admit inconsistent claimed material
   only through an explicit adversarial-mode construction option.

### Decision and rationale

Use option 3. `allow_invalid_claims` defaults to false in the actor and
fulfiller. The sybil runner enables it explicitly for the deliberately patched
test adversary. The exception changes only local witness construction; contract
mutators still reject invalid proofs and remain the authorization boundary.

This keeps honest semantics visible and testable while preserving an important
negative integration actor. The option name makes every caller acknowledge that
it is leaving the honest-client model.

### Consequences

- the production-default fulfiller fails closed on a local claim mismatch;
- dishonest harness behavior is explicit at actor construction;
- both strict rejection and adversarial allowance have focused tests; and
- a reverted invalid claim never selects a fallback planner intent.

### Reopen condition

Reopen only if dishonest claim construction moves into a separate adversary
implementation that can generate the same negative scenarios without an escape
hatch in the semantic fulfiller.

## D022: retire the superseded Lua actor cluster

Status: SETTLED.

### Context

After the production sybil runner moved to the semantic pipeline, the old
`player.lua -> state.lua -> strategy.lua -> gc.lua` cluster had no external
consumer. Keeping it would preserve a second imperative strategy authority. The
low-level `reader.lua`, however, remains useful to the rollups harness for direct
contract assertions and differential inspection.

### Options considered

1. Keep the complete old cluster during an indefinite migration period.
2. Delete the complete old cluster and the low-level reader together.
3. Delete the obsolete actor, state, strategy, and GC modules while retaining
   the low-level reader outside the acting path.

### Decision and rationale

Use option 3. The four obsolete policy modules are removed. `reader.lua` remains
as harness infrastructure, not as input to the semantic planner. Raw observer
ABI retirement is a separate compatibility decision.

### Consequences

- Lua has one acting strategy pipeline;
- the e2e harness retains direct assertion and differential tools;
- raw getter presence no longer implies a production strategy dependency; and
- future client behavior should extend the semantic domain instead of reviving
  the deleted imperative cluster.

### Reopen condition

Reopen only if a concrete non-strategy consumer needs a capability absent from
both the semantic reader and the retained low-level harness reader.

## D023: cross-view contradictions fail closed

Status: SETTLED failure policy; root-cause watch remains open.

### Context

One `multi_sybil` run observed `SEALED` from `matchTimeoutStatus` and
`READY_TO_SEAL` from the corresponding phase projection. Both call traces named
the same tournament and sampled head. An independent live Anvil probe confirmed
that the Cast JSON form used by the Lua transport honors an EIP-1898 historical
block hash. The contradiction did not recur after adding stronger diagnostics,
including in the final full acceptance run, so neither a contract-state cause
nor a transport cause has been proven.

### Options considered

1. Retry the projection until the two calls agree.
2. Normalize the pair by trusting one call's phase.
3. Reject the whole observation and retain exact transport evidence.

### Decision and rationale

Use option 3. A retry would turn an observation-integrity failure into apparent
success, and choosing one phase would create an off-chain authority over a
contract contradiction. The Lua adapter therefore keeps the mismatch fatal and
records the address, full-ID argument, hash argument, calldata, and pinned head.
The full-ID/hash identity is checked independently before either value reaches
the planner.

### Consequences

- no Hero or GC action can use a cross-view contradiction;
- a transient provider anomaly costs a polling iteration instead of corrupting
  policy;
- later green runs do not erase the failed observation; and
- Campaign 1 cannot claim zero unexplained same-head anomalies until the watch
  is closed or explicitly accepted as a provider limitation.

### Reopen condition

If the mismatch recurs, preserve the raw RPC responses and exact Anvil state,
replay both calls outside the actor, and compare Cast with a direct JSON-RPC
transport before changing the ABI or adding retries.

## D024: durable finalized prefix and disposable range tail

Status: SETTLED.

### Context

The first semantic reader implementation coupled three different concerns:

1. durable progress through finalized `F`;
2. discovery and reaction through latest `H`; and
3. proof that every live-tail log and point read belonged to one branch.

It walked backward from `H` to prove ancestry, queried logs separately at each
tail block hash, staged newly finalized events, and persisted them only after
semantic reads and a final canonicality check succeeded. This was a defensible
fail-closed construction, but it treated a disposable action hint as if it were
durable database state. It also multiplied block and log RPC calls with tail
length and allowed a transient latest-state failure to hold back independently
safe finalized progress.

PRT mutators provide the simpler safety boundary. They revalidate the current
state before every transition. If a reorg, race, duplicate, or stale
observation changes the applicability of calldata, the transaction either
performs a still-legal transition or reverts. No off-chain observation can
force an incorrect contract transition.

### Options considered

1. Keep the exact ancestry walk, per-block hash log queries, staged
   persistence, and final canonicality recheck.
2. Keep exact live-tail acquisition but persist finalized progress before
   reading the tail or semantic views.
3. Persist finalized progress independently, fetch the live tail by number
   range, pin only semantic point reads to sampled hash `H`, and let the next
   tick repair stale scratch state.
4. Read only finalized state and give up latest-block reaction.

### Decision and rationale

Use option 3:

1. replay the persisted structural prefix;
2. sample finalized `F` and extend through it with bounded number-range
   queries;
3. validate any returned log at the finalized boundary against sampled
   `F.hash`, globally normalize the discovered streams, and persist the
   structural harvest and watermark;
4. only then sample latest `H`, clone the finalized fold, and extend the clone
   over `F + 1..H` with the existing recursively bisected range reader;
5. pin semantic point calls to `H.hash` without `requireCanonical`; and
6. plan and submit from that disposable product.

The global ordering and dynamic child-discovery invariants remain strict.
Removed transaction-metadata cross-checks and ancestry proofs did not
contribute to either invariant. A malformed range response, event decode
failure, or cross-view semantic contradiction still rejects the volatile tick.

This is not a claim that response size is free. It can affect latency,
bandwidth, response caps, and a provider's internal work. It is a claim that
per-block request multiplication has no protocol value here. Provider billing
also commonly gives calls or methods their own unit weights. As of 2026-07-24,
Alchemy assigns `eth_getLogs` a fixed compute-unit weight, QuickNode charges
standard Ethereum methods per call, and Chainstack counts one JSON-RPC call as
one request even when a bounded `eth_getLogs` response contains many events:

- https://www.alchemy.com/docs/reference/compute-unit-costs
- https://www.quicknode.com/api-credits
- https://docs.chainstack.com/docs/request-units

These commercial policies can change and are operational evidence, not a
correctness premise. The existing recursive split remains the compatibility
mechanism for gateways that reject large ranges or responses.

### Consequences

- a latest-head, latest-tail, or semantic-view failure cannot delay finalized
  persistence;
- no unfinalized event is persisted;
- one tick may combine stale range events with point state at sampled `H`;
- the adapter may reject that combination, and otherwise any resulting stale
  mutation is revalidated by the contract;
- a reorg requires no explicit rollback or canonicality proof for scratch
  state; and
- the next poll is the recovery mechanism.

The same reasoning does not weaken finalized ingestion. The node still trusts
the provider's finalized tag, checks the boundary hash when a returned log
exists there, and never rolls back the persisted watermark.

### Reopen condition

Reopen exact live-tail proofs only if a mutator stops fully revalidating its
transition, a legal-but-wrong action becomes expressible, or measured range
behavior causes missed deadlines that recursive splitting cannot address.

## Fold taxonomy

The discussion exposed several different designs that are all called a
"fold." Keeping them distinct avoids arguing past one another.

| Regime | Key discovery | Current-state interpretation | Hero cold start | GC consequence | Current disposition |
| --- | --- | --- | --- | --- | --- |
| Structural history fold plus raw overlay | Replay the five current events | Raw point reads plus Rust/Lua logic | Replay persisted prefix and live tail | Complete forest is known | Pre-campaign baseline |
| Fully semantic event-sourced fold | Replay rich transition events | Fold reconstructs phases, clocks, and schedules | Full replay | Can enumerate all work | Parked; duplicates time semantics and grows hot logs |
| Structural fold plus typed point views | Replay current events | Contract-local facts from views; actor policy in planner | Same structural replay | Same fold serves GC and Hero | Implemented Campaign 1 regime |
| View-dominant aggregate | Structural fold discovers keys | One large current snapshot per key or tournament | Same structural replay | Same enumeration unless storage changes | Deferred optimization |
| Keyed latest-state streams plus discovery fold | Structural events discover dynamic keys | Last value per key plus current time | Still rebuilds discovery and finds latest values | Discovery remains; latest match and child schedules may simplify the GC reducer | Deferred experiment |
| Personalized commitment stream | Filter by local commitment and follow child path | Latest subject schedule plus current time | Intended Hero-only shortcut | Separate global fold still required | Parked |
| Views-only Hero with pointer storage | On-chain pointers discover local path | Total views | History-free over local path | GC fold remains unless active sets move on chain | Parked |
| Fully enumerable on-chain read model | Contract arrays, pages, or indexes | Views | History-free | Fold can disappear | Explicit non-goal for Campaign 1 |

The dynamic keyed-stream idea is not disproved by the inevitability of a fold.
Its value may be to change the fold's category from semantic transition replay
to discovery plus latest-value selection. The open empirical question is
whether that simplification remains material after dynamic discovery, timers,
tombstones, pinning, and reorg handling are counted.

## Preserved exploration: personalized latest-update interface

Snapshot status: SUPERSEDED AS THE CURRENT CAMPAIGN, PRESERVED AS A PARKED
DESIGN.

The remainder of this file is the earlier proposal almost verbatim. Its
history-free Hero target, candidate schedules, event query shapes, transition
table, and empirical criteria remain useful if D007 or D009 is reopened.
Historical heading levels and status labels are intentionally preserved.

The code remains the source of truth for current behavior. This snapshot never
became an implementation specification.

## Purpose

Redesign the interface between the PRT contracts and their Rust and Lua clients
now that contract, node, and reference-client changes may be coordinated.

The target interface should:

- expose protocol concepts rather than packed storage representations;
- let the honest Hero choose an action from rich, phase-safe domain types;
- make a cold Hero depend on at most the latest relevant update for each
  commitment on its recursive path, plus the observed block and local machine
  data;
- keep global tournament discovery and garbage collection in the node;
- keep persistent contract storage compact;
- make every time-dependent action boundary explicit;
- support one pinned and reorg-consistent observation of the chain.

## Scope and non-goals

The history-free target applies to the healthy Hero path. It does not apply to
garbage collection.

GC must still discover unrelated matches, expired children, and tournaments
that finish without a winner. It may retain an event fold over the active
tournament forest.

This design does not:

- move active-match enumeration or historical indexing into contract storage;
- change computation commitments, proof formats, or dispute geometry;
- make an event query constant-time on standard Ethereum JSON-RPC;
- settle event gas or data-availability costs before correctness and
  ergonomics have been validated;
- make observer views authoritative for later transactions. Mutators always
  revalidate against current state.

## Decision record

Labels:

- `AGREED`: established direction unless new evidence invalidates it.
- `LEADING`: current preference, still subject to the prototype.
- `OPEN`: deliberately unsettled.

| Status | Decision |
| --- | --- |
| AGREED | Design the Rust domain types before finalizing the Solidity ABI. |
| AGREED | Contract, Rust, and Lua interfaces may change together. |
| AGREED | Prefer node complexity over persistent on-chain indexing. |
| AGREED | Keep the global GC fold outside the history-free Hero target. |
| AGREED | Observer views should be total for ordinary lifecycle states and typed by variant. |
| LEADING | Use personalized Hero events keyed by commitment. |
| LEADING | Put the subject commitment in topic1 for every personalized event. |
| LEADING | Expose one total match-phase view followed by typed `try...` projections. |
| LEADING | Keep the full `Match.Id` out of ordinary match storage. |
| OPEN | Fully self-contained schedule events versus smaller locator events followed by typed views. |
| OPEN | A wildcard topic0 query versus an allowlisted topic0 OR-filter. |
| OPEN | Exact event names, fields, and which fields are indexed. |
| OPEN | Whether existing structural events are replaced, retained for GC, or derived from the new vocabulary. |

## Current baseline

The current contract stores a match under the hash of its ordered commitment
pair. The full pair is supplied by callers and is not stored beside ordinary
match state. The exception is the child-to-parent link required for recursive
settlement.

The current `Match.State` tuple is phase-overloaded. Its node fields mean active
bisection data before sealing and sealed divergence data afterward. The current
clock tuple also exposes storage sentinels: zero allowance is uninitialized and
zero start instant means paused.

The Rust reader currently:

- folds the finalized structural event prefix;
- refetches the reorg-sensitive tail;
- discovers linked child tournaments;
- overlays match, clock, result, and tournament views at one pinned block.

This is a sufficient and deliberate baseline. The redesign should remove
unnecessary Hero history and raw-state interpretation without moving the
reader's database into the EVM.

Relevant sources:

- [implemented dispute game](../dispute-game.md)
- [current node architecture](../node-architecture.md)
- [current match representation](../../prt/contracts/src/tournament/libs/Match.sol)
- [current tournament implementation](../../prt/contracts/src/tournament/Tournament.sol)
- [current Rust tournament reader](../../cartesi-rollups/node/src/tournament/reader.rs)
- [current Rust event fold](../../cartesi-rollups/node/src/tournament/fold.rs)

## Domain model first

The generated Solidity types are wire types. The Rust boundary validates and
converts them into domain types before Hero code sees them.

An initial match model is:

```rust
enum MatchView {
    Absent,
    Bisecting(BisectingMatch),
    ReadyToSealLeaf(ReadyToSealMatch),
    ReadyToSealInner(ReadyToSealMatch),
    SealedLeaf(SealedLeafMatch),
    SealedInner(SealedInnerMatch),
}

struct ActiveSegment {
    revealing_parent: Digest,
    waiting_children: [Digest; 2],
    start_position: U256,
    start_cycle: U256,
    remaining_height: u64,
}

struct TimeoutWindow {
    claim_at: Instant,
    claim_before: Instant,
}

struct LeafSchedule {
    prove_before: Instant,
    timeout: Option<TimeoutWindow>,
}
```

The Hero-facing position is richer than the stored match phase:

```rust
enum HeroPosition {
    Unmatched,
    Candidate(CandidateReadiness),
    Bisect(BisectRequest),
    Seal(SealRequest),
    WaitForOpponent(TimeoutWindow),
    ResolveLeaf(LeafResolution),
    EnterChild(ChildRequest),
    Resolved(CommitmentOutcome),
}
```

The planner should have a shape similar to:

```rust
fn plan(
    position: HeroPosition,
    observed_at: Instant,
    local: &LocalCommitment,
) -> Option<HeroAction>;
```

It must return at most one action for one observation.

## Dangling commitments are tournament candidates

Every dangling commitment is a tournament-winner candidate. The useful
distinction is not "waiting" versus "candidate"; it is whether tournament
resolution has become schedulable.

```rust
enum CandidateReadiness {
    BlockedByMatches,
    ResolutionScheduled(TournamentResolutionSchedule),
}

enum TournamentResolutionSchedule {
    RootWinner {
        ready_at: Instant,
    },
    InnerWinner {
        parent_commitment: Digest,
        ready_at: Instant,
        eliminate_at: Instant,
    },
}
```

`BlockedByMatches` means at least one unrelated live match still prevents the
tournament from finishing. The candidate has no Hero action, and the instant
of the final match deletion is not known.

`ResolutionScheduled` means there are no live matches. The current result is
therefore determined by time alone unless a later join, still permitted before
closure, supersedes the schedule.

All schedules in this design are revocable projections of current state, not
promises that no later transaction can supersede them. This is already true of
a bisection timeout schedule, which a successful response supersedes.

### Exact tournament boundaries

Let:

```text
close_at  = start_instant + tournament_allowance
finish_at = max(close_at, last_match_deleted)
```

`finish_at` becomes a usable schedule only when `matchCount == 0`.

For a root tournament with a dangling candidate:

```text
result usable at: [finish_at, infinity)
```

Root tournaments are not eliminable.

For an inner tournament with a dangling candidate whose paused allowance is
`A`:

```text
winner propagation: [finish_at, finish_at + A)
child elimination:  [finish_at + A, infinity)
```

At the exact `finish_at + A` boundary, the winner is no longer usable and child
elimination is eligible.

For an inner tournament with no dangling candidate:

```text
child elimination: [finish_at, infinity)
```

A root tournament with no dangling candidate has failed without a result. It
cannot be eliminated because it has no parent.

### Proposed candidate and tournament events

These names are provisional:

```text
DanglingCandidate(subject)

RootTournamentResultScheduled(
    subject,
    readyAt
)

InnerTournamentResultScheduled(
    subject,
    parentCommitment,
    readyAt,
    eliminateAt
)

InnerTournamentEliminationScheduled(
    parentMatchIdHash,
    eliminateAt
)

RootTournamentFailedScheduled(
    failedAt
)
```

The first three belong to a commitment's personalized stream. The last two are
tournament-level signals for GC, parent cleanup, or root failure reporting.

When a dangling candidate exists while other matches are live, emit
`DanglingCandidate`. When the final unrelated match is deleted, refresh that
candidate with the appropriate result schedule.

These wire events are refinements of one `Candidate` domain state, not distinct
commitment lifecycle states. Separate signatures preserve typed payloads:
`DanglingCandidate` has no exact schedule, while the root and inner result
variants do.

When no candidate exists and the last match is deleted, emit the appropriate
no-winner tournament schedule. A later join before closure may supersede it;
GC already owns the global fold needed to observe that change.

## Personalized event stream

### Key and query

Every Hero-relevant event places its subject commitment in the first indexed
argument, which is topic1:

```text
(tournament address, subject commitment)
```

A raw JSON-RPC query may leave topic0 unconstrained:

```json
{
  "address": "0xTournament",
  "fromBlock": "0x...",
  "toBlock": "0x...",
  "topics": [null, "0xSubjectCommitment"]
}
```

The client must allowlist and decode known event signatures before selecting
the latest update. An unknown same-address event must never supersede a valid
Hero update merely because its topic1 happens to match.

An alternative filter constrains topic0 to the OR of every personalized event
signature:

```json
{
  "topics": [
    ["0xBisect", "0xTimeout", "0xSeal", "0xLeaf", "0xChild", "0xCandidate"],
    "0xSubjectCommitment"
  ]
}
```

Both forms require provider-level validation.

### Ordering and pinning

The latest recognized update is selected by chain position:

```text
(block_number, transaction_index, log_index)
```

RPC array order is not the authority.

Logs and any companion views must observe the same pinned head. The client must
also protect against a reorg between log retrieval and point reads, either by
using hash-pinned calls where supported or by checking the sampled block hash
before accepting the observation.

### Identity

A match action requires the full ordered `Match.Id`.

For a strict latest-update-only design, every match-specific personalized
event must carry enough information to reconstruct it:

- subject commitment;
- opponent commitment;
- subject side in the ordered pair;
- match ID hash for validation and correlation.

If later events carry only the hash and the client retrieves the identity from
an earlier creation event, the design remains local and lightweight but is no
longer literally latest-update-only.

## Proposed personalized variants

The following names and payload partitions remain provisional:

```text
BisectRequested
TimeoutScheduled
SealRequested
LeafResolutionScheduled
ChildTournamentRequested
DanglingCandidate
RootTournamentResultScheduled
InnerTournamentResultScheduled
CommitmentEliminated
```

Every match-specific variant carries the common match identity described
above.

`BisectRequested` and `SealRequested` also carry:

- the active segment;
- the responder deadline;
- the tournament kind when it changes the sealing verb.

`TimeoutScheduled` carries the half-open interval during which the subject can
win by timeout.

`LeafResolutionScheduled` carries:

- the named sealed divergence;
- the strict proof deadline;
- the subject's optional timeout-winning interval.

`ChildTournamentRequested` carries:

- the child address;
- the sealed divergence and base cycle;
- enough child descriptor information to compute and join the subject's child
  commitment, or an explicit reference to one total descriptor view.

`CommitmentEliminated` is terminal for that subject in that tournament.

## Transition table

Notation:

- `C`: newly joined commitment
- `D`: pre-existing dangling candidate
- `W`: match winner
- `L`: match loser

| Trigger | Final personalized updates | Meaning and later action | GC or tournament-level update |
| --- | --- | --- | --- |
| Tournament creation | None | A global descriptor event or total view bootstraps geometry and timing. | `TournamentOpened` or equivalent. |
| `join(C)`, no dangling, other matches active | `DanglingCandidate(C)` | C is dangling but result time depends on unresolved matches. | None. |
| `join(C)`, no dangling, no active matches | Root or inner result schedule for C | Result becomes usable at closure unless a later join supersedes it. | Inner schedule also carries its elimination boundary. |
| `join(C)` with dangling D | `BisectRequested(D)` and `TimeoutScheduled(C)` | D is the initial responder; C may claim during D's missed-response window. | A live match is created. |
| `advanceMatch`, new height greater than one | New bisection and timeout updates with roles swapped | The new coordinate and deadlines supersede both prior updates. | None. |
| `advanceMatch`, new height equal to one | `SealRequested` and `TimeoutScheduled` | The responder must perform the correct leaf or inner seal. | None. |
| `sealLeafMatch` | `LeafResolutionScheduled` for both subjects | Each side can prove before the first expiry; only the longer side has a later timeout-winning interval. | Double elimination belongs to GC. |
| `sealInnerMatchAndCreateInnerTournament` | `ChildTournamentRequested` for both parent subjects | Each Hero computes and follows only its child commitment. | The parent waits; GC may later eliminate the child. |
| Single-winner proof, timeout, or child propagation | `CommitmentEliminated(L)` plus W's final candidate, result, or new-match update; possibly a new-match update for D | W is reinserted into asynchronous pairing only after its clock is settled. | Up to three subjects change. |
| Match or child double elimination | `CommitmentEliminated` for both match subjects | Neither subject has another Hero action. | If this was the last match, refresh D with a result schedule or emit a no-winner tournament schedule. |
| Time crosses a match deadline | No event | The existing schedule changes the planner result. | GC acts at the double-elimination boundary. |
| Time crosses result readiness | No event | Root result or inner propagation becomes eligible. | Existing schedule already names the boundary. |
| Time crosses inner elimination boundary | No event | Inner winner propagation is no longer valid. | Parent GC may eliminate the child and parent match. |
| `tryRecoveringBond` | No Hero strategy update | Dispute topology and result are unchanged. | Payment reporting must not supersede the strategy stream. |

### Final-projection emission rule

Every successful outer transition emits one final personalized projection for
each affected subject after all state mutations are complete.

This rule is required because current winner resolution may requeue and pair
the survivor before deleting the old match. Existing structural event order is
therefore not automatically a valid latest-state order for the survivor.

A single resolution may affect:

1. the loser;
2. the survivor;
3. a pre-existing dangling candidate paired with the survivor; or
4. an unrelated dangling candidate whose result becomes schedulable when the
   last match is deleted.

Intermediate helper events must not supersede these final projections.

## Total typed views

The proposed ABI encodes a sum type as one total tag view plus typed optional
projections:

```solidity
enum MatchPhase {
    ABSENT,
    BISECTING,
    READY_TO_SEAL,
    SEALED
}

function matchPhase(Match.IdHash idHash)
    external
    view
    returns (MatchPhase);

function tryBisectingMatch(Match.Id calldata id)
    external
    view
    returns (bool present, BisectingMatchView memory value);

function tryReadyToSealMatch(Match.Id calldata id)
    external
    view
    returns (bool present, ReadyToSealMatchView memory value);

function trySealedMatch(Match.Id calldata id)
    external
    view
    returns (bool present, SealedMatchView memory value);
```

`present` means only that the requested structural variant exists at the
observed block:

- matching phase: `true` and a fully meaningful value;
- absent, deleted, or another phase: `false` and a canonical zero value;
- impossible invariant violation after the phase matches: revert.

The separate phase view distinguishes absence from another live variant.
Returning `(bool, phase, value)` would make the boolean redundant. If a typed
projection must stand alone, returning `(actualPhase, value)` is more
informative.

The tag and projection calls must be pinned to the same block. The Rust reader
may batch phase calls and then batch only the selected projections.

The exact projection fields remain open. The current leading shape exposes:

- named active-segment coordinates instead of the raw overloaded match tuple;
- responder side;
- named sealed divergence;
- the contract-authoritative timeout classification or schedule;
- no raw clock sentinel interpretation in Hero code.

Leaf versus inner is a tournament property. Solidity may expose the three
stored structural variants while Rust enriches ready and sealed values into
leaf and inner variants.

## Reader and responsibility split

### Hero reader

The target Hero reader:

1. knows the root tournament and its local root commitment;
2. fetches the latest recognized personalized update for that commitment at a
   pinned head;
3. validates and converts it into `HeroPosition`;
4. selects at most one action;
5. when directed into a child, computes the local child commitment and repeats.

It does not reconstruct unrelated matches or the whole nested forest.

### GC reader

The GC reader retains global structure:

- every live match;
- every reachable child tournament;
- double-elimination eligibility;
- no-winner and expired-child cleanup.

Its fold may consume the same event vocabulary, but it is not constrained to
latest-update-only operation.

### Locator versus self-contained schedule

Two personalized designs remain candidates:

1. `Locator`: the latest event identifies the subject's current structural
   variant and full match identity; the reader obtains semantic state through
   the matching typed view.
2. `Schedule`: the latest event itself contains every coordinate and time
   boundary needed by the Hero; views are used only for reconciliation,
   diagnostics, and generic consumers.

The prototype must determine whether eliminating point reads justifies the
larger and more duplicated event payload.

## Empirical validation

Compare:

1. the current symmetric structural stream plus fold and overlay;
2. personalized locator events plus typed views;
3. personalized self-contained schedule events.

The current reader and Hero form the reference oracle. At every event prefix
and every relevant block between events:

```text
current Fold + Overlay + Hero
    ==
candidate latest update + pinned block + local machine data
```

For the self-contained schedule candidate, match and clock point reads may
construct the reference answer but must not be candidate inputs.

### Candidate schedule oracle

Acceptance is semantic, not based on event count or coverage percentage. The
scheduler must not serve as its own oracle.

Let:

- `B` be the pinned observation block;
- `F = max(close_at, last_match_deleted)` once no match remains; and
- `W = F + winner_allowance` for an inner tournament with a dangling
  candidate.

| State at B | Required schedule |
| --- | --- |
| One or more live matches | No terminal result or tournament-elimination action. A dangling commitment remains a blocked candidate. |
| No match, `B < F`, dangling C | Candidate C; wake at F. |
| No match, `B < F`, no dangling commitment | No-winner candidate; wake at F. |
| Root, `B >= F`, dangling C | Persistent result for C. |
| Root, `B >= F`, no dangling commitment | Terminal root failure; no elimination. |
| Inner, `F <= B < W`, dangling C | Propagate C; retain an elimination wake at W. |
| Inner, `B >= W`, dangling C | Eliminate the child only. |
| Inner, `B >= F`, no dangling commitment | Eliminate the child only. |

Result propagation and tournament elimination are mutually exclusive at one
observation block. A stored timer is only a wake-up hint. Before submitting an
action, the consumer must revalidate the latest update against one pinned chain
snapshot.

Required traces:

- commitment one and commitment two Hero orientations;
- every bisection role swap;
- transition into ready-to-seal;
- leaf proof before the first deadline;
- both single-winner timeout orientations;
- exact equal and unequal deadline boundaries;
- immediate survivor re-pairing with a third commitment;
- dangling candidate blocked by unrelated matches;
- unrelated final deletion making that candidate schedulable;
- scheduled result superseded by a new join before closure;
- one-, two-, and four-level recursive disputes;
- child result readiness, winner expiry, and parent elimination;
- no-winner child elimination;
- same-block multiple updates;
- live-tail reorg and cold restart.

Supersession traces must include:

1. A dangling candidate followed by a second join at `F - 1`.
2. A no-winner schedule followed by a legal pre-close join.
3. A resolved winner left dangling and then re-paired before closure.
4. A late join whose reduced allowance changes W.
5. A join attempted exactly at F, which must revert and leave the eligible
   result unchanged.
6. A fetched batch containing both a candidate update and a later join. The
   client must process every log through the pinned head before acting.
7. Exact `W - 1` and W observations.
8. Restart, duplicate delivery, and delayed execution of a stale wake.

Query validation:

- `[null, subject]` returns every recognized personalized update and no update
  for another subject;
- an allowlisted topic0 OR-filter produces the same recognized sequence;
- unknown signatures cannot supersede a recognized update;
- latest selection is independent of RPC result ordering;
- cold and persisted-prefix readers choose the same update and action;
- logs and companion views never produce an accepted mixed-head observation.

Measurements:

- requests per Hero tick;
- returned log count and filtered fraction;
- topic and data bytes on chain;
- raw and compressed RPC response bytes;
- cold and warm query latency;
- decode time and persisted bytes;
- contract log expansion versus Hero-specific response reduction.

Gas is a later guardrail, not the first selection criterion.

Go/no-go requirements:

- zero Hero-action mismatches at every tested prefix and time boundary;
- supported providers implement the selected topic filter correctly;
- no stale reorg branch or mixed observation is accepted;
- cold restart and warm operation are semantically identical;
- the selected design shows a material simplicity or query benefit over the
  current reader.

## Implementation sequence after design selection

1. Settle the exact Rust domain types and legal state transitions.
2. Settle exact Solidity event signatures and typed view structs.
3. Prototype locator and self-contained schedule variants against recorded and
   synthetic traces.
4. Select the event richness and query form from the differential evidence.
5. Implement contract views and events with exhaustive phase and boundary
   tests.
6. Regenerate bindings and implement one strict Rust wire-to-domain adapter.
7. Replace the Hero's raw fold-and-overlay interpretation with the selected
   reader.
8. Align the Lua reference client independently.
9. Retain or reshape the GC fold and prove that unrelated cleanup coverage is
   unchanged.
10. Run contract, Rust, Lua, recursive, reorg, and end-to-end gates.
11. Promote stable invariants from this plan into living docs and code comments;
    archive this plan when implementation is complete.

## Open questions for the next iteration

1. Should personalized updates use distinct event signatures or one tagged
   `CommitmentUpdate` wire event?
2. Does every update repeat opponent and side for strict latest-only identity,
   or may the reader retrieve one earlier identity event?
3. Does `TimeoutScheduled` carry raw deadlines, a normalized winning interval,
   or both?
4. Does a child request repeat its descriptor or point to one total child
   descriptor view?
5. Which fields belong in both schedule events and typed projections, and
   which have one authority?
6. Should tournament-level no-winner schedules have their own superseding
   global status stream, or remain GC-fold inputs?
7. Can the new event vocabulary replace current structural events without
   making GC or general indexing worse?
8. Which exact transition corpus and provider set form the prototype's
   acceptance evidence?
