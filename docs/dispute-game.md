# PRT dispute game

This document describes the dispute game implemented by the Solidity contracts
under `prt/contracts/`. It covers tournament structure, lifecycle, clocks,
recursive disputes, and economics. The code remains the source of truth; this
document states the protocol invariants and assumptions that code changes must
preserve.

The implementation of the Cartesi state-transition function is outside this
document. At the leaf level, the dispute game treats that function as the
authority that maps an agreed pre-state and proof to the next state.

The completed 2026-07 internal review, including resolved findings and deferred
leads, is preserved in
[`REVIEW.md`](reviews/2026-07-21-prt-dispute-game/REVIEW.md). That archive is
historical evidence, not an active backlog or a substitute for this description
of implemented behavior.

## Security statement and assumptions

The dispute game is intended to make the correct computation result win while
limiting the delay and cost an adversary can impose. Those properties are
conditional, not absolute.

Safety requires:

- At least one participant joins the correct commitment when a dispute exists.
- A correct participant can submit required transactions before its clocks and
  the relevant tournament windows expire.
- The participant can obtain the inputs, machine states, and proofs needed to
  act.
- Commitment hashes and Merkle proofs have their assumed collision and
  preimage resistance.
- The configured state-transition contract and data provider implement the
  intended computation and input history.
- Tournament parameters describe one consistent decomposition of that
  computation.

Liveness and bounded delay additionally require:

- The adversary's cumulative censorship of the correct participant does not
  exceed the one global budget `C` across one root dispute and all of its linked
  descendants; that budget does not reset per transaction, match, or level.
- The application is disputable within the clock dimensioning assumptions in
  [`dimensioning.md`](dimensioning.md).
- The chain time source advances according to the assumptions used to convert
  wall-clock durations into protocol durations.
- At least one externally motivated actor submits required progress and cleanup
  transactions. The protocol does not promise an endogenous validator profit.

Every timer uses an inclusive expiry boundary. A join at the tournament
deadline fails, although existing matches may continue resolving after closure.
A response or seal at the responder's deadline fails, and a leaf proof at either
leaf-clock deadline fails; the selected timeout verb becomes eligible at that
clock boundary. A child winner is no longer usable at its carryover deadline,
when child elimination becomes eligible. A configured duration must therefore
strictly exceed the aggregate block delay before a required progress action. If
a policy input such as `C` or `T` is specified as an inclusive wall-clock
maximum, deployment conversion must add the necessary boundary slack.

A timeout can make an incorrect commitment survive if the correct participant
does not act within those assumptions. Timeout victory is part of the protocol,
not evidence that the surviving computation was executed correctly.

## Relationship to the papers

The original [`prt/docs/prt.pdf`](../prt/docs/prt.pdf) is an architectural
ancestor, not a specification of these contracts. The
[`Dave paper`](../dave/docs/dave.pdf) describes a successor liveness design
that these contracts do not implement. These contracts do adopt its base-layer
threat model: censorship can be split and reordered, but its duration is one
cumulative, non-rechargeable budget. Importing that adversary model does not
import Dave's tournament algorithm or delay bound.

| Subject | Original PRT paper | Current contracts |
| --- | --- | --- |
| Participant organization | Teams and tournament bracket | One asynchronous pool with a dangling commitment |
| Pairing | Bracket-oriented | Commitments pair as they arrive and winners re-enter |
| Dispute depth | Paper construction | Recursive, configurable tournament levels |
| Per-match timing | High-level chess-clock model | Stored per-commitment clocks with explicit timeout entry points |
| Economics | Conceptual permissionless incentives | On-chain bonds, partial refund caps, capped winner payment, and residual burn |
| Child disputes | Paper construction | Parent-sealed match creates and links a child tournament |
| Dave liveness improvement | Not applicable | Not implemented |

The paper remains useful for motivation. Claims about callable functions,
pairing order, clock boundaries, bonds, or recursive state must be checked
against the contracts and this document.

## Tournament roles and configuration

Every tournament is an ERC-1167 clone of the same `Tournament` implementation.
Immutable arguments determine its role:

- A root tournament has `level == 0`. It has no contested parent states and its
  result is consumed by rollups consensus.
- An inner tournament has `level > 0`. It inherits two contested commitments
  and final states from a parent match.
- A leaf tournament has `level == levels - 1`. Its sealed matches are resolved
  with the state-transition contract.
- A non-leaf tournament has `level < levels - 1`. Its sealed matches create
  child tournaments.

The checked-in canonical provider configures the historical three-level table
`log2step = [44, 27, 0]`, `height = [48, 17, 27]`. The selected deployment
layout is the two-level table `log2step = [37, 0]`, `height = [55, 37]`.
That switch is not live. Generic and historical Solidity tests now inject their
own geometry, leaving the coordinated node change from root stride 44 to 37 as
an integration gate. The tournament lifecycle is intended to depend on
`levels`, not on either number.

A test-only table validator makes the shape rules executable: every row must
declare the same positive level count, heights must be positive, shifts and row
extents must fit the 256-bit coordinate space, adjacent rows must tile, the root
must span the expected coordinate width, and the leaf stride must be zero. It
also rejects a zero root allowance while deliberately accepting a zero response
budget. This is deployment evidence, not runtime validation. In particular, a
well-formed Solidity table does not prove that an off-chain node constructs the
same commitments. The selected two-level table therefore remains gated on
contract, node, and documentation conformance.

The generic recursion path is also exercised with a strict test-owned
four-level table, `log2step = [3, 2, 1, 0]` and
`height = [1, 1, 1, 1]`. That production factory-and-clone trace creates three
nested children, resolves the leaf, and propagates one winner through every
parent. It protects level-independent plumbing; it is not evidence that every
possible table is safe or that the test state sequence is a valid machine
execution.

The factory permits anyone to instantiate root or inner clones. An inner clone
created directly through the factory is an orphan: it is not authoritative for
any parent. A parent accepts only a child recorded in its own
`matchIdFromInnerTournaments` mapping when that parent sealed a match.
Factory construction rejects a no-code tournament implementation, parameters
provider, or state-transition dependency so those wiring errors fail before a
clone is instantiated. The per-tournament `IDataProvider` remains a protocol
dependency rather than a generic code-presence check: test state transitions
may legitimately ignore it, while production correctness depends on its
semantics rather than code length alone.

## Commitment lifecycle

### Join and asynchronous pairing

A participant joins by posting at least `bondValue()` to one tournament and
supplying a commitment root, its final state, and the proof binding that final
state to the last commitment leaf. An inner tournament accepts only one of the
two final states contested by its parent.

There is one dangling slot per tournament:

- If no commitment is dangling, the new commitment waits there.
- If one is dangling, the new commitment pairs with it and creates a match.

The older dangling commitment is `commitmentOne`; the newcomer is
`commitmentTwo`. Pairing does not change either clock balance. It starts the
older commitment's clock and leaves the newcomer paused, so time already lost
by a late join is never restored merely because that commitment finds an
opponent. The same rule applies when a surviving winner re-enters pairing.

Important invariants:

- There is at most one dangling commitment.
- Every live joined commitment is either dangling or belongs to one live match.
- `matchCount` equals the number of live matches.
- A commitment root can be joined only once in one tournament instance.

### Bisection

Each match compares two commitment trees. One clock runs while that participant
must reveal the next children. A valid `advanceMatch` moves the shared
first-divergence frontier one tree level, then switches the turn. A height-`H`
match has exactly `H` eligible responses: `H - 1` advances and one final leaf or
inner seal. If both child subtrees differ, bisection selects the left child,
preserving the first-divergence rule.

The stored reveal is deliberately staggered. At the start of a turn, the
waiting commitment's children are already cached. The current revealer opens
its parent to choose the divergent branch, then also opens its selected child.
The selected child from each commitment becomes the next divergence frontier:
the waiting child becomes the next `otherParent`, while the revealer's
grandchildren become the next cached pair. Roles then swap. Conceptually, the
two-tree search descends one level per advance even though each commitment
supplies two adjacent tree openings on its alternating turns.

Commitment one reveals first, and each advance swaps the revealer. The final
response therefore reveals commitment one's subtree and checks its agree-state
proof against commitment one when `H` is odd; it uses commitment two when `H`
is even. This turn derivation, rather than an independent parity convention, is
what justifies the odd/even proof selection.

If the first divergent leaf is `p` and the match still has height `h`, its
running position is the `h`-bit-aligned prefix
`floor(p / 2^h) * 2^h`. Interior right descents add an aligned power of two, so
the position remains even before sealing. Only a final right-leaf seal adds one;
the sealed position's low bit therefore records whether the divergence was in
the left or right leaf. Together with the final revealer, that bit determines
which contested state belongs to each original commitment.

Let a response begin with clock balance `b`, arrive after elapsed time `e`, and
have configured response budget `G` (the legacy-named `matchEffort` field). The
response is accepted only while `e < b`, and pauses the responder with

```text
b' = b - max(e - G, 0)
```

Thus a valid response discounts at most `G` of that action's elapsed time but
never increases the balance or revives an expired clock. Joining, pairing,
proof resolution, timeout cleanup, child propagation, elimination, and bond
recovery do not earn this discount.

Important invariants:

- Exactly one clock runs during active bisection.
- Match height decreases by exactly one per valid advance.
- The running leaf position remains inside the commitment tree.
- Child ordering and odd/even height parity preserve commitment-one and
  commitment-two attribution.
- A match cannot advance after it becomes sealable or sealed.

The bisection of one match is logarithmic in that commitment tree's leaf count.
The total delay imposed by many adversarial claims also depends on the number of
tournament levels and repeated winner pairing; it must not be summarized as one
flat `O(log N)` bound.

### Delay, work, and bracket shape

Let `K` be the number of live commitments in one tournament. There are
`M = floor(K / 2)` live matches and `D` dangling commitments, with

```text
K = 2M + D
D in {0, 1}
```

During bisection, one of each match's two clocks runs; after leaf sealing both
run. A leaf tournament therefore has at least `M` running clocks. Stale clock
storage for commitments already eliminated is not part of `K`.

A sealed non-leaf match is the recursive exception: after the final response
discount, both parent clocks pause with snapshotted remainders `r1` and `r2`,
and the child tournament receives `max(r1, r2)` as its initial allowance. A
child deadline closes joining; child finish still depends on resolving its
matches and any deeper children. The recursive structural invariant is
therefore that every parent pair either has a clock running or has delegated
population reduction to a child tournament. At most one commitment per
tournament escapes pairing by waiting dangling. If `S` of the `M` parent
matches are sealed-inner, the parent-local count is
`runningClocks >= M - S`; each of those `S` exceptions has one linked child
carrying the bounded resolution obligation.

The executable
[`ConcurrentRecursivePopulation.t.sol`](../prt/contracts/test/properties/ConcurrentRecursivePopulation.t.sol)
trace pins one production instance of this accounting: four parent commitments
form two sealed matches, the two linked children coexist with the same deadline,
and each child reduces four live commitments to one over two timeout waves before
propagation re-pairs the parent winners. The trace covers local timed matches
versus linked-child obligations at both even and odd parent populations. It is a
fixed balanced-arrival witness, not an asynchronous upper-bound model: parent
seals are immediate, allowances are equal, and cleanup occurs promptly at exact
deadlines.

On successful propagation, the returned child-winner clock replaces the
corresponding parent clock after post-finish deduction; it is not added to the
parent balance. The maximum is a shared pair envelope, not side-specific
carryover. If the child winner maps to the side with the smaller post-discount
snapshot, that side may return with more than its own `r_i`. The other parent is
eliminated, and the returned survivor still satisfies

```text
0 < returned <= max(r1, r2) <= r1 + r2
returned <= maxAllowance
```

The shared maximum is a worst-case envelope, not side-specific conservation. An
adversary controlling both sides can choose which Sybil survives. Against a
correct side, a child commitment is classified by its contested final state
rather than by claimer or root lineage, so a distinct child root may enter
either parent's final-state class. More exact lineage accounting would alter
individual schedules without excluding the preserved-clock delay strategy.
The fixed-budget, fixed-metric qualification and its non-claims are documented
in [`dimensioning.md`](dimensioning.md).
Thus recursive propagation may transfer live clock mass within the sealed pair,
but does not create live pair-level clock mass. The eliminated side's historical
clock storage may remain. Ordinary same-tournament settlement and pairing never
grant time.

That active-pair invariant, rather than the visual shape of the asynchronous
bracket, gives a structural population reduction. It does not say that one
clock allowance resolves a pair: the two clocks in one match can consume time
serially.

For one height-`H` match, let `B` be the sum of its two clock balances and `h`
the number of eligible responses still required. The potential

```text
potential = B + h * G
```

drops by `max(e, G)` on a successful response of elapsed duration `e`. Across
`q` responses,

```text
responseElapsed + B_after
    = B_before + sum(min(e_i, G))
    <= B_before + q * G
```

From any observation instant, a leaf match with current live balances `b1` and
`b2` and `h` eligible responses left has the safe local bound

```text
W_match <= b1 + b2 + h * G
```

to resolution with at most one survivor. For a non-leaf match, the same
expression bounds reaching local seal or timeout deletion, but excludes
resolution of any child created by sealing. Consequently, in a single-level
leaf tournament with per-clock bound `A`, every match present at instant `t`
resolves within the common bound `W = 2A + H * G`. If joining has closed and
permissionless cleanup is prompt, the structural population statement is

```text
K(t + W) <= ceil(K(t) / 2)
```

This treats transactions as available when needed; finite blockspace is a
separate source of wall-clock serialization. Iterating the structural statement
gives an all-at-once reservoir the coarse clock-delay upper bound

```text
(2A + H * G) * max(1, ceil(log2(P)))
```

for `P` commitments of one common height. This is deliberately conservative;
many timeout paths consume only one clock. It is also an upper-bound argument,
not a claim that half the population disappears after one allowance.

Production-path lower-bound traces show why that distinction matters. In the
height-three fixture, let two equal clocks start with allowance `A >= 2` and let
`0 <= G < A`. The active side can respond at `A - 1`, retaining `G + 1`, then
make the other side consume its full allowance. The first match is deleted at
elapsed time `2A - 1`. If a third claim has waited dangling since the initial
block, re-pairing starts its untouched clock and its timeout becomes available
at `3A - 1`. These schedules are reachable for both `G = 0` and `G > 0`; the
discount is the only extra term in the exact clock-mass identity. They show
that both clocks of a pair and then a dangling claim can serialize in wall
time. They neither show that a responsive correct participant must follow the
schedule, disprove the coarser population-window upper bound, nor prove that
this is the globally optimal adversarial strategy.

A separate proof-inclusive finite-state model exhausts every schedule in its
clock abstraction for `N = 1..6`, `A = 1..4`, `G = 0..2`, and `H = 1..3`
under prompt first-eligible-block timeout cleanup. It explores late joins,
responses, pre-timeout proofs, timeout and proof settlement, re-pairing, and
same-block ordering. For heights two and three, its finite maxima match

```text
N = 1: A
N >= 2: 2A - 1 + (H - 1)g
          + (ceil(N / 2) - 1) * (A + (H - 1)g)
where g = min(G, A - 1)
```

Height one has a distinct leaf-race table. The model deliberately lets either
side be provable independently at each leaf, forgetting cross-match correctness
correlation, and it does not impose an honest-validator strategy. Its values are
therefore a conservative clock-only envelope for that finite box, not the
general adversarial theorem. The executable maximum witness for
`N = 3, A = 4, G = 2, H = 3` completes at relative block 19 and is replayed
against `Tournament`.

Progressively late joins have their initial clocks reduced by their lateness,
and ordinary re-pairing never refills a survivor. Still, the asynchronous
bracket can look like a list and a same-time dangling claim can retain a full
paused clock.
Only one unmatched commitment per tournament can wait without an opposing
running clock or delegated child. Full population-halving rounds require a
corresponding live claim reservoir, but that structural fact must not be
substituted for a finite wall-time proof. The timeout argument also depends on
charging each elapsed interval at most once: a paused bisection winner inherits
the responder's overdue interval, while a running leaf winner has already paid
for it through its live remainder.

For the intended two-level deployment, let `A_i` denote the allowance-scale
term available at level `i`. An attack with `R` root claims and `S` claims in
each slow child has the approximate allowance-only delay shape

```text
log2(R) * (A0 + log2(S) * A1)
```

For `L` per-level reservoirs `n_i`, with total claim instances approximately
`N = product(n_i)`, the deepest nested allowance term has the shape

```text
A_(L - 1) * product(log2(n_i))
```

Under comparable per-level allowance and claim costs, the balanced construction
uses `n_i ~= N^(1/L)` and has the familiar leading shape

```text
A * (log2(N) / L)^L
```

These asymptotic expressions suppress finite response terms. For a conservative
one-level leaf window, substitute `W_i = 2A_i + H_i * G` for an
allowance-only term. The construction requires a full adversarial reservoir of
order `product(n_i)`. Here `N` counts claim instances across distinct
tournament contracts, not unique actors. Different per-level bond values change
the budget-balancing point.

The status of the delay claims is:

| Claim | Scope | Status |
| --- | --- | --- |
| At least `floor(K / 2)` clocks run | Single-level leaf tournament | Exact structural lower bound |
| `K(t + W) <= ceil(K(t) / 2)` | Joining closed, prompt cleanup, available transaction capacity | Conditional single-level bound |
| Balanced `(log2(N) / L)^L` shape | Multi-level claim-reservoir construction | Asymptotic attack construction |
| General attacker-versus-correct delay | Arbitrary recursive arrivals and finite blockspace | Open non-claim |

The construction is not a recursive upper bound over every asynchronous
ordering. The retained on-chain trace validates concurrent-child population
mechanics for its fixed four-root, four-child-claim shape, not the expression's
worst-case timing.

Clock-induced delay and transaction work are different properties. A skewed
arrival schedule can force a correct survivor through a linear number of
matches, with work proportional to the number of claims times the commitment
height. Clock conservation prevents arbitrary refill, but does not make that
work logarithmic. Finite blockspace can turn the linear transaction workload
into additional wall-clock delay. Bond dimensioning and operational capacity
must cover this resource attack separately from the chess-clock bound.

### Sealing

At height one, the match identifies the agreed pre-state and the two contested
post-states.

For a leaf tournament:

- `sealLeafMatch` verifies the agreed-state proof.
- The active side's seal is the final eligible response and applies one
  response discount.
- Both clocks are made running.
- Anyone may submit the state-transition proof.

For a non-leaf tournament:

- The active side's seal is the final eligible response; after its discount,
  both clocks are paused.
- The greater remaining duration becomes the child tournament's initial
  allowance.
- A child tournament is created and linked to the sealed parent match.

After sealing, the current `Match.State` storage slots change meaning:
`otherParent` holds the agree state, `leftNode` holds commitment one's final
state, and `rightNode` holds commitment two's final state. Code must check the
match phase before interpreting those fields. The implementation derives
uninitialized, bisecting, ready-to-seal, and sealed phases from the existing
fields and exposes phase-specific internal views; it does not add a stored
phase or reshape the externally visible tuple. The canonical commitment order
is an intentional change to the sealed tuple's semantics.

### Resolution and winner re-entry

A leaf proof is available only while neither clock has expired. `winLeafMatch`
checks that timeout status before invoking the state-transition contract. A
successful proof snapshots and pauses the proven side's live remainder, then
returns it to asynchronous pairing. Once either clock expires, proof resolution
reverts with `CannotAdvanceTimedOutClock`; callers must use the timeout verb
selected by the shared classifier.

This makes proof, single-winner timeout, and double elimination disjoint at one
observation instant. Objective state-transition correctness remains subordinate
to clock viability: a correct commitment that misses its clock can lose by
timeout. The strict verb partition also avoids doing an expensive proof after
the match has already become timeout-resolvable.

A non-leaf match resolves when its linked child finishes:

- If the child has a winner within its carryover window, that winner propagates
  to the parent, carrying its adjusted remaining clock.
- If the child has no usable winner and is eliminable, both parent commitments
  are eliminated.

A timeout resolution has one of three effects:

- Commitment one survives after any phase-dependent deferred charge is
  subtracted.
- Commitment two survives after any phase-dependent deferred charge is
  subtracted.
- Neither has enough time to survive, so both are eliminated.

The charge depends on the legal match phase. During active bisection the
prospective winner is paused, so the expired responder's overdue duration is a
deferred interval in which timeout cleanup could itself have been censored. The
paused winner survives only when its stored remainder is strictly greater than
that charge; equality eliminates both commitments. During a sealed leaf both
clocks are already running, so the survivor's live remainder has paid for the
elapsed interval and the deferred charge is zero. When the allowances differ,
the shorter clock's deadline begins a single-winner window that lasts through
the block before the longer clock's deadline; at the longer deadline both are
eliminated.

| Phase | No expired clock | Exactly one expired | Both expired |
| --- | --- | --- | --- |
| Active bisection | `NONE` | Paused opponent wins iff its remainder is greater than responder overdue; otherwise eliminate both | Not reachable in a legal pair |
| Sealed leaf | `NONE` | Running survivor wins with zero deferred charge | Eliminate both |
| Sealed inner | `NONE` | Not reachable; both clocks are paused | Not reachable |

The contract cannot identify why cleanup was delayed. Under the threat model, a
responsive correct participant and sufficient transaction capacity make the
permissionless timeout transaction available as soon as it becomes valid. The
model charges any further inclusion delay against `C`; in a real deployment the
same interval may instead arise from ordinary congestion. A
Sybil-versus-Sybil match may remain overdue by choice, but that does not
establish a delay bound for a correct participant.

The two mutating timeout paths and `canWinMatchByTimeout` derive from the same
pure four-way classification. The view is true only for a single-winner outcome
and returns false for nonexistent or deleted matches. It does not validate the
Merkle children needed to settle that winner.

The survivor re-enters the same dangling/pairing mechanism. This repeated
pairing is why total delay and total refunds are global properties rather than
properties of one match.

## Tournament completion and result

A tournament closes when its global allowance reaches its deadline. It is
finished when it is closed and has no live matches.

If one commitment remains dangling, it is the tournament winner. The root result
includes that commitment and its final state. An inner result additionally maps
the winning inner commitment back to one of the two parent commitments and
returns an adjusted paused clock.

`arbitrationResult()` is intended for root consumers, but the current contract
does not enforce a root-only guard. Parents use `innerTournamentWinner()` rather
than `arbitrationResult()`.

If no commitment remains, the tournament has finished without a winner. A root
cannot produce an arbitration result in that state. A parent may eventually
eliminate a no-winner child.

## Clock model

The current `Time` library uses `block.number` as its instant. Deployment code
converts configured wall-clock durations to block counts using a registered
average block time. Therefore a wall-clock statement is only valid when the
chain's `block.number` semantics and the registered conversion agree. Ethereum
is the supported deployment target. Other base chains are experimental unless
their time coordinate and conversion have been validated explicitly. In
particular, the current Arbitrum entries are not valid because the EVM
`NUMBER` opcode exposes the parent-chain block coordinate. See historical
finding PRT-001 in the
[`REVIEW.md`](reviews/2026-07-21-prt-dispute-game/REVIEW.md).

Each commitment clock stores an allowance and a start instant:

- `allowance == 0` is the uninitialized mapping value.
- `allowance > 0` and `startInstant == 0` means paused.
- `allowance > 0` and `startInstant > 0` means running.
- Expiry is derived when elapsed running time reaches the stored allowance.

Initialization and running are structural storage states, not topology or
viability checks. Eliminated commitments retain historical initialized clocks,
and an expired clock may remain structurally running even after match deletion.

For a running clock at instant `now`:

```text
remaining = max(allowance - (now - startInstant), 0)
overdue = max((now - startInstant) - allowance, 0)
```

At exact equality the clock is expired and overdue is zero. A paused initialized
clock retains its stored allowance and does not consume time.

| Live phase | Clock shape | Permitted next transition |
| --- | --- | --- |
| Dangling commitment | One paused clock | Pair with the next eligible commitment |
| Bisecting | Exactly one running, one paused | Advance or phase-aware timeout |
| Ready to seal | Exactly one running, one paused | Leaf or inner seal, or phase-aware timeout |
| Sealed leaf | Both running from the same instant | Proof while status is `NONE`, otherwise the selected timeout verb |
| Sealed inner | Both paused with one linked child | Child propagation or child elimination |
| Deleted match | No live match; historical clocks may remain initialized | None |

Required clock invariants:

- Bisection has exactly one running clock.
- A sealed leaf has two running clocks with the same start instant.
- A sealed inner match has two paused clocks.
- A dangling commitment and a surviving winner are paused.
- Pausing snapshots live remaining time.
- Charging a clock starts from live remaining time, never stale stored
  allowance.
- Timeout accounting subtracts one elapsed interval from a correct
  commitment's clock at most once.
- A running timeout winner is assigned no deferred charge because its live
  remainder already reflects elapsed time. A paused timeout winner is charged
  the expired responder's overdue duration.
- Pairing and ordinary same-tournament winner re-entry never grant time.
- Recursive child return may increase the selected side only within the shared
  sealed-pair envelope; it remains bounded by `max(r1, r2)` and by the pair's
  post-discount live clock mass.
- A response discount applies only before the responder's original deadline
  and never increases its starting balance.
- Parent carryover cannot create an initialized paused clock with zero time.

The principal time intervals are accounted for as follows:

| Interval | Clock accounting |
| --- | --- |
| Tournament creation to join | Deducted during initialization |
| Active turn to successful response | Charged to the responder except for at most `G` |
| Responder deadline to active-match cleanup | Deferred to the paused survivor |
| Leaf seal to proof or timeout | Reflected in both live remainders |
| Parent seal through child resolution | Parent clocks pause; the child owns the shared bounded obligation |
| Child finish to parent propagation | Deducted from the returned child winner |
| Dangling wait | Clock remains paused; closure stops new joins, but existing matches and children may delay finish; one slot bounds only the unpaired population |

The canonical parameters provider rejects `maxAllowance == 0` at deployment.
Before that guard, a canonical root with zero allowance was already closed at
its creation instant, so every join failed with `TournamentIsClosed` before
clock initialization. A zero response budget remains valid and simply applies
no discount. A generic parameters provider is not validated on every factory
read; supported deployments must validate its complete table before use.

The intended mainnet allowance is dimensioned from two distinct budgets:

```text
maxAllowance = censorshipBudget + (levels - 1) * innerCommitmentBudget
```

For the two-level deployment target this is one week of censorship tolerance
plus one inner-tournament commitment budget, currently one hour. The historical
`prt/measure_constants/measure.lua` tool explains how root slowdown and the
maximum inner commitment-building time determine tournament strides and
heights. These measured computation budgets are distinct from the
per-response budget `G`. The deployment stores `G = 5 minutes` in the
legacy-named `matchEffort` field; on Ethereum that is 25 blocks. One
root-to-leaf descent with one match at each level spans 92 tree heights and can
earn at most 7 hours 40 minutes of discounts, one at each successful response.
Repeated matches receive their own bounded response discounts.

`Clock.pauseAfterResponseAt()` implements the non-bankable response formula.
`Clock.chargeAndPauseAt()` snapshots live remaining time before subtracting a
caller-supplied deferred charge and pausing the winner. Single-clock operations
that observe elapsed time take an explicit instant, and `MatchClocks` owns the
legal bisection, leaf-race, and inner-seal phase transitions plus the shared
timeout classification. PRT-002 records the original sealed-leaf restoration
defect, PRT-004 the capability-view correction, PRT-009 the former bankable
pairing grant, and PRT-010 the historical proof/timeout overlap. The later
cumulative-censorship correction is recorded in the review archive's
[dated erratum](reviews/2026-07-21-prt-dispute-game/REVIEW.md#erratum-2026-07-23---sealed-leaf-censorship-amplification).
The pre-correction design history and compatibility fence are preserved in
[`CLOCK-DESIGN.md`](reviews/2026-07-21-prt-dispute-game/CLOCK-DESIGN.md);
neither archive file is the current clock specification.

## Bonds and refunds

Joining posts at least one bond to one tournament instance. A participant
following a recursive dispute may have a separate bond locked at each active
level. Any excess join value enters the same pooled balance as the bonds.

Each progress function uses a fixed `gasAllocation`. After the action body, the
`refundable` modifier computes:

```text
units = Gas.TX + gasBefore - gasAfter
effectivePrice = min(tx.gasprice, block.basefee + Bond.REFUND_PRIORITY_FEE_CAP)
requestedRefund = min(
    tournament balance before the callback,
    gasAllocation * Bond.WORK_PRICE_CAP,
    units * effectivePrice
)
```

It then attempts to transfer `requestedRefund` to the caller. The balance term,
the action-allocation term, and the measured-work term are independent caps.

This is a bounded partial refund, not a guarantee of full transaction cost or
profit. The measured delta is gross EVM work plus a fixed overhead, not exact
receipt gas; transaction-intrinsic calldata, storage-refund credits, and
chain-specific data or security fees are outside the promise. Proof forwarding
and copying after the snapshot remain inside the measured delta. Priority fee
above 10 gwei is also excluded. The action cap is the action allocation times
50 gwei. When real work exceeds that allocation, its effective reimbursed price
ceiling is below 50 gwei.

Exact reimbursement is not a correctness assumption or an endogenous validator
incentive. Seven action allocations have retained measured ceilings;
`WIN_LEAF_MATCH` uses a documented provisional subsidy selected from the
largest canonical InputBox reference witness. That full-stack witness covers
the production provider and state transition, but it is not a universal
proof-class or whole-transaction ceiling: arbitrary trailing proof bytes,
unresolved halt and exception semantics, and transaction-intrinsic calldata
remain outside the claim. Broader proof-class calibration is optional. PRT-003
records the review decision and known limitations;
[`prt-refund-accounting.md`](prt-refund-accounting.md) derives the living
reserve and conservation boundary.

The dated 2026-07-23 calibration measured a 5,359,940-unit whole-transaction
diagnostic for the maximum retained canonical input. That was 31.95% of
Ethereum's 16,777,216-unit per-transaction cap and 8.93% of its 60,000,000-unit
block gas limit. This establishes material admission headroom for that retained
witness, not a permanent limit over future forks, proof encodings, or
state-transition behavior. The
[`PRT leaf-proof gas calibration`](reviews/2026-07-23-prt-leaf-proof-gas-calibration/)
records the comparison, and the runbook requires it to be repeated.

The refund callback occurs after `gasAfter` is sampled, so accepting, rejecting,
or reentrant recipient behavior cannot change the requested value.
`PartialBondRefund.value` records that request whether or not the transfer
succeeds; `success` records whether a nonzero recipient call succeeded, or is
`true` when a zero request skipped the call. Recipient code receives at most
50,000 gas, and its return data is not copied. The
ABI-compatible `PartialBondRefund.ret` field is therefore always empty. A zero
refund skips recipient execution and reports success. A failed nonzero callback
transfers nothing and does not revert the completed action; the requested value
stays in the pooled balance and is not reserved for a later retry by that caller.

When a tournament finishes with a winner, `tryRecoveringBond` attempts to pay the
address that first joined the winning commitment
`min(current balance, bondValue())`. The configured refund caps reserve one
minimum join bond, so an accepting winner receives that amount under
the configured reserve invariant. A height-`h` match has at most `h - 1`
advances, and `J` unique paid joins create at most `J - 1` matches. Before
terminal recovery, the balance is therefore at least one minimum join bond. Only
after a nonzero winner payment succeeds does the contract send the entire
post-payment balance to the zero address. That residual may be zero when every
possible match consumes its complete configured reserve. If the balance is
zero, recovery skips the recipient call and completes defensively.

A commitment root can be joined only once, so copying the correct root first
intentionally claims that capped recipient slot; all progress and defense
operations remain permissionless. Eliminated claimers lose their terminal
payment claim. `Bond` derives the minimum join bond from the configured
match-work reserve: the manual gas table determines the terminal maximum,
tournament height determines the advance count, and the work-price cap converts
that allocation to Wei. Garbage collection advances matches and parent
tournaments, but does not imply that every child balance is settled. A
no-winner child has neither a winning-claimer payment nor this residual-burn
path, so its balance remains locked absent another mechanism.

Successful recovery deletes the winning claimer, and later calls return `true`
as no-ops. This also means ETH forcibly sent after recovery remains stranded;
the burn rule covers the balance present during successful recovery. If a
nonzero recipient payment is rejected, recovery returns `false`, burns nothing,
and preserves both the claimer and the full balance for retry. This idempotence
and retry behavior are required because recovery is permissionless and
tournament-result staging invokes it as best-effort cleanup. Parent propagation
deliberately does not settle the child balance: recovery is separate cleanup,
so a winning claimer's callback cannot consume gas needed to propagate the
child result.

Terminal recipient code has the same 50,000-gas execution ceiling and no
return-data copy. `DaveConsensus.stageTournamentResult` stores the result before
attempting recovery. It ignores both a `false` result and a recovery revert, so
recipient failure cannot undo staging or later acceptance; the old tournament
remains permissionlessly recoverable. An EOA, delegated EOA, or smart-wallet
receive path that cannot complete within the ceiling cannot receive through
this interface. Fixed call overhead is outside the recipient ceiling, and
EIP-150 may reduce forwarded gas in an under-gassed outer call.

Bonds are intended to provide Sybil resistance, not an endogenous validator
incentive. The model assumes validators defend applications they value. A full
residual sweep would conflict with that model: an attacker could claim the
deterministic correct root first, fund incorrect claims, let a correct validator
perform permissionless defense, and recover the losers' residual pool through
the winning claimer slot. The capped payment and residual burn prevent that
recycling after legitimate partial refunds. The contract cannot identify an
honest address; it can identify only the winning commitment and its first
claimer.

There is no additional Sybil stake. For a tournament with an accepting winner,
the aggregate losing reserves are either paid as bounded subsidies for
successful dispute work or remain for terminal burning. If an honest validator
performs the work, the attacker's pooled reserve funds that caller. If an
attacker collects a refund itself, the successful action still consumes
Ethereum execution and blockspace. This is not a receipt-exact or identity-level
attacker-cost theorem: refunds go to immediate `msg.sender`, the top-level gas
payer may differ, and the gross measurement can differ from receipt gas.

Under this rule, small repeated vandalism remains possible by design. For
example, two incorrect claims can make one opponent active while the other
waits dangling, serializing the active pair and then a replacement match.
Repeating the construction in sequential epochs creates linear cumulative
disruption for linear forfeited reserves and transaction work. The structural
population-window argument applies within one tournament after joining closes;
it is neither exponential deterrence across games whose clocks reset nor a
bound on transaction work.

Required economic invariants:

- A caller cannot withdraw more than the configured refund cap for one action.
- `J` unique paid joins create at most `J - 1` matches, and each match consumes
  at most its configured work reserve.
- Before successful winner recovery, configured refund caps preserve one
  minimum join bond.
- With exact-value joins and an accepting winner, aggregate losing reserves are
  either paid for successful dispute work or burned as terminal
  residual. No positive residual burn is guaranteed.
- Aggregate refunds, terminal payout, and residual burn conserve the actual
  tournament balance and cannot pay or burn the same value twice.
- Failed refund transfers do not corrupt tournament state. A failed terminal
  payout does not delete the claimer or burn any of the retryable balance.
- Recipient execution is bounded and return data cannot create an unbounded
  settlement or action-refund tail.
- Reentrant receivers cannot enter another state-changing operation on the same
  tournament.
- The documented incentive model includes every fee it claims to cover.

## Permissionless cleanup and access

Progress, timeout resolution, child propagation, garbage collection, and bond
recovery are permissionless entry points. Correctness must not depend on the
original claimer being the caller. Claimer identity controls only the capped
terminal-payment recipient; the residual always goes to the fixed burn sink.

Each tournament clone uses its own transient reentrancy lock around
state-changing calls, external ETH transfers, and child interactions. A nested
state-changing call to the same clone reverts with `ReentrancyDetected`. A
payment callback may enter and mutate a different clone whose independent lock
is free, provided the nested work fits the callback gas ceiling. The lock does
not globally serialize tournament instances. Cross-instance child calls remain
trust boundaries and must consume only children linked by the parent.

## Executable specification priorities

The most important prose invariants should also exist as Foundry properties:

- Stateful tournament accounting and legal lifecycle phases.
- Clock conservation, non-amplification of cumulative censorship, and
  timeout-outcome partitioning.
- Exhaustive bisection parity and divergence attribution.
- Parent-child winner and clock carryover.
- Parameter-table shape and recursion beyond the canonical level count.
- Aggregate bond and refund accounting.
- Deployment time-source conformance.

The bounded single-level scheduler is landed. Remaining liveness work is an
unbounded proof or counterexample, plus a recursive model that distinguishes an
attacker's choices from the responsive correct participant's strategy. The
finite search discovers and retains clock schedules; it must not be presented
as that general theorem.

Current Foundry evidence and its remaining gaps live in
[`prt-contract-testing.md`](prt-contract-testing.md). Cross-client timeout
alignment remains tracked in
[`prt-timeout-alignment.md`](plans/prt-timeout-alignment.md). The review archive
is historical evidence, not a hidden backlog.
