# PRT dispute-game review ledger

> Archived internal engineering review snapshot. Findings remain here as
> historical evidence after resolution; this is not an active backlog.

Status: complete for this campaign; deferred work and release gates remain
explicit below

Last reviewed: 2026-07-21

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

- Severity: Low
- Status: Resolved - bounded heuristic subsidy selected
- Area: economics, permissionless participation
- Evidence: `Gas`, `Bond`, `Tournament.refundable`,
  event counters in `Tournament`, [`REFUND-DESIGN.md`](REFUND-DESIGN.md),
  [`GAS-CALIBRATION.md`](GAS-CALIBRATION.md)

The hard-coded gas constants size the bond's work reserve and cap each caller
refund. They are best-effort subsidies for altruistic validators, not a safety
mechanism, an endogenous incentive, or a promise to cover every accepted proof.
Seven actions have retained calibrated ceilings. `WIN_LEAF_MATCH` instead uses
an explicit provisional ordinary-proof reference:

- Five production storage counters were added after the original constants.
  Their getters and values remain asserted compatibility and observability
  semantics, and their `SSTORE` cost is paid in production.
- Sequential measurements put ordinary and reset
  `CartesiStateTransition.transitionState()` calls alone at approximately 244k
  to 624k gas for the exercised proofs. Input-boundary calls reached
  approximately 1.08 million gas with only 32- to 128-byte synthetic inputs.
  A focused full-stack ordinary-proof run then measured 768,416 allocation
  units; its 842,758 reviewed minimum rounded to the selected provisional
  843,000-gas allocation.
- In the same mocked leaf-win gas harness, PRT-010's timeout classification
  increased `winLeafMatch` from 143,290 to 146,264 gas. Both exceeded the former
  127,728-gas allocation before a realistic state-transition proof.
- Transaction-intrinsic calldata, storage-refund credits, and receipt-exact
  transaction gas are not represented by the measured delta plus flat
  25,000-gas overhead. Proof forwarding, copying, and memory expansion after the
  snapshot are represented. Experimental OP Stack and Base deployments also
  charge separate L1 data or security fees that the formula does not reimburse.
- The action cap is its configured allocation times 50 gwei, not a universal
  50-gwei price ceiling for actual work. When actual work exceeds the
  allocation, saturation begins below 50 gwei. This underpayment is accepted by
  the selected best-effort subsidy policy.
- Before PRT-011, `winInnerTournament` also performed terminal child recovery,
  making its cost depend on the winning claimer's callback. Recovery is now
  separate; recalibration must use the decoupled path.
- PRT-012's explicit direct action cap removed the former clone-argument decode
  and multiply/divide from the unmetered refund postlude. It preserved payments
  at that checkpoint; this calibration measures the resulting path.
- PRT-013 bounds nonzero recipient execution at 50,000 gas, skips zero-value
  calls, and removes recipient return-data copying. Callback work remains
  outside the refund measurement.
- The production refund formula is now pinned independently of the allocation
  measurements. A timeout-action twin derives `Gas.TX + gasBefore - gasAfter`
  at a one-Wei price, then exact fuzzing varies balance, base fee, priority fee,
  receiver behavior, and both dangling and replacement-match topologies. The
  emitted value is the requested refund even when a rejecting recipient
  receives nothing. This establishes the implemented caps, not receipt-exact
  reimbursement or the adequacy of any action allocation.
- The current InputBox stores only the input hash. Its 65,536-byte cap and ABI
  framing permit at most 65,508 encoded bytes from a 65,216-byte payload. An
  input-boundary dispute resubmits the input; the provider hashes it, checks the
  stored hash, and Merkleizes it before the state transition uses the root. A
  pre-Merkleized InputBox remains a possible separate optimization.
- Successful proof encodings are not finitely bounded. `Buffer` does not require
  complete consumption, so every valid proof prefix can carry trailing bytes.
  At an out-of-range input index, the provider also returns zero before
  validating the supplied input, allowing an arbitrary declared input segment
  before valid access logs. This does not make the refund itself unbounded: the
  configured action cap limits the subsidy regardless of accepted proof size.
- Leaf sealing plus the provisional allocation is now the common terminal
  maximum at 950,000 gas. This is 249,000 gas above the former inner path, so
  every work reserve rises by 249,000 gas and every join deposit by 0.01245 ETH
  at the work-price cap.
- A test-owned target-two-level harness now measures the modifier's exact
  reimbursable quantity from `PartialBondRefund` with cold target accesses. The
  first charged right advance measures 115,351 allocation units. A
  position-one height-55 right inner seal measures 332,958; it combines a full
  proof with a real child clone. The equivalent height-37 right leaf seal
  measures 96,327. Retained left comparators measure 95,050 for advance,
  312,744 for inner seal, and 76,113 for leaf seal.
  With `max(10,000, ceil(delta / 10))` headroom and 1,000-gas rounding, those
  shared allocations are now 126,000, 364,000, and 107,000.
- Timeout calibration retains both winner orientations in active bisection and
  in the sealed-leaf race. Every winner is positively charged, the old match has
  a nonzero position, and a third dangling commitment forces the expensive
  re-pair branch. The active paths measured 237,603 and 237,646 allocation
  units; sealed leaf measured 238,261 and 238,304. The 260,000 allocation
  preserves the reviewed margin over the largest path.
- Double-elimination calibration retains an advanced active match and a
  position-one sealed leaf at the inclusive `remaining == overdue` boundary.
  They measured 123,940 and 124,269 allocation units. The 135,000 allocation
  preserves the reviewed margin. The leaf-seal-plus-timeout sequences are
  367,000 and 242,000 gas; both remain below the current terminal maximum, so
  neither action determines bond values.
- Child-resolution calibration uses real factory-created children and preserves
  decoupled recovery. Resolved children selecting parent sides one and two
  currently measure 307,612 and 307,787 allocation units at the final legal
  carryover block; a single-claim side-two comparator measures 307,742. Expired
  resolved and single-claim winners measure 158,805 and 158,790, while a child
  with no winner measures 153,866. The 337,000 and 173,000 allocations preserve
  the reviewed margins. Inner seal plus winner propagation remains 701,000 gas;
  the provisional leaf path now supersedes it for reserve sizing.
- The previous NatSpec promised gas reimbursement plus profit, which the
  formula does not guarantee. The comment is corrected in this documentation
  pass; the economic limitation remains.

Selected response:

1. Preserve the production-counter semantics and the seven retained calibrated
   action ceilings.
2. Use 843,000 gas as a documented provisional subsidy for canonical ordinary
   leaf proofs. Do not describe it as a complete proof-class or transaction
   bound.
3. Keep the bounded gross-Ethereum-work promise in `REFUND-DESIGN.md`; validation
   correctness and validator incentives do not depend on exact reimbursement.
4. Treat broader leaf-proof measurement, proof canonicalization, and InputBox
   pre-Merkleization as optional separate improvements.
5. The population-wide reserve theorem proves that configured refund caps
   preserve one minimum join bond across repeated re-pairing within each
   tournament. Pure models and real height-1 traces make the theorem executable.
   Recursive traces isolate child balances and compose two sequential children,
   so a recursive lifecycle handler is not a missing premise of this proof.
6. Exact formula and callback properties now distinguish requested values from
   successful transfers and same-instance locking from permitted cross-instance
   mutation. Keep those tests separate from gas allocation measurements.

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
- Status: Resolved
- Area: abstraction correctness, readability
- Evidence: `Match.hashFromId`, `Match.State.requireExists`,
  `Tournament.getMatchCycle`, child-resolution entry points

Hashing `Match.Id(0, 0)` produces a nonzero hash, so `IdHash.requireExist()` does
not establish that a mapped match or parent-child link exists. The child paths
already loaded the corresponding state and checked `Match.State.requireExists()`,
making their ID-hash checks redundant rather than protective. The cycle view
lacked the stored-state check and returned a plausible cycle for an absent slot.

Resolution:

1. Remove `ZERO_ID`, `IdHash.isZero`, `IdHash.requireExist`, and the unused
   ID-hash equality helper. A hash identifies a mapping slot; it does not prove
   that the slot contains a live match.
2. Child winner propagation and elimination now derive the mapped ID and rely
   on the immediately loaded `Match.State.requireExists()` check. Unlinked child
   tournaments still reject with `MatchDoesNotExist` before any child call.
3. `getMatchCycle` now applies the same stored-state check. It no longer returns
   the tournament's `startCycle` for a nonexistent match, and deleted matches
   reject consistently.
4. Regressions pin the nonzero hash of the default all-zero ID, both unlinked
   child-resolution entry points, and nonexistent and deleted cycle queries.

### PRT-007: Successful bond recovery is not idempotent

- Severity: High
- Status: Resolved
- Area: settlement liveness, recursive tournament propagation
- Evidence: `Tournament.tryRecoveringBond`,
  `Tournament.winInnerTournament`, `DaveConsensus.stageTournamentResult`

After a successful `tryRecoveringBond()`, the tournament deletes the winning
commitment's claimer. A second call reaches `assert(winner != address(0))` and
panics instead of reporting that recovery has already completed. Because the
entry point is permissionless, anyone can force this state before a required
caller reaches it.

At the root on the campaign's pre-sling base, an attacker could recover the
tournament first. Every later `DaveConsensus.settle()` called
`oldTournament.tryRecoveringBond()` and reverted, rolling back epoch settlement.
The current staging flow instead invokes the same recovery idempotently. In a
child, an attacker could recover first and
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
5. The fuzzed `DaveAppFactoryTest.testStageAndAcceptTournamentResult` covers
   ordinary and pre-recovered root recovery during result staging.
6. PRT-011 subsequently made child recovery independent of parent propagation,
   removing the child path's recovery dependency entirely.

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
   `min(current balance, bondValue())`. The configured work-reserve invariant
   reserves one minimum join bond before recovery.
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
8. `testInnerWinner` covers both child orderings: recovery before propagation,
   and propagation followed by explicit recovery and residual burn.
9. The fuzzed `DaveAppFactoryTest.testStageAndAcceptTournamentResult` covers
   payout and burn whether recovery happens before staging or inside
   `DaveConsensus.stageTournamentResult`.

This prevents the winning claimer from recovering unused losing reserves
directly. Those reserves can leave only as bounded refunds for successful
progress; otherwise they remain for terminal burning. Small repeated vandalism
remains possible: an attacker may still buy bounded delay in each independent
epoch for linear forfeited reserves and transaction work.

### PRT-009: Pairing grants bankable response time to fresh commitments

- Severity: Low
- Status: Resolved
- Area: clock dimensioning, bounded delay
- Evidence: `Clock.pauseAfterResponseAt`, `MatchClocks.switchTurnAt`,
  `MatchClocks.startLeafRaceAt`, `MatchClocks.pauseForInnerAt`,
  `Tournament.pairCommitment`, `Deployment._getMatchEffort`,
  `LeafPopulationDelay.t.sol`

Before this fix, every pairing added `matchEffort` to both clocks, including a
newly joined commitment whose initial allowance was already reduced by late
entry. A claim joining just before tournament close could therefore recover
almost the full grant. The allowance was and remains 169 hours; the former
pairing grant was 7 hours 40 minutes. One late incorrect claim could buy that
extra tail, and multiple late or repeatedly surviving claims could mint more.

Under prompt cleanup after joining closes, each one-level match has at most two
capped clocks and produces at most one survivor. A common window bounded by the
two clocks plus response discounts therefore halves the structural population;
one allowance does not. Those grants nevertheless broke the clean conservation
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
6. Two-level fuzzing covers child check-in across the nonzero pre-close portion
   of the delegated allowance and exact post-close proof charging. Reduced child
   carryover remains exact after parent re-pairing, while sequential child
   creation pins the next delegated tournament's arguments and linkage.

For clock mass `M` and `h` remaining responses, `M + h * G` decreases by
`max(elapsed, G)` after each response. A local height-`H` match therefore has
the conservative bound `b1 + b2 + H * G <= 2A + H * G` to leaf resolution, or
to non-leaf seal or timeout deletion before child resolution. Subsequent
production traces reach `2A - 1` for one pair and `3A - 1` with a third
same-time dangling claim. A proof-inclusive finite-state model subsequently
exhausted a clock-only upper envelope for `N <= 6`, `A <= 4`, `G <= 2`, and
`H <= 3` under prompt timeout cleanup. It independently chooses proof winners
and has no honest strategy, so the unbounded attacker-versus-honest proof or
counterexample remains in the broader liveness backlog.

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

### PRT-011: Parent propagation performs unrelated child bond recovery

- Severity: Low
- Status: Resolved
- Area: settlement liveness, gas accounting, separation of concerns
- Evidence: `Tournament.winInnerTournament`,
  `Tournament.tryRecoveringBond`, `Tournament.refundable`

Before this fix, `winInnerTournament` propagated the child winner, deleted the
parent match, and then called `child.tryRecoveringBond()`. Child recovery pays
the first claimer of the winning commitment with a value call that forwards all
available gas, subject to EIP-150. That recipient is not trusted. Although a
rejected payment returned `false` and the parent ignored the result, a receiver
could consume nearly all forwarded gas before failing. Parent progress
therefore had a recipient-controlled gas tail, and its fixed gas estimate could
not bound the complete operation. It also coupled adjudication to terminal
economic cleanup that does not affect the child result.

Resolution:

1. `winInnerTournament` consumes only the linked child's result and parent clock
   carryover. It does not invoke the child claimer or change the child balance.
2. `tryRecoveringBond` remains public, permissionless, retryable, and
   idempotent. Anyone may recover a winning child before or after propagation.
3. `testInnerWinner` pins both valid orderings and verifies that propagation
   alone leaves the child's claimer payout, residual burn, and balance
   untouched.
4. The external ABI, storage layout, events, and tournament winner semantics are
   unchanged. PRT-003 now calibrates `Gas.WIN_INNER_TOURNAMENT` on this
   decoupled path with real child tournaments.

### PRT-012: An additional Sybil principal was not justified

- Severity: Medium
- Status: Resolved
- Area: Sybil economics, bond dimensioning
- Evidence: `Bond`, `Tournament._refundableAfter`,
  [`REFUND-DESIGN.md`](REFUND-DESIGN.md)

Write `A = Gas.ADVANCE_MATCH`, `E` for the largest configured terminal path,
`P = Bond.WORK_PRICE_CAP`, `W(h) = (h - 1)*A + E`, and
`B(h) = W(h)*P`. A height-`h` match consumes at most one `B(h)` in configured
refunds. With `J` unique paid joins and `C` created matches, pairing and
resolution give `C <= J - 1` even when winners repeatedly re-enter. Configured
refunds therefore leave at least:

```text
J * B(h) - C * B(h) = (J - C) * B(h) >= B(h)
```

before terminal recovery. One minimum join bond is reserved without an
additional stake. With exact-value joins and an accepting winner:

```text
successful progress refunds + residual burn = (J - 1) * B(h)
```

The earlier accounting extracted an inherited 0.00450875 ETH remainder from
the former off-by-one advance reserve and called it a Sybil principal. That
reasoning treated contract burn as the only adversarial cost. The selected
policy instead counts the disposition of the complete losing reserve. If an
honest validator performs progress, the losing pool funds that caller. If the
attacker receives the refund itself, the successful transaction still consumes
Ethereum execution and blockspace. Anything not refunded remains for terminal
burning.

This is aggregate resource accounting, not a receipt-exact or identity-level
cost theorem. Refunds go to immediate `msg.sender`, not necessarily the bond
poster or top-level gas payer. The fixed allowance, gross gas measurement,
storage-refund credits, batching, paymasters, and proposer fee recovery can all
make private cost differ from the requested refund. The contract therefore
promises neither a positive per-loser ETH burn nor a precise attacker-cost
floor.

Resolution:

1. Remove the uncalibrated additive principal. Define `bondValue(h) = W(h)*P`,
   so the bond rolls automatically from the reviewed gas table, terminal
   maximum, tournament height, and work-price cap.
2. Preserve the one-winning-bond theorem and cap the winning claimer at that
   amount. Do not double the work reserve: with unchanged refund liability that
   would merely add a height-dependent stake and double honest capital.
3. The pure topology model and real height-1 traces pin one-bond solvency,
   nonzero refunds, repeated winners, double elimination, exact terminal
   payout, and the work-or-burn conservation identity.

### PRT-013: Payment callbacks have an unbounded gas and return-data tail

- Severity: Medium
- Status: Resolved
- Area: settlement liveness, gas accounting, external-call safety
- Evidence: `Tournament._refundableAfter`, `Tournament.tryRecoveringBond`,
  `DaveConsensus.stageTournamentResult`

Both ETH payment paths previously used Solidity calls without an explicit gas
limit. Under the pinned Solidity 0.8.30 optimized IR, even the ignored return
slot in `tryRecoveringBond` materialized and copied the complete return buffer;
`_refundableAfter` additionally emitted it. A refund caller primarily controlled
its own callback, but gas exhaustion or return-data expansion could revert the
already-completed action and prevented a deterministic complete-operation
ceiling.

The terminal boundary was adversarial: the first claimer of the winning root
may be an attacker. The campaign's pre-sling `DaveConsensus.settle` invoked root
recovery synchronously, and the current `stageTournamentResult` flow retains a
synchronous best-effort attempt. Without a bound, a gas-burning or
return-data-bomb recipient could therefore put an unbounded external tail on
protocol progress even though recipient behavior does not affect the
arbitration result.

Resolution:

1. Both nonzero payments use one assembly helper with a 47,700-gas `CALL`
   operand. The EVM's 2,300-gas value stipend gives recipient code an effective
   ceiling of 50,000 gas; EIP-150 may reduce it for an under-gassed caller.
2. The call supplies no output buffer, so recipient return data is never copied.
   The `PartialBondRefund` signature is preserved, but its `ret` field is now
   always empty.
3. Zero-value payments skip recipient execution. A zero refund still emits the
   existing event and reports success.
4. Refund failure remains non-reverting after progress and leaves the requested
   value in the tournament pool. Terminal failure remains retryable and returns
   before payment, residual burn, or claimer deletion.
5. Tournament-result staging stores the result before its synchronous recovery
   attempt. It ignores both `false` from a bounded recipient failure and a
   recovery revert, leaving the old tournament retryable without undoing
   staging or blocking later acceptance.
6. Focused tests pin the effective gas ceiling, gas exhaustion, zero-value
   skipping, empty return data, action persistence, terminal retry, idempotence,
   and the exact `ReentrancyDetected` selector for same-tournament recovery
   reentry. They also prove that a callback can complete zero-balance recovery
   on a different clone whose independent lock is free. This cross-instance
   witness performs real mutation but does not claim arbitrary nested actions
   fit the 50,000-gas ceiling. A downstream integration test proves staging and
   acceptance advance under a gas-exhausting winning claimer and that later
   recovery succeeds.

Recipient contracts are now subject to an explicit compatibility rule: their
ETH receive path, including EIP-7702 delegated code, must complete within the
50,000-gas ceiling. Fixed `CALL` overhead is outside that ceiling. The change
preserves selectors, event signatures, storage, and clone arguments, but changes
event payload behavior and `Tournament` creation bytecode.

## Configuration decision

### CFG-001: Coordinate the selected two-level tournament layout

- Status: Planned
- Evidence: `ArbitrationConstants`, `docs/dimensioning.md`,
  `docs/plans/constants.md`, `TournamentParameterTableValidator.t.sol`,
  `FourLevelRecursiveLifecycle.t.sol`

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
tests use injected, test-owned geometry outside the canonical conformance
suite. A contracts-only switch would create a silent cross-implementation
mismatch.

Before CFG-001 is implemented:

1. Completed: generic and historical contract tests inject a frozen test-owned
   geometry; only the canonical conformance suite imports
   `ArbitrationConstants`.
2. Completed: a test-only whole-table validator checks positive and consistent
   level counts, positive heights and root allowance, 256-bit shift and extent
   bounds, the expected root span, inter-level tiling, and zero leaf stride. It
   accepts a zero response budget because that is mechanically valid.
3. Completed: a strict four-level production factory-and-clone trace uses
   `log2step = [3, 2, 1, 0]` and `height = [1, 1, 1, 1]`, creates three nested
   children, resolves the leaf, and propagates the winner to the root.
4. The coordinated node branch must construct level-zero commitments at stride
   37 and update its generated or node-facing parameter records.
5. Contract, node, and documentation conformance checks must agree on the same
   complete table before deployment.

The test-only validator proves internal table shape, not that the node builds
commitments with the same strides or coordinate semantics. The four-level trace
proves one strict recursive path, not arbitrary-table safety. Neither removes
the cross-implementation gate.

This review branch does not touch the node. The selected table may be applied
to contracts in a later, integration-gated commit, but it must not be deployed
with a stride-44 node.

### CFG-002: Fail early on unusable factory dependencies and canonical timing

- Status: Resolved
- Evidence: `MultiLevelTournamentFactory.constructor`,
  `CanonicalTournamentParametersProvider.constructor`,
  `MultiLevelTournamentFactoryDependencies.t.sol`,
  `CanonicalTournamentGeometry.t.sol`

The factory constructor now rejects a no-code tournament implementation,
parameters provider, or state-transition dependency with `FailedDeployment`.
Without those guards, clone creation or the first provider or transition call
could fail only after an unusable factory had been deployed. The per-root
`IDataProvider` is not included in this generic code-presence policy: test state
transitions may ignore it, and production correctness depends on its semantics
rather than code length alone.

The canonical parameters provider now rejects `maxAllowance == 0` with
`MaxAllowanceCannotBeZero`. The previous exact behavior was not a later clock
panic: a zero-allowance root was closed at its creation instant, so
`joinTournament` reverted `TournamentIsClosed` before clock initialization.
Zero `matchEffort` remains accepted and means that all response latency is
charged.

This hardening does not make an arbitrary parameters provider safe. Production
keeps the canonical table static and validates the full table in tests rather
than paying for repeated runtime geometry checks. A supported deployment must
run that validator and the cross-implementation conformance gate described by
CFG-001. No callable selector changed; `MaxAllowanceCannotBeZero` is an additive
deployment-error ABI item.

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
- Factory deployment rejects no-code implementations, parameter providers, and
  state transitions. The canonical provider rejects zero maximum allowance;
  before that guard a zero-allowance root was immediately closed rather than
  failing later during clock initialization.
- Whole-table validation is test-only and catches malformed Solidity geometry,
  but cannot establish that the node builds the same commitments. A strict
  four-level trace protects generic recursion without removing that integration
  gate.
- `winLeafMatch` validates the objective post-state and then consults the same
  timeout status as timeout cleanup. A compatible single winner receives the
  same overdue charge; an incompatible proof rejects. Objective proof
  correctness does not override a missed clock.
- Timeout settlement now conserves the winner's live remaining time. A winner
  must retain strictly more time than the loser's overdue duration; equality
  and the following blocks eliminate both commitments.
- At a leaf level, `K` live commitments imply `floor(K / 2)` running clocks, but
  both clocks in one pair may consume time serially. The safe local leaf bound
  is `W <= b1 + b2 + h * G`; production traces reach `2A - 1` for two claims
  and `3A - 1` when a third same-time claim waits dangling.
- A sealed non-leaf pair delegates population reduction to a child, whose
  finish still depends on its matches and deeper children. At most one
  commitment per tournament may wait dangling.
- Structural population reduction, clock-induced wall time, transaction work,
  and blockspace serialization are distinct. Asynchronous pairing can force a
  linear number of matches and transactions even when clock mass is conserved.
- The intended allowance is `censorship + (levels - 1) * inner commitment
  time`. Pairing response latency is a separate budget.
- Same-root first-claimer ownership is intended; terminal recovery now caps its
  payout at one bond and burns the post-payment residual.
- Configured action caps reserve one minimum join bond across repeated
  re-pairing. The bond is exactly the configured match-work reserve and rolls
  automatically from the gas table. Aggregate losing reserves pay bounded
  successful-work subsidies or remain for terminal burning; no positive
  per-loser burn is guaranteed.
- Refund and terminal-payment recipients have a 50,000-gas execution ceiling;
  return data is discarded, zero-value callbacks are skipped, and
  tournament-result staging and acceptance advance after a bounded
  terminal-payment failure.
- `PartialBondRefund.value` is the requested amount, while `success` and balance
  movement distinguish an accepted transfer. Recipient behavior occurs after
  the gas snapshot and cannot change that request.
- Reentrancy locks belong to individual clones. Same-instance nested mutation
  rejects exactly; a different clone may mutate within the callback gas budget.

### Documentation model

The current layered approach is appropriate if each layer keeps one role:

- `docs/dispute-game.md` states implemented behavior, invariants, and trust
  assumptions without silently presenting proposed fixes as live behavior.
- `REVIEW.md` retains findings, decisions, evidence, and regression
  targets after fixes land.
- Focused design records such as `CLOCK-DESIGN.md` and `REFUND-DESIGN.md`
  capture the decision before a security-sensitive refactor, then record what
  landed and what remains deferred.
- `GAS-CALIBRATION.md` is an operational runbook: it pins how to regenerate
  volatile measurements and trace their effects without turning the findings
  ledger into a build script.
- `TEST-REPORT.md` assesses the current test layers, oracle independence,
  mutation evidence, limitations, and stop rule without duplicating this
  chronological ledger.
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
- `TEST-GAS-001` (landed for seven actions): retained cold witnesses enforce
  reviewed headroom for advance, timeout win and elimination, both seal paths,
  and real child winner and elimination branches. Leaf proof uses the explicit
  provisional subsidy instead of a retained ceiling.
- `TEST-GAS-002` (optional): measure additional realistic leaf-proof classes and
  calldata sizes if tighter reimbursement or the InputBox redesign is pursued.
- `TEST-FUND-001` (landed): fuzz positive heights and every current terminal
  branch; require each match's configured refunds to stay within its work
  reserve and require the reserve to equal the maximum across all legal paths.
- `TEST-FUND-002` (landed model): fuzz joins, pairing, repeated winners, and
  double elimination in a geometry-independent population model; require
  `matches <= joins - 1` and pessimistically reserve full work for every live
  or resolved match.
- `TEST-FUND-003` (landed): execute height-1 tournaments with nonzero refunds,
  repeated winner re-entry, and double elimination; assert pooled-balance
  conservation, one minimum join bond, and that aggregate losing reserves
  fund successful progress or remain for terminal burning.
- `TEST-CALLBACK-001` (landed): bound action-refund recipient gas, discard large
  success and revert data, skip zero-value callbacks, and require gas exhaustion
  to preserve completed progress while reporting the requested refund as failed.
  The emitted request is identical for accepting, rejecting, and handled
  same-instance-reentry callbacks. A second mutation in the same transaction
  pins lock release.
- `TEST-CALLBACK-002` (landed): bound terminal recipient gas, preserve the bond
  and claimer after failure, reject same-tournament recovery reentry with the
  exact selector, retry successfully, pay at most one bond, burn the residual,
  and advance tournament-result staging and acceptance despite a gas-exhausting
  winning claimer.

### Priority 1

- Landed: a stateful tournament handler checks population partitioning,
  `matchCount`, the single dangling slot, match uniqueness and exact Merkle
  coordinates, monotonic match height, clock balances and legal phases, the
  floor-half-running invariant, claimers, winner re-entry, and terminal state.
  The positive campaign requires every model-legal production call to succeed.
- Landed: a complementary stateful rejection campaign interleaves legal
  progress with exact-selector checks for duplicate and late joins, wrong Match
  phases, expired responses, disallowed timeout resolution, ineligible proofs,
  and every progress path over deleted matches. Deterministic companion traces
  prove that each rejection family is reached rather than relying on random
  selector frequency.
- Landed: an independent sparse-Merkle model exhausts every position through
  height 8, covers boundary paths at every height through 55, fuzzes arbitrary
  positions and both commitment orders, and checks winner attribution plus
  agree-proof ownership without reproducing Match's height-parity table. A
  multi-difference comparator pins leftmost-divergence precedence.
- Landed deterministic seam: a test-owned two-level provider injects the smallest
  nontrivial tiling, root `(height=2, log2step=2)` over leaf
  `(height=2, log2step=0)`, through the production factory and clone path.
  Coordinate-coherent parent and child claims derive from one 16-state table;
  complete traces cover both child winners, propagation and parent re-pairing,
  child double elimination, the final legal carryover block, the inclusive
  elimination boundary, child balance isolation, and terminal root results.
  Fuzzing covers late single entrants and active child resolution strictly after
  global close. A further trace composes two sequential children on different
  disputed segments after parent re-pairing. A fixed balanced-arrival trace now
  adds four parent commitments, two coexisting linked children, four
  same-final-state commitments per child, two timeout reduction waves, and the
  parent population sequence `4 -> 3 -> 2 -> 1`.
- Rejected as duplicative: a one-child stateful recursive oracle over that fixed
  seam would permute already pinned branches while reproducing substantial Match
  and clock policy in its ghost state. Meaningful remaining stateful work must
  vary adversarial arrival schedules and timing rather than duplicate the now
  landed concurrent-child seam; that belongs to the population-delay model
  below.
- Landed: injected production-path suites cover one and two levels, while the
  frozen historical and canonical suites cover three. A strict four-level trace
  crosses three child seams and propagates one leaf winner to the root. A
  test-only table validator covers empty and inconsistent tables, zero allowance
  and height, 256-bit height/stride/extent boundaries, wrong root span,
  non-tiling rows, and nonzero leaf stride. This is contract-shape evidence, not
  arbitrary-provider or node conformance.
- Landed: exact refund-formula fuzzing covers balance, allocation, measured-work,
  base-fee, and priority-fee caps, both timeout-winner topologies, zero requests,
  and failed receivers. Six deterministic cases pin every kink. Foundry's
  storage-refund counter remains diagnostic because the implemented promise
  deliberately prices the gross `gasleft()` delta.
- Partially landed: the deterministic production trace covers a balanced
  four-root reservoir, two coexisting child tournaments, four same-final-state
  claims per child, propagation, re-pairing, and exact-deadline cleanup. A
  single-level production trace reaches `2A - 1` with two equal-allowance claims
  and `3A - 1` with a third same-time dangling claim, for zero and positive
  response budgets and across the bounded fuzz domain. A proof-inclusive
  finite-state model now exhausts all joins, responses, pre-timeout proofs,
  timeout cleanup, re-pairing, and same-block orderings for `N <= 6`, `A <= 4`,
  `G <= 2`, and `H <= 3`. It treats proof winners as independently selectable,
  so it is a clock-only upper envelope rather than an exact one-honest game.
  Still open are staggered recursive child populations and an unbounded
  attacker-versus-honest proof or counterexample.
- Landed: same-instance refund and terminal reentry reject with the exact
  selector, while a callback can mutate a second finished clone through
  zero-balance recovery. The latter proves lock isolation, not that arbitrary
  cross-instance actions fit the callback gas ceiling.

### Priority 2

- Partially landed for close-time boundaries: a single child entrant fuzzes nonzero
  pre-close lateness and exact check-in deduction. A paired child fuzzes proof
  resolution strictly after global close, including the winner's elapsed time,
  the opponent's overdue charge, and `timeFinished = lastMatchDeleted`. The
  generic rejection trace pins join rejection at exact close. A broader role
  and operation matrix remains open.
- Landed for the strict carryover edge: child propagation succeeds with one
  block remaining and rejects at equality, while elimination has the inverse
  availability.
- Landed: a real but unlinked child is rejected by both parent winner and parent
  elimination entry points through the stored-match existence check. An
  arbitrary unknown address reaches the same check before any child call.
- Decision landed: the first claimer owns a same-root commitment and later
  callers cannot join it; defense remains permissionless. Fixture tests pin the
  first claimer and rejection tests pin duplicate-root failure, while the capped
  payout and residual burn prevent the former losing-bond recycling path.
- Landed: a child with no winner is immediately eliminable after its final match
  is deleted, and parent elimination does not touch the child balance.
- Landed: nonexistent and deleted match-cycle queries reject consistently.
  Exact non-root result retrieval and parent-commitment mapping are now pinned
  by the recursive traces.

The deterministic suite covers the principal lifecycle paths, and the small
single-level handler now explores both their legal composition and their public
rejection surface against an independent shadow model. The sparse Match model
still owns exhaustive bisection path and parity coverage; the lifecycle pool
selects representative divergence positions instead of duplicating that
campaign. Coverage reporting is operational: the recipe computes an absolute
`machine/step` remapping for Solar, uses IR-minimum as the stack-depth
workaround, and excludes FFI, gas-calibration, exact refund-formula,
out-of-scope state-transition tests and sources, and the slow invariant
executors. Coverage instrumentation changes measured refund units and can make
the production action cap bind, so the ordinary dispute gate owns both gas
observation suites. Companion deterministic lifecycle traces remain
instrumented. IR-minimum can produce
inaccurate source mappings, so line and especially branch totals remain a map
for investigation rather than evidence that an invariant is covered.

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
work. Mutating `MatchClocks` transitions validate their required local clock
shape; the timeout classifier assumes a legal caller-supplied shape. `Match`
and `Tournament` retain structural phase ownership. The focused tests mirror
that split in separate single-clock and pair-policy harnesses. See
[`CLOCK-DESIGN.md`](CLOCK-DESIGN.md).

### `Match.State` phase and mutation API (resolved)

Before sealing, `otherParent`, `leftNode`, and `rightNode` describe bisection
nodes. After sealing, those slots hold the agree hash and the two contested final
states. `Match` now derives an explicit internal phase and exposes phase-specific
views without adding storage or reshaping the externally visible tuple. Creation,
advance, and seal use state-machine verbs; branch choice, sealing-side parity,
legacy sealed encoding, decoding, and fixed-side ordering each have one
implementation. Raw state, events, error precedence, ABI, and storage layout are
pinned by separate compatibility suites. The design and validation record lives
in [`MATCH-DESIGN.md`](MATCH-DESIGN.md).

### `Tournament` mixes all lifecycle layers

The single deployed implementation is reasonable, but the source combines
joining, pairing, bisection, clock policy, child creation, settlement, refunds,
and observability. Characterization now covers lifecycle and rejection behavior,
recursive propagation, Match encoding and events, and refundable gas witnesses.
Any future extraction around these lifecycle boundaries should use those fences
and remain a separately reviewed change to the existing clone architecture.

### Production event counters affect economics

Production storage counters still add writes to the paths whose gas they are
used to estimate. Characterization, lifecycle, recursive, gas, and rollups
integration tests assert their values, so they now function as compatibility
and observability semantics rather than disposable test instrumentation. Keep
their worst-case writes in gas witnesses; removal belongs to an explicit
versioned interface decision.

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
- Decision: preserve the current validation order. `winLeafMatch` checks both
  commitment clocks before stored match existence. A fabricated ID with unknown
  roots therefore rejects with `ClockNotInitialized`, while a reversed or
  deleted ID whose roots were joined rejects with `MatchDoesNotExist`.
  Normalizing this public error precedence has no known safety benefit and would
  spend the compatibility budget without strengthening an invariant.
- Landed at test time: the whole canonical parameter table is validated for
  level consistency, positive and 256-bit-safe geometry, root extent,
  inter-level tiling, zero leaf stride, and positive root allowance. Canonical
  geometry changes must regenerate the table and pass that conformance test;
  they do not need a repeated runtime check on every clone.
- Resolved for immutable factory dependencies and canonical timing: the factory
  rejects no-code implementation, parameters-provider, and state-transition
  addresses, and the canonical provider rejects zero maximum allowance. A zero
  response budget is mechanically safe and remains accepted.
- Decision for generic providers: do not add repeated runtime shape validation.
  A custom deployment must validate its whole table before use. This catches
  malformed contract geometry but does not replace node agreement checks.
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
- Resolved by the simplification batch: the three `MatchClocks` bisection
  exits share one private `_pauseResponderAt` helper, so the response discount
  has a single implementation; `pauseForInnerAt` reads snapshotted remainders
  through the phase-checked `Clock.pausedAllowance` instead of the raw
  allowance field, using a new `Time.max` for durations.
- Resolved by the simplification batch: the `Match` storage phase guards share
  one `_establishedPhase` implementation of the existence-before-phase-error
  precedence. The guards were renamed to `requireExists` and `requireSealed`,
  which also removes the accidental name collision with `Tree.requireExist`.
- Resolved by the simplification batch: `Match.create` takes the commitment
  height directly and asserts it positive, so a zero-height state can no
  longer be born phase-indistinguishable from `SEALED`. This is a birth-site
  invariant tripwire, consistent with the library's other asserts, not runtime
  parameter validation.
- Resolved by the coverage follow-up: the `Time.add(Duration, Duration)` and
  `Time.min(Duration, Duration)` helpers lost their last callers when the
  PRT-009 refactor removed `addMatchEffort` and were deleted, following the
  `Time.sub` precedent. Both metadata-free Tournament bytecode witnesses were
  byte-identical before and after, confirming the functions were unreferenced.

## Areas reviewed without a confirmed defect

The following high-risk paths were traced and cross-checked without finding a
confirmed dispute-game defect:

- Odd/even bisection parity, left/right winner attribution, and final-revealer
  agree-proof selection. The independent sparse model covers both commitment
  orders, every position through height 8, and arbitrary positions through the
  reviewed height-55 test bound; a two-difference comparator covers the case in
  which both child subtrees disagree.
- Child winner identity and clock mapping into the parent, including idempotent
  recovery after PRT-007.
- Parent-child linkage against permissionlessly created orphan children.
- Live-match accounting through match deletion and winner re-pairing.
- Inclusive tournament closure and the main timeout-elimination comparison.
- Same-root first-claimer ownership: later callers cannot join the same
  commitment, while every defense operation remains permissionless. This is
  intended; PRT-008 changed only the residual payout policy.
- Payment callbacks cannot re-enter the source clone's state-changing surface,
  but may progress another clone under its independent lock. The source action's
  requested refund is fixed before any callback behavior.
- Child-winner propagation selects the parent side by contested final state,
  not by tree identity. A distinct-root child entrant sharing a contested
  final state may win the child; `innerTournamentWinner` maps it to the parent
  commitment with that state, propagation rejects the entrant's own children
  with `WrongTournamentWinner`, and the entrant's separate parent commitment
  is untouched. This is intended: an inner tournament adjudicates final
  states. `InvalidTournamentWinner` remains defensive dead code for
  parent-created children, whose seeded contested commitments always equal
  the recorded match id, like `InvalidWinnerCommitment` in match deletion. A
  deterministic trace now pins both the rejection and the selection.

This is review evidence, not a proof. Independent parity properties and the
single-level lifecycle model cover exhaustive bisection paths, legal stateful
composition, and rejected operations. Recursive traces cover both winner
mappings, strict carryover boundaries, late child entry, post-close child
resolution, two sequential child tournaments, and one fixed four-root trace
with two coexisting children. A strict four-level trace crosses three child
seams, while the sequential leaf traces pin reachable two- and three-claim
lower bounds. A bounded proof-inclusive model exhausts the small one-level
clock envelope. The remaining liveness gap is recursive scheduling and an
unbounded attacker-versus-honest proof or counterexample, not another fixed
lifecycle trace or an extrapolation from finite search.

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

After deriving the refund reserve:

- `prt/contracts`: `just test-disputes` passed 76 tests. Three new accounting
  properties fuzz the production bond formula, every current configured match
  path, and the pairing population model for 256 runs each.
- The model covers every positive `uint64` height and up to 64 modeled join or
  resolution operations per run, including single-winner re-pairing and double
  elimination. It pessimistically books one complete work reserve when each
  match is created, including active matches whose advances or seal may already
  have been refunded.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256 runs.
- `forge fmt --check` and `git diff --check` passed. The accounting tests import
  production gas allocations but no canonical geometry, production contract,
  or node source changed.

After exercising the pooled refund reserve:

- `prt/contracts`: `just test-disputes` passed 78 tests. The two real height-1
  traces execute nonzero seal, leaf-win, and timeout-elimination refunds.
- The repeated-winner trace fuzzes one through eight losing commitments for 256
  runs, exercises the winner in both match orientations, and conserves the
  pooled balance through every re-pairing.
- The double-elimination trace resolves at the exact common clock deadline and
  preserves the independent dangling winner.
- Both traces pay exactly one bond to the winning claimer, burn the terminal
  residual, and conserve all joined value across refunds, payout, and burn.

After making bond policy explicit:

- `prt/contracts`: `just test-disputes` passed 79 tests. The policy checkpoint
  pins one common 0.00450875 ETH principal, direct action caps, and algebraic
  equivalence with the former formula using unconstrained `uint64` fuzz inputs.
- Invalid height zero remains behavior-compatible pending separate parameter
  validation; height one exposes exactly the literal principal above the common
  terminal work reserve.
- The real repeated-winner and double-elimination accounting traces pass with
  the explicit principal and direct refund cap.
- `cartesi-rollups/contracts`: both integration fuzz properties passed 256 runs.
- The `Tournament` ABI SHA-256 remains
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
  Persistent slots 0 through 12, the transient lock, clone arguments, events,
  errors, and factory interfaces are unchanged.
- `Tournament` creation bytecode changes, so its zero-salt CREATE2 deployment
  address and the dependent factory address must be regenerated.
- `forge fmt --check` passed in both contract packages, and `git diff --check`
  passed. No node source changed.

After bounding payment callbacks:

- `prt/contracts`: `just test-disputes` passed 87 tests. Eight focused callback
  regressions cover the literal 50,000-gas recipient ceiling, successful and
  failed large return data, gas exhaustion, zero-value skipping, empty event
  return data, same-transaction lock release, terminal retry and idempotence,
  and rejected recovery reentry.
- `cartesi-rollups/contracts`: all three tests passed, including both fuzz
  properties with 256 runs and a deterministic staging-and-acceptance trace.
  The trace keeps complete proof validation, stages under a gas-exhausting
  winning claimer within a 500,000-gas ceiling, accepts the result, records both
  final roots, and then recovers the old tournament separately.
- The `Tournament` ABI SHA-256 remains
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
  Persistent slots 0 through 12, the transient lock, clone arguments, event
  signatures, errors, and factory interfaces are unchanged.
- `Tournament` creation bytecode changes, so its zero-salt CREATE2 deployment
  address and the dependent factory address must be regenerated.
- `forge fmt --check` passed in both contract packages, and `git diff --check`
  passed. No node source changed.

After the first PRT-003 calibration slice:

- `prt/contracts`: `just test-disputes` passed 95 tests. The new configurable
  fixture validates sparse height-55 roots, final-state proofs, and second-last
  agree-state proofs without canonical or historical geometry.
- Cold target-two-level witnesses measured 116,470 allocation units for the
  first charged right advance, 98,085 for a position-one full-proof leaf seal,
  and 334,941 for the equivalent inner seal with a real child clone. The
  127,000, 109,000, and 366,000 allocations preserve the selected reviewed
  headroom.
- The reserve tests prove that recalibrating `ADVANCE_MATCH` does not change the
  explicit 0.00450875 ETH Sybil principal. `Bond.terminalAllocation` now takes
  the maximum over every legal direct, leaf, and inner terminal sequence.
- The invalid height-zero bond changed in this slice and follows the explicit
  formula. Zero remains unsupported geometry, not a frozen-value compatibility
  promise.
- The actual runner is Forge 1.5.1-dev with Solidity 0.8.30, optimized IR, and the
  Prague EVM. `forge fmt --check` and `git diff --check` passed.
- The `Tournament` ABI SHA-256 remains
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
  Storage layout and external interfaces are unchanged. Runtime and creation
  bytecode change, so deployment artifacts and CREATE2 addresses must be
  regenerated. No node source changed.

After the timeout PRT-003 calibration slice:

- `prt/contracts`: `just test-disputes` passed 101 tests. Six retained timeout
  tests cover active and sealed-leaf phases, both winning orientations, positive
  winner charges, nonzero match positions, dangling re-pairing, and exact
  double-elimination boundaries.
- Cold active timeout winners measured 237,603 and 237,646 allocation units.
  Sealed-leaf winners measured 238,261 and 238,304. Cold active and sealed-leaf
  double eliminations measured 123,940 and 124,269. The 260,000 and 135,000
  allocations preserve the selected reviewed headroom.
- The 369,000-gas leaf-seal-plus-timeout-win and 244,000-gas
  leaf-seal-plus-double-elimination paths remained below the then-existing
  619,030-gas inner terminal maximum. The common work reserve, all three
  canonical-height deposits, and the explicit 0.00450875 ETH Sybil principal
  were unchanged in that slice.
- The actual runner remains Forge 1.5.1-dev with Solidity 0.8.30, optimized IR,
  and the Prague EVM. `forge fmt --check` and `git diff --check` passed.
- The `Tournament` ABI SHA-256 remains
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
  Storage layout and external interfaces are unchanged. Runtime and creation
  bytecode change, so deployment artifacts and CREATE2 addresses must be
  regenerated. No node source changed.

After the child-resolution PRT-003 calibration slice:

- `prt/contracts`: `just test-disputes` passed 107 tests. Six new cold
  real-child witnesses cover both propagated parent winners, resolved and
  single-claim child finish states, expired winners, and a child with no winner.
  Propagation leaves child balances untouched and rejects reuse after
  propagation.
- Resolved child winners measured 307,595 and 307,770 allocation units; the
  single-claim side-two comparator measured 307,725. Resolved-winner,
  single-claim-winner, and no-winner eliminations measured 158,788, 158,773, and
  153,849. The 337,000 and 173,000 allocations pin the selected rounding and
  reviewed headroom.
- `Bond.terminalAllocation` is now 703,000 gas. The height-48, height-17, and
  height-27 work reserves are 6,672,000, 2,735,000, and 4,005,000 gas; their
  deposits are 0.33810875, 0.14125875, and 0.20475875 ETH. The principal remains
  exactly 0.00450875 ETH. The reserve fuzz test now proves equality with the
  largest legal path without hard-coding which terminal branch is largest.
- `cartesi-rollups/contracts`: all three integration tests passed, including
  both fuzz properties with 256 runs and the bounded-callback settlement trace.
- The actual runner remains Forge 1.5.1-dev with Solidity 0.8.30, optimized IR,
  and the Prague EVM. `forge fmt --check` and `git diff --check` passed.
- The `Tournament` ABI SHA-256 remains
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
  Storage layout and external interfaces are unchanged. Runtime and creation
  bytecode change, so deployment artifacts and CREATE2 addresses must be
  regenerated. No node source changed.

After the PRT-006 state-backed existence slice:

- `prt/contracts`: `just test-disputes` passed 108 tests. Regressions prove that
  unlinked child tournaments reject through stored match state, nonexistent
  inner-match cycles reject even when the tournament has a nonzero start cycle,
  and deleted match cycles reject with `MatchDoesNotExist`.
- Removing the dead ID-hash check lowered every child winner and elimination
  witness by 19 gas. The largest paths now measure 307,751 and 158,769
  allocation units; the 337,000 and 173,000 allocations retain their selected
  headroom. `Bond.terminalAllocation`, every work reserve and deposit, and the
  explicit Sybil principal are unchanged.
- `cartesi-rollups/contracts`: all three integration tests passed, including
  both fuzz properties with 256 runs and the bounded-callback settlement trace.
- The actual runner remains Forge 1.5.1-dev with Solidity 0.8.30, optimized IR,
  and the Prague EVM. `forge fmt --check` and `git diff --check` passed.
- The `Tournament` ABI SHA-256 remains
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`.
  Storage layout, selectors, events, and external functions are unchanged.
  Runtime and creation bytecode change, so deployment artifacts and CREATE2
  addresses must be regenerated. No node source changed.

After the refund-gas calibration runbook slice:

- `measure-gas` now rejects a dirty authoritative run, Foundry-version drift,
  `FOUNDRY_*` overrides, an unexpected effective compiler configuration, and
  installed-dependency drift. It records the candidate revision, release
  Foundry build, effective configuration, configuration and dependency hashes,
  and recursive submodule revisions before forcing a single-threaded rebuild.
- All 15 retained gas witnesses passed under the Foundry v1.4.3 release pin.
  Every measured allocation, rounded recommendation, and diagnostic complete
  call matched the Forge 1.5.1-dev comparison exactly. The report now prints the
  reviewed minimum and rounded recommendation instead of requiring manual
  arithmetic.
- `prt/contracts`: the release-pinned `test-disputes` passed 108 tests. The
  configured seven action allocations and all alternate retained branches still
  preserve their reviewed margins. `WIN_LEAF_MATCH` remains explicitly
  uncalibrated pending the canonical proof/input envelope.
- `cartesi-rollups/contracts`: all three integration tests passed, including
  both fuzz properties with 256 runs and the bounded-callback settlement trace.
- `optimizer_runs = 200` now makes the former Foundry default explicit. The
  `Tournament` ABI, storage-layout, creation-bytecode, and runtime-bytecode
  SHA-256 values remain respectively
  `ece9dcb68d32fe686388894f69e03afa0c2522ea9458909fa342a83c15cab0e9`,
  `61246ee7057c132a3e6d9db0da88c522bfe599c8348e04ed622f1a888984be87`,
  `b58ec836bdddd732862e7fc2f35892fee23ecd6537fb413fc06e3b98cf2fea5c`,
  and `c6707d539aaf32b6d072cdd576ef84f4b2248dc7f98fe67e8c2426975c138a8e`.
  The slice changes only tests, documentation, and reproducibility tooling. No
  node source changed.

After restoring dispute-game coverage reporting:

- The instrumented in-scope suite passed 89 tests under both the release-pinned
  Foundry v1.4.3 and the local Forge 1.5.1-dev comparison.
- Excluding tests, scripts, dependencies, the external machine step, and the
  out-of-scope state-transition sources, the report measured 673 of 707 lines
  (95.19%), 684 of 715 statements (95.66%), 66 of 134 branches (49.25%), and
  138 of 145 functions (95.17%).
- `Tournament` remains the main gap: 92.44% of lines and 93.82% of statements
  are mapped, but only 44.00% of branches and 91.23% of functions. `Match`,
  `Clock`, and `MatchClocks` have complete line, statement, and function
  mappings, while their branch mappings remain incomplete where applicable.
- The recipe uses Foundry's IR-minimum mode to avoid the coverage-only stack
  depth failure. Foundry warns that this mode can produce inaccurate source
  mappings, so these numbers prioritize investigation; they neither prove
  execution of every reported source location nor cover protocol invariants.
- This slice changes only test tooling and documentation. It does not change
  production Solidity, external interfaces, storage, bytecode, or node source.

After the independent bisection-parity model:

- `prt/contracts`: `just test-disputes` passed 114 tests. The new suite executes
  1,313 deterministic complete bisection traces: every position through height
  8 in both commitment orders, both boundary paths and orders at every height
  through 55, mixed height-55 paths, and final-responder proof rejection at
  every reviewed height. Two additional traces give both root children
  different hashes and require bisection to choose the leftmost divergence.
- The arbitrary-height, arbitrary-position, and commitment-order property
  passed 10,000 fuzz runs. Its sparse Merkle oracle uses linear space and tracks
  the revealer by turn alternation rather than copying Match's odd/even proof or
  winner tables.
- Every advance checks height, aligned running position, next revealer, and both
  stored children. Every seal checks agree-proof ownership, the agree state and
  cycle, exact leaf position, and contested-state attribution to the original
  commitment order. The opposite commitment's proof is rejected after every
  possible count of revealer swaps.
- The release-pinned coverage recipe passed all 95 included tests, but its
  aggregate source-map totals remained exactly unchanged. This is useful
  evidence that line and branch percentages do not measure input-domain,
  sequence, or independent-oracle strength.
- `cartesi-rollups/contracts`: all three integration tests passed, including
  both fuzz properties with 256 runs and the bounded-callback settlement trace.
- This slice changes only tests and documentation. It does not change
  production Solidity, external interfaces, storage, bytecode, or node source.

After adding the small full-tree fixture:

- `prt/contracts`: `just test-disputes` passed 118 tests. The test-owned fixture
  builds complete trees for injected heights 1 through 8 without importing a
  canonical or historical parameter provider. Callers may supply leaves to
  create shared prefixes and nonzero divergence positions; malformed sizes and
  unsupported heights reject explicitly.
- Every node coordinate is reconstructed from its two children, and every leaf
  proof is checked through production `Commitment.getRoot`. The rightmost state
  and proof are also checked through the specialized final-leaf path used by
  `joinTournament`.
- The fixture exposes roots, leaves, arbitrary subtree nodes and children,
  proofs, final states, and first-divergence discovery. This is the reusable
  witness layer for the pending small-geometry tournament handler, not a second
  protocol implementation.
- This slice changes only test infrastructure and its validation ledger. It does
  not change production Solidity, external interfaces, storage, bytecode, or
  node source.

After wiring the inspectable small tournament:

- `prt/contracts`: `just test-disputes` passed 120 tests. The production
  multi-level factory now has a test-only specialization that injects one
  level, height three, and caller-selected timing parameters while preserving
  the production clone and immutable-argument paths.
- A functions-only `Tournament` subclass exposes the dangling commitment,
  active-match count, most recent deletion, and claimer mapping without adding
  storage or initialization behavior. The production ABI and storage layout
  remain untouched.
- The wiring test checks every injected clone argument, the first commitment's
  dangling and paused-clock state, the second commitment's exact pairing and
  stored match witnesses, both claimers and allowances, and all applicable
  counters. The parameters provider rejects unsupported levels, and the
  settlement stub rejects malformed payloads.
- The selected-state transition is deliberately only a tournament-settlement
  harness; it is not evidence about state-transition correctness. This slice
  changes only test infrastructure and its validation ledger. It does not
  change production Solidity, external interfaces, storage, bytecode, or node
  source.

After adding the small-tournament lifecycle model:

- `prt/contracts`: `just test-disputes` passed 127 tests. The positive stateful
  campaign completed 256 runs of depth 128: 32,768 generated calls distributed
  across join, advance, leaf seal, leaf proof, timeout resolution, and time
  elapse, with zero reverts or discards.
- The shadow model independently tracks population, pairing, exact clock
  balances, match heights, claimers, counters, deletion time, and terminal
  results. Full-tree coordinates derive every expected live `Match.State`
  directly rather than storing and replaying production's three-node mutation.
- The invariant enforces the exact population partition, unique historical
  match IDs, `created - deleted == active`, positive non-increasing allowances,
  one running bisection clock, two equal-start sealed clocks, and
  `running == active + sealed`. Since `live = 2 * active + dangling`, at least
  `floor(live / 2)` clocks run and the only odd-population slack is one paused
  dangling commitment.
- Six deterministic companion traces pin both active timeout winners, a sealed
  timeout winner with residual time, the sealed inclusive tie, repeated proven
  winners and re-pairing, and a double-elimination terminal without a winner.
  Candidate commitments have unique final states and representative first
  divergences at positions 0, 2, and 5; the independent parity suite retains
  exhaustive path ownership.
- The coverage recipe passed 107 instrumented tests and now maps 683 of 707
  lines (96.61%), 689 of 715 statements (96.36%), 66 of 134 branches (49.25%),
  and 143 of 145 functions (98.62%). `Tournament` maps 340 of 357 lines,
  339 of 356 statements, 33 of 75 branches, and all 57 functions.
- Instrumenting the full invariant executor produced exactly the same source
  totals as its deterministic companion traces but increased the instrumented
  test phase from seconds to more than three minutes. The coverage recipe now
  excludes only that executor; `test-disputes` remains the authoritative
  invariant gate.
- This is a positive lifecycle model: model-illegal calls return before touching
  production, so a separate negative stateful campaign remains open. This slice
  changes only tests, test tooling, documentation, and the validation ledger.
  It does not change production Solidity, external interfaces, storage,
  bytecode, or node source.

After adding the stateful lifecycle rejection campaign:

- `prt/contracts`: `just test-disputes` passed 135 tests. The original positive
  campaign again completed 256 runs of depth 128, or 32,768 calls, with zero
  reverts or discards. The mixed legal/rejection campaign completed another 128
  runs of depth 128, or 16,384 calls, with zero handler reverts or discards.
- Rejection actions derive their preconditions from the independent ghost
  state, call production through a low-level test helper, and require the exact
  public error selector. An unexpected success, a different error, or a model
  drift fails the invariant without updating ghost state.
- Seven deterministic traces pin duplicate and closed joins, Match phase
  errors, every disallowed timeout branch, expired advance and seal paths, a
  timed loser's otherwise-valid proof, proof rejection during double
  elimination, and all five progress operations over a deleted match.
- `MatchDoesNotExist` documentation now describes its stored-state meaning; the
  obsolete zero-hash-sentinel rationale was removed with no interface change.
- The coverage recipe passed 114 instrumented tests. Both stateful executors
  remain in the ordinary test gate while 13 deterministic lifecycle traces map
  their production paths. Source totals remain 683 of 707 lines (96.61%), 689
  of 715 statements (96.36%), 66 of 134 branches (49.25%), and 143 of 145
  functions (98.62%).
- `forge fmt --check`, focused lint, and `git diff --check` passed. This slice
  changes tests, test tooling, comments, and the validation ledger. It does not
  change executable production behavior, external interfaces, storage, or node
  source.

After synchronizing the audit-start documentation:

- `MAP.md` now identifies itself as a historical map rather than the current
  backlog. Its parity lead, child-clock carryover question, and broad coverage
  gap are annotated with their landed derivations and remaining recursive work.
- `CLOCK-DESIGN.md` records the landed single-level legal and rejection models.
  The Match backlog now states the external tuple compatibility fence, and
  generic-provider hardening is separated from landed canonical-table
  conformance tests.
- `git diff --check` passed. This slice changes documentation only; no Solidity,
  test, interface, storage, bytecode, or node source changes.

After adding the injected two-level fixture:

- `prt/contracts`: `just test-disputes` passed 137 tests. The provider exposes
  only rows zero and one and rejects any deeper level with a named error.
- The root row `(height=2, log2step=2)` and leaf row
  `(height=2, log2step=0)` satisfy exact inter-level tiling and each retain one
  real advance before sealing. Clone-argument tests pin both roles, delegated
  versus maximum allowance, nested contested values, start cycle, factory,
  and the wrong-level operation guards.
- The proof-selected state-transition stub moved into a level-neutral shared
  fixture. It remains explicitly a settlement selector rather than an oracle
  for state-transition correctness.
- Focused fixture lint, `forge fmt --check`, and `git diff --check` passed. This
  slice changes test fixtures, tests, and the validation ledger only; no
  production, external interface, storage, bytecode, or node source changes.

After adding coherent two-level claims:

- `prt/contracts`: `just test-disputes` passed 140 tests. The witness fixture
  derives four parent leaves as the final states of four consecutive four-state
  segments rather than constructing unrelated trees at each level.
- Parent claims one and two share the first two segment finals and first diverge
  at parent position two. Their child claims start at cycle eight from the same
  prior state, end at the exact parent contested states, and first diverge at
  local child position zero. A third distinct parent claim remains available
  for post-propagation re-pairing.
- The fixture is explicitly coordinate-coherent rather than transition-correct;
  state-transition semantics remain outside this campaign. Focused fixture
  lint, `forge fmt --check`, and `git diff --check` passed. No production,
  external interface, storage, bytecode, or node source changes.

After tracing the recursive two-level lifecycle:

- `prt/contracts`: `just test-disputes` passed 146 tests. Six deterministic
  traces create a child through the production factory, resolve it for either
  contested parent commitment, propagate the winner, re-pair it with a waiting
  third claim, and finish the root by timeout. Separate traces cover child
  double elimination and winner expiry.
- The parent seal trace independently pins the shared prior state, cycle eight,
  both contested states, delegated allowance, paused parent clocks, exact
  parent-child link, and every parent counter. Child proof payloads select a
  disputed child leaf only; they are not state-transition correctness evidence.
- At `F + A - 1`, child elimination rejects and propagation stores exactly one
  block in the parent. At `F + A`, propagation rejects and parent elimination
  succeeds. Both propagation and elimination leave the child's balance
  untouched, clear the link, and produce the expected parent topology,
  claimers, deletion time, and arbitration result.
- Coverage passed 125 instrumented tests and now maps 685 of 707 lines (96.89%),
  691 of 715 statements (96.64%), 68 of 134 branches (50.75%), and 143 of 145
  functions (98.62%). `Tournament` maps 342 of 357 lines, 341 of 356
  statements, 35 of 75 branches, and all 57 functions. The two-line and
  two-branch increase is localized to the recursive seam; IR-minimum source-map
  qualifications still apply.
- Reconciling Forge's final suite total exposed that the prior ledger correction
  was inverted: it omitted the six positive single-level companion traces from
  every later full-suite total. Starting from the measured 120-test baseline,
  the commit-local additions are seven positive lifecycle tests, eight rejection
  tests, two injected-fixture tests, three coherent-claim tests, and six
  recursive traces. The corrected progression is therefore 127, 135, 137, 140,
  and 146. No test was added or removed by this ledger correction.
- `forge fmt --check`, focused lint, and `git diff --check` passed. The
  `InspectableTournament` test subclass adds only a view over the existing child
  link mapping. Production Solidity, external interfaces, storage, bytecode,
  and node source are unchanged.

After extending recursive timing and composition coverage:

- The focused recursive suite passed 9 tests, including two fuzz properties at
  256 runs each. `prt/contracts`: `just test-disputes` passed 149 tests. A late
  sole entrant is checked over the bounded nonzero pre-close domain and carries
  exactly `allowance - lateness` without a match or refill.
- A paired child resolves strictly after global close. For join lateness `J` and
  post-close delay `R`, the bounded domain requires `J > 2R`; the trace checks
  winner live time `J - R`, loser overdue time `R`, and exact parent carryover
  `J - 2R`. Since the match is deleted after close, `timeFinished()` is the
  deletion block rather than the global deadline.
- The sequential trace resolves an A/B dispute on parent segment two, propagates
  A into a C/A re-pairing after the root has closed, then resolves a second child
  on segment zero. It pins both child argument sets, winner mappings, links,
  balances, counters, claimers, and the terminal A result at the second deletion
  time.
- Coverage passed 128 instrumented tests and remains 685 of 707 lines (96.89%),
  691 of 715 statements (96.64%), 68 of 134 branches (50.75%), and 143 of 145
  functions (98.62%). `Tournament` remains 342 of 357 lines, 341 of 356
  statements, 35 of 75 branches, and all 57 functions. The unchanged production
  totals are expected: these tests compose already mapped paths at new recursive
  timing and population boundaries.
- A proposed fixed one-child stateful oracle was rejected because it would
  duplicate this seam with a large second implementation of Match and clock
  policy. The remaining stateful recursive campaign is the materially different
  multi-population delay model with concurrent children and adversarial arrival
  schedules.
- Focused recursive tests, `just test-disputes`, coverage, `forge fmt --check`,
  focused lint, and `git diff --check` passed. This slice changes tests and
  documentation only; production Solidity, external interfaces, storage,
  bytecode, and node source are unchanged.

After completing the Match refactor and gas recalibration:

- `Match` now derives its phase and exposes phase-specific views. Creation,
  bisection, and sealing use `create`, `advanceBisection`, and
  `sealDivergence`; branch selection, total-height sealing parity, legacy
  sealed encoding, decoding, and fixed-side final-state ordering each have one
  implementation. `Tournament` uses those verbs without changing an external
  function name.
- Compatibility characterization pins exact active and sealed tuples, events,
  errors, validation order, and rollback. The 379-line zero-heavy helper suite
  and its legacy wrappers were removed. A concrete zero-pair Match ID remains
  pinned at
  `0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5`,
  and a separate vector proves commitment-order sensitivity.
- The retained gas suite now has 18 witnesses. Right and left advance measure
  115,351 and 95,050 allocation units; right and left leaf seal measure 96,327
  and 76,113; right and left real-child inner seal measure 332,958 and 312,744.
  Their shared allocations are 126,000, 107,000, and 364,000 gas respectively,
  using the recorded 10-percent/10,000-gas minimum margin and 1,000-gas
  rounding rule.
- The configured common terminal allocation is 701,000 gas. Under that
  accounting, checked-in heights 48, 17, and 27 have work reserves 6,623,000,
  2,717,000, and 3,977,000 gas and join deposits 0.33565875, 0.14035875, and
  0.20335875 ETH. Target two-level heights 55 and 37 have work reserves
  7,505,000 and 5,237,000 gas and deposits 0.37975875 and 0.26635875 ETH under
  the same price policy.
- Local Forge 1.5.1-dev and release Forge 1.4.3 reproduced all 18 gas witnesses
  exactly and passed all 159 dispute-game tests. On both versions, the positive
  stateful model completed 32,768 calls and the rejection model completed
  16,384 calls with no handler reverts or discards. `rollups-contracts` passed
  all three integration tests, including both 256-run fuzz properties and the
  bounded-callback settlement trace.
- The coverage recipe passed 135 included tests. `Match.sol` maps 107/107 lines,
  102/102 statements, 10/20 branches, and 24/24 functions; aggregate production
  totals are 697/719 lines, 711/735 statements, 64/130 branches, and 144/146
  functions. IR-minimum source-map qualifications still apply.
- The canonical ABI hash remains
  `67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a`, and the
  semantic storage-layout hash remains
  `952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`.
  Executable bytecode changed intentionally: final metadata-free creation and
  runtime hashes are
  `94798529a349a513d59fbb4b3ff697dc41a1062fca3fcc8dc3f50574dc6d3dbe` and
  `cdcb81a8c101935b5700b491cf4046d4a2ed0583d0c26f5f49f06eacfb0185b7`.
  Deployment and CREATE2 artifacts must be regenerated and reviewed before
  release. No node source changed.

After tracing concurrent recursive population:

- The coordinate-coherent fixture now retains the original three claims while
  adding a fourth root claim and four deterministic child variants per claim.
  Paired roots first diverge at segment two; every variant preserves the
  parent-selected final state, and each noncanonical variant changes only a
  non-final child leaf. The fixtures are timeout and topology witnesses, not
  execution oracles.
- A production-path trace joins four parent roots, seals two parent matches,
  and keeps both linked children alive under the same block-300 deadline. Each
  child population reduces `4 -> 3 -> 2 -> 1` over the block-300 and block-500
  timeout waves. Propagation then reduces the parent `4 -> 3 -> 2`, re-pairs
  both child winners, and reaches one root winner at block 700.
- The trace pins both child initial states, both contested final states, cycle
  eight, parent-child links, exact clocks and zero-overdue deadline boundaries,
  topology, deletion times, counters, carryover, cleared links, claimers, and
  the final arbitration result. At that historical checkpoint, every
  sealed-state assertion established match existence first because raw
  `Match.isSealed()` also returned true for zero storage. The later derived-phase
  review removed that ambiguity.
- This is fixed balanced-arrival characterization, not an asynchronous delay
  model or proof of the dimensioning expression. Parent seals are immediate,
  allowances are equal, cleanup is prompt at exact deadlines, and each child's
  four commitments share one contested final state.
- `prt/contracts`: `just test-disputes` passed all 163 tests. The positive and
  rejection stateful campaigns again completed 32,768 and 16,384 calls with no
  handler reverts or discards. The focused concurrent trace, focused lint,
  `forge fmt --check`, and `git diff --check` passed.
- These slices change fixtures, tests, prose, and one source comment only. They
  do not change executable production behavior, the external interface,
  storage layout, or node source. The ABI, semantic storage-layout, and both
  metadata-free bytecode hashes recorded immediately above remain exact.

After pinning callback isolation and the exact refund formula:

- `RefundFormulaTest` passed all 3 tests. Its fuzz property completed 10,000
  runs across balance, base-fee, priority-fee, recipient, and topology inputs;
  one deterministic matrix covers six cap boundaries. Independent unit-price
  twins pin equal measured units, exact event requests, actual transfers, and
  progress for both dangling and replacement-match outcomes.
- The formula fixture uses `vm.deal` to isolate balances below the ordinary
  reserve lower bound; this does not weaken the funded-tournament theorem.
  Foundry's reported storage refunds remain diagnostic: the no-dangling and
  replacement-match twins report 28,800 and 31,600 while production prices the
  gross `gasleft()` delta.
- `RefundCallbacksTest` passed all 11 tests. Same-instance refund and terminal
  reentry return the exact `ReentrancyDetected` selector; a zero-balance recovery
  on a second clone mutates that clone during the first clone's payment. The
  terminal two-bond cases pay at most one bond, burn one residual bond after
  success, preserve the full pool and claimer after rejection, and remain
  idempotent.
- `just test-disputes` passed all 169 tests. The positive and rejection stateful
  campaigns completed 32,768 and 16,384 calls with no handler reverts or
  discards.
- Coverage passed all 142 included tests and remains 697/719 lines, 711/735
  statements, 64/130 branches, and 144/146 functions. `Tournament` remains
  342/357 lines, 341/356 statements, 35/75 branches, and 57/57 functions. The
  gas-calibration and exact-formula observation suites are intentionally
  excluded: IR instrumentation raises the formula control to 279,771 units,
  above its 260,000 action cap, so the event can no longer expose the uncapped
  quantity being tested.
- The ABI, semantic storage-layout, metadata-free creation, and metadata-free
  runtime hashes remain respectively
  `67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a`,
  `952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`,
  `94798529a349a513d59fbb4b3ff697dc41a1062fca3fcc8dc3f50574dc6d3dbe`, and
  `cdcb81a8c101935b5700b491cf4046d4a2ed0583d0c26f5f49f06eacfb0185b7`.
  This campaign changes tests, coverage routing, prose, and source comments. It
  does not change executable production behavior, external interfaces, storage,
  metadata-free bytecode, or node source. `forge fmt --check`, scoped
  high-severity lint, ASCII validation, and `git diff --check` passed.

After hardening configuration and expanding shape and delay coverage:

- The factory dependency suite passed all 7 cases: zero and no-code tournament
  implementations, parameters providers, and state transitions reject with
  `FailedDeployment`, while valid dependencies produce a callable root clone.
  The canonical configuration suite passed all 5 cases, including exact
  rejection of zero maximum allowance and acceptance of zero response budget.
- The test-only table validator passed all 20 tests. It validates the checked-in
  canonical table and the four-level miniature, pins every named malformed
  shape, and runs five 256-run boundary properties around height, stride,
  extent, tiling, and leaf stride.
- The strict four-level production trace passed from root creation through
  three child seals, leaf proof resolution, three winner propagations, and the
  final root result. It pins every clone's arguments, coordinate-coherent
  commitments, parent-child link, clocks, topology, claimers, and counters.
- The sequential leaf-delay suite passed its zero-budget and positive-budget
  schedules plus the bounded fuzz property over `A >= 2` and `0 <= G < A`. It
  reaches the exact `2A - 1` pair deletion and `3A - 1` three-claim completion
  times while retaining the survivor's `G + 1` balance.
- The bounded proof-inclusive scheduler passed all 6 tests and exhausts 216
  configurations across `N = 1..6`, `A = 1..4`, `G = 0..2`, and `H = 1..3`.
  It retains a relative-block-19 timeout witness replayed against `Tournament`
  and a separate maximum witness that requires pre-timeout proof settlement.
- `prt/contracts`: `just test-disputes` passed all 208 tests. The positive and
  rejection stateful campaigns completed 32,768 and 16,384 calls with no
  handler reverts or discards.
- The table, recursion, and delay additions are test-only. The factory and
  canonical-provider guards change only deployment behavior and do not change
  tournament storage or callable selectors. No node source changed. The
  selected two-level table remains integration-gated on node agreement.

After selecting the provisional leaf-proof subsidy:

- Progress refunds are now explicitly documented as best-effort subsidies for
  altruistic validators, not correctness mechanisms, endogenous incentives, or
  exact reimbursement promises. PRT-003 is resolved under that policy; broader
  proof-class calibration remains optional.
- A focused full-stack ordinary-proof run measured 768,416 allocation units.
  Its reviewed minimum was 842,758, rounded to the provisional 843,000-gas
  `WIN_LEAF_MATCH` allocation. The reference path is not presented as a retained
  proof-class maximum.
- Leaf seal plus proof is now the 950,000-gas terminal maximum. Every work
  reserve increases by 249,000 gas and every join deposit by 0.01245 ETH at the
  50-gwei cap. The checked-in height-48, height-17, and height-27 bonds are
  0.34810875, 0.15280875, and 0.21580875 ETH. Target height-55 and height-37
  bonds are 0.39220875 and 0.27880875 ETH.
- `RefundReserveTest` passed all 6 tests. The retained gas suite passed all 18
  witnesses, `test-disputes` passed all 208 tests, and `rollups-contracts`
  passed all 3 integration tests. The positive and rejection stateful campaigns
  completed 32,768 and 16,384 calls with no handler reverts or discards.
- `forge fmt --check` passed. The ABI and semantic storage hashes remain
  `67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a` and
  `952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`.
  The metadata-free creation and runtime hashes changed intentionally to
  `7e588430fe82973d26f5f3303fbff8c1ffe2860f5d4acf3e343fcfcc2e716d3e` and
  `65eee8b9ea55b333ea1ae567c4f3ff45feadd951701bd33c38609ab2fded797c`.
  Deployment and CREATE2 artifacts must be regenerated before release. No node
  source changed.

After deriving the bond entirely from the configured work reserve:

- The uncalibrated 0.00450875 ETH additive principal was removed. For positive
  height `h`, `bondValue(h) = ((h - 1) * ADVANCE_MATCH + terminalMaximum) *
  WORK_PRICE_CAP`. Existing gas-allocation changes now propagate automatically
  through the terminal maximum, work reserve, and bond; a new legal terminal
  sequence must still be added explicitly to the enumeration and path test.
- The checked-in height-48, height-17, and height-27 bonds are now 0.3436,
  0.1483, and 0.2113 ETH. Target height-55 and height-37 bonds are 0.3877 and
  0.2743 ETH. Work allocations, action caps, and the 950,000-gas terminal
  maximum are unchanged.
- The reserve theorem now proves that `J` exact-value joins and at most `J - 1`
  matches preserve one minimum join bond. With an accepting winner, successful
  progress refunds plus residual burn equal all aggregate losing bonds. No
  positive per-loser burn or receipt-exact attacker cost is promised.
- `RefundReserveTest` passed all 6 tests. The retained gas suite passed all 18
  witnesses, `test-disputes` passed all 208 tests, and `rollups-contracts`
  passed all 3 integration tests. The positive and rejection stateful campaigns
  completed 32,768 and 16,384 calls with no handler reverts or discards.
- `forge fmt --check`, scoped high-severity lint, ASCII validation, and
  `git diff --check` passed.
  The ABI and semantic storage hashes remain
  `67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a` and
  `952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`.
  The metadata-free creation and runtime hashes changed intentionally to
  `2fc9a85a0b72cdbffd2e19d5bf51d8003478da10d9d8bb966cdf4c20a866b791` and
  `9d24e85b0e71038c2c40bde3725f20a70f95c1826dda44e3d4031c63055eb1ad`.
  Deployment and CREATE2 artifacts must be regenerated before release. No node
  source changed.

After the bounded Match implementation review:

- The derived Match phase is now authoritative for all memory predicates and
  storage phase guards. Storage guards establish existence before returning the
  existing phase-specific error, so a default mapping slot cannot be
  misclassified as sealed. `winLeafMatch` consumes the existence-aware
  `SealedView` after its intentional clock checks and computes the cycle from
  the decoded divergence position.
- The sealed writer now owns the agree state, divergent leaves, position, and
  terminal height in one operation. The redundant raw `getDivergence`, Match
  `toCycle`, `_setAgreeState`, and test-only `BisectionView` abstractions were
  removed. The active representation remains documented directly on
  `Match.State`; the retained sealed view performs real parity decoding and has
  a production consumer.
- The focused regressions fuzz the complete phase partition, exhaust the
  storage-guard matrix, reject invalid newcomer children, prove zero agree and
  final-state hashes remain valid payload, and pin `winLeafMatch` precedence for
  unknown roots, reversed IDs, and deleted IDs with initialized clocks. The
  independent sparse-Merkle oracle now reads the production sealed view.
- The storage-aware reads reduced five retained gas recommendations. The
  configured allocations are now 124,000 for advance, 362,000 for inner seal,
  105,000 for leaf seal, 336,000 for inner winner propagation, and 172,000 for
  inner elimination. All 18 witnesses pass under local Forge 1.5.1-dev and
  release Forge 1.4.3.
- The terminal maximum is now 948,000 gas. Automatic work-reserve propagation
  makes the height-48, height-17, and height-27 bonds 0.3388, 0.1466, and
  0.2086 ETH; target height-55 and height-37 bonds are 0.3822 and 0.2706 ETH.
- The complete dispute gate passed 212 tests. The positive and rejection
  stateful campaigns completed 32,768 and 16,384 targeted handler calls with no
  handler reverts or discards. `rollups-contracts` passed all 3 integration
  tests.
- The ABI and semantic storage hashes remain
  `67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a` and
  `952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329`.
  Current metadata-free creation and runtime hashes are
  `4e7afa78938feda5bbaca9e6f9caa1194c2059d8dd43a87ac9ace285486a3032` and
  `0ae057042e4bb4a0852140a59787f3a4ee90937b33907557381fa186041c28ed`.
  Deployment and CREATE2 artifacts must be regenerated before release.
- Deployed ABI, storage, raw Match encoding, events, selectors, and protocol
  outcomes are preserved. Solidity projects that imported the removed internal
  Match helpers would need to rebuild against the new source API; repository
  clients use the deployed interface and require no change. No node source was
  touched.

After the bounded Clock implementation review and test assessment:

- No further production Clock or MatchClocks refactor was justified. `Clock`
  owns one-clock representation and arithmetic, `MatchClocks` owns pair policy,
  `Match` owns structural phase, and `Tournament` composes them.
- The former mixed Clock harness was split into 17 single-clock tests and 16
  pair-policy tests. The rejection matrix now pins every relevant clock shape,
  proven-leaf validation precedence, paused carryover source and target phases,
  the valid zero in-memory deduction, and its forbidden storage boundary.
- The default Foundry fuzz budget is pinned at 256 runs. All 33 focused Clock
  and MatchClocks tests passed; their 12 fuzz properties also passed 10,000 runs
  with seed `0x5eed`. The 21 focused Match phase, parity, and validation tests
  passed with both fuzz properties at 10,000 runs under the same seed.
- The complete non-FFI gate passed 225 tests. The positive and rejection
  lifecycle campaigns completed 32,768 positive and 16,384 mixed handler
  invocations with no handler reverts or discards. `rollups-contracts` passed
  all 3 downstream integration tests.
- A clean Forge 1.4.3 calibration at that pre-simplification contract and test
  checkpoint reproduced all 18 retained gas witnesses. Release-pinned coverage
  passed 198 included tests and mapped
  686/708 lines, 710/734 statements, 65/147 branches, and 141/143 functions;
  IR-minimum mapping qualifications still apply.
- ABI, semantic storage, and both metadata-free bytecode hashes remain exactly
  those recorded in the preceding Match checkpoint. This slice changes tests,
  Foundry fuzz configuration, and documentation only; no production Solidity or
  node source changed.
- [`TEST-REPORT.md`](TEST-REPORT.md) records the goal assessment, test-layer
  ownership, oracle independence, manual mutation evidence, current snapshot,
  explicit non-claims, and the campaign stop rule.

After the simplification batch:

- The batch deliberately reopened the "no further refactor" decision above at
  the maintainer's request, with a taste-level goal: extract the remaining
  one-place invariants without changing supported dispute outcomes. Two
  behaviors did change deliberately: unsupported zero-height match creation
  now fails the birth-site assert, and the consequent gas recalibration
  changes two refund caps and every derived bond value. `MatchClocks` centralizes
  its response discount in one private `_pauseResponderAt` helper; `Match`
  centralizes existence-before-phase-error precedence in `_establishedPhase`;
  `create` takes the height directly and asserts it positive; `pauseForInnerAt`
  reads remainders through the phase-checked `Clock.pausedAllowance` and a new
  `Time.max` for durations; the guards are now `requireExists` and
  `requireSealed`, removing the accidental name collision with
  `Tree.requireExist`. Public verbs, selectors, events, and revert precedence
  are unchanged.
- The gas witnesses caught the batch as designed: measured units moved by 0 to
  +754 depending on path (double eliminations moved exactly zero), pushing the
  advance and inner-seal recommendations across their rounding boundaries.
  Following the calibration procedure, `Gas.ADVANCE_MATCH` is now 125,000 and
  `Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` 363,000. The terminal
  maximum remains 948,000, so `E` is unchanged; automatic propagation makes
  the height-48, height-17, and height-27 bonds 0.34115, 0.1474, and 0.2099
  ETH, and the target height-55 and height-37 bonds 0.3849 and 0.2724 ETH.
  All 18 witnesses and the updated bond-policy checkpoint pass under local
  Forge 1.5.1-dev. The historical clean release-Forge cross-check is recorded
  in the pre-rebase calibration checkpoint below; the current release record
  follows it.
- The complete non-FFI gate passed 229 tests, including three new
  `pausedAllowance` regressions and a new zero-height
  `create` assertion regression. `rollups-contracts` passed all 3 downstream
  integration tests, including bounded-callback settlement.
- The ABI and semantic storage hashes remain byte-identical
  (`67e34c...feb8a`, `952af2...a329`). New metadata-free creation and runtime
  bytecode hashes are recorded in [`MATCH-DESIGN.md`](MATCH-DESIGN.md);
  deployment and CREATE2 artifacts must be regenerated before release.

After the coverage follow-up:

- An intermediate instrumented dispute summary, taken before the dead-helper
  removal and the follow-up tests landed, reported 96.77% lines (688/711),
  96.60% statements (710/735), and 98.64% functions (145/147) over 199
  included tests; the current campaign snapshot lives in
  [`TEST-REPORT.md`](TEST-REPORT.md). An lcov detail pass classified every
  uncovered production line.
  Modifier plumbing, `pairCommitment`'s dangling clear, the payment assembly
  call, the factory return, and the pair-helper return are IR-minimum mapping
  artifacts contradicted by function-level coverage and demonstrably executing
  tests. All four simplification-batch functions are covered, with the
  MatchClocks branch metric complete.
- The uncovered-function signal exposed the dead `Time` duration helpers,
  which were removed with byte-identical bytecode witnesses.
- Every role-guarded entry point now has a wrong-role rejection:
  `winLeafMatch` on a non-leaf, `winInnerTournament` and
  `eliminateInnerTournament` on a leaf, and `canBeEliminated` and
  `innerTournamentWinner` on a root, joining the two previously pinned seal
  guards.
- A deterministic trace pins child-winner selection by contested final state:
  a distinct-root child entrant sharing side one's final state wins the child,
  its own children are rejected with `WrongTournamentWinner`, parent side one
  propagates with the carried clock, and the entrant's separate parent match
  is untouched. `InvalidTournamentWinner` is reclassified above as defensive
  dead code for parent-created children.
- The complete non-FFI gate passed 231 tests and all 18 gas witnesses. The
  metadata-free creation and runtime bytecode hashes are unchanged from the
  simplification batch, so no recalibration or artifact regeneration is
  required beyond what that batch already recorded.

### Release calibration checkpoint before rebase

On 2026-07-20, the release-pinned gas recipe ran from a clean worktree at
pre-squash revision `a6e077a0db360164a746c4d9552f3c5740887cd6` on Darwin
25.5.0 arm64. The history rewrite preserved its measured contract and test tree
exactly in candidate `9b0198b1556a877f3ad9cd8a371a70501e6e7def`, recorded in
[`TEST-REPORT.md`](TEST-REPORT.md); the following revision changes documentation
only.

The reproducibility inputs were:

```text
Forge: 1.4.3-v1.4.3
Forge commit: fa9f934bdac4bcf57e694e852a61997dda90668a
effective config: {"solc":"0.8.30","via_ir":true,"optimizer":true,"optimizer_runs":200,"evm_version":"prague"}
foundry.toml sha256: 52cbcb59a04926e546a2498ad27383b6f3670dcd6de4c1e051b118190d87acf6
soldeer.lock sha256: fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53
dependency digest: ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3
```

All 18 retained witnesses passed. The first charged right advance measured
114,077 gas and retained the 125,000-gas allocation; the full-proof
position-one inner seal measured 331,520 gas and retained the 363,000-gas
allocation. At the same revision, local Forge 1.5.1-dev passed the complete
231-test dispute gate and the 204-test coverage map; all 3 downstream
`rollups-contracts` tests also passed. The supported envelope, complete
measurement table, unchanged 948,000-gas terminal maximum, derived work
reserves and bonds, and economic policy remain in
[`REFUND-DESIGN.md`](REFUND-DESIGN.md). The refund-formula, callback-isolation,
ABI, storage, and pending deployment-artifact results remain in this ledger and
[`TEST-REPORT.md`](TEST-REPORT.md).

This is a historical pre-rebase checkpoint, not final release approval. The
completed history rewrite replaced revision identifiers but preserved the
contract and test tree exactly. The rebase changed the Foundry pin, which is a
recalibration trigger under [`GAS-CALIBRATION.md`](GAS-CALIBRATION.md). The
following post-rebase record completes that required rerun.

### Release calibration checkpoint after rebase

On 2026-07-21, the release-pinned gas recipe ran from a clean worktree at
post-rebase candidate `7565ec29797388a0108a267ba0b4676d09b63837` on macOS
26.5.2 (Darwin 25.5.0) arm64. The last Solidity or test change is
`ac3bea0c5057702e5778b3ea00086bfc31cc68ea`; the intervening audit and
calibration commits do not change that tree.

The reproducibility inputs were:

```text
Forge: 1.5.1-v1.5.1
Forge commit: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
release archive sha256: b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d
forge binary sha256: 051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c
effective config: {"solc":"0.8.30","via_ir":true,"optimizer":true,"optimizer_runs":200,"evm_version":"prague"}
foundry.toml sha256: 52cbcb59a04926e546a2498ad27383b6f3670dcd6de4c1e051b118190d87acf6
soldeer.lock sha256: fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53
dependency digest: ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3
machine/emulator: 8bfca6912f4849e03b7b55677e17e385c0b2dfbe
machine/emulator/third-party/riscv-arch-test: 8f92acd11aa5d59005505ec7a48569c75e128167
machine/emulator/third-party/riscv-tests: a64ad67b8235c681cd244b087ced36c4d5df3cb9
machine/emulator/third-party/riscv-tests/env: d3931fa7c5d3fd9725351dc2fe26f578eb782335
machine/step: 3f5d163df0f7564fef3345fc919252a371e5fb9f
machine/step/lib/forge-std: 1714bee72e286e73f76e320d110e0eaf5c4e649d
```

The run used no `FOUNDRY_*` overrides. An earlier command placed the release
binary before `direnv`, whose environment then restored local Forge 1.5.1-dev.
The former prefix check accepted that development build. Its matching
measurements are diagnostic only. The recipe now requires the exact
`1.5.1-v1.5.1` version string; the unqualified development environment fails
closed before measurement.

All 18 retained witnesses passed and reproduced the pre-rebase measurements
exactly. The first charged right advance measured 114,077 gas and retained the
125,000-gas allocation. The full-proof position-one inner seal measured 331,520
gas and retained the 363,000-gas allocation. The post-rebase rerun required no
further `Gas` or `Bond` change. The terminal maximum remains 948,000 gas; the
supported work reserves, bonds, fee boundary, and provisional leaf-proof policy
remain those derived in
[`REFUND-DESIGN.md`](REFUND-DESIGN.md).

Official Forge 1.5.1 also passed all 231 dispute tests across 52 suites and all
4 downstream `rollups-contracts` tests. The three downstream fuzz properties
used 256 runs each; the deterministic gas-exhausting winner regression staged
and accepted the result, then recovered the old tournament separately. The
coverage recipe passed 204 included tests and mapped 693/705 lines, 715/727
statements, 65/138 branches, and 145/145 functions, exactly reproducing the
current snapshot in [`TEST-REPORT.md`](TEST-REPORT.md).

The compatibility witnesses also reproduced exactly:

```text
Tournament ABI sha256: 67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a
semantic storage-layout sha256: 952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
metadata-free creation bytecode sha256: a638837b16a7cb21139706ff3aaecbb79a2f3b663d1b1dbb50f1e0243735ed4c
metadata-free runtime bytecode sha256: 631eb0908dfce360f6b6d85fb827ff4c5fe201b9e48e6af74b99f0cd35d2d5d3
```

No node source changed. Deployment and CREATE2 artifacts remain to be
regenerated before release.

## Erratum: 2026-07-23 - sealed-leaf censorship amplification

This erratum corrects the reviewed PRT-002, PRT-004, and PRT-010 timeout policy.
It does not rewrite the historical findings or validation record above.

The PRT-002 repair correctly stopped settlement from restoring time already
consumed by a running winner. The subsequent shared classifier nevertheless
made a wrong policy choice for sealed leaves: it subtracted the expired
opponent's overdue duration from the winner's live remainder in every phase.
That policy treated the censorship allowance as if it recharged for timeout
cleanup. The adopted threat model instead gives the adversary one cumulative,
non-rechargeable censorship budget across the modeled dispute.

Let a sealed leaf start both clocks at instant `S`, with correct allowance
`h` and shorter sybil allowance `s`, where `h > s`. While the sybil is expired
and the correct clock remains live, `s <= x < h`, the reviewed classifier
required

```text
h - x > x - s
```

so it began double elimination at `2x >= h + s`, while the correct clock still
had positive live time until `x >= h`. The interval after the sybil expired was
charged once by the correct clock continuing to run and a second time by
subtracting the sybil's overdue duration. A sacrificial sybil could therefore
remove the correct commitment near the midpoint. With a third incorrect claim
waiting dangling, that premature removal could leave an incorrect tournament
winner without spending an equivalent additional censorship interval against
the correct participant.

The corrected policy is phase-aware:

1. During active bisection the prospective winner is paused. The responder's
   overdue duration remains a deferred charge because the winner was not
   consuming that interval.
2. During a sealed leaf both clocks run. A live survivor receives zero deferred
   charge because its live remainder already accounts for the elapsed interval.
   It may win from the shorter deadline through the block before the longer
   deadline. At the longer deadline both commitments are eliminated.
3. Leaf proof resolution is valid only while the timeout classifier returns
   `NONE`. After the first deadline, callers must use timeout victory or double
   elimination. Proof and timeout verbs are disjoint.

`testSealedLeafTimeoutDoesNotChargeRunningWinnerTwice`,
`testSealedLeafTimeoutEliminatesAtLongClockDeadline`,
`testFuzzLeafProofYieldsToTimeout`, and
`testSacrificialLeafCannotAmplifyCensorshipIntoDanglingWinner` retain the
contract-level regressions. The independent pair-clock oracle, stateful
lifecycle model, recursive lifecycle, and bounded scheduler were updated to the
same phase table. At this revision, off-chain Rust and Lua alignment remained a
separate client-integration concern; current coverage is maintained in
[`test-harness.md`](../../test-harness.md).
