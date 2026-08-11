# Recursive dispute reader

Status: IMPLEMENTED, locally validated 2026-08-09, and retained temporarily as
a preliminary Rust-review aid. Contract-authored match schedules, the recursive
event model, the fused reader, and the one-way narrow observer are implemented.
Current behavior is documented by [node-architecture.md](../node-architecture.md).
After preliminary review, move any remaining stable rationale there and delete
this plan; Git preserves the campaign history.

Review caveat: recovery passages below describe the intended shared-tree
shape, not the current implementation. Production recovery independently walks
finalized `NewInnerTournament` logs from storage-known epoch roots. Reconcile
that seam when folding this plan after preliminary review.

This document records the follow-up to Campaign 1: make the recursive
dispute the node's authoritative event-derived model, derive match cleanup from
absolute event schedules, and restrict point reads to tournament-wide results
and the validator's one recursive Hero path.

The code remains the source of truth. Rust excerpts below explain the shape and
may omit fields; Solidity event signatures describe the implemented interface.

## Why revisit the reader

Campaign 1 established useful boundaries: a finalized event prefix, a
disposable latest tail, typed contract views, pure planners, and one serialized
transaction lane. Its global observation step is deliberately conservative,
but expensive. For `T` reachable tournaments and `M` live matches, one complete
observation performs approximately:

```text
2T + 2M point reads
```

Each tournament contributes a descriptor and standing read. Each match
contributes a timeout classification and one phase projection. Multicall can
reduce transport round trips, but it cannot remove the underlying work or
response volume.

The global adapter also reconciles event-derived and view-derived versions of
the same facts on every tick. That redundancy was useful while the event model
was intentionally incomplete. It is not a desirable permanent authority
model: both projections come from the same contracts through the same provider,
so comparing them does not prove log completeness or provider honesty. It adds
availability and RPC coupling without an independent trust anchor.

The follow-up design chooses one production authority for each fact and moves
cross-projection parity to differential tests.

This reopens a decision that Campaign 1 deliberately deferred; it does not
rewrite that campaign's history. Campaign 1 established the typed views and
gave the event fold an independent oracle. The new evidence is the resulting
`2T + 2M` logical-call shape. Enriching events with one contract-authored
cleanup schedule avoids reconstructing clocks in the client and uses those
views as migration evidence rather than a permanent second authority.

## Design principles

1. One fact has one production authority. Events own enumerable history and
   recursive structure; a contract view owns a fact only when history does not
   carry enough information to derive it.
2. The domain mirrors the protocol. A tournament contains matches, and a sealed
   non-leaf match contains its child tournament.
3. Raw ABI values never enter policy. Boundary decoders and checked
   constructors remain strict even when redundant production reconciliation is
   removed.
4. Exactly one boundary is treated as solid. The reader never maintains an
   intermediary confirmation tier.
5. The latest tail is disposable quantum foam. Rebuild it from the solid
   dispute every tick; do not detect, reverse, or repair reorgs.
6. Contract mutators remain the final action authority and revalidate every
   stale or raced intent.
7. Start with simple memory ownership and measured RPC bounds. Persistent data
   structures, aggregate views, and new schedule families require evidence.

## Authority table

| Question | Production authority | Reason |
| --- | --- | --- |
| Which tournaments and commitments exist | Events | Solidity mappings do not enumerate them. |
| Which matches are live | Events | Creation and deletion form the enumerable lifecycle. |
| Which child belongs to a match | Events | `NewInnerTournament` supplies the parent-to-child direction. |
| Whether a clock-bearing match is cleanup-eligible | Absolute schedule in its latest event state | The contract computes the clock boundary once; Rust compares block numbers. |
| Whether a matchless inner tournament is eliminable | One `tournamentStanding()` read | Closure and winner carryover can change without another event. |
| The validator's current match details | Pinned views on the one Hero path | Equal-hash descent and proof material are not fully event-derived. |
| Whether a historical bond is recoverable | Pinned `bondRecovery()` at the solid boundary in the first slice | The recursive dispute supplies provenance and enumeration; event-derived recovery remains separate work. |
| Whether a submitted action is still legal | Contract mutator | Other actors and reorgs may supersede any observation. |

The configured RPC provider remains part of the read trust boundary. A
successful `eth_getLogs` response is trusted to contain every matching log in
the requested range; the Rust reader does not compare it with the event
counters. The reader rejects malformed responses and incomplete internal
values, but does not attempt to prove receipt inclusion, detect latest-chain
rollback, or compare two responses from the same provider as a substitute for
such a proof.

## Recursive domain

The implemented model owns the recursion directly:

```rust
struct Dispute {
    root: Tournament,
}

struct Tournament {
    address: Address,
    commitments: HashMap<Claim, Commitment>,
    matches: Vec<Match>,
}

struct Match {
    id: MatchId,
    status: MatchStatus,
}

enum MatchStatus {
    Clocked {
        eliminable_at: BlockInstant,
    },
    Leaf {
        eliminable_at: BlockInstant,
    },
    Inner {
        child: Box<Tournament>,
    },
    Resolved {
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
        child: Option<Box<Tournament>>,
    },
}
```

`Resolved` retains its historical child. Hero and cleanup traverse only
`Inner`; recovery also traverses children retained by resolved matches. A child
must not disappear merely because its parent match is no longer reachable: its
bond may still be recoverable.

Plain `Box` ownership and one deep clone per tick are the baseline. The fused
loader updates each tournament from its own local stream, so it needs neither
global recursive address search nor a persistent address index.

`Dispute` is timeless. Time-dependent queries take the height through which the
working event state was derived:

```rust
impl Dispute {
    fn eliminable_matches(&self, current: u64) -> Vec<EliminableMatch>;
}

fn plan_gc(
    dispute: &Dispute,
    current: u64,
    standings: &HashMap<Address, TournamentStanding>,
) -> Option<GcIntent>;
```

## Local claim lookup and lazy Hero recursion

Claims are scoped to a tournament. The same digest may occur at different
levels, so there is no global `match_for(claim)` operation.

```rust
enum CommitmentPosition<'a> {
    NotJoined,
    Candidate(&'a Commitment),
    Engaged {
        commitment: &'a Commitment,
        match_: &'a Match,
        side: MatchSide,
    },
    Eliminated {
        commitment: &'a Commitment,
        match_: &'a Match,
        reason: MatchDeletionReason,
    },
}

impl Tournament {
    fn position(&self, claim: Claim) -> CommitmentPosition<'_>;
}
```

Hero begins with the root tournament and root claim. An engaged clock-bearing
match is hydrated through point views. An engaged inner match yields its child
tournament; Hero computes the child claim lazily and applies the same decision
procedure again. Computation-hash work therefore follows only the selected
root-to-leaf path.

The controller must still respect the solid/foam action split. Joining a
tournament is a semantic commitment and is decided from Solid. Once the local
commitment is engaged, deadline-sensitive match reactions follow the recursive
Foam path. One undifferentiated "Hero snapshot" must not blur those policies.
An action may use a latest-pinned negative guard to suppress work already
mined, but that guard never supplies a join/vote payload or retires durable
state.

RPC methods do not belong on `Tournament` or `Match`. The recursive domain is
pure; `tournament::observer` performs one-way reads of current standings and
enriches only the selected Hero engagement at one pinned head.

## Match cleanup schedules

An event schedule must name the first block at which
`eliminateMatchByTimeout` is legal, not the first block at which one side may
win. Call this value `eliminableAt` or `eliminateBothAt`.

For a legal unchanged match state:

```text
clocked bisection or ready-to-seal:
    running.start + running.allowance + paused.allowance

sealed leaf with both clocks running:
    max(one.start + one.allowance, two.start + two.allowance)

sealed non-leaf:
    no local schedule; responsibility belongs to the child tournament
```

The arithmetic must live beside `MatchClocks.classifyTimeoutAt`. The contract
and client invariant is:

```text
while no later transition supersedes the schedule,

current block >= emitted eliminableAt
    iff
classifyTimeoutAt(current block) == ELIMINATE_BOTH
```

The event changes are:

- append `Time.Instant eliminableAt` to `MatchCreated`;
- append the replacement `eliminableAt` to every `MatchAdvanced`;
- add `LeafMatchSealed(matchIdHash, eliminableAt)`;
- let `NewInnerTournament` replace the parent match's clocked state with its
  child; and
- let `MatchDeleted` resolve and tombstone the current schedule.

Historical schedules are never filtered directly. Block-grouped event
transitions first derive the current live match state in Foam; cleanup then
compares that state with the sampled latest block number for the tick.

The leaf event has one indexed match ID and one data-word schedule.
`getLeafMatchSealedCount()` extends the existing per-event count surface. The
additional log data, leaf counter write, and winner re-pair emissions are part
of the refund-gas calibration and bond propagation, not incidental overhead.

Adding `eliminableAt` changes the `MatchCreated` and `MatchAdvanced` event
signatures and therefore their `topic0`. Indexing
`CommitmentJoined.commitment` leaves that event's signature and `topic0`
unchanged but changes its topics/data layout. Together with the clone-argument
change, these require a coordinated deployment generation, not dual decoding:
a fresh Tournament implementation, factory, and dependent Dave bundle deploy
with matching Rust, Lua, bindings, and artifacts. No live dispute or persisted
tournament-event stream from the prior generation may cross that boundary.
Release evidence must establish that precondition. Dual decoding would still
lack the old events' cleanup schedules and would create a weaker second domain
model.

## Block-local logs and domain transitions

An EVM block, not an individual `LOG` opcode, is the reader's observable state
boundary. Point reads and action decisions already observe block states.
Current granular events do not each preserve a strong dispute value. For
example, these single-transaction sequences contain invalid intermediate log
prefixes:

```text
occupied-slot join:
    CommitmentJoined(new)
    MatchCreated(oldCandidate, new)

winner paired with an existing candidate:
    MatchCreated(candidate, winner)
    MatchDeleted(oldMatch, winner)
```

The first intermediate has two candidates. The second has the winner in two
live matches. Reversing the second pair merely changes its invalid midpoint to
two candidates.

The reader distinguishes external logs from atomic local transitions:

```text
ContractLog[] from one tournament in one block
    -> checked LocalBlock
    -> apply(Tournament, LocalBlock)
    -> Tournament
```

An internal builder may consume logs in canonical order, but a strong
`Tournament` is published and validated only at the block boundary. This also
handles multiple transactions in one block without requiring transaction hash
or index metadata that policy never otherwise uses. The
recursive loader publishes the strong parent only after every discovered child
has also been loaded. This preserves pure local block transitions without
redesigning every granular Solidity event into a compound log.

## Point-read budget

Once match cleanup schedules are event-derived, the reader no longer observes
every live match. It uses:

- one `tournamentStanding()` call per reachable tournament;
- one immutable descriptor read when a tournament is discovered; and
- at most one timeout plus one phase projection at each clock-bearing Hero
  level. A delegated parent needs only its sealed projection.

The steady upper bound becomes approximately:

```text
T + 2L
```

`T` is reachable tournament breadth and remains adversarial. `L` is configured
depth. RPC batching may reduce latency but does not change this work bound.

Standing results form a small disposable capability overlay. The point calls
that produce them are mutually pinned, but Foam is not claimed to belong to the
same block hash. They are not folded into `Dispute` or compared with a second
derived standing. A pure cleanup planner consumes the event-derived tree,
match schedules, and this nonredundant tournament-result input.

Tournament schedule events are deferred. They are necessary only if evidence
requires zero point reads for inner-tournament cleanup. The current aggregate
standing view is a much smaller first step and shares its result authority with
the parent-facing `innerResult` implementation.

## Recursive loading and dynamic discovery

Dynamic event sources follow the same recursion as the domain. The implemented
reader fetches and applies each tournament's events during one recursive descent
rather than first collecting a flat log set:

```text
load_tournament(address, existing, range):
    fetch this tournament's local logs
    group them into local block batches
    apply each batch to a private Tournament builder
    recursively load every existing or newly discovered child
    attach each completed child
    publish one strong Tournament

load_dispute(root, base, range):
    root = load_tournament(root, base.root, range)
    return Dispute { root }
```

The loader owns RPC and the private block builder; `Dispute`,
`Tournament`, and `Match` remain pure strong values. `NewInnerTournament`
constructs a valid empty child immediately. The loader recursively extends that
child before publishing the completed root.

The parent contract owns the attachment and the child contract owns its local
state. Current cross-contract operations consume a child through views and
record their effects in the parent; no domain transition needs another
contract's intermediate log state. Therefore each tournament's logs can be
applied in local block groups even when logs from different addresses
interleave globally. Contract lifecycle tests pin the cross-contract ordering,
and recursive-reader tests cover discovery and child use later in the same
block without maintaining a second Rust state model.

The semantic API remains recursive when siblings are fetched concurrently or
their addresses are batched. Only `NewInnerTournament` from an already trusted
tournament introduces another trusted event source. Existing children are
extended recursively; new children are loaded from their creation block or
the current suffix start. Resolved children remain attached for recovery. A
child that resolves within the current range is extended through that range;
once its parent resolution is part of the base tree, its structural stream is
frozen and no longer fetched on every tick.

For a solid extension, the loader also retains the recognized raw logs as a
side output for one atomic database commit. They are applied while loading, not
collected as a prerequisite to constructing the dispute. Quantum-foam logs
need not survive the load.

Cross-address order remains useful only for validating and persisting the raw
chain artifact: reject duplicate global log positions, conflicting hashes for
one height, and a child log that precedes its parent's discovery. It does not
drive the domain transitions.

The first implementation follows the recursion sequentially. That exposes the
cost honestly and keeps the loader small. Bounded sibling concurrency,
address-array filters, and provider-sized batches remain measured latency
optimizations rather than domain machinery. Existing block-range bisection
remains the response-size fallback.

## Solid island and quantum foam

The reader has exactly one policy boundary:

| Value | Lifetime and authority |
| --- | --- |
| Solid | Durable event state through the selected solid tag; source for joins, votes, recovery, and retirement. |
| Foam | A fresh working clone extended through a sampled latest height; disposable input for eager Hero and cleanup. |

The initial solid tag is Finalized. Selecting Safe later should be a small code
change, not a third state tier. The policy decision is still material: with no
rollback machinery it explicitly accepts a rare Safe reorg as a fatal
solid-boundary violation rather than pretending Safe has Finalized semantics.

The first implementation holds at most two deep-cloned recursive trees:

```text
Solid --clone and recursively extend (B, L]--> Foam
```

At the expected dispute size this is the clearest baseline. Measure the clone
before considering an alternative ownership model.

### Tick lifecycle

1. Sample the selected solid boundary `B` as `(number, hash)`.
2. Recursively extend the stored Solid value from its durable cursor through
   `B`.
3. Validate the complete solid tree, then atomically persist its recognized raw
   logs and new cursor. Replace the in-memory Solid value only after commit.
4. Sample Latest as height `L` and hash `H`, deep-clone Solid, and recursively
   extend the clone over the numeric range `(B, L]` to produce Foam. The event
   tail is not claimed to be an ancestor projection of `H`.
5. Obtain only the nonredundant tournament standings and Hero-path point facts
   required by this tick, pin those point calls to `H`, plan a bounded action
   set, and submit through the one nonce-owning lane.
6. Drop Foam and sleep.

The next tick advances Solid independently and derives a new Foam from
scratch. Foam logs are never promoted, compared with the previous tick, or
reverse-applied. Blocks previously seen in Foam are deliberately refetched when
the solid boundary reaches them.

There is no latest rollback protocol: no remembered latest cursor, rollback
depth, header walk, post-harvest latest resample, or ancestry proof. A reorg
during a multi-request load can make Foam fail its local invariants, produce a
stale guarded intent, or delay one action until the next tick. It cannot mutate
Solid, and the contract mutator remains the correctness authority.

This simplicity has an explicit operational cost. A stale or raced intent may
still consume gas if the submission endpoint mines reverts, and persistently
bad RPC data can harm liveness. Keep the Foam action set tiny with Hero first.
If stronger fee protection is required, preflight only the selected transaction
at the pinned point-read head; do not restore whole-dispute reconciliation.

The loader still rejects internally malformed input: unexpected emitters,
out-of-range or removed logs, missing positions, duplicate global positions,
and conflicting block hashes for logs claiming the same height. Those checks
say that one load can construct a valid `Dispute`; they do not claim that Foam
belongs to one proven latest branch.

## Memory and RPC bounds

The first version uses mechanical limits rather than a generic cache or
streaming framework:

- persist only recognized Solid raw logs and its numeric watermark;
- retain one hot in-memory Solid dispute for the active root;
- deep-clone once and rebuild Foam every tick;
- retain non-overlapping block-range bisection;
- reject removed logs, missing position metadata, conflicting block hashes,
  duplicate log positions, unexpected emitters, and any child named by a
  recognized parent event that could not be loaded;
- cache no Foam suffix or child across ticks;
- read immutable descriptors at tournament discovery and retain them only with
  their containing Solid or Foam tree; and
- plan at most one cleanup mutation, and only when no Hero action was selected.

Do not impose an arbitrary maximum number of valid tournaments. An adversary
may legitimately purchase a broad dispute. If an operational budget expires,
the whole load fails and produces no action; the reader never intentionally
publishes a known prefix as a complete dispute.

Old unretired epoch roots need only Solid state. Recovery may rebuild them from
persisted logs on its low cadence or cache their exact Solid disputes while
they remain nonterminal. This is a memory-versus-replay choice, not a semantic
distinction; a cache entry is valid only at its recorded Solid cursor and is
evicted when the epoch retires.

## Validation policy

Production keeps checks that narrow external data into a semantic type:

- dispatch by known topic and fail on malformed protocol payloads, ignoring
  only explicitly irrelevant events;
- known ABI discriminants and canonical active payloads;
- timeout-charge and phase shape;
- match geometry, coordinate alignment, cycle derivation, and responder parity;
- legal match kind and child attachment;
- trusted source provenance and canonical local log ordering; and
- coherence of the few point reads combined into one Hero decision.

State-machine invariants live in `Dispute` construction and are checked once
per block transition: unique joins and matches, candidate cardinality,
known live parents, legal child depth, and legal lifecycle transitions.
Violating one of these invariants after checked external decoding is a program
bug and should be expressed as an assertion where appropriate. Malformed RPC
or ABI input remains an ordinary load error: reject the working value rather
than panic or construct a weaker value.

The following recurring production comparisons do not occur in the recursive
reader:

- event candidate versus point-read candidate;
- event live-match count versus point-read standing;
- recursive level versus point-read descriptor level;
- event winner final state versus a second current-state projection; and
- whole-tree child topology versus duplicate point views.

Their truths remain important. Differential and state-machine tests compare the
event projection against Solidity across transitions and time boundaries. The
former global fold/view adapter and its redundant hot-path reconciliation are
deleted; production uses a one-way narrow observer only for facts that events
do not carry and for the selected Hero action payload.

A narrow Hero-path read still returns an actual match phase. If it reports the
selected event-derived engagement absent, no valid calldata can be constructed
and the tick stops. Likewise, the few point calls used for one action must agree
with each other. These are local action-construction checks; they do not make
Foam canonical or establish a second global authority.

## Core invariants

1. Solid equals the event-derived state obtained from exactly the persisted
   recognized logs through its stored numeric watermark. The hot in-memory
   value pairs that watermark with the sampled finalized hash.
2. Foam starts from a fresh clone of Solid and contains every recognized log
   returned for the requested numeric tail during this tick. It makes no
   ancestry claim about the separately sampled point-read hash.
3. No Foam event or child mutates Solid.
4. Every child is introduced exactly once by an event from an already trusted
   parent.
5. No consumer receives a partially discovered or partially extended dispute.
6. Foam schedule queries use the sampled latest block number for that tick;
   Solid schedule queries use the Solid cursor.
7. The few point reads combined into one action are pinned to one sampled hash.
8. Join, sentry vote, settlement, recovery, and retirement derive their
   semantic content from Solid. A latest negative guard may suppress duplicate
   work but never changes that content or retires state. Eager dispute
   responses and permissionless cleanup use Foam.
9. A resolved match retains any historical child until recovery no longer
   needs it.
10. All mutations serialize through the single nonce-owning transaction lane.

## Migration and evidence

1. Implemented: specify and test the event transition table and absolute match
   schedules.
2. Implemented: add match schedules and the missing leaf-seal event in
   Solidity; regenerate both clients and measure gas and event counters.
3. Implemented: introduce the fused recursive loader and block-grouped local
   event transitions, then remove the superseded global Rust fold and its
   pre-ABI chain-recording oracle.
4. Implemented locally; preliminary Rust review remains: differentially compare
   the retained event and view projections for candidate placement, live
   matches, recursive topology, timeout boundaries, and nested cleanup.
5. Implemented: use one Finalized-first Solid value and one freshly deep-cloned
   Foam value per tick.
6. Implemented: switch match cleanup to event schedules and tournament cleanup
   to at most one standing read per relevant tournament.
7. Implemented: restrict match point reads to the recursive Hero path.
8. Implemented: remove the global observation map and recurring fold/view
   reconciliation.
9. Deferred: revisit event-derived tournament schedules, alternative
   ownership, and standing-call batching only after measurement.

Required evidence includes:

- schedule equivalence at `h - 1`, `h`, and after every superseding response;
- leaf sealing, child delegation, deletion, and same-block repair;
- recursive cold load, child discovery, and local block-transition tests over
  the current event ABI;
- Solid-prefix plus Foam-tail equivalence with an all-at-once local fold when
  the returned logs are stable;
- independent Foam rebuilds over alternative tails from one unchanged Solid,
  with no state carried between ticks;
- dynamic children created and used later in the same block;
- exact RPC-call accounting as tournament breadth and Hero depth vary;
- deep-clone memory and latency measurements before any persistent structure;
  and
- recovery traversal through children retained by resolved matches.

## Deliberately deferred

- Additional tournament-level elimination schedule events. One aggregate
  standing read per relevant tournament is the smaller first design.
- A contract aggregate over arbitrary tournaments or matches. That would turn
  the protocol ABI into an RPC optimization surface.
- Persistent collections or a permanent address index before profiling.
- Cryptographic proof of RPC log completeness or receipt inclusion.
- Event-derived bond-recovery classification. The first slice keeps the
  Solid-pinned capability view while the recursive dispute owns candidate
  provenance and historical traversal.
- Persisting Foam.
- Changing tournament level coordinates, proof formats, computation hashes, or
  action-priority policy as part of this reader redesign.
