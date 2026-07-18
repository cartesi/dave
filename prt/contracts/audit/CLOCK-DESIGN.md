# Clock API design checkpoint

Status: clock API, timeout classifier, and response budget implemented

Last reviewed: 2026-07-17

This document records the implemented dispute-game clock abstraction and its
policy decisions. Current protocol behavior is documented in
[`docs/dispute-game.md`](../../../docs/dispute-game.md); confirmed and resolved
clock findings are tracked in [`REVIEW.md`](REVIEW.md).

## Implemented scope

- Every clock phase transition is explicit at the call site.
- Elapsed-time accounting is centralized in pure functions with an explicit
  observation instant.
- Single-clock arithmetic is separate from two-player match policy.
- Timeout resolution is one pure four-way classification shared by the
  capability view, both timeout mutation paths, and proven-leaf settlement.
- Response latency is discounted only after a successful bisection response;
  pairing and winner re-entry never increase clock balances.
- Tournament operations read the chain time source once for their clock work and
  pass that value through.
- The one-slot storage representation and external tuple are unchanged.

The work deliberately did not select a new cross-chain time source, change the
allowance formula or level layout, move error declarations, or refactor
unrelated lifecycle code. Those remain separate reviewable changes. The
response-budget migration did change the configured legacy-named `matchEffort`
value from the former `5 minutes * sum(heights)` one-descent aggregate to the
per-response scalar.

## Representation and compatibility fence

`Clock.State` remains:

```solidity
struct State {
    Time.Duration allowance;
    Time.Instant startInstant;
}
```

The stored states are interpreted as follows:

| `allowance` | `startInstant` | Meaning |
| --- | --- | --- |
| zero | zero | Uninitialized mapping value |
| positive | zero | Initialized and paused |
| positive | positive | Initialized and running |

An expired clock remains in the running representation. Expiry is derived from
the current instant; it is not a stored phase. An initialized paused clock with
zero allowance is forbidden because zero allowance is the initialization
sentinel.

The refactor preserved the library and type name, field names, order, and
user-defined value types. This is stricter than preserving function selectors:

- `getCommitment` and `innerTournamentWinner` expose the tuple.
- ABI component names appear in generated bindings.
- The Rust binding reads `allowance` and `startInstant` by name.
- The Lua reader decodes the two `uint64` values positionally.

A pre/post `forge inspect Tournament abi` comparison was byte-identical. No
status field was added, and clock errors remain declared in `ITournament`.
Moving a same-signature error would preserve its raw selector, but it would
break Solidity source consumers that reference `ITournament.ClockNotInitialized`
and the other qualified names.

## Single-clock invariants

For an initialized clock and an observation instant `current`:

```text
elapsed = running ? current - startInstant : 0
remaining = max(allowance - elapsed, 0)
overdue = running ? max(elapsed - allowance, 0) : undefined
```

The implementation maintains these rules:

1. Uninitialized clocks cannot be queried as tournament participants or
   transitioned to running.
2. Starting requires an initialized paused clock and a nonzero start instant.
3. Response pausing requires a running clock before its deadline, charges
   `max(elapsed - responseBudget, 0)`, and clears the start instant.
4. No mutation uses raw `allowance` as remaining time unless it has established
   that the clock is paused.
5. Charging first snapshots live remaining time, subtracts the charge, and
   pauses the clock.
6. A response discount never increases the action-start balance and cannot
   revive an expired running clock.
7. A storage transition cannot create an initialized paused clock with zero
   remaining time.
8. `current` cannot precede a running clock's start instant.

At the exact deadline, remaining time is zero and the clock is expired. Its
overdue duration is still zero. Expiry is a predicate; overdue is a duration.

## Implemented single-clock interface

`Clock` now exposes explicit verbs. Operations that observe elapsed time take an
explicit instant; paused-only arithmetic does not:

```solidity
function isInitialized(State memory state) internal pure returns (bool);
function isRunning(State memory state) internal pure returns (bool);

function requireInitialized(State memory state) internal pure;
function requireUninitialized(State memory state) internal pure;
function requirePaused(State memory state) internal pure;
function requireRunning(State memory state) internal pure;

function remainingAt(State memory state, Time.Instant current)
    internal pure returns (Time.Duration);
function overdueByAt(State memory state, Time.Instant current)
    internal pure returns (Time.Duration);

function initializePausedAt(
    State storage state,
    Time.Instant checkin,
    Time.Duration initialAllowance,
    Time.Instant current
) internal;
function startAt(State storage state, Time.Instant current) internal;
function pauseAfterResponseAt(
    State storage state,
    Time.Duration responseBudget,
    Time.Instant current
) internal;
function chargeAndPauseAt(
    State storage state,
    Time.Duration charge,
    Time.Instant current
) internal;
function replaceWithPaused(State storage state, State memory source) internal;
function deductPaused(State memory state, Time.Duration charge)
    internal pure returns (State memory);
```

The ambiguous toggle and silent repair operations were removed:

| Removed operation | Implemented replacement |
| --- | --- |
| `notInitialized` | `!isInitialized` |
| `hasTimeLeft` | `remainingAt(current) > 0`, after an initialization check |
| `timeLeft` | `remainingAt` |
| `timeSinceTimeout` | `overdueByAt` |
| `max` | `pauseForInnerAt`, after snapshotting the running side |
| `setNewPaused` | `initializePausedAt` |
| `advanceClock` | `startAt`, `pauseAfterResponseAt`, or a pair-level transition |
| `setPaused` | `pauseAfterResponseAt` from an explicitly running response phase |
| `deducted` | `chargeAndPauseAt` |
| memory `deduct` | `deductPaused` |
| `addMatchEffort` | Removed; pairing does not mutate clock balances |
| `reInitialized` | `replaceWithPaused` |

`Time.currentTime()` is no longer called by `Clock`. `block.number` is already
constant within one transaction, so this is not an intra-transaction consistency
fix. It makes the arithmetic pure and fuzzable and centralizes a future
time-source decision behind the tournament boundary.

## Pair-level policy

`MatchClocks` owns the transitions whose invariant involves two clocks:

```solidity
function startBisectionAt(
    State storage one,
    State storage two,
    Time.Instant current
);
function switchTurnAt(
    State storage one,
    State storage two,
    Time.Duration responseBudget,
    Time.Instant current
);
function startLeafRaceAt(
    State storage one,
    State storage two,
    Time.Duration responseBudget,
    Time.Instant current
);
function pauseForInnerAt(
    State storage one,
    State storage two,
    Time.Duration responseBudget,
    Time.Instant current
) returns (Time.Duration);
function settleProvenLeafWinnerAt(
    State storage one,
    State storage two,
    ITournament.WinnerCommitment provenWinner,
    Time.Instant current
);
```

The legal phase table is:

| Match phase | Commitment one | Commitment two |
| --- | --- | --- |
| Active bisection | Exactly one running | Exactly one paused |
| Sealed leaf | Running | Running |
| Sealed inner | Paused | Paused |
| Dangling or surviving winner | Paused | Not applicable |

`switchTurnAt` establishes that exactly one clock was running, applies the
response discount, and swaps the turn. `startLeafRaceAt` establishes the same
source phase, discounts the final responder, and starts both clocks at the
supplied instant. `pauseForInnerAt` discounts the final responder, leaves both
clocks paused, and returns their maximum remainder. `settleProvenLeafWinnerAt`
requires the two-running-clock leaf phase, including a shared start instant,
and applies the timeout status to the proven side. These helpers assert on an
illegal internal phase instead of repairing it silently.

## Implemented timeout classifier

PRT-004 made timeout resolution one shared classification:

```solidity
enum TimeoutOutcome {
    NONE,
    ONE_WINS,
    TWO_WINS,
    ELIMINATE_BOTH
}

struct TimeoutStatus {
    TimeoutOutcome outcome;
    Time.Duration winnerCharge;
}
```

- A live clock wins only when its live remaining time is greater than the other
  clock's overdue duration.
- Settlement charges that overdue duration from the winner's live remainder and
  pauses it.
- Equality belongs to `ELIMINATE_BOTH`.
- If both clocks are expired, neither can win by timeout.
- `winnerCharge` carries the overdue duration used to reach a single-winner
  result, so settlement does not independently reconstruct the policy.
- `canWinMatchByTimeout`, `winMatchByTimeout`, and
  `eliminateMatchByTimeout` derive from the same status.
- The capability view returns false for nonexistent or deleted matches and for
  `NONE` and `ELIMINATE_BOTH`.

The classifier assumes its two initialized clocks already belong to a legal
match phase. It does not revalidate, for example, that two running sealed-leaf
clocks share a start instant; the pair transition that created the phase
establishes that invariant.

The external ABI is unchanged. `NeitherClockHasTimedOut` remains the legacy
selector for every status in which no individual commitment can win. This
normalizes the former accidental zero-allowance revert throughout the
one-expired double-elimination region, including equality.

PRT-010 made the classifier authoritative for `winLeafMatch` too. A proof may
settle under `NONE` or the single-winner outcome matching the proven side. The
former applies a zero charge; the latter applies `winnerCharge`. An opposite
winner or `ELIMINATE_BOTH` rejects the proof with the existing
`CannotAdvanceTimedOutClock` selector. Proof and timeout entry points now agree
whenever both succeed: at the same observation instant they select the same
survivor and clock charge before identical re-pairing. If the proven side is
opposite the timeout winner, or the timeout outcome is `ELIMINATE_BOTH`, proof
settlement rejects and leaves the timeout outcome authoritative.

## Implemented non-bankable response budget

Before PRT-009, `pairCommitment` front-loaded a capped bankable grant onto both
commitments whenever they paired. That restored time to a fresh late join and
let repeated winners accumulate newly minted clock budget. Pairing now leaves
both balances unchanged. A small amount of elapsed time is discounted only
after a valid bisection response succeeds.

For a response that starts with balance `b`, arrives after elapsed time `e`, and
has response budget `G`:

```text
require e < b
newBalance = b - max(e - G, 0)
```

This preserves the original strict expiry boundary, never increases a balance,
never revives an expired clock, and discounts at most `G` of that action's
latency. An adversary can deliberately spend every eligible discount, so every
discount appears in the delay bound.

The eligible actions are exactly:

- every successful `advanceMatch`;
- the final `sealLeafMatch`; and
- the final `sealInnerMatchAndCreateInnerTournament`.

A height-`H` match therefore has `H - 1` advance discounts plus one sealing
discount, for at most `H * G`. Joining, pairing, timeout cleanup, leaf-proof
resolution, child propagation or elimination, and bond recovery receive none.
Proof resolution is deliberately excluded so it remains convergent with the
shared timeout outcome established by PRT-010.

For clock mass `M` and `h` eligible responses remaining, the potential

```text
P = M + h * G
```

drops by `max(e, G)` on each successful response. Across `q` responses,

```text
responseElapsed + M_after
    = M_before + sum(min(e_i, G))
    <= M_before + q * G
```

A conservative local height-`H` bound to leaf resolution, or to non-leaf seal
or timeout deletion before child resolution, is therefore
`b1 + b2 + H * G <= 2A + H * G`, where `A` bounds each starting clock. Child
allowance is the maximum post-response parent balance, and child return plus
parent re-pairing cannot raise it.

The local bound must not be shortened to one allowance. A production-path
height-three trace waits `A - 1` before one response, leaving the responder
`G + 1`, then lets the opposing clock consume all `A`. The pair resolves at
`2A - 1`. With a third claim already waiting dangling, re-pairing starts that
claim's untouched clock and completion reaches `3A - 1`. The traces cover
`G = 0`, a positive `G`, and fuzz `A >= 2` with `0 <= G < A`. They are reachable
lower bounds, not a proof of the optimal attack or a contradiction of the
coarser population-window upper bound.

The external `TournamentArguments.matchEffort` field and tuple order remain
unchanged for compatibility, but internal code calls the value
`responseBudget`. Deployment now stores the per-response scalar `G = 5
minutes`, or 25 blocks on Ethereum, instead of the former
`5 minutes * sum(heights)` one-descent aggregate.
One root-to-leaf descent with one match at each level spans 92 heights and can
still earn at most 7 hours 40 minutes, one successful response at a time.
Repeated matches receive new bounded discounts.

## Validation and remaining test work

The PRT-002 integration tests continue to protect running-winner conservation,
both timeout branches, and the strict equality boundary. The refactor and its
policy follow-ups added explicit-instant fuzz properties for:

- one-shot initialization and late-entry charging;
- remaining and overdue arithmetic, including the exact deadline;
- start, non-bankable response pausing, and live-time charge;
- the exact response formula, strict deadline, and both running sides;
- paused child carryover and its zero boundary;
- bisection turn changes, leaf racing, and inner sealing;
- rejection of illegal source phases;
- the four-way timeout model, symmetry, and disjoint/exhaustive partition;
- exact bisection and sealed-leaf deadline and equality boundaries;
- proven-leaf eligibility and charging for both sides under every timeout
  outcome, including rejection of unequal leaf-race start instants.

The integration suite also checks agreement between the capability view and
both timeout mutation paths, including fabricated and deleted match IDs. It
compares compatible proof and timeout settlement from identical snapshots and
checks that incompatible proofs leave the match and both clocks unchanged.
PRT-009 adds strict-deadline rollback for advance and both seal paths, a late
join plus winner re-pairing property, deployment calibration, and exact child
allowance return without a parent refill. The injected single-level stateful
model covers legal lifecycle composition and rejected operations. Deterministic
two-level traces now pin child delegation, both winner mappings, exact
carryover, parent re-pairing, child double elimination, and the strict
`F + A - 1` / `F + A` boundary. Two-level fuzzing also covers late child
check-in and proof resolution strictly after global close, and a sequential
trace composes two child tournaments on different parent segments. A fixed
one-child stateful oracle was evaluated and rejected because it would duplicate
the covered seam rather than explore a new clock state space. The sequential
leaf lower-bound trace now separates per-match clock conservation from bracket
shape. A proof-inclusive finite-state scheduler subsequently exhausted the
clock-only envelope for `N <= 6`, `A <= 4`, `G <= 2`, and `H <= 3` under prompt
timeout cleanup. It does not correlate proof winners across matches or impose
an honest strategy. Recursive multi-population modeling and the unbounded
attacker-versus-honest proof or counterexample remain separate from the
completed Clock API work.
