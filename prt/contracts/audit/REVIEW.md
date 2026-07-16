# PRT dispute-game review ledger

Status: active

Last reviewed: 2026-07-16

This ledger records the reviewed conclusions and follow-up work for the Solidity
dispute game under `prt/contracts/`. It is deliberately separate from the
normative protocol documentation in
[`docs/dispute-game.md`](../../../docs/dispute-game.md). Findings remain here
after they are fixed so that the reasoning, evidence, and regression target do
not disappear with the patch.

The machine-generated [`MAP.md`](MAP.md) is a broader source map and lead
inventory. It is useful orientation, but its claims are not findings until they
have been checked independently.

## Scope

In scope:

- Tournament joining, asynchronous pairing, bisection, sealing, resolution,
  recursive child tournaments, clocks, bonds, refunds, and result retrieval.
- Factories, deployment parameters, interfaces, comments, Markdown, and tests
  that define or exercise the dispute game.
- The state-transition contract as an opaque leaf-resolution dependency and
  gas consumer.

Out of scope:

- Correctness of the Cartesi state-transition implementation itself.
- Correctness of the Cartesi Machine emulator and step implementation.
- A full audit of the concrete data provider and off-chain clients.

The review used source tracing, history inspection, deterministic Foundry tests,
a focused regression test for clock conservation, diagnostic gas measurement,
and a comparison with the original PRT paper. The clock reproduction was
temporary and removed after establishing the issue. That is an evidence gap in
the staged tree; the permanent regression must land with the clock fix.

## Status vocabulary

- `Confirmed`: independently reproduced or established directly from source.
- `Open`: confirmed and not fixed.
- `Planned`: follow-up has an agreed direction but is not implemented.
- `Resolved`: fixed and protected by an appropriate regression test.
- `Needs decision`: behavior is understood, but the intended contract is not.
- `Deferred`: confirmed interaction, but ownership or prerequisite semantics
  are being resolved outside this review branch.

## Findings

### PRT-001: Arbitrum clocks use the wrong time calibration

- Severity: Medium
- Status: Open
- Area: liveness, deployment configuration
- Evidence: `Time.currentTime`, `Deployment._registerChains`,
  `Deployment._getMatchEffort`, `Deployment._getMaxAllowance`

`Time.currentTime()` returns Solidity `block.number`. The deployment registry
converts seconds to block counts using 2500 ms for Arbitrum One and Arbitrum
Sepolia. On Arbitrum, the `NUMBER` opcode exposes the parent-chain block number,
not the Arbitrum L2 block number. Ethereum-parent ticks are therefore much
slower than the configured 2.5 seconds.

Approximate consequences on Ethereum-parent Arbitrum chains:

- 7 days + 1 hour becomes 33.8 days.
- 7 hours 40 minutes of match effort becomes 36.8 hours.
- A 9-hour testnet allowance becomes 43.2 hours.

This does not change which state transition is correct, but it violates the
bounded-delay and capital-lock assumptions used by operators and clients.

Ethereum is the supported target. Deployments on other base chains are
experimental until the contract time coordinate and conversion are validated.
For a chain with dynamically governed or variable block semantics, a historical
weekly average is a deployment assumption rather than a stable protocol fact.

Recommended response:

1. Keep non-Ethereum chain registrations explicitly experimental.
2. Make the time source an explicit chain-level decision.
3. If Arbitrum support is pursued, either calibrate the parent-chain coordinate
   or adopt and document a different source, including upgrade and sequencer
   assumptions.
4. Add fork-based conformance tests for every chain promoted to supported.

External reference: the Arbitrum documentation-hosted Trail of Bits security
review describes the `block.number` behavior:
<https://docs.arbitrum.io/assets/files/2025-12-offchain-arbitrum-chains-genesis-generator-securityreview-ecc17bd8f262c11ea3c8fd6458ff271e.pdf>.

### PRT-002: Sealed-leaf timeout restores elapsed winner time

- Severity: Medium
- Status: Open
- Area: clock conservation, bounded delay
- Evidence: `Clock.deducted`, `Tournament.sealLeafMatch`,
  `Tournament.winMatchByTimeout`

`Clock.deducted()` subtracts the late-claim penalty from the stored
`state.allowance`. It does not first account for time already consumed by a
running clock. This is hidden during normal bisection because the prospective
winner is paused. It becomes observable after `sealLeafMatch`, where both clocks
run.

A focused regression reached timeout resolution with 10 blocks of live winner
time remaining. Resolution stored the full 2700-block allowance instead of 10.
The winner's elapsed leaf-race time was restored.

The boundary behavior is stronger than time restoration. Suppose a sealed leaf
starts both clocks at instant `S` with allowances `a1 > a2`. After commitment
two expires:

```text
eliminateMatchByTimeout is valid when 2 * (t - S) >= a1 + a2
winMatchByTimeout remains valid while t - S < a1
```

Throughout that overlap, both permissionless entry points succeed and
transaction ordering chooses between eliminating both commitments and reviving
commitment one as a survivor. Intended timeout classification gives the entire
overlap to `ELIMINATE_BOTH` once the winner's live remaining time is less than
or equal to the loser's overdue time.

The required invariant is:

```text
remaining_after = remaining_at_resolution - loser_overdue
```

The calculation must never use the raw stored allowance unless the operation
has established that the clock is paused.

Recommended response:

1. Define the desired clock API and phase transitions in
   [`CLOCK-DESIGN.md`](CLOCK-DESIGN.md).
2. Add the focused regression plus boundary fuzzing.
3. Calculate the deduction from live remaining time.
4. Assert the exact tie: `remaining == overdue` eliminates both and the win path
   reverts.
5. Refactor ambiguous clock operations after the correctness fix is protected.

### PRT-003: Bond and refund estimates do not bound actual transaction costs

- Severity: Medium
- Status: Open
- Area: economics, permissionless participation
- Evidence: `Gas`, `Tournament._totalGasEstimate`, `Tournament.refundable`,
  event counters in `Tournament`

The hard-coded gas constants are used to size the bond and cap each caller
refund. They are no longer conservative:

- Five production storage counters were added after the constants and are only
  consumed by tests. Their `SSTORE` cost is paid in production.
- A sequential measurement put `CartesiStateTransition.transitionState()` alone
  at approximately 513k to 626k gas for the exercised proofs. The complete
  `WIN_LEAF_MATCH` allocation is 127,728 gas.
- OP Stack and Base charge L1 data or security fees separately from L2 execution
  gas. The current formula cannot reimburse those fees.
- The bond-share cap is dimensioned at `MAX_GAS_PRICE`, currently 50 gwei.
  Sustained base fee above that value under-reimburses even if every execution
  estimate is exact.
- Terminal child recovery now adds a value-bearing residual-burn call inside
  `winInnerTournament` when the child has funds left. Recalibration must include
  that branch.
- The previous NatSpec promised gas reimbursement plus profit, which the
  formula does not guarantee. The comment is corrected in this documentation
  pass; the economic limitation remains.

Recommended response:

1. Remove test-only counters from production and assert emitted events instead.
2. Add CI gas ceilings for every refundable entry point, compiler setting, and
   representative leaf-proof size.
3. Generate reviewed constants with an explicit safety margin.
4. Specify the complete fee model the refund promises to cover, including L1
   data fees and the base-fee ceiling, or design chain-aware payment.
5. Prove that aggregate refunds across repeated re-pairing cannot consume funds
   belonging to other commitments.

### PRT-004: Timeout capability view does not match timeout resolution

- Severity: Low
- Status: Open
- Area: interface semantics
- Evidence: `Tournament.canWinMatchByTimeout`,
  `Tournament.winMatchByTimeout`

`canWinMatchByTimeout()` returns true when either clock has no time left. It also
returns true when both clocks have no time left, while `winMatchByTimeout()`
requires exactly one viable winner and reverts in the double-timeout case. The
view does not validate that the match exists.

Recommended response: derive the view and mutation from one timeout-outcome
function returning `NONE`, `ONE_WINS`, `TWO_WINS`, or `ELIMINATE_BOTH`.

### PRT-005: `arbitrationResult` was documented as root-only but is not guarded

- Severity: Low
- Status: Resolved
- Area: interface semantics
- Evidence: `ITournament.arbitrationResult`, `Tournament.arbitrationResult`

The function returns the dangling winner for a finished inner tournament.
Before this documentation pass its interface and implementation NatSpec implied
root-only behavior, but no guard existed. Current parent logic does not use it.

Decision: keep the current generic behavior; a root-only view adds no safety and
parents already use `innerTournamentWinner`. Preserve the existing selector for
compatibility. A clearer generic alias and deprecation can be considered in a
future interface version rather than adding a breaking guard or rename now.

### PRT-006: Match ID hash zero is not a valid existence sentinel

- Severity: Low
- Status: Open
- Area: abstraction correctness, readability
- Evidence: `Match.IdHash.ZERO_ID`, `Match.hashFromId`, `Match.requireExist`

Hashing `Match.Id(0, 0)` produces a nonzero hash, so `IdHash.requireExist()` does
not establish that a mapped match or parent-child link exists. Actual
`Match.State.requireExist()` checks protect the important paths today, making
some ID-hash checks redundant rather than protective.

Recommended response: remove the misleading sentinel check and establish
existence from stored state or an explicit mapping membership flag.

### PRT-007: Successful bond recovery is not idempotent

- Severity: High
- Status: Resolved
- Area: settlement liveness, recursive tournament propagation
- Evidence: `Tournament.tryRecoveringBond`,
  `Tournament.winInnerTournament`, `DaveConsensus.settle`

After a successful `tryRecoveringBond()`, the tournament deletes the winning
commitment's claimer. A second call reaches `assert(winner != address(0))` and
panics instead of reporting that recovery has already completed. Because the
entry point is permissionless, anyone can force this state before a required
caller reaches it.

At the root, an attacker can recover the tournament first. Every later
`DaveConsensus.settle()` calls `oldTournament.tryRecoveringBond()` and reverts,
rolling back epoch settlement. In a child, an attacker can recover first and
make the parent's `winInnerTournament()` revert at its final child-recovery
call. This can block propagation of the only correct child winner. Once the
child's winner carryover window expires, `eliminateInnerTournament()` deletes
both parent commitments; an incorrect commitment already waiting dangling can
then become the root winner. The child path is therefore safety-relevant, not
only a stuck payment path.

Resolution:

1. If a finished tournament has a dangling winner but its claimer was already
   deleted after successful recovery, return `true` without another transfer.
   This remains a state-neutral no-op even if ETH is forcibly sent afterward;
   such later value stays stranded.
2. Preserve the claimer and return `false` when the recipient call fails so a
   later retry remains possible.
3. `testTryRecoveringRootBondIsIdempotent` covers direct root recovery.
4. `testInnerWinner` pre-recovers the child before parent propagation.
5. The fuzzed `DaveAppFactoryTest.testSettle` covers ordinary and pre-recovered
   root settlement.

### PRT-008: Residual winner sweep lets losing Sybil bonds be recycled

- Severity: Medium
- Status: Resolved
- Area: Sybil economics, bounded delay
- Evidence: `Tournament.joinTournament`, `Tournament.deleteMatch`,
  `Tournament.tryRecoveringBond`

The commitment root determines one claimer slot, and the first address to join
that root owns it. The correct root is deterministic. Before this fix, an
attacker could therefore claim it first, add many incorrect claims, let a
correct validator perform the permissionless defense, and then receive the
entire residual pool when the correct commitment won. The attack still required
concurrent capital, but much of the losing-bond pool could be reused in later
disputes.

First-claimer ownership of a duplicated root is intended. Bonds are Sybil
protection, not an endogenous reward for identifying an honest validator, and
the contract has no honest-address oracle.

Resolution:

1. Pay the registered first claimer of the eventual winning commitment at most
   `min(current balance, bondValue())`. No terminal bond is reserved, so
   legitimate progress refunds may leave a smaller payment.
2. If a nonzero winner payment fails, return `false` without deleting the
   claimer or burning any of the full retryable balance.
3. After a successful payment, burn the actual post-callback balance and delete
   the claimer. A zero balance skips the recipient call and completes directly.
4. Later calls are idempotent no-ops. The burn covers the balance present at
   successful recovery, not ETH forcibly sent afterward.
5. `testFuzzTryRecoveringRootBondCapsPayoutAndBurnsResidual` covers balances
   from zero through three bonds and repeated recovery.
6. `testTryRecoveringRootBondPreservesBalanceForRetry` covers rejection, full
   balance preservation, retry, residual burn, and idempotence.
7. `testTryRecoveringEmptyRootBondSkipsRecipientCall` covers zero-balance
   completion with a rejecting recipient.
8. `testInnerWinner` covers capped payout and burn when parent propagation
   settles a child tournament.
9. The fuzzed `DaveAppFactoryTest.testSettle` covers payout and burn whether
   recovery happens before settlement or inside `DaveConsensus.settle`.

This makes the unrefunded terminal portion of losing deposits irreversible. It
does not eliminate small repeated vandalism: an attacker may still buy bounded
delay in each independent epoch for a linear burned cost.

### PRT-009: Pairing grants bankable response time to fresh commitments

- Severity: Low
- Status: Planned
- Area: clock dimensioning, bounded delay
- Evidence: `Tournament.pairCommitment`, `Clock.addMatchEffort`,
  `Deployment._getMatchEffort`

Every pairing adds `matchEffort` to both clocks, including a newly joined
commitment whose initial allowance was already reduced by late entry. A claim
joining just before tournament close can therefore recover almost the full
grant. On mainnet the current values are 169 hours of allowance and 7 hours 40
minutes of pairing grant; one late incorrect claim can buy that extra tail, and
multiple late or repeatedly surviving claims can mint more.

Under prompt cleanup after joining closes, each one-level match has at most two
capped clocks and produces at most one survivor, so bounded windows still halve
the population. The current grants nevertheless break the clean conservation
law between elapsed time and survivor balance, can return a child clock larger
than its delegated allowance, and change finite delay constants. The agreed
direction preserves the external `matchEffort` field but reinterprets it as a
non-bankable per-bisection response discount:

```text
require elapsed < startingBalance
newBalance = startingBalance - max(elapsed - responseBudget, 0)
```

The balance never increases and an expired clock is never revived. The field's
value must change from the current aggregate 7 hours 40 minutes to the intended
per-response value, currently five minutes. Implement this only after the
PRT-002 fix and clock API refactor, with a model-based delay regression and an
explicit list of eligible actions.

## Deferred state-transition issue

### STF-TODO-001: `RiscVStateTransition.step` discards `UArchStepStatus`

- Severity: Undetermined; potentially safety-relevant until reachability and
  semantics are settled
- Status: Deferred
- Evidence: `RiscVStateTransition.step`, `UArchStep.step`,
  `docs/computation-hash.md`

`UArchStep.step()` returns `Success`, `CycleOverflow`, or `UArchHalted`, but the
adapter discards the status and returns the access-log context. Overflow and
halt are documented by the step library as fixed points, and repeated halted
states are used to pad fixed-size commitment spans. That makes identity
behavior plausible. It is not sufficient, by itself, to prove that every
status is reachable only at a position where the dispute-game transition must
be identity or that exception and halt semantics match commitment generation.

State-transition behavior under halt and exception is being defined in a
separate workstream. This branch records the issue and makes no semantic change.
Before discharge, the final rules need a cross-implementation test that covers
success, halt padding, cycle overflow, reset boundaries, and exceptions.

## Documentation corrections and gaps

The following items were corrected or explicitly documented in this pass:

- The original PRT paper is an architectural ancestor, not a specification of
  the deployed asynchronous, multi-level game.
- Safety and liveness are conditional on a correct participant remaining able
  to act within the configured clock and censorship bounds.
- A participant may lock one bond at each active tournament level, not one bond
  for the entire recursive dispute.
- `matchEffort` is a per-pairing response allowance, not the time to compute one
  commitment.
- Permissionless factory calls can create orphan inner tournaments. A parent
  only consumes children linked from its own sealed matches.
- Garbage collection advances protocol state; it does not universally settle
  every balance. A child eliminated without a winner has no winning-claimer
  payout or residual-burn path.
- Refunds are bounded partial execution-gas payments, not guaranteed full-cost
  reimbursement or profit.
- `arbitrationResult` lacks the root-only guard previously claimed by NatSpec.
- For `level > 0`, each configured height is the stride gap from the preceding
  level; level zero is dimensioned independently and completes the 92-bit
  meta-cycle span.
- Mainnet wall-clock values are only as accurate as the chain-specific time
  source and conversion assumptions.
- The checked-in constants use three levels while the deployment target is two;
  changing the count requires regenerating the entire stride and height table.
- `winLeafMatch` is proof-gated, not clock-gated. A proof can resolve an expired
  match until timeout elimination lands first.
- At a leaf level, `K` live commitments imply `floor(K / 2)` running clocks. A
  sealed non-leaf pair instead delegates population reduction to a child, whose
  finish still depends on its matches and deeper children. At most one
  commitment per tournament may wait dangling.
- Logarithmic clock-induced delay does not imply logarithmic work; asynchronous
  pairing can force a linear number of matches and transactions.
- The intended allowance is `censorship + (levels - 1) * inner commitment
  time`. Pairing response latency is a separate budget.
- Same-root first-claimer ownership is intended; terminal recovery now caps its
  payout at one bond and burns the post-payment residual.

### Documentation model

The current layered approach is appropriate if each layer keeps one role:

- `docs/dispute-game.md` states implemented behavior, invariants, and trust
  assumptions without silently presenting proposed fixes as live behavior.
- `audit/REVIEW.md` retains findings, decisions, evidence, and regression
  targets after fixes land.
- Focused design records such as `CLOCK-DESIGN.md` capture proposed behavior
  before a security-sensitive refactor.
- `AGENTS.md` is orientation and routing, not a second protocol specification.
- `MAP.md` is a broad source inventory and lead generator, not an authority.

Stable reasons and invariants should live in prose; volatile call sequences and
edge partitions should also be executable Foundry properties. Avoid copying
parameter tables into multiple files without naming their source and generation
rule.

## Test backlog

Priority 0 means a regression is required with the associated correctness fix.
Priority 1 means high-value invariant coverage. Priority 2 is broader hardening.

### Priority 0

- `TEST-RECOVERY-001` (landed): recover a root winner twice and require the second call
  to succeed without transferring or mutating state.
- `TEST-RECOVERY-002` (landed): pre-recover a child winner, then propagate that child
  through `winInnerTournament` successfully.
- `TEST-RECOVERY-003` (landed): pre-recover a root winner, then settle its epoch through
  `DaveConsensus` successfully.
- `TEST-BOND-001` (landed): cap terminal winner payment at the lesser of the
  remaining balance and one bond, then burn the residual; cover zero, sub-bond,
  exact-bond, and excess-balance cases.
- `TEST-BOND-002` (landed): if the terminal recipient rejects payment, retain
  the claimer and entire balance without burning; retry successfully and make
  later recovery idempotent.
- `TEST-CLK-001`: reproduce the sealed-leaf restoration bug.
- `TEST-CLK-002`: fuzz clock conservation for paused and running winners.
- `TEST-CLK-003`: exercise exact expiry, one block before, and one block after;
  pin `remaining == overdue` to `ELIMINATE_BOTH`.
- `TEST-CLK-004`: replace bankable pairing grants with the recalibrated
  non-bankable response discount; pin late joins, repeated winners, and
  child-to-parent clock conservation.
- `TEST-TIME-001`: chain conformance for the time source and deployment
  conversion, especially Arbitrum.
- `TEST-GAS-001`: fail when any refundable path exceeds its allocation.
- `TEST-GAS-002`: measure realistic leaf proofs and calldata sizes.

### Priority 1

- Stateful tournament handler checking `matchCount`, the single dangling slot,
  match uniqueness, monotonic match height, legal clock phases, winner re-entry,
  and terminal state.
- Exhaustive or fuzzed bisection parity for heights 1 through 48 and every
  divergence position. Check both winner attribution and agree-proof selection.
- Multi-level parameter fuzzing for one, two, three, and more levels, including
  malformed heights, strides, allowances, and unsafe shifts.
- Economic invariants proving pooled-balance conservation across refunds,
  terminal payment, residual burn, and repeated recovery.
- Model-based one- and two-level delay tests covering balanced reservoirs,
  skewed/list pairing, late joins, and non-bankable response discounts.
- Reverting and reentrant refund/bond receivers, including cross-instance
  callbacks.

### Priority 2

- Join and resolve at every close-time boundary.
- Child win and elimination at every carryover deadline boundary.
- Orphan and unknown child tournaments.
- Same-root first-claimer ownership under the capped terminal payout.
- No-winner child balance behavior.
- Exact views for unknown matches, double timeout, nonexistent match cycles, and
  non-root result retrieval.

The current deterministic suite covers the principal lifecycle paths well, but
the dispute game has almost no stateful invariant testing. Existing parity tests
focus on small heights and edge divergences. The coverage command also needs
repair: the non-IR path hits stack depth, while the IR/Solar path does not resolve
the external machine-step imports.

## Readability and abstraction backlog

### `Clock.State` and clock operations

`Clock.State` encodes uninitialized, paused, running, and expired states through
two fields. Operations named `advanceClock`, `deducted`, `setNewPaused`, and
`addMatchEffort` hide phase transitions or elapsed-time charging. The proposed
replacement is specified in [`CLOCK-DESIGN.md`](CLOCK-DESIGN.md).

### `Match.State` changes meaning after sealing

Before sealing, `otherParent`, `leftNode`, and `rightNode` describe bisection
nodes. After sealing, those slots hold the agree hash and the two contested final
states. Introduce an explicit phase and phase-specific accessors or structures so
that readers cannot apply pre-seal meanings to post-seal data.

### `Tournament` mixes all lifecycle layers

The single deployed implementation is reasonable, but the source combines
joining, pairing, bisection, clock policy, child creation, settlement, refunds,
and observability. After characterization tests exist, extract internal helpers
or libraries around these lifecycle boundaries without changing the clone
architecture.

### Test instrumentation changes production economics

Production storage counters exist to make tests easier. Replace them with event
recording and assertions so that tests do not alter the gas behavior being
tested.

### Comments restate role matrices

Several comments repeat root/inner/leaf combinations around individual methods.
Keep stable invariants and non-obvious reasons near code; link protocol-wide
role and lifecycle explanations to `docs/dispute-game.md`.

### Smaller cleanup

- Decode immutable tournament arguments once per entry point when practical.
- Preserve the external `matchEffort` field for compatibility, but use a clearer
  internal name when it becomes a non-bankable per-response discount.
- Add the same explicit stored-state existence check to
  `sealInnerMatchAndCreateInnerTournament` that the leaf seal path uses. The
  current zero state cannot be sealable, so this is hardening and symmetry, not
  a confirmed exploit.
- Validate factory and parameter-provider addresses, level shapes, nonzero
  allowances, and response budgets at construction rather than failing later
  through clock or array panics.
- Remove the duplicate state-transition import in `Deployment.s.sol`.
- Remove unused and dangerous arithmetic helpers such as non-saturating
  `Time.sub` if no invariant requires them.

## Areas reviewed without a confirmed defect

The following high-risk paths were traced and cross-checked without finding a
confirmed dispute-game defect:

- Odd/even bisection parity and left/right winner attribution.
- Agree-state proof selection at the final divergent leaf.
- Child winner identity and clock mapping into the parent, including idempotent
  recovery after PRT-007.
- Parent-child linkage against permissionlessly created orphan children.
- Live-match accounting through match deletion and winner re-pairing.
- Inclusive tournament closure and the main timeout-elimination comparison.
- Same-root first-claimer ownership: later callers cannot join the same
  commitment, while every defense operation remains permissionless. This is
  intended; PRT-008 changed only the residual payout policy.

This is review evidence, not a proof. The parity and lifecycle properties still
need exhaustive and stateful tests.

## Validation baseline

At the time of review:

- `direnv exec .. just prt-contracts::test-disputes`: 42 passed, 0 failed.
- A focused sealed-leaf clock regression reproduced PRT-002.
- A sequential state-transition gas measurement confirmed the PRT-003 leaf gas
  mismatch without evaluating state-transition correctness.
- Foundry coverage did not produce a reliable aggregate because of the build
  issues recorded above.

After the PRT-007 fix:

- `prt/contracts`: `just test-disputes` passed 43 tests.
- `cartesi-rollups/contracts`: `just test` passed both fuzz properties with 256
  runs each, including settlement after pre-recovery.

After the PRT-008 fix:

- `prt/contracts`: `just test-disputes` passed 46 tests, including root and
  child payout, burn, rejection, retry, zero-balance, and idempotence paths.
- `cartesi-rollups/contracts`: `just test` passed both fuzz properties with 256
  runs each, including capped payout and residual burn before or during
  settlement.
