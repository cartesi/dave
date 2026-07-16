# Clock API design checkpoint

Status: proposed, not implemented

Last reviewed: 2026-07-16

This document defines the intended shape of the dispute-game clock abstraction
before Solidity behavior is changed. It is a working design record, not a claim
about the current implementation. Current protocol behavior is documented in
[`docs/dispute-game.md`](../../../docs/dispute-game.md); confirmed clock defects
are tracked in [`REVIEW.md`](REVIEW.md).

## Goals

- Make every phase transition explicit at the call site.
- Make elapsed-time accounting impossible to bypass accidentally.
- Separate single-clock arithmetic from two-player match policy.
- Make the semantic core pure and directly fuzzable.
- Read the chain time source once per tournament operation.
- Preserve the current one-slot storage representation initially, unless an ABI
  review approves a status field.

Non-goals for the first clock change:

- Selecting the final cross-chain time source.
- Redesigning tournament deadlines or dimensioning constants.
- Changing the economic timeout policy.
- Refactoring unrelated tournament lifecycle code.

## Current representation

`Clock.State` contains:

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

An expired clock remains in the third representation. Expiry is derived from
the current instant; it is not a stored phase. An initialized paused clock with
zero allowance is forbidden.

This representation fits in one storage slot. The main problem is not its size;
it is that callers manipulate it through operations whose names do not expose
their preconditions or phase changes.

## Required single-clock invariants

For an initialized clock and an instant `now`:

```text
elapsed = running ? now - startInstant : 0
remaining = max(allowance - elapsed, 0)
overdue = running ? max(elapsed - allowance, 0) : undefined
```

The implementation must maintain these rules:

1. Uninitialized clocks cannot be queried as tournament participants or
   transitioned to running.
2. Starting requires an initialized, paused clock with positive remaining time.
3. Pausing snapshots live remaining time and clears the start instant.
4. No mutation may use raw `allowance` as remaining time unless it has proved
   that the clock is paused.
5. Charging a clock first snapshots live remaining time, then subtracts the
   charge, then pauses it.
6. Granting effort first snapshots live remaining time, adds the grant up to the
   cap, then pauses it.
7. A storage transition may not create an initialized paused clock with zero
   remaining time.
8. `now` must not precede a running clock's start instant.

At the exact deadline, remaining time is zero and the clock is expired. Its
overdue duration is still zero. This distinction is intentional: expiry is a
state predicate, while overdue duration measures how late resolution is.

## Proposed single-clock interface

Names are part of the security boundary. The API should prefer explicit verbs
and explicit instants:

```solidity
function isInitialized(State memory state) internal pure returns (bool);
function isRunning(State memory state) internal pure returns (bool);

function remainingAt(State memory state, Time.Instant now)
    internal pure returns (Time.Duration);

function overdueByAt(State memory state, Time.Instant now)
    internal pure returns (Time.Duration);

function initializePausedAt(
    State storage state,
    Time.Instant checkin,
    Time.Duration initialAllowance,
    Time.Instant now
) internal;

function startAt(State storage state, Time.Instant now) internal;
function pauseAt(State storage state, Time.Instant now) internal;

function chargeAndPauseAt(
    State storage state,
    Time.Duration charge,
    Time.Instant now
) internal;

function grantAndPauseAt(
    State storage state,
    Time.Duration grant,
    Time.Duration maximum,
    Time.Instant now
) internal;
```

The existing operations map approximately as follows:

| Current | Proposed direction |
| --- | --- |
| `notInitialized` | `!isInitialized` |
| `hasTimeLeft` | `remainingAt(now) > 0`, after initialization check |
| `timeLeft` | `remainingAt` |
| `timeSinceTimeout` | `overdueByAt` |
| `max` | A pair-level maximum with an explicit both-paused precondition |
| `setNewPaused` | `initializePausedAt` |
| `advanceClock` | Remove; use `startAt` or `pauseAt` |
| `setPaused` | Remove; pair-level helpers know which clock must pause |
| `deducted` | `chargeAndPauseAt` |
| `deduct` on memory | A pure snapshot/charge helper with a paused precondition |
| `addMatchEffort` | `grantAndPauseAt` |
| `reInitialized` | An explicit child-to-parent carryover operation |

`Time.currentTime()` should not be called throughout the library. Tournament
entry points should obtain one `now` value from the configured time source and
pass it through. `block.number` is already constant within one transaction, so
this is not an intra-transaction consistency fix. It makes the core arithmetic
pure and directly fuzzable, and it centralizes the eventual time-source decision
behind one seam.

Clock-specific errors should live with the clock abstraction or in a small error
module. The low-level library should not import the whole `ITournament`
interface solely to obtain error selectors.

`remainingAt` should reject uninitialized clocks. `overdueByAt` should reject
both uninitialized and paused clocks. Callers that need only phase information
must use `isInitialized` and `isRunning` rather than relying on zero-valued time.

## Pair-level policy

Several important invariants involve two clocks and cannot be enforced by a
single-clock API. A `MatchClocks` library or tightly scoped tournament helper
should own these transitions:

```solidity
function startBisectionAt(
    State storage one,
    State storage two,
    Time.Instant now
);
function switchTurnAt(State storage one, State storage two, Time.Instant now);
function startLeafRaceAt(State storage one, State storage two, Time.Instant now);
function pauseForInnerAt(State storage one, State storage two, Time.Instant now);
function maximumPausedRemainingAt(
    State memory one,
    State memory two,
    Time.Instant now
) returns (Time.Duration);
function timeoutOutcomeAt(State memory one, State memory two, Time.Instant now)
    returns (TimeoutOutcome);
function settleTimeoutWinnerAt(
    State storage winner,
    State memory loser,
    Time.Instant now
);
```

The legal phase table is:

| Match phase | Commitment one | Commitment two |
| --- | --- | --- |
| Active bisection | Exactly one running | Exactly one paused |
| Sealed leaf | Running | Running |
| Sealed inner | Paused | Paused |
| Dangling or surviving winner | Paused | Not applicable |

`switchTurnAt` must establish that exactly one clock was running before it
changes either clock. `startLeafRaceAt` must establish the same source phase,
pause the running clock, then start both. `pauseForInnerAt` must establish the
source phase and pause its running clock. These helpers should fail on an
illegal phase instead of repairing it silently.

Timeout resolution should be one shared classification:

```solidity
enum TimeoutOutcome {
    NONE,
    ONE_WINS,
    TWO_WINS,
    ELIMINATE_BOTH
}
```

- A live clock wins only when its live remaining time is greater than the other
  clock's overdue duration.
- Settlement charges that overdue duration from the winner's live remaining
  time and pauses it.
- If the charge consumes all winner time, both commitments are eliminable.
- If both clocks are expired, neither can win by timeout.
- The capability view and mutating entry points must derive from the same
  classification.

The minimal PRT-002 fix intentionally changes a sealed-leaf boundary. Suppose
both clocks started together, commitment one has more allowance, and commitment
two expires first. Today there is a window in which `winMatchByTimeout` can
declare commitment one the winner while `eliminateMatchByTimeout` can also
eliminate both; transaction ordering chooses the result. After the fix, a
winner exists only while its live remaining time is strictly greater than the
loser's overdue time. Equality belongs to `ELIMINATE_BOTH`, so the win path must
revert throughout the former overlap.

## Non-bankable response budget

The current `addMatchEffort` front-loads a bankable grant onto both commitments
whenever they pair. It can restore time to a fresh late join and lets repeated
winners accumulate newly minted clock budget. The cleaner follow-up is to
discount a small amount of elapsed time only when a valid bisection response is
actually submitted.

For a response that starts with balance `b`, arrives after elapsed time `e`, and
has response budget `G`:

```text
require e < b
newBalance = b - max(e - G, 0)
```

This preserves the existing expiry boundary, never increases a balance, never
revives an expired clock, and refunds at most `G` of the latency of that action.
The first response needs no special front-loaded grant: the initial allowance
already covers its deadline, and the discount is applied when the response
lands. An adversary can spend every eligible discount deliberately, so all such
discounts must appear in the per-match delay bound.

If only `advanceMatch` is eligible, a height-`H` match has `H - 1` discounts and
the additive budget is at most `(H - 1) * G`. If sealing is also eligible, that
becomes `H * G`. The implementation decision must enumerate eligible actions
and state how seal and resolution inclusion latency is paid; it must not infer
the count from height without that mapping.

The external `TournamentArguments.matchEffort` field can be preserved and
reinterpreted as `G`, avoiding an ABI shape change. Its value must be
recalibrated: today the field contains the aggregate
`5 minutes * sum(heights)`, or 7 hours 40 minutes, which cannot be applied to
every response. The behavior and parameter change should follow the correctness
fix and mechanical clock API refactor as a separate commit with a delay-model
regression.

## Storage and ABI decision

An explicit status enum would make uninitialized, paused, and running states
more obvious and would still fit with the two `uint64` values in one storage
slot. It would, however, change the ABI tuples returned by `getCommitment` and
`innerTournamentWinner`, generated Rust bindings, and off-chain decoding.

Recommendation for the first patch:

1. Preserve the two-field representation.
2. Centralize and document its validity predicate.
3. Make all transitions explicit and enforce their preconditions.
4. Review external consumers before deciding whether an enum is worth the ABI
   change in a later version.

## Test contract for the redesign

The refactor is complete only when tests establish:

- Initialization is one-shot and elapsed pre-checkin time is charged.
- Start and pause transitions reject illegal source phases.
- Remaining time is monotonic while running and unchanged while paused.
- Pause snapshots exactly the live remaining time.
- Charge and grant always use live remaining time.
- Exact deadline semantics are consistent across all views and mutations.
- Bisection always has exactly one running clock.
- Leaf sealing always produces two running clocks without restoring time.
- Inner sealing always produces two paused clocks.
- Timeout classification partitions all fuzzed clock pairs into one outcome.
- Timeout settlement conserves time for both paused and running winners.
- After inner sealing with parent remainders `r1` and `r2`, a propagated child
  winner replaces the corresponding parent clock and returns no more than
  `max(r1, r2)` once bankable grants are removed.
- Child-to-parent carryover cannot be simultaneously non-eliminable and
  impossible to initialize.

The first clock implementation commit should contain the PRT-002 regression and
the minimal correctness fix. The API refactor should follow as a separate
mechanical commit protected by these properties. Replacing bankable pairing
grants with the non-bankable response budget is a third behavioral commit.
