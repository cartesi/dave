# Bond and refund design checkpoint

Status: accounting and callback boundary implemented; calibration and gas budgets open

Last reviewed: 2026-07-18

This document separates three concepts that the current implementation folds
into one formula:

1. the irreversible principal that makes a losing Sybil claim costly;
2. the work reserve that pays bounded dispute-game action refunds; and
3. the terminal payment returned to the first claimer of the winning root.

The derivation below describes the current code. It corrects the former claim
that progress refunds can consume the winning commitment's entire deposit, but
it also exposes that the current irreversible Sybil principal is much smaller
than the full amount paid at join time.

PRT-003 in [`REVIEW.md`](REVIEW.md) tracks the stale gas estimates and incomplete
fee model. PRT-008 records why terminal recovery pays at most one winning
deposit and burns the residual.

## Current formula

For one tournament instance, define:

```text
A = Gas.ADVANCE_MATCH
E = max(
        Gas.SEAL_LEAF_MATCH + Gas.WIN_LEAF_MATCH,
        Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT
            + Gas.WIN_INNER_TOURNAMENT
    )
h = commitment tree height for this tournament
P = Bond.WORK_PRICE_CAP
S = Bond.SYBIL_PRINCIPAL
W(h) = (h - 1) * A + E
B(h) = S + W(h) * P
```

`B(h)` is the amount required by `joinTournament`. For an action with configured
allocation `g`, the refund cap is now expressed directly:

```text
actionRefundCap(g) = g * P
```

The absolute action cap is therefore independent of tournament height and of
the economic principal. The inherited checkpoint sets `S = A * P`, so the
current join value remains exactly equal to the former formula:

```text
B(h) = A * P + ((h - 1) * A + E) * P
     = (h * A + E) * P
```

The current constants give:

```text
A = 90,175 gas
E = 515,561 gas
P = 50 gwei
S = 0.00450875 ETH
```

Every allocation currently includes the flat 25,000-gas `Gas.TX` term:

| Action | Allocation `g` | Absolute share cap `g * P` |
| --- | ---: | ---: |
| Advance match | 90,175 gas | 0.00450875 ETH |
| Win by timeout | 111,203 gas | 0.00556015 ETH |
| Eliminate by timeout | 87,135 gas | 0.00435675 ETH |
| Seal inner match | 262,531 gas | 0.01312655 ETH |
| Propagate inner winner | 253,030 gas | 0.01265150 ETH |
| Eliminate inner match | 110,183 gas | 0.00550915 ETH |
| Seal leaf match | 82,355 gas | 0.00411775 ETH |
| Win leaf match | 127,728 gas | 0.00638640 ETH |

The checked-in heights produce the following join deposits:

| Height | `T(h)` | `B(h)` |
| ---: | ---: | ---: |
| 48 | 4,843,961 gas | 0.24219805 ETH |
| 17 | 2,048,536 gas | 0.10242680 ETH |
| 27 | 2,950,286 gas | 0.14751430 ETH |

These are accounting values, not validated gas ceilings. PRT-003 establishes
that several current estimates understate real execution.

## Per-match work bound

A new match starts at height `h`. `advanceMatch` is legal only while its current
height is greater than one, so one match can advance at most `h - 1` times. Its
largest configured terminal branch is inner seal followed by inner winner
propagation, whose allocation is `E`.

The maximum configured refundable work for one resolved match is therefore:

```text
W(h) = (h - 1) * A + E
     = T(h) - A
```

Leaf proof, sealed-leaf timeout, direct timeout, and inner elimination all have
smaller configured totals. Reverted operations transfer no refund because the
whole modifier execution reverts.

At the maximum `h - 1` advances, the configured path totals are:

| Terminal path | Configured match total |
| --- | ---: |
| Direct timeout win | `(h - 1) * A + 111,203` |
| Direct timeout elimination | `(h - 1) * A + 87,135` |
| Leaf seal and proof | `T(h) - 395,653` |
| Leaf seal and timeout win | `T(h) - 412,178` |
| Leaf seal and timeout elimination | `T(h) - 436,246` |
| Inner seal and winner propagation | `T(h) - A` |
| Inner seal and elimination | `T(h) - 233,022` |

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
recovery. Each match consumes at most `W(h) * P` in configured refunds, hence:

```text
Q <= (J - 1) * W(h) * P
```

The current checkpoint satisfies:

```text
B(h) = S + W(h) * P
```

Since each join deposits at least `B(h)`, a finished tournament with a winner
has, immediately before its first successful terminal recovery:

```text
balance >= J * B(h) - (J - 1) * W(h) * P
        = B(h) + (J - 1) * S
```

Failed refund callbacks, under-budget actions, excess join value, and forced ETH
only increase this lower bound. Therefore, under the configured share caps:

- one complete winning join deposit is reserved;
- an accepting winning claimer receives exactly `B(h)`, not merely "up to" a
  possibly depleted amount; and
- terminal recovery burns at least `(J - 1) * S` from eliminated commitments.

The qualifications still matter. A rejecting winning claimer defers both payout
and burn for retry. A no-winner tournament has no terminal recovery path, so its
balance remains locked. This proof is per tournament instance; each child has
its own joins, work reserve, and terminal accounting.

## The economic policy exposed by the proof

The full join deposit is not the irreversible Sybil cost. A participant can
permissionlessly execute progress itself and receive the same bounded work
refunds as an honest validator. If those refunds accurately cover its work, the
guaranteed principal burned for each eliminated claim is `S`, not `B(h)`.

The inherited value was an accidental consequence of the off-by-one between
`h` budgeted advances and at most `h - 1` legal advances:

```text
S = 90,175 * 50 gwei = 0.00450875 ETH
```

This is the minimum guaranteed residual across tournament kinds. A leaf
tournament cannot take the larger inner terminal path used to compute `E`, so
it retains additional configured slack. Direct timeout and inner-elimination
paths also retain more. A common maximum keeps the formula simple but makes the
effective losing cost path- and level-dependent.

Nothing documents that amount as the intended price of one Sybil identity. The
implementation now names it as a Wei-denominated `Bond.SYBIL_PRINCIPAL`, so
recalibrating `Gas.ADVANCE_MATCH` cannot change it implicitly. Its final value
is still a protocol decision, not a gas measurement result.

The implemented join deposit is:

```text
bondValue(h) = sybilPrincipal + W(h) * WORK_PRICE_CAP
```

and an action is capped directly at:

```text
actionRefundCap(g) = g * WORK_PRICE_CAP
```

The initial `0.00450875 ETH` literal is behavior-identical to the former formula.
It is a mechanical refactor checkpoint, not approval of that economic value.
The direct action cap also removes a clone-argument decode and a multiply/divide
from the refund postlude. That work occurs after the modifier's gas snapshot, so
the configured payment is unchanged at this checkpoint while total transaction
gas decreases. PRT-003 measurements must use the new path.

## Principal calibration rule

Use one common principal floor for every tournament level. The refundable work
reserve already varies with height, so peak capital remains level-dependent.
Making the irreversible principal depend on height, gas estimates, or allowance
would couple economic security back to implementation parameters. A per-level
schedule would also create a cheapest-level bottleneck unless its ratios came
from a reviewed marginal-delay model; no such model currently justifies extra
parameters.

Keep three attacker costs separate:

1. Peak capital fronts `principal + workReserve(level)` for every live claim.
   Refunds and a winning terminal payment can make much of that capital reusable.
2. Irreversible loss is at least one principal for each eliminated claim.
3. Transactions and blockspace are separate resources, only partially covered
   by the work-subsidy policy.

The geometry and timing tools derive how claims turn into delay; they do not
price that delay. In particular, `measure.lua` takes root slowdown and inner
commitment time as inputs. It supplies neither an attacker budget nor the value
of disrupting an application. In a two-level reservoir strategy, root claims
and replicated child claims trade off multiplicatively, so the final principal
must be chosen by minimizing irreversible cost over those strategies for a
stated tolerated delay. The missing deployment inputs are:

- the disruption duration to price;
- the minimum attacker burn desired at that duration; and
- the maximum capital an honest validator should need across active levels.

A fixed Wei value also changes in external purchasing power. Treat the final
literal as deployment policy with a review cadence, not a universal protocol
constant. Until those inputs are selected, the inherited literal is the only
non-arbitrary compatibility checkpoint.

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

The price term is:

```text
min(tx.gasprice, block.basefee + 10 gwei)
```

so priority fee above 10 gwei is excluded. The action cap is `g * P`, not
a direct 50-gwei cap on every unit actually consumed. If measured work `X`
exceeds configured estimate `g`, share saturation begins at `g * P / X`, which
may be well below 50 gwei. For example, a 600,000-gas leaf action against the
current 127,728-gas allocation saturates near 10.64 gwei.

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
| Dynamic calldata and transaction envelope | Excluded |
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
  the tournament side and are paid by the transaction sender outside both the
  recipient-execution ceiling and the refund measurement.
- The assembly call supplies no output buffer. Recipient return data is never
  copied into tournament memory, and the ABI-compatible `ret` event field is
  always empty.
- Zero-value payments skip recipient execution. A zero action refund still
  emits `PartialBondRefund` with `success = true`.

An action-refund failure does not revert the action. Its computed value remains
in the pooled tournament balance and is not earmarked for that caller. A
terminal winner-payment failure returns `false` before payout, burn, or claimer
deletion, preserving the full balance for permissionless retry.

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

The five production counters are external API today. Tests no longer depend on
them, but removing their writes would change getter semantics. Keep them and
include their worst-case storage writes in gas measurements unless a later ABI
version explicitly deprecates them.

## Decisions and open questions

The following constraints are selected for this campaign:

- Ethereum is the supported fee environment. Other registered chains remain
  experimental.
- Refunds are bounded work subsidies, not validator profit or exact receipts.
- Existing selectors, event signatures, tuple shapes, storage, and counter
  semantics remain compatible.
- Child economic recovery stays independent of parent winner propagation.
- Recipient callbacks have a 50,000-gas execution ceiling, copy no return data,
  and are skipped for zero value.

The following decisions remain open before economic calibration:

1. Select the final value of the common Sybil principal from an attacker budget,
   tolerated disruption, and honest-validator liquidity target.
2. Keep the common maximum terminal reserve, or use the known leaf/non-leaf
   role to avoid path-dependent excess slack.
3. Define the maximum supported state-transition proof and input envelope.
4. Select action headroom, the 50-gwei work-price cap, and the 10-gwei priority
   cap from deployment policy rather than historical constants.
5. Decide whether no-winner tournament balances remain locked or gain a
   permissionless burn path.

## Sequencing

1. Completed: correct current documentation and add pure tests for the bond,
   action-cap, and current legal-path algebra above.
2. Completed: the pure population model covers joins, repeated re-pairing,
   winners, double elimination, and worst-case work liability. Real height-1
   traces exercise nonzero refunds, both recurring-winner orientations, exact
   terminal payout, residual burn, and pooled-balance conservation. The common
   maximum inner path remains an algebraic bound until the general multi-level
   Match handler lands.
3. Completed design checkpoint: use one common Wei-denominated principal and
   pin the inherited value without treating it as calibrated policy.
4. Completed: make the accounting formula explicit without changing selectors
   or storage.
5. Completed: bound refund and terminal callback recipient execution and
   discard return data.
6. Measure every successful refundable branch, including supported maximum
   state-transition proof shapes, under pinned compiler and EVM settings.
7. Generate new action budgets with reviewed headroom and enforce ceilings in
   CI.

The state-transition workstream must define a finite maximum supported proof or
proof-class set before `WIN_LEAF_MATCH` can be claimed as a true upper bound.
