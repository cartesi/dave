# Bond and refund design checkpoint

Status: accounting, exact refund formula, and callback boundary implemented;
seven actions calibrated; leaf proof uses an explicit provisional subsidy

Last reviewed: 2026-07-20

This document relates three accounting flows:

1. the work reserve required from every join and available for bounded
   dispute-game action refunds;
2. the terminal payment attempted for the first claimer of the winning root;
   and
3. the residual balance burned after that payment succeeds.

The bond has no additional Sybil stake. It derives automatically from the
reviewed gas table, tournament height, and work-price cap. For a tournament
that ends with an accepting winner, every losing reserve is either paid as a
bounded subsidy for successful dispute progress or remains in the terminal
residual and is burned. This is aggregate resource accounting, not a promise of
receipt-exact attacker cost or a positive per-loser ETH burn.

PRT-003 in [`REVIEW.md`](REVIEW.md) tracks the stale gas estimates and incomplete
fee model. PRT-008 records why terminal recovery pays at most one configured
bond and burns the residual. [`GAS-CALIBRATION.md`](GAS-CALIBRATION.md) is the
operational procedure for reproducing the measurements, changing a constant,
tracing its propagated effects, and recording the result.

## Current formula

For one tournament instance, define:

```text
A = Gas.ADVANCE_MATCH
E = max(
        Gas.WIN_MATCH_BY_TIMEOUT,
        Gas.ELIMINATE_MATCH_BY_TIMEOUT,
        Gas.SEAL_LEAF_MATCH + max(
            Gas.WIN_LEAF_MATCH,
            Gas.WIN_MATCH_BY_TIMEOUT,
            Gas.ELIMINATE_MATCH_BY_TIMEOUT
        ),
        Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT + max(
            Gas.WIN_INNER_TOURNAMENT,
            Gas.ELIMINATE_INNER_TOURNAMENT
        )
    )
h = commitment tree height for this tournament
P = Bond.WORK_PRICE_CAP
W(h) = (h - 1) * A + E
B(h) = W(h) * P
```

`B(h)` is the amount required by `joinTournament`. For an action with configured
allocation `g`, the refund cap is now expressed directly:

```text
actionRefundCap(g) = g * P
```

The absolute action cap is independent of tournament height. The join bond is
the complete configured match-work reserve, so changes to `A`, `E`, or `P`
propagate into it without another manually maintained value.

For one successful action body, define:

```text
units = Gas.TX + gasBefore - gasAfter
effectivePrice = min(tx.gasprice, block.basefee + Bond.PRIORITY_FEE_CAP)
requestedRefund = min(
    tournament balance before the callback,
    actionRefundCap(g),
    units * effectivePrice
)
```

`PartialBondRefund.value` is `requestedRefund` even when the recipient rejects
the payment. `success` distinguishes an accepted nonzero transfer from a failed
one; a zero request skips recipient code and reports success. A failed transfer
leaves the requested amount in the pooled tournament balance.

The current constants give:

```text
A = 125,000 gas
E = 948,000 gas
P = 50 gwei
```

Every allocation currently includes the flat 25,000-gas `Gas.TX` term:

| Action | Allocation `g` | Absolute share cap `g * P` |
| --- | ---: | ---: |
| Advance match | 125,000 gas | 0.00625000 ETH |
| Win by timeout | 260,000 gas | 0.01300000 ETH |
| Eliminate by timeout | 135,000 gas | 0.00675000 ETH |
| Seal inner match | 363,000 gas | 0.01815000 ETH |
| Propagate inner winner | 336,000 gas | 0.01680000 ETH |
| Eliminate inner match | 172,000 gas | 0.00860000 ETH |
| Seal leaf match | 105,000 gas | 0.00525000 ETH |
| Win leaf match | 843,000 gas | 0.04215000 ETH |

The checked-in heights produce the following join deposits:

| Height | `W(h)` | `B(h)` |
| ---: | ---: | ---: |
| 48 | 6,823,000 gas | 0.34115000 ETH |
| 17 | 2,948,000 gas | 0.14740000 ETH |
| 27 | 4,198,000 gas | 0.20990000 ETH |

The target two-level gas witnesses use heights 55 and 37. If deployed with the
same accounting constants, they would require:

| Height | `W(h)` | `B(h)` |
| ---: | ---: | ---: |
| 55 | 7,698,000 gas | 0.38490000 ETH |
| 37 | 5,448,000 gas | 0.27240000 ETH |

These are accounting values, not a claim that every gas ceiling is validated.
`WIN_LEAF_MATCH` is deliberately a heuristic subsidy. It uses the rounded
recommendation from one canonical ordinary proof and is not a maximum across
state-transition proof or input classes.

## Per-match work bound

A new match starts at height `h`. `advanceMatch` is legal only while its current
height is greater than one, so one match can advance at most `h - 1` times.
`Bond.terminalAllocation` explicitly takes the maximum over every legal direct,
leaf, and inner terminal sequence. The current configured maximum is leaf seal
followed by proof resolution.

The maximum configured refundable work for one resolved match is therefore:

```text
W(h) = (h - 1) * A + E
```

Leaf proof, sealed-leaf timeout, direct timeout, and inner elimination all have
smaller configured totals. Reverted operations transfer no refund because the
whole modifier execution reverts.

At the maximum `h - 1` advances, the configured path totals are:

| Terminal path | Configured match total |
| --- | ---: |
| Direct timeout win | `(h - 1) * A + 260,000` |
| Direct timeout elimination | `(h - 1) * A + 135,000` |
| Leaf seal and proof | `(h - 1) * A + 948,000` |
| Leaf seal and timeout win | `(h - 1) * A + 365,000` |
| Leaf seal and timeout elimination | `(h - 1) * A + 240,000` |
| Inner seal and winner propagation | `(h - 1) * A + 699,000` |
| Inner seal and elimination | `(h - 1) * A + 535,000` |

This bound assumes a valid positive tournament height. Canonical and test-owned
geometry validation should reject a zero-height configuration before
deployment.

## Tournament-wide reserve

Let `J >= 1` be the number of unique paid commitments joined to one fresh
tournament instance and `C` the number of matches created over its lifetime.
Pairing combines two disjoint live commitment histories. Resolving a match
returns at most one of them to the dangling slot, so every match permanently
reduces the live population by at least one. Late joins and repeated winner
re-pairing do not change this accounting:

```text
C <= J - 1
```

Let `Q` be the total successful progress-refund outflow before terminal
recovery. Since `B(h) = W(h) * P`, each match consumes at most one bond in
configured refunds, hence:

```text
Q <= C * B(h) <= (J - 1) * B(h)
```

Since each join deposits at least `B(h)`, a finished tournament with a winner
has, immediately before its first successful terminal recovery:

```text
balance >= J * B(h) - C * B(h)
        = (J - C) * B(h)
        >= B(h)
```

Failed refund callbacks, under-budget actions, excess join value, and forced ETH
only increase this lower bound. Therefore, under the configured share caps:

- one minimum join bond is reserved;
- an accepting winning claimer receives exactly `B(h)`, not merely "up to" a
  possibly depleted amount; and
- after that payment, the residual may be zero when every possible match
  consumes its complete configured reserve.

With exact-value joins and no forced ETH, terminal conservation is:

```text
successful progress refunds + winning payment + residual burn = J * B(h)
successful progress refunds + residual burn = (J - 1) * B(h)
```

The qualifications still matter. A rejecting winning claimer defers both payout
and burn for retry. A no-winner tournament has no terminal recovery path, so its
balance remains locked. This proof is per tournament instance; each child has
its own joins, work reserve, and terminal accounting.

## The economic policy exposed by the proof

The work reserve is also the forfeitable Sybil bond. Aggregate losing reserves
have two possible destinations:

```text
losing reserves = successful progress refunds + residual burn
```

If an honest validator performs the work, the attacker's pooled reserve pays
that caller or remains for burning. If the attacker performs successful work
and receives the refund, the transaction still consumes Ethereum execution and
blockspace. The capped winner payment prevents the winning claimer from
recovering unused losing reserves directly.

This is not an identity-level cost theorem. Refunds go to immediate
`msg.sender`, which need not be the bond poster or top-level gas payer. The
formula uses a per-action fixed allowance and a gross `gasleft()` delta rather
than receipt gas, and it does not reconcile storage-refund credits. A batching
contract, paymaster, or proposer coalition can therefore make its private cost
differ from the requested refund. Every successful refund accompanies real EVM
work, but the contract does not prove `refund <= recipient transaction cost`.

The selected policy does not add an independent ETH-burn floor. Exact
reimbursement is not a correctness assumption, and the bonds are intended to
make adversarial identities fund dispute work rather than create an endogenous
validator incentive. If a future policy requires an additional fee-market- and
caller-independent loss, it should add and calibrate an explicit stake. Doubling
the work reserve without increasing refund liability would merely disguise
such a stake and double honest capital requirements.

The implemented formulas are:

```text
bondValue(h) = W(h) * WORK_PRICE_CAP
actionRefundCap(g) = g * WORK_PRICE_CAP
```

`Bond.terminalAllocation()` derives `E` directly from the manual `Gas` table,
and `matchWorkAllocation(h)` derives `W(h)`. Gas calibration therefore changes
every affected join bond automatically. Increasing a cheaper terminal action
does not change a bond while its legal sequence remains below the current
maximum. The direct action cap also removed a clone-argument decode and a
multiply/divide from the refund postlude; PRT-003 measurements use that newer
path.

## Refund promise

The current modifier is not a receipt-exact transaction refund. It snapshots
`gasleft()` after acquiring the transient lock and adds the flat `Gas.TX`
allowance. The measured delta includes the remaining modifier stack, action
body, state-transition or child-result calls, events, and production counter
writes. It excludes:

- transaction intrinsic gas and dynamic calldata cost;
- ABI dispatch and decoding before the snapshot;
- lock acquisition;
- refund calculation, callback, event, unlock, and return after the snapshot;
- exact end-of-transaction storage-refund credits; and
- chain-specific data, envelope, blob, or L2 security fees.

For calibration, define `delta = gasBefore - gasAfter` at those production
snapshots. With base fee zero, transaction gas price one Wei, and enough pooled
balance, `PartialBondRefund.value` is exactly:

```text
(Gas.TX + delta) * 1 Wei
```

The test harness therefore measures the quantity the action cap governs without
adding production instrumentation. Fixture construction occurs in Foundry's
separate `setUp` transaction, so the measured action starts with cold tournament
and nested-contract accesses. The selected headroom is:

```text
margin(delta) = max(10,000 gas, ceil(delta / 10))
allocation = roundUpTo1000(Gas.TX + delta + margin(delta))
```

CI asserts that the complete reviewed margin remains; it does not wait for the
literal cap itself to be crossed. Solidity 0.8.30, optimized IR with 200 runs,
the Prague EVM, and the dependencies in `soldeer.lock` are pinned. The current
witnesses, including the simplification batch's recalibrated advance and inner
seal allocations, reproduced under local Forge 1.5.1-dev and the clean
pre-rebase Forge 1.4.3 checkpoint recorded in
[`REVIEW.md`](REVIEW.md#release-calibration-checkpoint-before-rebase).
Compiler, EVM, dependency, geometry, or supported-proof changes require a new
calibration even when an old ceiling happens to pass. The planned rebase changes
the Foundry pin, so this release checkpoint must be repeated on the clean
post-rebase candidate before merge.

The production-formula campaign separately pins the three-way minimum rather
than selecting an allocation. Independent timeout-action twins first recover
`units` at zero base fee and a one-Wei gas price, then vary base fee, priority
fee, tournament balance, receiver behavior, and whether the winner becomes
dangling or creates a replacement match. The fuzz property passed 10,000 runs;
six deterministic cases pin zero price, measured work, balance, priority,
allocation, and rejected-recipient boundaries. `vm.deal` deliberately creates
underfunded test balances to isolate the balance cap; that fixture does not
contradict the reserve theorem for normally funded tournaments. Foundry's
`lastCallGas.gasRefunded` values, 28,800 for the no-dangling twins and 31,600 for
the replacement-match twins, remain diagnostics. The protocol formula uses the
gross `gasleft()` delta and does not reconcile that storage-refund counter.

The first target-two-level witnesses use injected heights 55 and 37 rather than
the checked-in canonical geometry:

| Action and retained witness | `Gas.TX + delta` | Margin | Shared action allocation |
| --- | ---: | ---: | ---: |
| First charged right advance; first counter and position writes | 114,077 | 10,000 | 125,000 |
| First charged left advance; position remains zero | 91,876 | 10,000 | 125,000 |
| Charged position-one right leaf seal; full 37-sibling proof | 94,902 | 10,000 | 105,000 |
| Charged position-two left leaf seal; full 37-sibling proof | 74,788 | 10,000 | 105,000 |
| Charged position-one right inner seal; full 55-sibling proof and real child clone | 331,520 | 30,652 | 363,000 |
| Charged position-two left inner seal; full 55-sibling proof and real child clone | 311,406 | 28,641 | 363,000 |
| Active timeout, side one wins; charged survivor, nonzero position, dangling re-pair | 237,443 | 21,245 | 260,000 |
| Active timeout, side two wins; charged survivor, nonzero position, dangling re-pair | 237,559 | 21,256 | 260,000 |
| Sealed-leaf timeout, side one wins; charged survivor, position one, dangling re-pair | 238,101 | 21,311 | 260,000 |
| Sealed-leaf timeout, side two wins; charged survivor, position one, dangling re-pair | 238,217 | 21,322 | 260,000 |
| Active double elimination; nonzero position, exact equality boundary | 123,734 | 10,000 | 135,000 |
| Sealed-leaf double elimination; position one, later classifier branch, exact equality boundary | 124,063 | 10,000 | 135,000 |
| Resolved child selects parent side one; one-block carryover, position-one parent, dangling re-pair | 306,800 | 28,180 | 336,000 |
| Resolved child selects parent side two; one-block carryover, position-one parent, dangling re-pair | 306,975 | 28,198 | 336,000 |
| Single-claim child selects parent side two; positive carryover deduction and dangling re-pair | 306,930 | 28,193 | 336,000 |
| Resolved child winner expires; position-one parent deletion | 157,949 | 13,295 | 172,000 |
| Single-claim child winner expires; position-one parent deletion | 157,934 | 13,294 | 172,000 |
| Child finishes without a winner; position-one parent deletion | 153,010 | 12,801 | 172,000 |

Rows for one entry point share one configured constant, selected from its
largest retained witness. The other rows enforce that the shared constant still
covers their reviewed margins; they are not separate per-branch allocations.
Each largest witness also pins the 1,000-gas rounding rule exactly.
For timeout winners, a dangling re-pair dominates merely storing the survivor
as dangling because it also creates and starts a fresh match. A nonzero old
position clears one more storage word. Elimination does not inspect the dangling
slot; its retained maximum combines a nonzero position with the later timeout
classifier branch.

Child propagation uses real factory-created children and leaves child recovery
separate. The resolved-winner fixtures propagate at the final legal carryover
block, so the parent stores a one-block allowance, and a parent dangling claim
forces a fresh match. Both contested-parent orientations are retained. The
single-claim comparator covers the alternate child-finish branch. Child
elimination covers no-winner, single-claim winner, and resolved-winner states at
their inclusive deadlines; the resolved winner is the largest retained path.

The retained suite calibrates seven actions. A focused full-stack run of an
ordinary canonical uarch proof through the real Tournament, Cartesi state
transition, dangling re-pair, and refund seam measured 768,416 allocation
units. The ordinary margin rule produced 842,758 and rounded to the provisional
843,000-gas subsidy. This is not a retained maximum witness and does not cover
reset, input-boundary, halt, exception, or arbitrary proof encodings.

Leaf seal plus the provisional proof subsidy is 948,000 gas and remains larger
than the 699,000-gas inner winner path, so it defines `E`. There is no separate
bond parameter to update: allocation changes flow through `E`, `W(h)`, and
`B(h)` automatically.

The price term is:

```text
min(tx.gasprice, block.basefee + 10 gwei)
```

so priority fee above 10 gwei is excluded. The action cap is `g * P`, not
a direct 50-gwei cap on every unit actually consumed. If measured work `X`
exceeds configured estimate `g`, share saturation begins at `g * P / X`, which
may be well below 50 gwei. The provisional leaf allocation is not intended to
remove that possibility for every proof class.

The recommended promise is therefore:

> A best-effort, bounded subsidy for successful gross Ethereum EVM work, not
> profit, receipt-exact cost, dynamic calldata, L2 fees, or execution beyond the
> reviewed action and price caps.

`Gas.TX` should be renamed to describe the fixed unmetered-overhead policy. It
must not be documented as exact transaction gas. Full fork-aware calldata or
receipt reimbursement would be a different design.

The selected accounting scope is:

| Component | Current subsidy treatment |
| --- | --- |
| Successful action body and nested proof work | Gross `gasleft` delta |
| Unmetered prelude and postlude | Flat 25,000-gas proxy |
| Transaction-intrinsic calldata and pre-snapshot decoding | Excluded |
| Proof forwarding, copying, and memory expansion in the action body | Included in the gross delta |
| End-of-transaction storage-refund credits | Not reconciled |
| Refund-recipient callback | Outside measurement; recipient execution capped at 50,000 gas |
| `joinTournament` and `tryRecoveringBond` | Not refundable |
| Priority fee | Capped at 10 gwei |
| Work above the action cap | Excluded |
| L2 data or security fee | Unsupported |

## Callback boundary

PRT-011 removed terminal child recovery from `winInnerTournament`, so an
untrusted child claimer no longer controls gas needed for parent progress.
PRT-013 now gives both remaining recipient calls one shared boundary:

- Recipient code receives at most 50,000 gas. The nonzero-value `CALL` operand
  is 47,700 because the EVM adds a 2,300-gas value-transfer stipend. EIP-150 may
  reduce the forwarded amount when the caller has too little remaining gas; the
  policy is a ceiling, not a guaranteed minimum.
- Fixed `CALL` costs, including account access and value transfer, execute on
  the tournament side outside the measured delta. They are covered only
  indirectly by the flat 25,000-gas proxy, not reconciled receipt-exactly.
  Recipient execution remains outside the measurement.
- The assembly call supplies no output buffer. Recipient return data is never
  copied into tournament memory, and the ABI-compatible `ret` event field is
  always empty.
- Zero-value payments skip recipient execution. A zero action refund still
  emits `PartialBondRefund` with `success = true`.

The transient lock belongs to one tournament clone, not to the protocol as a
whole. A callback that tries another state-changing operation on the same clone
receives `ReentrancyDetected`; if it handles that failure, the outer payment and
action may still complete. A callback may mutate a different clone whose lock is
free. The retained cross-instance trace performs zero-balance recovery on a
second finished tournament during the first tournament's payment and deletes
the second claimer. It proves instance isolation, not that an arbitrary nested
operation fits the 50,000-gas callback ceiling.

An action-refund failure does not revert the action. Its computed value remains
in the pooled tournament balance and is not earmarked for that caller. A
terminal winner-payment failure returns `false` before payout, burn, or claimer
deletion, preserving the full balance for permissionless retry.

The callback suite also pins the terminal sequence with a two-bond pool.
Same-instance recovery reentry fails with the exact selector; the outer
recovery pays one bond, burns the other, deletes the claimer, and cannot pay
twice. A rejecting callback instead preserves both bonds and the claimer, after
which an accepting retry pays one bond and burns the residual. Across refund
callbacks, acceptance, rejection, and handled same-instance reentry produce the
same requested value because the gas snapshot precedes recipient execution.

`DaveConsensus.stageTournamentResult` still invokes terminal recovery
synchronously, after storing the staged result. Recipient rejection or callback
exhaustion is represented as `false`, and an unexpected recovery revert is
caught as well. Neither outcome undoes staging or blocks later acceptance; the
old tournament remains retryable. The bounded call removes the adversarial
unbounded gas and return-data tail, but does not make an arbitrarily under-gassed
transaction succeed.

The recipient contract is part of the compatibility requirement: an EOA,
EIP-7702 delegation, or smart-wallet receive path must complete within the
50,000-gas execution ceiling. A permanently more expensive recipient cannot
recover its terminal payment under this interface.

## Compatibility fence

The next implementation phase must preserve:

- every external function and error selector;
- `TournamentArguments`, clock tuples, storage layout, and generated bindings;
- event signatures;
- first-claimer ownership of the winning commitment; and
- permissionless action refunds and terminal recovery.

Runtime ABI and storage compatibility do not preserve deployment addresses.
Changing `Tournament` creation bytecode changes its zero-salt CREATE2 address;
the factory address changes too because its constructor embeds the implementation
address. Deployment artifacts must be regenerated for the release.

The five production counters are external API today and remain asserted as
compatibility and observability semantics across lifecycle, recursive, gas, and
rollups integration tests. Removing their writes would change getter semantics.
Keep them and include their worst-case storage writes in gas measurements unless
a later ABI version explicitly deprecates them.

## Decisions and open questions

The following constraints are selected for this campaign:

- Ethereum is the supported fee environment. Other registered chains remain
  experimental.
- Refunds are bounded work subsidies, not validator profit or exact receipts.
- The bond is exactly the configured match-work reserve. There is no additional
  Sybil stake or guaranteed positive terminal burn.
- Existing selectors, event signatures, tuple shapes, storage, and counter
  semantics remain compatible.
- Child economic recovery stays independent of parent winner propagation.
- Recipient callbacks have a 50,000-gas execution ceiling, copy no return data,
  and are skipped for zero value.
- Reentrancy locks are per clone: same-instance mutation is rejected, while a
  different clone may progress within the callback gas ceiling.

The following economic and accounting decisions remain open:

1. Keep the common maximum terminal reserve, or use the known leaf/non-leaf
   role to avoid path-dependent excess slack.
2. Define the maximum supported state-transition proof and input envelope.
3. The action headroom is selected above. Select the 50-gwei work-price cap and
   10-gwei priority cap from deployment policy rather than history.
4. Decide whether no-winner tournament balances remain locked or gain a
   permissionless burn path.

## Sequencing

1. Completed: correct current documentation and add pure tests for the bond,
   action-cap, and current legal-path algebra above.
2. Completed: the pure population model covers joins, repeated re-pairing,
   winners, double elimination, and worst-case work liability. Real height-1
   traces exercise nonzero refunds, both recurring-winner orientations, exact
   terminal payout, residual burn, and pooled-balance conservation.
3. Completed: remove the inherited additive principal. The complete bond now
   derives from the manual gas table, tournament height, and work-price cap.
4. Completed: make the accounting formula explicit without changing selectors
   or storage.
5. Completed: bound refund and terminal callback recipient execution and
   discard return data.
6. Completed for the selected policy: advance, timeout, double-elimination,
   both seal paths, and both real-child resolution actions have retained
   witnesses under pinned compiler and EVM settings. Leaf proof instead uses a
   documented provisional ordinary-proof subsidy.
7. Completed for accounting: all eight actions have explicit caps and feed the
   reserve algebra. Seven are retained ceilings; `WIN_LEAF_MATCH` is knowingly
   heuristic and may be revisited without changing any safety assumption.
8. Completed: exact formula fuzzing and six deterministic cap boundaries cover
   both timeout topologies, accepted and rejected transfers, and event/request
   semantics. Callback tests cover same-instance rejection, cross-instance lock
   isolation, terminal retry, one-bond payout, and residual burn.

The state-transition workstream would need a finite canonical proof language
before `WIN_LEAF_MATCH` could be claimed as a true upper bound. The refund is
not a correctness mechanism or an endogenous validator incentive, so that
stronger claim is not required by the selected policy. The optional measurement
and update checklist, including the current InputBox path and the
pre-Merkleized alternative, lives in `GAS-CALIBRATION.md`.
