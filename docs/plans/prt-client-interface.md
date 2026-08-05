# PRT contract-client interface campaign

Status: IMPLEMENTED (updated 2026-07-25). The six-view observer ABI, Rust
semantic domain, disposable range-tail reader, strict adapter, pure Hero
planner, intent-preparation pipeline, single-dispatch Hero actor, deterministic
GC planner, independent Lua semantic pipeline, and replaceable transaction lane
described below are implemented in the current campaign tree. Both exact
sealed-leaf end-to-end boundaries pass. One non-reproduced Lua cross-view
contradiction remains a fail-closed validation watch.

Reconciled 2026-08-04 onto the merged contract review (PR #273): the observer
side enum now lives in `ITournamentObserver` (the Match library dropped it),
sealed projections read the canonical commitment-order storage without a
parity argument, observer invariant guards follow the assert terminology, the
Lua harness reads the renamed `responseBudget` argument shape, and the gas
witnesses were re-pinned for the observer-bearing bytecode with unchanged
allocations.

The code remains the source of truth. The companion
[decision log](prt-client-interface-decisions.md) preserves the reasoning,
alternatives, scheduling experiments, and reopening conditions behind this
plan.

## Current position

Campaign 1 should make a small, coherent improvement around the event fold that
already exists:

- keep contract storage, mutators, and the five structural events unchanged;
- keep the fold as the node's history-derived structural index;
- add small, total, typed point views for contract-local protocol facts;
- convert wire values immediately into rich Rust domain types;
- assemble one domain snapshot from the fold and point views at one pinned
  block; and
- make a pure Hero planner choose at most one intent before local data is
  fulfilled and one Hero transaction is sent.

This is a staged semantic boundary, currently favored toward small point views.
It is not a decision to make the fold a mere address book, nor a decision to
move every useful derivation into Solidity.

The central design question is:

> Which facts are naturally history-derived structure, and which facts are
> naturally current contract-state projections?

The answer should minimize duplicate authorities. It should not minimize
either the fold or the views for its own sake.

## Decision dashboard

Labels:

- `SETTLED`: an implementation constraint unless new evidence reopens it.
- `FAVORED`: the current choice, still subject to interface review and tests.
- `OPEN`: deliberately unsettled and relevant to the current campaign.
- `DEFERRED`: outside Campaign 1 and not a blocker.
- `PARKED`: explored seriously, with an explicit reopening condition.

| Status | Decision |
| --- | --- |
| SETTLED | Design the Rust domain types and transition table before fixing the Solidity ABI. |
| SETTLED | Keep the existing event fold in Campaign 1. |
| SETTLED | Keep storage, mutators, and the five structural event signatures unchanged in Campaign 1. |
| SETTLED | Observer views are total for ordinary lifecycle states and expose typed variants rather than storage encodings. |
| SETTLED | Multiple point reads are acceptable when every read belongs to one pinned observation. |
| SETTLED | The pure Hero planner returns zero or one Hero intent for one observation. |
| SETTLED | Mutators remain the final authorization boundary and revalidate current state. |
| SETTLED | Start with small typed point views and compose them with the existing fold in one strict Rust adapter. |
| SETTLED | Let the contract own phase, orientation, clock, timeout, and result semantics; let the fold own enumeration and relationship directions absent from contract lookup; let the planner own actor-relative policy. |
| SETTLED | Hash-keyed match projections return `(actualPhase, payload)`; a separate full-ID timeout view also returns `actualPhase`. |
| SETTLED | Do not add a standalone phase call without a demonstrated phase-only consumer or batching result. |
| SETTLED | Campaign 1 exposes current planner dispositions only. Future schedules belong to a wake-driven campaign. |
| SETTLED | Derive Leaf versus NonLeaf domain variants from one validated immutable tournament descriptor, not duplicate wire variants. |
| SETTLED | The child tournament's immutable descriptor owns its level geometry and base cycle; the fold owns provenance and reachability. |
| SETTLED | Use one total tagged tournament-standing view for active, awaiting-closure, root-result, inner-winner, and inner-elimination dispositions. |
| SETTLED | Keep commitment heights and total row extents below 256 so the clients can represent every full span. |
| SETTLED | Land contract plus Rust first, then migrate Lua independently in the same campaign. |
| SETTLED | Persist the finalized fold independently, rebuild the unfinalized tail with bounded number-range queries, and pin semantic point calls to sampled hash `H` without requiring continued canonicality. |
| SETTLED | Keep `plan_gc -> Vec<GcIntent>`, run it only after Hero policy on the same accepted observation, and consume at most one deterministic intent. |
| SETTLED | Replace Alloy's cached nonce filler with one exclusive-signer slot at the `latest` mined account nonce; submission is fire-and-forget after bounded RPC acceptance, with no receipt or confirmation dependency. |
| OPEN | Explain or explicitly disposition the one non-reproduced Lua same-head phase contradiction; its failure policy remains fail-closed. |
| SETTLED | The implemented six-view observer raises Tournament runtime from 13,832 to 16,622 bytes and leaves 7,954 bytes of EIP-170 headroom. |
| DEFERRED | Aggregate or batch views and any one-call-per-tournament target. |
| DEFERRED | Removing raw getters after all consumers migrate. |
| DEFERRED | Event enrichment and provider topic-filter experiments. |
| PARKED | Personalized latest-update schedules and storage pointers. |
| DEFERRED | Dynamic keyed latest-state streams after Campaign 1 provides their oracle and evidence. |

## Implemented Campaign 1 evidence

The implementation has crossed the intended semantic boundaries; deferred
designs and one fail-closed empirical watch remain:

- `ITournamentObserver` defines six total semantic reads: three phase
  projections, full-ID timeout status, immutable tournament descriptor, and
  tagged tournament standing. `Tournament` implements that interface while the
  legacy raw getters remain available for harness assertions, differential
  tests, and a separate ABI-retirement decision.
- The reader samples finalized `F`, extends and persists the structural fold
  through it, then samples latest `H`, rebuilds `F + 1..H` with recursively
  bisected number-range queries, and pins semantic point reads to `H`. The live
  product is disposable; the reader neither proves its ancestry nor requires
  `H` to remain canonical.
- The semantic adapter is the acting Rust path. Raw-getter comparison remains
  test-only differential scaffolding; it is not sampled on the
  deadline-sensitive action path.
- One accepted observation now flows through
  `observe -> assemble context -> plan one intent -> prepare local material ->
  dispatch once`. Planning performs no provider reads or machine mutation,
  preparation sends no transaction, and the dispatch seam maps one prepared
  variant to exactly one arena mutation.
- `plan_gc` is pure and actor-neutral. It returns every currently legal cleanup
  in deterministic global innermost-first order, preserving fold creation order
  within one depth. After Hero policy returns Wait, or returns terminal Won
  without an arena action, the actor retains at most the first GC intent from
  that same accepted observation; the epoch loop may submit only that retained
  intent.
- The epoch loop gives Hero same-tick priority, suppresses settlement while the
  Hero is running or local settlement material is still being prepared, and
  attempts at most one settlement mutation before considering cleanup.
  Settlement is eligible only after `Won`; `Lost` and `FailedNoWinner` are
  explicit fail-closed outcomes and submit no further mutation.
- The Lua reference client independently implements
  `semantic reader -> fold -> adapter -> context -> planner -> fulfiller ->
  dispatcher`. The production sybil runner uses this path; deliberately invalid
  test claims require an explicit adversarial-mode opt-in and remain rejected
  by the honest fulfiller.

Hero, cleanup, and settlement now share the implemented D017 transaction lane.
Its disabled-automining test proves that identical work is rebroadcast and
changed work is replaced at the same mined nonce; no `n + 1` queue is allocated
while `latest` remains at `n`. A separately configured submit endpoint must
support `eth_chainId` for the construction-time chain check and
`eth_sendRawTransaction` for bounded submission.

## Goals

Campaign 1 should:

- remove phase-overloaded `Match.State` tuples from Rust Hero and GC strategy
  code;
- remove raw clock sentinels and duplicated timeout classification from Rust
  strategy code;
- make absent, wrong-variant, and impossible states distinguishable;
- retain the fold where it is the cheapest and most reliable index;
- make the fold/view join an explicit, tested boundary;
- make action priority a pure, reviewable transition table;
- keep cold restart, nested-tournament discovery, and GC coverage intact; and
- provide an incremental path to aggregate views or enriched events only if
  later evidence justifies them.

## Explicit non-goals

Campaign 1 does not:

- remove history from a full validator;
- eliminate or weaken the GC fold;
- move active-set enumeration into contract storage;
- add commitment-to-match or match-to-child pointer mappings;
- change event signatures, indexed topics, or emission order;
- introduce personalized or schedule events;
- require a custom batch view;
- remove legacy raw getters before every consumer has migrated;
- change computation commitments, proof formats, dispute geometry, or clock
  behavior; or
- make an observer view authoritative for a later transaction.

Gas calibration and event-cost comparison remain separate work. Campaign 1
should still run ordinary regression gates, but cost is not the design selector
for this iteration.

## Pre-campaign baseline

Before this campaign, the reader already had two complementary sources:

1. A fold over five structural event types:
   `CommitmentJoined`, `MatchCreated`, `MatchAdvanced`, `MatchDeleted`, and
   `NewInnerTournament`.
2. A pinned point-read overlay over reachable tournaments.

The fold discovered:

- tournament addresses and parent-child topology;
- joined commitments and their immutable final states;
- the full ordered `Match.Id`;
- match creation and deletion;
- each commitment's most recent engagement; and
- the child address created from a sealed parent match.

The raw overlay read:

- live match coordinates;
- commitment clocks;
- root and inner tournament winners;
- elimination readiness; and
- tournament level constants.

That split existed for concrete reasons that still govern the semantic reader:

- Solidity mappings are intentionally not enumerable.
- The contract stores matches by the hash of an ordered commitment pair; it
  does not store a commitment-to-current-match index.
- The contract stores the child-tournament-to-parent-match settlement link,
  while `NewInnerTournament` gives the node the parent-match-to-child-tournament
  direction needed for discovery.
- `MatchAdvanced` cannot determine a live position when equal child hashes make
  the descent direction ambiguous.
- Events do not identify enough clock mutations to reconstruct authoritative
  allowances.
- Tournament results and elimination depend on current time and contract
  validity rules.

The baseline was sufficient, but its point reads exposed storage
representations:

- `Match.State` reuses the same node fields before and after sealing.
- Sealed commitment orientation depends on the computation height parity.
- `Clock.State` uses zero values as initialization and pause sentinels.
- Rust and Lua can reconstruct timeout behavior differently from Solidity.
- result methods combine `false`, zero values, and reverts in ways that do not
  directly express the domain variant.

Relevant sources:

- [implemented dispute game](../dispute-game.md)
- [current node architecture](../node-architecture.md)
- [current match representation](../../prt/contracts/src/tournament/libs/Match.sol)
- [current clock representation](../../prt/contracts/src/tournament/libs/Clock.sol)
- [current timeout authority](../../prt/contracts/src/tournament/libs/MatchClocks.sol)
- [current tournament implementation](../../prt/contracts/src/tournament/Tournament.sol)
- [current Rust tournament reader](../../cartesi-rollups/node/src/tournament/reader.rs)
- [current Rust event fold](../../cartesi-rollups/node/src/tournament/fold.rs)

## The Goldilocks ownership rule

Use four questions for every fact:

1. Does answering it require discovering entities or replaying relationships
   that mappings do not enumerate? The fold owns it.
2. Given an entity key, does answering it require decoding contract storage,
   current block time, phase invariants, or contract validity rules? A view owns
   it.
3. Does answering it depend on our commitment, local machine material,
   traversal objective, or action priority? The planner owns it.
4. Is the question whether a transaction is still legal when mined? The
   mutator owns it.

In short:

```text
events enumerate
views interpret contract-local facts
the planner decides for this actor
mutators authorize
```

This is a one-authority rule, not a rule that all current facts belong in one
Solidity snapshot.

### Proposed ownership by fact

| Fact | Natural authority | Reason |
| --- | --- | --- |
| Which tournaments exist | Fold | Child addresses are dynamically discovered from history. |
| Which commitments joined | Fold | The event is the enumerable index and includes immutable final state. |
| Ordered `Match.Id` and match hash | Fold | `MatchCreated` supplies the full pair; contract storage is keyed by its hash. |
| Current live match set | Fold | Creation and deletion enumerate it; Solidity mappings do not. |
| A commitment's current engagement | Fold | No commitment-to-match pointer exists on chain. |
| Parent match to child tournament | Fold | `NewInnerTournament` supplies this direction; storage serves child-to-parent settlement. |
| Child provenance and current reachability | Fold | A valid immutable descriptor does not prove that a parent created or still reaches the child. |
| Tournament level, kind, base cycle, stride, and height | Immutable descriptor view | Each clone owns these facts, including the child's `startCycle`; the parent is a consistency check. |
| Match phase | View | It decodes the overloaded `Match.State` representation. |
| Active segment and live position | View | Equal-hash descent is ambiguous from events. |
| Current responder side | View | It follows the established match phase, parity, and clock shape. |
| Named sealed divergence and commitment orientation | View | The contract owns the parity-sensitive decoding. |
| Optional diagnostic clock variant | View | Zero is a storage sentinel and time is block-relative; strategy consumes timeout disposition instead. |
| Timeout outcome and deferred charge | View | `MatchClocks` is the protocol authority and exact equality matters. |
| Root result, inner winner, failure, and elimination readiness | View | These combine topology state, closure, allowance, and current time. |
| Whether the commitment is ours | Planner | It is actor-relative. |
| Which proof, opening, or child commitment to construct | Planner and local machine | The contract does not have local computation material. |
| Which one valid verb has priority | Planner | This is actor policy over contract facts. |
| Whether the submitted verb remains legal | Mutator | State may change after observation. |

The view may validate a fold-supplied identity or live relationship. It should
not become a second enumerable index for that relationship.

### What must not be duplicated

- The fold and Rust must not independently decode match parity or raw clock
  sentinels.
- Migrated Rust and Lua consumers must not independently reimplement
  `MatchClocks.classifyTimeoutAt`.
- Schedule events and views must not both claim to be current-state authority.
- New pointer mappings must not duplicate fold indexes without a demonstrated
  requirement.
- A large snapshot must not encode Hero policy that belongs in the planner.

The current timeout-alignment work is evidence that individually reasonable
client reconstructions can drift. A "minimal" interface is coherent only if it
moves those contract-local semantic facts behind one contract authority. Merely
renaming the raw tuples would be cosmetic.

## Campaign 1 options

### Option A: typed point facts, interpretive fold retained

Add orthogonal total views for match variants, semantic clocks, timeout status,
and tournament resolution. Keep the present fold and let one Rust adapter
compose the returned facts with its structural indexes.

Benefits:

- smallest ABI and runtime-code increase;
- no new storage, mutation path, or log;
- easy phase-by-phase contract tests;
- several pinned calls are already an accepted operating model; and
- the fold continues doing useful work instead of being artificially weakened.

Risks:

- clients can recombine individually correct facts inconsistently;
- more than one call must belong to exactly one observation;
- a poorly chosen DTO set can leak just enough raw state to recreate the old
  timeout or orientation duplication.

Mitigation: generated wire DTOs never reach Hero or GC. One strict adapter
builds the domain snapshot and rejects inconsistent combinations.

### Option B: view-dominant semantic snapshot

Expose one large match or tournament snapshot that includes most current facts.
The fold becomes mainly an address book and active-set index.

Benefits:

- fewer calls and fewer client-side joins;
- one call can be internally consistent;
- generic consumers receive a ready-made current projection.

Risks:

- a large DTO freezes today's client needs into the ABI;
- optional union fields and canonical zeros are harder to review;
- contract runtime size and view complexity increase;
- actor policy can accidentally migrate on chain; and
- facts already known safely from the fold are computed again.

This remains a valid aggregation optimization, not the default semantic
authority model.

### Option C: staged semantic boundary

Define the rich Rust domain first. Add Option A's small ABI-owned DTOs and point
views as the components of that domain. Assemble them with fold facts through
one adapter. Add an Option B aggregate only if experience shows a concrete
ergonomic or RPC problem.

Benefits:

- preserves the smallest useful Campaign 1;
- keeps the later aggregation path open without inventing a second model;
- makes each contract addition independently testable; and
- lets evidence determine whether the aggregate is worth freezing.

Cost:

- the migration temporarily retains legacy and new read paths;
- the adapter boundary must be designed carefully; and
- a later aggregate is another ABI addition.

### Current recommendation

Use Option C, leaning toward Option A for the first implementation slice.

This recommendation accepts the user's central observation: because the fold
is staying, the design should lean on it for the facts it represents naturally.
It also retains the earlier review's central observation: clients should not
interpret packed contract state or reimplement contract time rules.

The resulting `SemanticSnapshot` is an off-chain domain value assembled from
both sources. It is not necessarily one Solidity method.

## Domain model first

Generated Solidity values are wire types. They are validated and converted
before planner code sees them.

The implemented Rust domain has the following shape; fields are abbreviated
here where their constructors enforce additional invariants:

```rust
enum MatchObservation {
    Absent,
    Live(LiveMatch),
}

struct LiveMatch {
    state: LiveMatchState,
    timeout: TimeoutDisposition,
}

enum LiveMatchState {
    Bisecting(BisectingMatch),
    ReadyToSealLeaf(ReadyToSealMatch),
    ReadyToDelegate(ReadyToSealMatch),
    SealedLeaf(SealedLeafMatch),
    AwaitingChild(AwaitingChildMatch),
}

enum TimeoutDisposition {
    None,
    OneWins {
        deferred_charge: BlockDuration,
    },
    TwoWins {
        deferred_charge: BlockDuration,
    },
    EliminateBoth,
}

enum TournamentKind {
    Leaf,
    NonLeaf,
}

struct TournamentDescriptor {
    address: Address,
    kind: TournamentKind,
    level: u64,
    levels: NonZeroU64,
    initial_hash: Digest,
    base_cycle: U256,
    log2_stride: u64,
    height: NonZeroU64,
}

enum TournamentStanding {
    MatchesActive {
        candidate: Option<Digest>,
        joins: JoinDisposition,
    },
    AwaitingClosure {
        candidate: Option<Digest>,
    },
    RootWinner(RootWinner),
    RootFailed,
    InnerWinner(InnerWinner),
    InnerEliminable {
        reason: InnerEliminationReason,
    },
}

enum InnerEliminationReason {
    NoCandidate,
    WinnerExpired {
        candidate: Digest,
    },
}

enum HeroDecision {
    Terminal(HeroTerminal),
    Wait(WaitReason),
    Act(HeroIntent),
}

enum HeroIntent {
    Join(JoinIntent),
    ClaimTimeout(TimeoutIntent),
    Advance(AdvanceIntent),
    SealLeaf(SealIntent),
    CreateChild(ChildIntent),
    ProveLeaf(ProofIntent),
    PropagateChild(PropagationIntent),
}

enum GcIntent {
    EliminateMatch(EliminateMatchIntent),
    EliminateChild(EliminateChildIntent),
}

enum LocalCommitmentStanding {
    NotJoined,
    Candidate,
    Engaged(Engagement),
    Eliminated(EliminationRecord),
}
```

The match payloads carry named concepts rather than raw slots:

- active segment coordinates;
- the responder side;
- waiting and revealing nodes by role;
- the current leaf position or cycle where meaningful;
- named sealed divergence;
- final states explicitly oriented to commitment one and two;
- no duplicated Leaf versus NonLeaf wire shape; and
- no individual clock representation in Hero strategy.

`OneWins` and `TwoWins` name the surviving commitment side, not the transaction
submitter. Timeout settlement is permissionless. `deferred_charge` may be zero,
including at the exact first deadline and throughout a sealed-leaf
single-winner window.

A separate total clock observer may still be useful for diagnostics. If added,
it should expose `Absent`, `Paused`, `Running`, and `Expired` variants, with
`Expired { overdue: 0 }` at exact equality. It must not become a second strategy
input or reintroduce client-side timeout arithmetic.

Every dangling commitment is a candidate. `MatchesActive` does not distinguish
"waiting for a pair" from "candidate": its optional candidate cannot yet
produce a tournament result because another match is live. Once no match
remains, `AwaitingClosure` says that no result is currently usable. A later
legal join may supersede that observation.

Planner-facing domain variants carry current dispositions, not future wake
times. A diagnostic observer may separately explain the boundary that produced
a disposition, but the polling planner neither needs nor derives it.

The adapter derives `ReadyToSealLeaf` versus `ReadyToDelegate`, and
`SealedLeaf` versus `AwaitingChild`, from the immutable tournament kind. The
word "inner" is avoided for this distinction because a non-root tournament may
itself be the leaf tournament.

### Structural identity in the domain

The fold already owns the full ordered `Match.Id`, current engagement, and child
address. The adapter should join those values to the typed point reads.

Storing the full `Match.Id` in ordinary contract state would add two storage
words per match or require a new packed representation and invariant. It would
not create an enumerable commitment-to-current-match or
parent-match-to-child-tournament lookup without more pointers. Campaign 1
obtains the identity from `MatchCreated`, where it is already enumerable and
required by GC, so no storage change is justified.

### Hero one-intent transition table

The first matching row wins. Descending into a child does not create a second
intent: it continues the same pure planning walk and returns at most one
decision for the whole root observation.

| Tournament or local state | Additional condition | Hero decision |
| --- | --- | --- |
| Root winner | Winner is ours | Terminal `Won` |
| Root winner | Winner is not ours | Terminal actor-relative `Lost` |
| Root failed | No dangling winner | Terminal `FailedNoWinner` |
| Inner winner | Winner maps to our parent commitment | `PropagateChild` |
| Inner winner | Winner maps to the other parent commitment | Terminal `Lost` for this actor's parent path |
| Inner eliminable | Any reason | Wait; `plan_gc` owns `EliminateChild` |
| Not joined | Tournament still accepts joins | `Join` |
| Not joined | Tournament no longer accepts joins | Wait (`JoinsClosed`) |
| Eliminated | No later re-entry exists | Terminal actor-relative `Lost` |
| Candidate | No live engagement | Wait |
| Engaged | Timeout winner is our side | `ClaimTimeout` |
| Engaged | Timeout winner is the other side | Wait |
| Engaged | Both sides are eliminable | Wait; `plan_gc` owns `EliminateMatch` |
| Bisecting, no timeout | We are the responder | `Advance` |
| Bisecting, no timeout | We are not the responder | Wait |
| Ready-to-seal Leaf, no timeout | We are the responder | `SealLeaf` |
| Ready-to-seal NonLeaf, no timeout | We are the responder | `CreateChild` |
| Ready-to-seal, no timeout | We are not the responder | Wait |
| Sealed Leaf, no timeout | Any local proof data is fulfilled later | `ProveLeaf` |
| Awaiting child | Child is reachable and coherent | Recurse and return the child's one decision |

This table is encoded by the pure Rust planner and validated independently from
the sender. Timeout disposition outranks an otherwise actionable phase, and GC
never becomes a fallback Hero verb.

## Typed point-view shape

### Match variants

The implemented external shape makes every projection independently total and
keeps timeout classification orthogonal:

```solidity
enum MatchTimeoutOutcome {
    NONE,
    ONE_WINS,
    TWO_WINS,
    ELIMINATE_BOTH
}

function bisectingMatch(Match.IdHash idHash)
    external
    view
    returns (Match.Phase actualPhase, BisectingMatchView memory value);

function readyToSealMatch(Match.IdHash idHash)
    external
    view
    returns (Match.Phase actualPhase, ReadyToSealMatchView memory value);

function sealedMatch(Match.IdHash idHash)
    external
    view
    returns (Match.Phase actualPhase, SealedMatchView memory value);

function matchTimeoutStatus(Match.Id calldata id)
    external
    view
    returns (
        Match.Phase actualPhase,
        MatchTimeoutOutcome outcome,
        Time.Duration deferredCharge
    );
```

The payloads use role names rather than overloaded storage names:
`revealingParent`, `waitingLeft`, `waitingRight`, segment position and cycle,
responder, sealed agree state and divergence coordinates, and final states
oriented to commitments one and two. Their contract is:

- matching phase: return that phase and a fully meaningful payload;
- absent, deleted, or another phase: return the actual phase and a canonical
  zero payload;
- impossible invariant contradiction after the requested phase matches:
  revert.

The adapter inspects `actualPhase` before decoding the payload. Zero hashes,
durations, and enum discriminants may be valid domain values, so the payload
cannot identify its own presence.

`matchTimeoutStatus` accepts the full supplied ID because ordinary match storage
does not retain the two commitment roots needed to load both clocks. It must:

- check match existence before reading historical clock storage;
- return `(UNINITIALIZED, NONE, 0)` for an absent or deleted match;
- validate the legal phase-and-tournament-kind clock shape;
- delegate classification to the same `MatchClocks.classifyTimeoutAt`
  authority used by mutators;
- return meaningful `deferredCharge` only for `ONE_WINS` or `TWO_WINS`; and
- return canonical zero charge for `NONE` and `ELIMINATE_BOTH`.

Returning `actualPhase` from the timeout view avoids conflating an absent match,
a sealed NonLeaf match with paused parent clocks, and a live match that has not
timed out.

Campaign 1 does not require a standalone `matchPhase`. The ordinary adapter
flow is:

1. call `matchTimeoutStatus(fullId)`;
2. select exactly one hash-keyed phase projection;
3. require both returned phases to agree; and
4. combine the result with the fold and immutable tournament descriptor.

A phase-only method remains a possible later optimization for a demonstrated
consumer. It is not a prerequisite for using a projection.

Reverting merely because the caller selected the wrong ordinary variant is
rejected. Ordinary probing should be total. Reverting remains appropriate for
an impossible internal invariant after a variant has been established.

### Clock and timeout facts

Campaign 1 exposes only the current timeout disposition and deferred charge.
The node is a poller: it samples a new chain observation every configured
interval, currently 30 seconds by default. It does not need a future boundary
to choose an action now. The same rule applies to tournament standing:
Campaign 1 returns whether a result or elimination is usable now, not when it
may become usable later.

Hard rule: if a future consumer needs the instant at which a claim or
elimination becomes valid, that boundary must come from the contract. It must
not be reconstructed from typed clocks in the planner.

For sealed leaves, the correct boundaries are the shorter and longer clock
deadlines. There is no protocol midpoint: treating the former off-chain
midpoint as a boundary is precisely the classifier error this campaign is
removing.

Future schedules are reopened only for wake-driven execution or a measured
polling/RPC bottleneck. They remain part of D009 rather than Campaign 1.

### Tournament descriptor

One total descriptor view exposes the immutable facts needed to interpret every
match in a tournament:

- `level` and `levels`;
- Leaf versus NonLeaf kind;
- commitment `initialHash`;
- `startCycle`, named `baseCycle` at the client boundary;
- `log2step`; and
- commitment height.

Supported commitment heights are 1 through 255, and
`height + log2step < 256`. A height or row extent of 256 would require the
clients to represent the span `2^256` in a 256-bit coordinate type. The
test-only Solidity table validator and both semantic adapters reject it.

The child tournament owns these values in its immutable clone arguments.
The legacy node reads the child's level geometry but derives its base cycle
from the parent match. The semantic adapter instead uses the child's own
`startCycle` as authority.

The fold still owns whether that child was legitimately created by a live
parent match and is reachable from the root. While the parent remains live, the
adapter should validate that the child base cycle equals the parent sealed
match's disputed cycle. An orphan created directly through the permissionless
factory must not become reachable merely because its descriptor is valid.

Leaf versus NonLeaf is derived once from `level` and `levels`. Identical wire
match phases are then enriched into semantic Rust variants such as
`ReadyToSealLeaf`, `ReadyToDelegate`, `SealedLeaf`, and `AwaitingChild`.

### Tournament standing

The current root-result, inner-winner, and eliminability methods now have one
total, tagged counterpart:

```solidity
enum TournamentStanding {
    MATCHES_ACTIVE,
    AWAITING_CLOSURE,
    ROOT_WINNER,
    ROOT_FAILED,
    INNER_WINNER,
    INNER_ELIMINABLE_NO_WINNER,
    INNER_ELIMINABLE_WINNER_EXPIRED
}

struct TournamentStandingView {
    TournamentStanding standing;
    bool acceptsJoins;
    bool hasCandidate;
    Tree.Node candidate;
    Machine.Hash finalState;
    Tree.Node parentCommitment;
}

function tournamentStanding()
    external
    view
    returns (TournamentStandingView memory);
```

It distinguishes:

- still in progress because a match remains;
- no live match but closure is not yet reached;
- root winner available;
- root failure without a dangling commitment;
- inner winner currently propagatable;
- inner tournament currently eliminable; and
- ordinary active or awaiting-closure states without probing result methods of
  the wrong tournament kind.

Result propagation and inner elimination are mutually exclusive for one
observation. `acceptsJoins` is exactly `!isClosed()`, including a closed
tournament that still has active matches. Inactive payload fields are
canonical zero values.

Candidate identity sits close to the Goldilocks boundary. It can be
reconstructed from complete pairing and deletion history, but the contract
also stores the current dangling candidate and uses it in result validity. The
implemented view returns it as part of tournament standing while the fold
remains authority for the enumerable live-match set. The adapter validates
their consistency.

### Shared observer-view rules

- Define observer DTOs independently from storage structs.
- Keep legacy getters during migration.
- Preserve storage layout and all event signatures.
- Pin descriptor, timeout, and phase-projection calls to the same block
  observation.
- Return canonical zero payloads whenever `actualPhase` differs from the
  requested projection.
- Revert on impossible storage contradictions, not ordinary lifecycle absence.
- Do not silently repair a bad clock or match shape in a view.
- Let mutators repeat every authorization check at execution time.
- Start with scalar methods. JSON-RPC batching may combine calls without
  changing the ABI.

## Fold responsibilities in Campaign 1

Campaign 1 retains the fold's complete structural model because Hero and GC
already need it:

- discovered tournament addresses and parent relationships;
- joined commitments;
- ordered match identities;
- live and deleted match membership;
- commitment engagement;
- child address lookup; and
- provenance checks over malformed or duplicate event streams.

The first adapter implementation retained `MatchAdvanced` counts and frontier
breadcrumbs as extra fold/view reconciliation. They were removed after the
semantic view became the sole current-state authority: those fields duplicated
the view without resolving the equal-child ambiguity. The fold still rejects
an advance for an unknown or deleted match, and event decoding tests retain the
wire evidence.

The public fold API may eventually become narrower, such as:

```text
engagement(tournament, commitment)
child(tournament, match_id_hash)
live_matches(tournament)
reachable_tournaments()
```

That API narrowing is an encapsulation change, not proof that the fold has lost
semantic value.

## Observation and planner pipeline

The implemented Hero pipeline is:

```text
ChainObservation { number, hash }
    -> structural event fold through that observation
    + typed point reads at that observation
    -> strict wire-to-domain adapter
    -> SemanticSnapshot
    -> plan_hero(&snapshot) -> HeroDecision
    -> prepare(intent, context, local_machine) -> PreparedArenaAction
    -> dispatch at most once
```

The main design seam is the fold/view join inside the adapter.

Required properties:

- all logs and calls describe one accepted block;
- a same-height reorg or mixed-head observation is rejected or retried;
- generated ABI values do not escape the adapter;
- one legal contract state maps to one domain state;
- the Hero planner performs no provider calls, sends no transactions, and needs
  no mutable machine;
- one observation yields at most one Hero intent; and
- failure to fulfill one intent does not make the planner try a second verb
  from the same observation.

The last rule matters because the pre-campaign imperative Hero could attempt a
timeout path and then continue into a phase path. That implementation remains
useful historical evidence, but it is not the specification for unique action
priority.

### GC planner and executor

Campaign 1 keeps a separate pure planner:

```text
plan_gc(&fold, &observations) -> Vec<GcIntent>
```

The actor-neutral vector describes all cleanup eligible in one accepted
observation and preserves deterministic innermost-first ordering. This keeps GC
throughput visible and makes complete cleanup coverage easy to test without
conflating the complete forest with the Hero-local snapshot.

The vector is not permission to submit an unbounded transaction queue. The
executor must:

1. plan and submit any Hero intent before new housekeeping;
2. consume only a configured or structurally bounded GC prefix;
3. isolate a GC submission failure from the already chosen Hero action;
4. tolerate stale cleanup through mutator revalidation; and
5. submit through the exclusive-signer slot at the account nonce read from
   `latest` mined state.

The implemented node plans Hero first and lets at most one same-observation GC
intent cross the epoch boundary. This fixes the pre-campaign complete sweep
ahead of Hero. The shared D017 lane also establishes priority across ticks: an
already submitted cleanup and a later Hero use the same mined nonce `n` until
the chain advances it. A bounded GC prefix reduces stale work, while the nonce
rule prevents that work from creating a queue.

## Validation strategy

### Contract views

Extend the current contract evidence to cover:

- absent, deleted, bisecting, ready-to-seal, sealed-leaf, and awaiting-child
  matches;
- the full phase-by-projection cross product: the matching projection returns
  its phase and a meaningful payload, every other projection returns the actual
  phase with byte-exact canonical zeros, and absent or deleted matches return
  `ABSENT`;
- both commitment orientations and computation-height parity;
- equal-child-hash descent where event history cannot recover position;
- exact timeout boundaries and both single-winner orientations;
- the shorter and longer sealed-leaf deadlines, with no midpoint transition;
- the equality boundary that eliminates both sides;
- descriptor validation for root, Leaf, NonLeaf, and permissionless orphan
  children;
- child `baseCycle` equality with the live parent match cycle;
- root winner and root failure;
- inner winner propagation and expiry;
- no-winner child elimination;
- a dangling candidate blocked by unrelated matches;
- the final match deletion before and after closure; and
- a legal pre-close join that supersedes a previously observed standing.

An impossible internal contradiction after a projection's phase has matched
must revert in a focused harness. It must not be normalized to an ordinary
false result.

Reuse the existing authorities and suites rather than making the new projection
its own oracle:

- `MatchViews.t.sol`
- `Clock.t.sol`
- `MatchClocks.t.sol`
- `Tournament.t.sol`
- `TournamentLifecycleInvariant.t.sol`
- `RecursiveTournamentLifecycle.t.sol`
- `ConcurrentRecursivePopulation.t.sol`
- `FourLevelRecursiveLifecycle.t.sol`

The storage layout and five structural event schemas must remain unchanged.
ABI additions will still change implementation bytecode and dispatcher shape,
so compatibility output must be inspected rather than updated mechanically.

### Runtime-size gate

A fresh `direnv exec . forge build --force --sizes` on 2026-07-24 measured the
baseline and implemented six-view observer:

```text
baseline runtime:  13,832 bytes
observer runtime:  16,622 bytes
delta:              2,790 bytes (+20.17%)
EIP-170 ceiling:   24,576 bytes
headroom:           7,954 bytes
```

The semantic storage-layout hash remains unchanged at
`952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`.
The implemented compatibility witnesses are:

```text
Tournament ABI sha256:
c7b75c2b036a4e71c180cc2d18176c8a949f4a44c9b0ea6e7690c6cae70c79f0

Tournament runtime bytecode without metadata sha256:
c12ddfef8bdd83deeaacaf56e928340599eb15e64595e602303d834ca4250d44

semantic storage-layout sha256:
952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
```

The ABI and runtime bytecode hashes changed as expected; the semantic storage
layout did not. Continue to gate every production build on the full deployed
runtime size.

Deployment compatibility is version-paired even though storage and structural
events are unchanged: the migrated clients require a `Tournament`
implementation that exposes this observer ABI. Release manifests must pair
client binaries and generated bindings with the matching implementation rather
than point a new client at an older deployment that lacks the six views.

The compatibility-hash recipe strips metadata and is not the EIP-170
measurement. Use the full `forge build --sizes` runtime. A separate viewer
contract is not the default escape hatch: it cannot read Tournament storage
directly and would either preserve raw getters or require a smaller
authoritative core surface. Prefer trimming DTOs before creating a second
semantic implementation.

### Recorded implementation tests

The 2026-07-24 campaign evidence records these completed results:

- the focused observer suite reported 26 of 26 tests passing;
- the combined observer, `MatchViews`, and `MatchClocks` run reported 44 of 44;
- the core `Tournament` suite reported 20 of 20;
- the full PRT dispute-contract run reported 259 of 259;
- the Rust node library run reported 198 of 198;
- the final `just check` ran 232 conventional Rust tests: 24 machine tests, 198
  node-library tests, 7 engine-machine integration tests, and 3 recorded-fold
  tests, plus documentation tests;
- workspace Clippy with `-D warnings` completed successfully;
- the independent Lua client suite reported 59 of 59; and
- Lua lint completed with zero warnings or errors across 62 files.

After the D017 transaction lane, D024 range-tail simplification, timeout
closeout, and removal of superseded production validation scaffolding, the
2026-07-25 final `just check` passed. It ran 189 node-library tests, 24 machine
tests, 7 engine-machine integration tests, 3 recorded-fold tests, documentation
tests, workspace Clippy with `-D warnings`, the 59-test Lua client suite, and
Lua lint with zero warnings across 65 files.

Focused `gc_match` and `gc_tournament` end-to-end scenarios also completed
successfully through the semantic Lua actor. `gc_match` asserts a
`TIMEOUT/NONE` match deletion. `gc_tournament` asserts the child
`TIMEOUT/NONE` deletion followed by the parent
`CHILD_TOURNAMENT/NONE` deletion. These are direct cleanup-semantic and
integration witnesses, but they are not evidence for single-slot nonce reuse or
replacement behavior.

The concurrent `multi_sybil` scenario also completed through the semantic Lua
actor after the terminal-Won GC path was enabled: two active adversaries
traversed nested tournaments, invalid test claims were rejected, a silent
commitment timed out, and the honest commitment won against all three sybils.
One earlier run failed closed when timeout status and a phase projection
reported different phases despite carrying the same traced head. The mismatch
did not recur after adding full call traces and an independent full-ID/hash
identity assertion, including in the final 329-second acceptance run. No root
cause has been proven. Those diagnostics remain mandatory; the reader neither
retries nor normalizes this contradiction.

The isolated `kill_mid_match` scenario also passed after the semantic Hero
cutover. Its first campaign run completed the dispute but never killed the node
because the refactor had removed the harness's stable `advance match` marker.
Restoring concise action markers at the single-dispatch seam made the next run
observe one SIGKILL, respawn over the retained state, and still win. No scenario
timeout or assertion changed.

The final post-D017 and post-D024 end-to-end pass repeated `multi_sybil`,
`gc_match`, `gc_tournament`, `kill_mid_match`, and `kill_settle` successfully.
Both kill scenarios observed the intended SIGKILL and respawn. The
`kill_settle` trace exercised all three settlement mutations through the shared
transaction lane before settlement survived the injected interruption.

The timeout closeout then added two deterministic real-node scenarios. Both
build one unequal sealed-leaf race by reading the deployed `matchEffort` and
pre-seal clocks, controlling the final response block, and checking the
contract observer at exact boundaries. `sealed_leaf_timeout_winner` observed
the longer honest clock win after the legacy midpoint boundary and before its
own deadline. `sealed_leaf_timeout_both` observed `TWO_WINS` one block before
the longer deadline, `ELIMINATE_BOTH` at exact equality, and a
`TIMEOUT/NONE` deletion in the next block. The timeout-alignment plan records
the dated block evidence and aggregate recipe.

A normalized source comparison against `feature/sling-node` found no difference
in the five structural event declarations, including indexed fields. A live raw
log trace also preserved the representative pairing order: transaction
`0x29bd9d57ce82b3603286fed8a904503fdb6295ae95aebf347082eea2a377f204`
emitted `CommitmentJoined` at global log index `0x0`, then `MatchCreated` at
index `0x1` from the same tournament and block. No observer view emits a log.

### Fold and adapter

- Keep event decode, prefix replay, live-tail, and recursive discovery tests
  green.
- Compare fold lookups with the current model at every recorded prefix.
- Reject mismatched phase/projection combinations and impossible payloads.
- Check fold-supplied identities and live membership against the pinned views.
- Differentially compare the legacy overlay and the new adapter at the same
  block.
- Inject a branch change between live-tail acquisition and point reads. No
  unfinalized event may become durable; semantic contradictions must fail
  closed, while any otherwise planned stale mutation remains subject to
  contract revalidation. Inject a head change between semantic point reads and
  verify that every call still uses the same sampled hash.

The existing chain recordings contain logs and timestamps, not historical
point-read state. They prove enumeration and prefix equivalence, but cannot by
themselves prove semantic-view equivalence. Use deterministic live Anvil traces
or capture semantic snapshots at event and deadline blocks.

### Planner

- Specify expected intent independently from the old imperative Hero.
- Cover every domain variant with zero or one expected intent.
- Add the adversarial case where a timeout claim is valid while phase structure
  also appears actionable; timeout priority must still produce one intent.
- Test idempotence across repeated observations.
- Test that local fulfillment failure causes no fallback send.
- Preserve fold enumeration and cleanup reachability, but do not require legacy
  and new GC timeout decisions to be equal. Check both against the
  contract-authoritative timeout view and independent boundary tables. Expected
  corrections to the old off-chain classifier must be named rather than
  suppressed as differential failures.

### Lua and integration

Unchanged events preserve parsing, not semantic agreement. The Lua client now
independently reconstructs the structural fold, pins semantic calls, validates
the observer DTOs into its own domain values, assembles actor context, plans one
intent, fulfills local material, and dispatches once.

Campaign 1 was implemented in two reviewable slices:

1. contract views plus Rust Hero and GC migration; and
2. Lua adapter and planner migration.

The selected order was Rust first, then Lua immediately. The production sybil
actor now uses the semantic path, and provider-free Lua tests independently
exercise the same phase, timeout, topology, and one-intent boundaries. Legacy
raw getters remain for harness assertions and differential inspection; removing
their ABI is a separate compatibility decision. The mixed-head tests exercise
both client observation boundaries, and the live Lua path fails closed on any
cross-view phase disagreement.

Relevant end-to-end evidence includes:

- `multi_sybil` for concurrent matches, dangling candidates, re-pairing, and
  timeout deletion;
- `gc_match` for double elimination;
- `gc_tournament` for child elimination;
- `sealed_leaf_timeout_winner` for the corrected post-midpoint winner interval;
- `sealed_leaf_timeout_both` for exact longer-deadline double elimination;
- `stf_all` for recursive proof paths;
- `kill_mid_match` for pinned observation and restart;
- `kill_join` for repeated join decisions;
- `kill_settle` for terminal results;
- many simultaneous cleanup candidates plus a near-deadline Hero action; and
- an unmined GC at nonce `n` followed by a Hero replacement at the same `n`,
  including ambiguous submission and fee-bump paths.

Use repository `just` recipes and `just logged` for long gates. Regardless of
the exact implementation slice, the minimum evidence includes:

- `just prt-contracts::compatibility-hashes`, with expected ABI and bytecode
  additions separated from unchanged storage and structural event schemas;
- `just test-smart-contracts`;
- `just check`;
- generated-binding compilation and deployment checks;
- `direnv exec . forge build --sizes` from `prt/contracts`, recording the
  `Tournament` deployed-runtime delta and remaining EIP-170 margin;
- focused `multi_sybil`, `gc_match`, `gc_tournament`, and restart scenarios;
- a structural comparison of the five event signatures and indexed fields; and
- at least one representative raw-log trace proving their relative emission
  order is unchanged.

The implementation diff may add gates. New gas calibration and event-cost
comparison remain outside this design iteration.

## Implementation sequence

Keep each boundary reviewable and avoid a contract-and-node flag day.

1. **IMPLEMENTED: add the Rust semantic domain, initially unwired.**

   Define wire-independent tournament descriptors, match observations,
   tournament standing, `HeroDecision`, `HeroIntent`, and `GcIntent`. Validate
   every constructor invariant. Production behavior remains unchanged.

2. **IMPLEMENTED: add the pure Hero transition table, initially unwired.**

   Implement `plan_hero(&snapshot) -> HeroDecision` with explicit
   priority:

   1. terminal result;
   2. propagate an available child result;
   3. join if absent;
   4. claim an authoritative timeout when our side wins;
   5. wait when the opponent wins or both eliminate; and
   6. otherwise bisect, seal, enter a child, prove, or wait according to the
      typed phase.

   Intent carries chain locators, not Merkle openings, machine proofs, or a
   sender.

3. **IMPLEMENTED: prototype and measure the scalar ABI.**

   Implement enough local view code to compile the concrete descriptor,
   timeout-status, phase-projection, and tournament-standing DTOs. Measure the
   exact deployed-runtime delta with `forge build --sizes`. Review adapter
   readability and canonical zero payloads, then settle names and fields.

4. **IMPLEMENTED: land contract views and focused view tests.**

   Keep storage, mutators, raw getters, and structural events unchanged. Treat
   the timeout classifier and existing mutators as the oracle. This is a
   contract-only review boundary.

5. **IMPLEMENTED: generate bindings and add the strict reader adapter with a
   test-only legacy differential.**

   Assemble descriptor, fold structure, timeout status, and one phase
   projection into the Rust domain at a single observation. The semantic path
   acts; raw-getter comparison remains available in focused adapter tests but
   performs no RPC on the action path. Persist finalized progress before
   observing the disposable live tail, and reject contradictory semantic
   projections pinned to one sampled hash.

6. **IMPLEMENTED: cut Hero over to `plan -> prepare -> submit once`.**

   Separate proof and opening construction from planning. Submit any Hero
   action before housekeeping. A fulfillment or GC failure cannot select a
   fallback Hero verb or suppress the chosen Hero submission.

7. **IMPLEMENTED: add the pure GC planner and bounded executor shape.**

   Produce a complete deterministic innermost-first `Vec<GcIntent>`, then
   retain at most the first intent only after Hero policy has returned Wait or
   terminal Won without an arena action for the same accepted observation.
   Settlement runs before cleanup after Won. Raw clock classification has been
   replaced. Hero, cleanup, and settlement use the tested
   latest-mined-nonce replacement slot, so an unmined lower-priority mutation
   cannot allocate a nonce ahead of later Hero work.

8. **IMPLEMENTED: migrate Lua independently after the Rust slice.**

   The Lua semantic reader, fold, adapter, context, planner, fulfiller,
   dispatcher, and actor retain Hero-before-GC ordering and validate the exact
   boundaries without sharing Rust expected tables.

9. **IMPLEMENTED FOR ACTING CLIENTS: retire legacy interpretation after both
   clients agree.**

   Raw getter use is absent from both acting strategy paths. The isolated old
   Lua actor/state/strategy/GC cluster is removed; the low-level Lua reader
   remains for harness assertions and differential inspection. Removing the
   legacy ABI is a separate deferred compatibility decision. Measure actual
   ergonomics and RPC behavior before reopening aggregate views or D009 event
   streams.

10. **PARTIAL: promote stable invariants and archive the campaign evidence.**

    Move implemented behavior into living docs and code comments; freeze this
    plan and decision log with their differential and end-to-end evidence.

## Campaign 1 acceptance

Campaign 1 is complete only when:

- every legal match and tournament state has one typed domain interpretation;
- ordinary absent and wrong-variant reads are total;
- timeout and result boundaries agree with the contract at exact equality;
- every observation produces zero or one Hero intent;
- an eligible Hero submission precedes every new GC submission from that
  observation;
- the fold still discovers every active match and reachable child needed by
  GC;
- child descriptor geometry and base cycle agree with every live parent link;
- old and new readers have no unexplained semantic mismatch at the same block;
- restart and reorg tests preserve the finalized prefix, never persist the
  live tail, and safely retry or submit revert-tolerant stale work;
- a stuck cleanup transaction cannot silently strand a later Hero action;
- the final `Tournament` runtime remains deployable with recorded EIP-170
  headroom;
- storage and structural events are unchanged; and
- no migrated strategy code decodes raw match slots or clock sentinels.

Solidity, Rust, and Lua now share the semantic boundary through independent
adapters and typed planners, D017 settles executor ownership, and the exact
sealed-leaf timeout boundaries pass end to end. The one non-reproduced same-head
Lua contradiction remains an empirical watch; later passing runs do not erase
it.

The current tree satisfies the stuck-cleanup condition for one exclusive signer
process: Hero, cleanup, and settlement share one in-memory slot, read only the
mined nonce for allocation, and retain signed bytes and a fee floor across
ticks and ambiguous RPC failures. The slot is intentionally not durable across
restart; deterministic replacement of an unknown public-mempool fee floor
after restart is an operational property to revisit if it becomes required.

## Deferred design campaigns

Campaign 1 deliberately leaves several serious designs on the table:

- a view-dominant aggregate assembled inside Solidity;
- personalized commitment-keyed event streams;
- self-contained schedule events;
- dynamic match- and tournament-keyed latest-state streams;
- views-only Hero traversal using new pointer mappings;
- enriched structural events; and
- fully enumerable on-chain active sets.

They are not discarded. They are documented, compared, and given reopening
conditions in the [decision log](prt-client-interface-decisions.md). Campaign 1
produced the domain model, planner, traces, and measurements now available to
evaluate them empirically rather than speculatively.

## Campaign questions and closeout gates

Questions 1 through 9 are retained as design provenance and are answered by the
implemented domain, ABI, adapter, range-tail reader, one-intent GC prefix, and
replaceable transaction lane plus D001-D006, D011, D013, D015-D017, and D019.
Question 10 has a measured hard-ceiling margin; choosing a larger project
release margin is separate policy.

1. What are the minimal fields of each Rust domain variant?
2. Should tournament standing be one tagged method or a tag plus typed result
   projections?
3. Is candidate identity simpler and equally authoritative when derived by the
   fold, or should it remain in tournament standing?
4. Does a diagnostic-only total clock view justify its selector and runtime
   bytes?
5. Does a real phase-only consumer justify a standalone `matchPhase` method?
6. What exact fold/view consistency checks are fatal?
7. What exact observation token and provider behavior establish one pinned
   block?
8. What bounded GC prefix preserves cleanup throughput without crowding Hero
   transactions?
9. Does the latest-mined-nonce replacement slot preserve Hero liveness across
   RPC ambiguity, fee replacement, reorg, and the configured submit endpoint?
10. What release headroom above the EIP-170 hard ceiling should the project
    require after the ABI is final?
