# PRT dispute-game review ledger

Status: active

Last reviewed: 2026-07-17

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

The review used source tracing, history inspection, deterministic and fuzzed
Foundry tests, diagnostic gas measurement, and a comparison with the original
PRT paper. Permanent clock-conservation and timeout-partition regressions now
retain the original PRT-002 evidence in the tree.

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
- Status: Deferred
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
- One five-minute response budget becomes about 24 minutes; one 92-response
  root-to-leaf descent with one match at each level becomes 36 hours 48
  minutes. Repeated matches add their own discounts.
- A 9-hour testnet allowance becomes 43.2 hours.

This does not change which state transition is correct, but it violates the
bounded-delay and capital-lock assumptions used by operators and clients.
The severity applies if the current parameters are deployed on Arbitrum; the
supported Ethereum target is not affected.

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

Decision: defer non-Ethereum time-source work. Chain registration allows the
deployment script to produce parameters; it does not designate protocol
support. Ethereum is the only supported target. Every other registered chain
remains experimental until the requirements above are met.

External reference: the Arbitrum documentation-hosted Trail of Bits security
review describes the `block.number` behavior:
<https://docs.arbitrum.io/assets/files/2025-12-offchain-arbitrum-chains-genesis-generator-securityreview-ecc17bd8f262c11ea3c8fd6458ff271e.pdf>.

### PRT-002: Sealed-leaf timeout restores elapsed winner time

- Severity: Medium
- Status: Resolved
- Area: clock conservation, bounded delay
- Evidence: `Clock.chargeAndPauseAt`, `Tournament.sealLeafMatch`,
  `Tournament.winMatchByTimeout`

Before this fix, the former `Clock.deducted()` subtracted the late-claim penalty
from stored `state.allowance`. It did not first account for time already consumed
by a running clock. This was hidden during normal bisection because the
prospective winner is paused. It became observable after `sealLeafMatch`, where
both clocks run.

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

Throughout that pre-fix overlap, both permissionless entry points succeeded and
transaction ordering chose between eliminating both commitments and reviving
commitment one as a survivor. Intended timeout classification gives the entire
overlap to `ELIMINATE_BOTH` once the winner's live remaining time is less than
or equal to the loser's overdue time.

The required invariant is:

```text
remaining_after = remaining_at_resolution - loser_overdue
```

The calculation must never use the raw stored allowance unless the operation
has established that the clock is paused.

Resolution:

1. `Clock.chargeAndPauseAt()` computes live remaining time at the operation's
   explicit instant before applying the charge. A successful timeout win
   therefore stores `liveRemaining - loserOverdue`.
2. PRT-002 initially used `_setPaused`'s zero rejection as a safety backstop.
   PRT-004 now classifies `liveRemaining <= loserOverdue`, including equality,
   as `ELIMINATE_BOTH` before settlement, so the former overlap is an explicit
   disjoint partition.
3. `testSealedLeafTimeoutChargesLiveWinnerTime` pins conservation one block
   before the equality boundary.
4. `testSealedLeafTimeoutTieAndNextBlockEliminateBoth` pins equality and the
   following block to double elimination.
5. `testFuzzSealedLeafTimeoutPartition` covers both commitment orderings and
   fuzzes the full interval in which exactly one sealed-leaf clock is expired.
6. `testTimeout` retains both paused-winner orderings and now asserts that their
   banked allowance is conserved.
7. The explicit single-clock and pair-phase API is now implemented and fuzzed.
   The shared timeout classifier was subsequently implemented by PRT-004, as
   recorded in [`CLOCK-DESIGN.md`](CLOCK-DESIGN.md).

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
- In the same mocked leaf-win gas harness, PRT-010's timeout classification
  increased `winLeafMatch` from 143,290 to 146,264 gas. Both measurements already
  exceed that allocation before a realistic state-transition proof.
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
- Status: Resolved
- Area: interface semantics
- Evidence: `MatchClocks.classifyTimeoutAt`,
  `Tournament.canWinMatchByTimeout`, `Tournament.winMatchByTimeout`,
  `Tournament.eliminateMatchByTimeout`

Before this fix, `canWinMatchByTimeout()` returned true when either clock had no
time left. It therefore returned true when both clocks were expired and when a
nominal winner could not survive the overdue-time charge. It also did not
validate that the match existed, so a fabricated ID composed from initialized
commitment clocks could produce a false positive.

Resolution:

1. `MatchClocks.classifyTimeoutAt()` returns `NONE`, `ONE_WINS`, `TWO_WINS`, or
   `ELIMINATE_BOTH`, together with the overdue duration to charge a winner.
2. The capability view and both timeout mutation paths derive from that one
   pure classification. A single winner requires
   `winnerRemaining > loserOverdue`; equality eliminates both.
3. The capability view returns false for nonexistent and deleted matches and
   for `NONE` and `ELIMINATE_BOTH`.
4. The external ABI and existing error selectors are unchanged. A timeout-win
   call in any non-winner status now consistently reverts with the legacy
   `NeitherClockHasTimedOut` selector instead of leaking the zero-allowance
   storage sentinel throughout the one-expired double-elimination region,
   including equality.
5. Model-based fuzzing covers all legal pair phases, both commitment orderings,
   symmetry, the exhaustive/disjoint partition, and exact bisection and sealed
   leaf boundaries. Integration tests pin view/mutation agreement and
   fabricated/deleted match behavior.

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
- Status: Resolved
- Area: clock dimensioning, bounded delay
- Evidence: `Clock.pauseAfterResponseAt`, `MatchClocks.switchTurnAt`,
  `MatchClocks.startLeafRaceAt`, `MatchClocks.pauseForInnerAt`,
  `Tournament.pairCommitment`, `Deployment._getMatchEffort`

Before this fix, every pairing added `matchEffort` to both clocks, including a
newly joined commitment whose initial allowance was already reduced by late
entry. A claim joining just before tournament close could therefore recover
almost the full grant. The allowance was and remains 169 hours; the former
pairing grant was 7 hours 40 minutes. One late incorrect claim could buy that
extra tail, and multiple late or repeatedly surviving claims could mint more.

Under prompt cleanup after joining closes, each one-level match has at most two
capped clocks and produces at most one survivor, so bounded windows still halve
the population. Those grants nevertheless broke the clean conservation
law between elapsed time and survivor balance, could return a child clock larger
than its delegated allowance, and changed finite delay constants. The
implemented resolution preserves the external `matchEffort` field but
reinterprets it as a non-bankable per-bisection response discount:

```text
require elapsed < startingBalance
newBalance = startingBalance - max(elapsed - responseBudget, 0)
```

The balance never increases and an expired clock is never revived.

Resolution:

1. Pairing and winner re-entry leave both balances unchanged.
2. Every successful `advanceMatch` and the final leaf or inner seal applies the
   formula above. A height-`H` match therefore has exactly `H` eligible
   discounts.
3. Joining, pairing, proof or timeout resolution, child propagation or
   elimination, and bond recovery earn no discount.
4. The legacy-named external field and tuple layout remain unchanged. Its
   deployment value changed from the former `5 minutes * sum(heights)`
   one-descent aggregate to the five-minute scalar, 25 blocks on Ethereum.
5. Formula fuzzing and deterministic kink tests pin non-minting and the strict
   original deadline. Integration regressions cover advance and both seal
   paths, late joining, winner re-pairing, deployment conversion, and exact
   child-to-parent clock carryover.

For clock mass `M` and `h` remaining responses, `M + h * G` decreases by
`max(elapsed, G)` after each response. A local height-`H` match therefore has
the conservative bound `b1 + b2 + H * G <= 2A + H * G` to leaf resolution, or
to non-leaf seal or timeout deletion before child resolution. Stateful global
bracket models remain in the broader liveness backlog.

### PRT-010: Leaf proof resolution overlaps timeout cleanup

- Severity: Low
- Status: Resolved
- Area: clock policy, transaction ordering
- Evidence: `MatchClocks.settleProvenLeafWinnerAt`,
  `Tournament.winLeafMatch`, `Tournament.winMatchByTimeout`,
  `Tournament.eliminateMatchByTimeout`

Before this fix, `winLeafMatch` validated the objective state-transition result
and then paused the proven winner whenever that winner still had positive live
time. It did not classify or charge the opponent's overdue duration.

If the opponent had expired, this created two timeout-path overlaps:

- While `winnerRemaining > opponentOverdue`, both proof resolution and timeout
  victory were valid. They selected the same survivor, but only timeout victory
  charged the overdue duration from its clock.
- While `0 < winnerRemaining <= opponentOverdue`, proof resolution and double
  elimination were both valid. Transaction ordering chose between preserving
  the proven winner and eliminating both commitments.
- Once the proven winner itself expired, the former `pauseAt` rejected the
  proof path.

Resolution:

1. The four-way timeout status is authoritative after objective proof
   validation. `NONE` permits either proven side with a zero charge. A matching
   `ONE_WINS` or `TWO_WINS` permits only that proven side and applies the exact
   classified overdue charge.
2. An opposite timeout winner or `ELIMINATE_BOTH` rejects the proof with the
   existing `CannotAdvanceTimedOutClock` selector. Equality cannot produce a
   survivor: proof settlement rejects, and `eliminateMatchByTimeout` is the
   valid resolver.
3. At the same observation instant, successful proof and timeout resolutions
   cannot conflict. A proof compatible with a single-winner timeout outcome
   selects the same survivor and clock charge before identical re-pairing; an
   incompatible proof rejects and leaves the timeout outcome authoritative.
   Deletion reason, gas use, and caller refund can still differ because proof
   and timeout remain distinct entry points.
4. This removes a transaction-order-dependent late rescue, not an independent
   safety guarantee. Permissionless timeout cleanup could already defeat that
   rescue. The explicit policy is that objective state-transition correctness
   does not override a missed clock; a correct commitment may lose by timeout.
5. Pair-level fuzzing covers all timeout outcomes and both proven sides.
   Integration fuzzing compares compatible proof and timeout settlement from
   identical snapshots in both commitment orderings, rejects the opposite proven
   side without changing the match or clocks, and deterministic coverage pins
   the inclusive equality boundary.

## Configuration decision

### CFG-001: Coordinate the selected two-level tournament layout

- Status: Planned
- Evidence: `ArbitrationConstants`, `docs/dimensioning.md`,
  `docs/plans/constants.md`

The selected deployment layout has two levels with
`log2step = [37, 0]` and `height = [55, 37]`. The root tree spans
`55 + 37 = 92` meta-cycle bits, and the inner leaf tree refines one root
stride down to individual usteps. The table comes from the documented
60-minute inner-commitment measurement under the selected root-slowdown
assumptions.

Selection records the protocol direction, not production calibration sign-off.
The checked-in derivation is a single-machine, single-run measurement;
validator-grade calibration remains required before deployment.

The checked-in contracts still use the historical three-level table
`log2step = [44, 27, 0]`, `height = [48, 17, 27]`. This is deliberate while
the current node constructs root commitments at stride 44 and the Solidity
tests still need to be separated from canonical deployment constants. A
contracts-only switch would create a silent cross-implementation mismatch.

Before CFG-001 is implemented:

1. Completed: generic and historical contract tests inject a frozen test-owned
   geometry; only the canonical conformance suite imports
   `ArbitrationConstants`.
2. The coordinated node branch must construct level-zero commitments at stride
   37 and update its generated or node-facing parameter records.
3. Contract, node, and documentation conformance checks must agree on the same
   complete table before deployment.

This review branch does not touch the node. The selected table may be applied
to contracts in a later, integration-gated commit, but it must not be deployed
with a stride-44 node.

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
- `matchEffort` is the legacy external name for a non-bankable per-response
  elapsed-time discount, not time granted by pairing or time to compute one
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
- The checked-in constants use the historical three-level table while CFG-001
  records the selected two-level table and its integration gate.
- `winLeafMatch` validates the objective post-state and then consults the same
  timeout status as timeout cleanup. A compatible single winner receives the
  same overdue charge; an incompatible proof rejects. Objective proof
  correctness does not override a missed clock.
- Timeout settlement now conserves the winner's live remaining time. A winner
  must retain strictly more time than the loser's overdue duration; equality
  and the following blocks eliminate both commitments.
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
- Focused design records such as `CLOCK-DESIGN.md` capture the decision before a
  security-sensitive refactor, then record what landed and what remains deferred.
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
- `TEST-CLK-001` (landed): reproduce the sealed-leaf restoration bug and pin
  the surviving clock to `liveRemaining - loserOverdue`.
- `TEST-CLK-002` (landed): cover paused winners in both commitment orderings
  and fuzz running sealed-leaf winners symmetrically.
- `TEST-CLK-003` (landed): exercise the strict boundary before, at, and after
  `remaining == overdue`; pin equality to `ELIMINATE_BOTH`.
- `TEST-CLK-004` (landed): fuzz the shared four-way timeout model, symmetry,
  bisection and sealed-leaf boundaries, view/mutation agreement, and
  fabricated/deleted match IDs.
- `TEST-CLK-005` (landed): make leaf-proof settlement follow the same timeout
  status; fuzz both proven sides and compare proof-first with timeout-first
  semantic outcomes from identical snapshots.
- `TEST-CLK-006` (landed): replace bankable pairing grants with the recalibrated
  non-bankable response discount; pin formula boundaries, advance and both seal
  paths, late joins, repeated winners, deployment conversion, and
  child-to-parent clock conservation.
- `TEST-TIME-001` (deferred): chain conformance for the time source and
  deployment conversion is required before promoting any non-Ethereum target,
  especially Arbitrum.
- `TEST-GAS-001`: fail when any refundable path exceeds its allocation.
- `TEST-GAS-002`: measure realistic leaf proofs and calldata sizes.

### Priority 1

- Stateful tournament handler checking `matchCount`, the single dangling slot,
  match uniqueness, monotonic match height, legal clock phases, winner re-entry,
  and terminal state.
- Exhaustive or fuzzed bisection parity through the largest checked-in or
  selected height (currently 55) and every divergence position. Check both
  winner attribution and agree-proof selection.
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
- Exact views for nonexistent match cycles and non-root result retrieval.

The current deterministic suite covers the principal lifecycle paths well, but
the dispute game has almost no stateful invariant testing. Existing parity tests
focus on small heights and edge divergences. The coverage command also needs
repair: the non-IR path hits stack depth, while the IR/Solar path does not resolve
the external machine-step imports.

## Readability and abstraction backlog

### `Clock.State` and clock operations (resolved)

`Clock.State` still encodes uninitialized, paused, running, and expired states
through two ABI-compatible fields. The ambiguous toggle and silent-pause
operations were replaced by explicit-instant single-clock operations and a
`MatchClocks` phase library. Invalid pair phases now fail instead of being
repaired. Timeout views, timeout mutations, and proven-leaf settlement now share
a pure four-way classifier. The external tuple and `Tournament` ABI are
byte-identical to the pre-refactor snapshot. PRT-009 completed the response
budget design without changing that tuple; PRT-001 remains separate time-source
work. See [`CLOCK-DESIGN.md`](CLOCK-DESIGN.md).

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
- Preserve the external `matchEffort` field for compatibility; internal clock
  paths now call it `responseBudget`.
- Resolved: `sealInnerMatchAndCreateInnerTournament` now performs the same
  explicit stored-state existence check as the leaf seal path. The former zero
  state was not sealable, so this changes the nonexistent-match error from
  `MatchCannotBeSealed` to the accurate `MatchDoesNotExist`; it fixes abstraction
  symmetry rather than an exploit.
- Validate factory and parameter-provider addresses, level shapes, nonzero
  allowances, and the chosen response-budget range at construction rather than
  failing later through clock or array panics. A zero response budget is
  mechanically safe and simply charges full elapsed time.
- Coordinate `cartesi-rollups/node/src/bin/measure.rs` and its generated or
  node-facing planning prose (`docs/plans/constants.md`, `measurements*.md`,
  `snapshots.md`, and `sling-design.md`) with the landed response-discount
  semantics on the node branch; do not describe `G` as a fresh 300-second grant
  or deadline.
- Resolved: the duplicate `CartesiStateTransition` import in
  `Deployment.s.sol` was removed.
- Resolved: the unused strict `Time.sub` helper and its test-only wrapper were
  removed. Duration differences that intentionally clamp at zero use the
  explicitly named `Time.monus` operation.

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

After the PRT-002 fix:

- `prt/contracts`: `just test-disputes` passed 49 tests, including symmetric
  sealed-leaf timeout fuzzing and deterministic conservation, equality, and
  post-equality boundaries.
- `cartesi-rollups/contracts`: `just test` passed both fuzz properties with 256
  runs each.
- `forge fmt --check` passed in both contract packages.

After the mechanical clock API refactor:

- `prt/contracts`: `just test-disputes` passed 60 tests, including 16 focused
  clock tests with 9 fuzz properties at 256 runs each.
- All 9 focused clock properties passed 10,000 runs each, and the sealed-leaf
  timeout partition passed 2,000 runs.
- The existing sealed-leaf timeout partition and conservation regressions passed
  unchanged.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256 runs.
- Pre/post `forge inspect Tournament abi` output was byte-identical.
- `forge fmt --check` passed in both contract packages.

After the PRT-004 timeout classifier:

- `prt/contracts`: `just test-disputes` passed 65 tests, including 20 focused
  clock tests with 12 fuzz properties at 256 runs each.
- The three new classifier/model and boundary properties passed 10,000 runs
  each, and the sealed-leaf view/mutation partition passed 2,000 runs.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256 runs.
- The pre/post `forge inspect Tournament abi` SHA-256 remained
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
- `forge fmt --check` passed in both contract packages.

After the PRT-010 proven-leaf settlement policy:

- `prt/contracts`: `just test-disputes` passed 67 tests, including 21 focused
  clock tests with 13 fuzz properties at 256 runs each.
- The pair-level proven-winner property passed 10,000 runs. The full
  `winLeafMatch` property passed 2,000 runs across both commitment orderings,
  compatible timeout victory, double elimination, and rejection of the
  opposite proven side without state changes.
- Deterministic coverage pins the inclusive equality boundary and rejects a
  two-running-clock leaf phase with unequal start instants.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256
  runs.
- The `forge inspect Tournament abi` SHA-256 remained
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
- `forge fmt --check` passed in both contract packages, and `git diff --check`
  passed.

After the PRT-009 non-bankable response budget:

- `prt/contracts`: `just test-disputes` passed 71 tests, including 20 focused
  clock tests with 12 fuzz properties at 256 runs each.
- The response formula, both active sides, leaf transition, and inner-seal
  properties passed 10,000 runs each. Late join plus winner re-pairing passed
  5,000 runs; both sealed-leaf ordering properties passed 2,000 runs.
- Deterministic integration tests pin strict-deadline rollback for advance and
  both seal paths, reduced child delegation and exact parent return, and the
  five-minute/25-Ethereum-block deployment calibration.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256
  runs.
- The `forge inspect Tournament abi` SHA-256 remained
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
- `forge fmt --check` passed in both contract packages, and `git diff --check`
  passed.

After separating tests from canonical geometry:

- The premature contracts-only two-level switch was reverted. The live
  provider remains the historical three-level table while CFG-001 retains the
  selected two-level table and its node integration gate.
- `prt/contracts`: `just test-disputes` passed 75 tests. The historical
  root/inner/leaf suites run under `test/characterization/` against a frozen
  test-owned provider, and the canonical configuration suite pins the complete
  live table plus its tiling invariants.
- `ArbitrationConstants` is imported only by the canonical configuration suite;
  behavioral tests do not change when the production table changes.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256
  runs.
- The `forge inspect Tournament abi` SHA-256 remained
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
- `forge fmt --check` and `git diff --check` passed. No production Solidity or
  node source changed in the test-isolation commits.
