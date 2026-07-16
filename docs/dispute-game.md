# PRT dispute game

This document describes the dispute game implemented by the Solidity contracts
under `prt/contracts/`. It covers tournament structure, lifecycle, clocks,
recursive disputes, and economics. The code remains the source of truth; this
document states the protocol invariants and assumptions that code changes must
preserve.

The implementation of the Cartesi state-transition function is outside this
document. At the leaf level, the dispute game treats that function as the
authority that maps an agreed pre-state and proof to the next state.

Active review findings and proposed changes live in
[`prt/contracts/audit/REVIEW.md`](../prt/contracts/audit/REVIEW.md). They are not
silently presented here as implemented behavior.

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

- The correct participant is not censored beyond the configured allowance.
- The application is disputable within the clock dimensioning assumptions in
  [`dimensioning.md`](dimensioning.md).
- The chain time source advances according to the assumptions used to convert
  wall-clock durations into protocol durations.
- At least one externally motivated actor submits required progress and cleanup
  transactions. The protocol does not promise an endogenous validator profit.

A timeout can make an incorrect commitment survive if the correct participant
does not act within those assumptions. Timeout victory is part of the protocol,
not evidence that the surviving computation was executed correctly.

## Relationship to the papers

The original [`prt/docs/prt.pdf`](../prt/docs/prt.pdf) is an architectural
ancestor, not a specification of these contracts. The Dave paper describes a
successor liveness design that these contracts do not implement.

| Subject | Original PRT paper | Current contracts |
| --- | --- | --- |
| Participant organization | Teams and tournament bracket | One asynchronous pool with a dangling commitment |
| Pairing | Bracket-oriented | Commitments pair as they arrive and winners re-enter |
| Dispute depth | Paper construction | Recursive, configurable tournament levels |
| Per-match timing | High-level chess-clock model | Stored per-commitment clocks with explicit timeout entry points |
| Economics | Conceptual permissionless incentives | On-chain bonds, partial refund caps, and winner balance sweep |
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

The checked-in canonical provider configures three levels. The deployment
target is two levels, and that change requires regenerated and validated height
and stride tables. The tournament lifecycle is intended to depend on `levels`,
not on either number.

The factory permits anyone to instantiate root or inner clones. An inner clone
created directly through the factory is an orphan: it is not authoritative for
any parent. A parent accepts only a child recorded in its own
`matchIdFromInnerTournaments` mapping when that parent sealed a match.

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
`commitmentTwo`. The current implementation grants both clocks the configured
pairing-response budget, capped by `maxAllowance`, and starts the older
commitment's clock. This includes a fresh newcomer, so a late join can recover
time that its decayed initial allowance had already lost. The delay-model
consequences and proposed non-bankable replacement are tracked in the review
ledger.

Important invariants:

- There is at most one dangling commitment.
- Every live joined commitment is either dangling or belongs to one live match.
- `matchCount` equals the number of live matches.
- A commitment root can be joined only once in one tournament instance.

### Bisection

Each match compares two commitment trees. One clock runs while that participant
must reveal the next children. A valid `advanceMatch` descends one tree level
toward the first divergent leaf, then switches the turn.

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
`floor(K / 2)` live matches and at most one dangling commitment. During
bisection, one of each match's two clocks runs; after leaf sealing both run. A
leaf tournament therefore has at least `floor(K / 2)` running clocks.

A sealed non-leaf match is the recursive exception: both parent clocks pause
with live remainders `r1` and `r2`, and the child tournament receives
`max(r1, r2)` as its initial allowance. A child deadline closes joining; child
finish still depends on resolving its matches and any deeper children. The
recursive structural invariant is therefore that every parent pair either has a
clock running or has delegated population reduction to a child tournament. At
most one commitment per tournament escapes pairing by waiting dangling.

On successful propagation, the returned child-winner clock replaces the
corresponding parent clock after post-finish deduction; it is not added to the
parent balance. The intended non-bankable design should establish
`returned <= max(r1, r2)`. Current pairing grants can violate that conservation
predicate because child clocks are capped by the global `maxAllowance`, not by
the smaller delegated allowance.

That active-pair invariant, rather than the visual shape of the asynchronous
bracket, gives the timeout bound. Once joining has closed, every bounded
resolution window turns each existing pair into at most one survivor. The live
population therefore falls by a constant factor per window. In the
idealized model with no response grants and prompt permissionless cleanup, an
all-at-once balanced attack with `P` total commitments reaches

```text
A * max(1, ceil(log2(P)))
```

where `A` is the initial allowance. Progressively late joins can make the
pairing tree look like a list, but their initial clocks have already lost the
same time they spent waiting. Only one unmatched commitment can remain paused
without an opposing running clock or delegated child. A new full-allowance
delay layer therefore requires an exponentially larger reservoir of
simultaneously live claims.

This reasoning depends on charging timeout winners from their live remaining
time. It also becomes less exact when pairing grants bankable clock time. The
current grants remain capped by `A`, so each newly created one-level match has
at most `2A` total clock mass and produces at most one survivor. With prompt
timeout cleanup after joining closes, each `2A` window therefore reduces the
population to at most `ceil(K / 2)`, even if those survivors re-pair and receive
another grant. The coarse one-level timeout bound remains logarithmic, but the
grants change finite constants and let late claims buy bounded tails. The
sealed-leaf accounting defect in PRT-002 and the current fresh-join grant are
therefore liveness issues even though neither changes that coarse asymptotic
statement.

For the intended two-level deployment, an attack with `R` root claims and `S`
claims in each slow child has the approximate delay shape

```text
log2(R) * (A0 + log2(S) * A1)
```

and requires a full adversarial reservoir of order `R * S`. Here `N` counts
adversarial claim instances across distinct tournament contracts, not unique
actors. With equal allowances and equal per-level bonds, a fixed claim budget is
balanced at `R ~= S ~= sqrt(N)`, giving the familiar leading
`log2(N)^2 / 4` factor. Actual fixed-ETH dimensioning must weight levels by
their different bond values. This is a validated attack construction and
dimensioning model, not yet a formal upper bound over every asynchronous
ordering.

Clock-induced delay and transaction work are different properties. A skewed
arrival schedule can force a correct survivor through a linear number of
matches, with work proportional to the number of claims times the commitment
height, even though it cannot give every match a fresh allowance-sized delay.
Finite blockspace can turn that work into additional wall-clock delay. Bond
dimensioning and operational capacity must cover this resource attack
separately from the chess-clock bound.

### Sealing

At height one, the match identifies the agreed pre-state and the two contested
post-states.

For a leaf tournament:

- `sealLeafMatch` verifies the agreed-state proof.
- Both clocks are made running.
- Anyone may submit the state-transition proof.

For a non-leaf tournament:

- Both clocks are paused and their remaining times are snapshotted.
- The greater remaining duration becomes the child tournament's initial
  allowance.
- A child tournament is created and linked to the sealed parent match.

After sealing, the current `Match.State` storage slots change meaning: fields
that held bisection nodes hold the agree hash and contested final states. Code
must check the match phase before interpreting those fields.

### Resolution and winner re-entry

A leaf match resolves when the state-transition contract computes a post-state
equal to one contested final state. The corresponding commitment survives,
becomes paused, and returns to asynchronous pairing. `winLeafMatch` checks match
existence and the proof, but not whether either clock has expired. A valid proof
can therefore beat a timeout until a timeout-resolution transaction actually
eliminates the match. This makes proof resolution permissionless and avoids a
separate clock race in that path; transaction ordering decides which valid
resolution lands first.

A non-leaf match resolves when its linked child finishes:

- If the child has a winner within its carryover window, that winner propagates
  to the parent, carrying its adjusted remaining clock.
- If the child has no usable winner and is eliminable, both parent commitments
  are eliminated.

A timeout resolution has one of three effects:

- Commitment one survives and is charged for commitment two's overdue time.
- Commitment two survives and is charged for commitment one's overdue time.
- Neither has enough time to survive, so both are eliminated.

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
`NUMBER` opcode exposes the parent-chain block coordinate. See PRT-001 in the
review ledger.

Each commitment clock stores an allowance and a start instant:

- `allowance == 0` is the uninitialized mapping value.
- `allowance > 0` and `startInstant == 0` means paused.
- `allowance > 0` and `startInstant > 0` means running.
- Expiry is derived when elapsed running time reaches the stored allowance.

For a running clock at instant `now`:

```text
remaining = max(allowance - (now - startInstant), 0)
overdue = max((now - startInstant) - allowance, 0)
```

At exact equality the clock is expired and overdue is zero. A paused initialized
clock retains its stored allowance and does not consume time.

Required clock invariants:

- Bisection has exactly one running clock.
- A sealed leaf has two running clocks.
- A sealed inner match has two paused clocks.
- A dangling commitment and a surviving winner are paused.
- Pausing snapshots live remaining time.
- Charging a clock starts from live remaining time, never stale stored
  allowance.
- Effort grants are capped by `maxAllowance`.
- Parent carryover cannot create an initialized paused clock with zero time.

The intended mainnet allowance is dimensioned from two distinct budgets:

```text
maxAllowance = censorshipBudget + (levels - 1) * innerCommitmentBudget
```

For the two-level deployment target this is one week of censorship tolerance
plus one inner-tournament commitment budget, currently one hour. The historical
`prt/measure_constants/measure.lua` tool explains how root slowdown and the
maximum inner commitment-building time determine tournament strides and
heights. These measured computation budgets are distinct from the
five-minutes-per-anticipated-response budget, currently summed across 92 tree
heights into 7 hours 40 minutes and front-loaded through `matchEffort`.

The current `Clock.deducted()` violates the live-remaining rule when a sealed
leaf timeout charges a still-running winner. This is PRT-002 in the review
ledger. The proposed replacement API and test contract are recorded in
[`prt/contracts/audit/CLOCK-DESIGN.md`](../prt/contracts/audit/CLOCK-DESIGN.md).

## Bonds and refunds

Joining posts one bond to one tournament instance. A participant following a
recursive dispute may have a separate bond locked at each active level.

Each progress function uses a fixed gas allocation. The `refundable` modifier
pays the caller the minimum of:

- The tournament's current balance.
- The function's configured fraction of one bond.
- Measured execution gas priced by a capped gas price, with a fixed transaction
  overhead.

This is a bounded partial refund, not a guarantee of full transaction cost or
profit. In particular, the formula does not account for every chain-specific L1
data or security fee. The bond-share cap also assumes at most the configured
`MAX_GAS_PRICE`, currently 50 gwei, so sustained base fees above that value are
under-reimbursed even if the execution-gas estimate is exact. The fixed
estimates must be kept conservative and tested against representative proof
sizes. PRT-003 records known estimate failures.

Under the current implementation, when a tournament finishes with a winner,
the address that first joined the winning commitment may sweep the entire
remaining tournament balance. A commitment root can be joined only once, so
copying the correct root first intentionally claims that recipient slot; all
progress and defense operations remain permissionless. Eliminated claimers lose
their sweep claim. Garbage collection advances matches and parent tournaments,
but does not imply that every child balance becomes recoverable. A no-winner
child has no winner to perform the ordinary balance sweep.

Successful recovery deletes the winning claimer. The current function is not
idempotent: a second permissionless call panics. This can block both root epoch
settlement and propagation of an already-recovered child winner. PRT-007 tracks
the fix.

Bonds are intended to provide Sybil resistance, not an endogenous validator
incentive. The model assumes validators defend applications they value. The
current residual sweep conflicts with the Sybil-cost model: an attacker can
claim the deterministic correct root first, fund incorrect claims, let a correct
validator perform permissionless defense, and recover the losers' residual pool
through the winning claimer slot. The agreed redesign, not yet implemented,
pays the registered claimer of the eventual winning commitment at most one bond
and burns the rest. The contract cannot identify an honest address; it can
identify only the winning commitment and its first claimer.

Under that redesign, small repeated vandalism remains possible by design. For
example, two incorrect claims can make one opponent active while the other
waits dangling, buying roughly two single-level clock windows. Repeating the
construction in sequential epochs creates linear cumulative disruption for
linear bond burn net of legitimate partial refunds. The logarithmic delay
statement is per tournament, not a promise of exponential deterrence across
games whose brackets and clocks reset.

Required economic invariants:

- A caller cannot withdraw more than the configured refund cap for one action.
- Aggregate refunds, terminal payout, and residual burn cannot exceed deposited
  tournament funds or pay the same balance twice.
- Failed refund transfers do not corrupt tournament state.
- Reentrant receivers cannot enter another state-changing operation on the same
  tournament.
- The documented incentive model includes every fee it claims to cover.

## Permissionless cleanup and access

Progress, timeout resolution, child propagation, garbage collection, and bond
recovery are permissionless entry points. Correctness must not depend on the
original claimer being the caller. Claimer identity controls only the final
balance recipient.

The tournament uses a transient reentrancy lock around state-changing calls,
external ETH transfers, and child interactions. Cross-instance child calls are
still trust boundaries and must consume only children linked by the parent.

## Executable specification priorities

The most important prose invariants should also exist as Foundry properties:

- Stateful tournament accounting and legal lifecycle phases.
- Clock conservation and timeout-outcome partitioning.
- Exhaustive bisection parity and divergence attribution.
- Parent-child winner and clock carryover.
- Aggregate bond and refund accounting.
- Deployment time-source conformance.

The detailed test backlog is maintained in the review ledger rather than here,
so this document can remain focused on protocol behavior.
