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
must reveal the next children. A valid `advanceMatch` descends one tree level
toward the first divergent leaf, then switches the turn. A height-`H` match has
exactly `H` eligible responses: `H - 1` advances and one final leaf or inner
seal.

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

A sealed non-leaf match is the recursive exception: both parent clocks pause
with live remainders `r1` and `r2`, and the child tournament receives
`max(r1, r2)` as its initial allowance. A child deadline closes joining; child
finish still depends on resolving its matches and any deeper children. The
recursive structural invariant is therefore that every parent pair either has a
clock running or has delegated population reduction to a child tournament. At
most one commitment per tournament escapes pairing by waiting dangling. If `S`
of the `M` parent matches are sealed-inner, the parent-local count is
`runningClocks >= M - S`; each of those `S` exceptions has one linked child
carrying the bounded resolution obligation.

On successful propagation, the returned child-winner clock replaces the
corresponding parent clock after post-finish deduction; it is not added to the
parent balance. Pairing cannot refill it, so
`returned <= max(r1, r2) <= maxAllowance`.

That active-pair invariant, rather than the visual shape of the asynchronous
bracket, gives the timeout bound. Once joining has closed, every bounded
resolution window turns each existing pair into at most one survivor. The live
population therefore falls by a constant factor per window.

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

For a leaf match, `b1 + b2 + H * G` conservatively bounds resolution to at most
one survivor. For a non-leaf match, the same expression bounds reaching local
seal or timeout deletion, but excludes resolution of any child created by
sealing. Consequently, in a single-level leaf tournament with per-clock bound
`A`, a population-reduction window is at most `2A + H * G`. With prompt
permissionless cleanup after joining closes, each such window reduces `K` live
commitments to at most `ceil(K / 2)`. An all-at-once reservoir therefore has a
coarse logarithmic clock-delay bound of

```text
(2A + H * G) * max(1, ceil(log2(P)))
```

for `P` commitments of one common height. This is deliberately conservative;
many timeout paths consume only one clock. Progressively late joins can make
the pairing tree look like a list, but their initial clocks have already lost
the same time they spent waiting, and re-pairing cannot refill them. Only one
unmatched commitment can remain paused without an opposing running clock or
delegated child. A new full-allowance delay layer therefore requires an
exponentially larger reservoir of simultaneously live claims. This reasoning
also depends on charging timeout winners from their live remaining time, as
fixed by PRT-002.

For the intended two-level deployment, an attack with `R` root claims and `S`
claims in each slow child has the approximate delay shape

```text
log2(R) * (A0 + log2(S) * A1)
```

This asymptotic expression suppresses finite response terms: discounts add up
to `H_i * G` per match. For a conservative one-level leaf window, substitute
`2A_i + H_i * G` for an allowance-only term. The construction requires a full
adversarial reservoir of order `R * S`. Here `N` counts
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

After sealing, the current `Match.State` storage slots change meaning: fields
that held bisection nodes hold the agree hash and contested final states. Code
must check the match phase before interpreting those fields.

### Resolution and winner re-entry

A leaf match may resolve for the side whose contested final state equals the
post-state computed by the state-transition contract, but only if the shared
timeout status also permits that side. With no timeout, clock settlement charges
zero from the proven side's live remaining time. If the same commitment is the
single timeout winner, it is charged the opponent's classified overdue duration.
Its settled clock then returns to asynchronous pairing, which may leave it
paused or immediately start another match. An opposite timeout winner or
`ELIMINATE_BOTH` rejects the proof as too late.

At the same observation instant, successful proof and timeout resolutions
cannot select different survivors. A proof compatible with a single-winner
timeout outcome selects the same survivor and clock charge before identical
re-pairing; an incompatible proof rejects in favor of the timeout outcome.
Objective state-transition correctness remains subordinate to clock viability:
a correct commitment that misses its clock can lose by timeout, just as it
could before this ordering ambiguity was removed.

A non-leaf match resolves when its linked child finishes:

- If the child has a winner within its carryover window, that winner propagates
  to the parent, carrying its adjusted remaining clock.
- If the child has no usable winner and is eliminable, both parent commitments
  are eliminated.

A timeout resolution has one of three effects:

- Commitment one survives and is charged for commitment two's overdue time.
- Commitment two survives and is charged for commitment one's overdue time.
- Neither has enough time to survive, so both are eliminated.

When exactly one clock is expired, its opponent survives only if the opponent's
live remaining time is strictly greater than the expired clock's overdue time.
Equality or a larger overdue duration eliminates both commitments. The two
mutating timeout paths and `canWinMatchByTimeout` derive from the same pure
four-way classification. The view is true only for a single-winner outcome and
returns false for nonexistent or deleted matches. It does not validate the
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
- A sealed leaf has two running clocks with the same start instant.
- A sealed inner match has two paused clocks.
- A dangling commitment and a surviving winner are paused.
- Pausing snapshots live remaining time.
- Charging a clock starts from live remaining time, never stale stored
  allowance.
- Pairing and winner re-entry never increase either clock balance.
- A response discount applies only before the responder's original deadline
  and never increases its starting balance.
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
per-response budget `G`. The deployment stores `G = 5 minutes` in the
legacy-named `matchEffort` field; on Ethereum that is 25 blocks. One
root-to-leaf descent with one match at each level spans 92 tree heights and can
earn at most 7 hours 40 minutes of discounts, one at each successful response.
Repeated matches receive their own bounded response discounts.

`Clock.pauseAfterResponseAt()` implements the non-bankable response formula.
`Clock.chargeAndPauseAt()` snapshots live remaining time before subtracting the
loser's overdue duration and pausing the winner. Single-clock operations that
observe elapsed time take an explicit instant, and `MatchClocks` owns the legal
bisection, leaf-race, and inner-seal phase transitions plus the shared timeout
classification and proven-leaf settlement policy. PRT-002 records the prior
sealed-leaf defect, PRT-004 the capability-view correction, PRT-009 the former
bankable pairing grant, and PRT-010 the removal of proof/timeout ordering
ambiguity. The clock decisions and regression model are recorded in
[`prt/contracts/audit/CLOCK-DESIGN.md`](../prt/contracts/audit/CLOCK-DESIGN.md).

## Bonds and refunds

Joining posts at least one bond to one tournament instance. A participant
following a recursive dispute may have a separate bond locked at each active
level. Any excess join value enters the same pooled balance as the bonds.

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

When a tournament finishes with a winner, `tryRecoveringBond` pays the address
that first joined the winning commitment
`min(current balance, bondValue())`. It does not reserve one bond: legitimate
progress refunds may leave less than that amount. Only after a nonzero winner
payment succeeds does the contract send the entire post-payment balance to the
zero address. If the balance is zero, it skips the recipient call and completes
recovery directly.

A commitment root can be joined only once, so copying the correct root first
intentionally claims that capped recipient slot; all progress and defense
operations remain permissionless. Eliminated claimers lose their terminal
payment claim. Garbage collection advances matches and parent tournaments, but
does not imply that every child balance is settled. A no-winner child has
neither a winning-claimer payment nor this residual-burn path, so its balance
remains locked absent another mechanism.

Successful recovery deletes the winning claimer, and later calls return `true`
as no-ops. This also means ETH forcibly sent after recovery remains stranded;
the burn rule covers the balance present during successful recovery. If a
nonzero recipient payment is rejected, recovery returns `false`, burns nothing,
and preserves both the claimer and the full balance for retry. This idempotence
and retry behavior are required because recovery is permissionless and both
root settlement and parent propagation call it as part of their own lifecycle.

Bonds are intended to provide Sybil resistance, not an endogenous validator
incentive. The model assumes validators defend applications they value. A full
residual sweep would conflict with that model: an attacker could claim the
deterministic correct root first, fund incorrect claims, let a correct validator
perform permissionless defense, and recover the losers' residual pool through
the winning claimer slot. The capped payment and residual burn prevent that
recycling after legitimate partial refunds. The contract cannot identify an
honest address; it can identify only the winning commitment and its first
claimer.

Under this rule, small repeated vandalism remains possible by design. For
example, two incorrect claims can make one opponent active while the other
waits dangling, buying roughly two single-level clock windows. Repeating the
construction in sequential epochs creates linear cumulative disruption for
linear bond burn net of legitimate partial refunds. The logarithmic delay
statement is per tournament, not a promise of exponential deterrence across
games whose brackets and clocks reset.

Required economic invariants:

- A caller cannot withdraw more than the configured refund cap for one action.
- Aggregate refunds, terminal payout, and residual burn conserve the actual
  tournament balance and cannot pay or burn the same value twice.
- Failed refund transfers do not corrupt tournament state. A failed terminal
  payout does not delete the claimer or burn any of the retryable balance.
- Reentrant receivers cannot enter another state-changing operation on the same
  tournament.
- The documented incentive model includes every fee it claims to cover.

## Permissionless cleanup and access

Progress, timeout resolution, child propagation, garbage collection, and bond
recovery are permissionless entry points. Correctness must not depend on the
original claimer being the caller. Claimer identity controls only the capped
terminal-payment recipient; the residual always goes to the fixed burn sink.

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
