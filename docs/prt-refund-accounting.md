# PRT refund and bond accounting

This document states the reserve argument behind PRT joins, progress refunds,
the terminal winner payment, and residual burning. It owns the algebra and its
economic interpretation. Current action allocations and price parameters live
in [`Gas.sol`](../prt/contracts/src/tournament/libs/Gas.sol) and
[`Bond.sol`](../prt/contracts/src/tournament/libs/Bond.sol); current callback
and recovery behavior lives in [`dispute-game.md`](dispute-game.md).

The bond has no separately maintained Sybil-principal component. It is the
configured work reserve for one match. This makes allocation changes propagate
to join deposits automatically, but it does not promise exact reimbursement or
a fixed positive burn for every losing commitment.

## Per-match reserve

For one tournament instance, define:

```text
A = Gas.ADVANCE_MATCH
r = tournament role: leaf or non-leaf
E_r = maximum configured allocation over terminal sequences legal for role r
h = commitment tree height for the tournament
P = Bond.WORK_PRICE_CAP
W_r(h) = (h - 1) * A + E_r
B_r(h) = W_r(h) * P
```

`B_r(h)` is the minimum value accepted by `joinTournament`. For a refundable
action with configured allocation `g`:

```text
actionRefundCap(g) = g * P
```

A positive-height match advances at most `h - 1` times. Direct timeout paths
are legal for both roles. Sealed-leaf paths are legal only in leaf tournaments,
and sealed-inner paths are legal only in non-leaf tournaments:

| Terminal sequence | Legal role | Allocation expression |
| --- | --- | --- |
| Direct timeout win | Both | `Gas.WIN_MATCH_BY_TIMEOUT` |
| Direct timeout elimination | Both | `Gas.ELIMINATE_MATCH_BY_TIMEOUT` |
| Leaf proof | Leaf | `Gas.SEAL_LEAF_MATCH + Gas.WIN_LEAF_MATCH` |
| Sealed-leaf timeout win | Leaf | `Gas.SEAL_LEAF_MATCH + Gas.WIN_MATCH_BY_TIMEOUT` |
| Sealed-leaf timeout elimination | Leaf | `Gas.SEAL_LEAF_MATCH + Gas.ELIMINATE_MATCH_BY_TIMEOUT` |
| Inner winner propagation | Non-leaf | `Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT + Gas.WIN_INNER_TOURNAMENT` |
| Inner elimination | Non-leaf | `Gas.SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT + Gas.ELIMINATE_INNER_TOURNAMENT` |

`Bond.terminalAllocation(isLeafTournament)` factors these paths into direct
timeout and the selected sealed family. The current maxima are 4,428,000 gas
units for leaf tournaments and 701,000 for non-leaf tournaments. The
independent accounting tests enumerate every legal path for each role. A new
successful terminal path must be added to both production and that role's
model. Changing an existing allocation flows automatically through `E_r`,
`W_r(h)`, and `B_r(h)` when that path becomes or remains the role maximum.

The formula assumes valid positive geometry. Nothing at runtime rejects a
zero-height table - `Bond.bondValue(0)` returns a defined but meaningless
value - so zero-height rejection is enforced only by the pre-deployment
test gate (`test/fixtures/TournamentParameterTableValidator.sol`, run by
`test/config/*.t.sol`), which must be pointed at any new table before it
ships.

## Tournament-wide reserve proof

Let `J >= 1` be the number of paid commitments joined to one fresh tournament
and `C` the number of matches created over its lifetime.

Pairing combines two disjoint live commitment histories. Resolving a match
returns at most one history to the dangling slot. Each match therefore reduces
the live population by at least one, even with late joins and repeated survivor
re-pairing:

```text
C <= J - 1
```

Let `Q` be the total successful progress-refund outflow before terminal
recovery. Every match in one tournament has the same role and at most `W_r(h)`
configured refundable gas units, therefore at most one bond of configured
refund liability:

```text
Q <= C * B_r(h)
  <= (J - 1) * B_r(h)
```

Since the joins contribute at least `J * B_r(h)`, a finished tournament with a
winner has, immediately before its first successful terminal recovery:

```text
balance >= J * B_r(h) - C * B_r(h)
        = (J - C) * B_r(h)
        >= B_r(h)
```

Under the configured action caps, one minimum join bond is therefore reserved
for an accepting winning claimer. The implementation defensively pays
`min(balance, B_r(h))`; the reserve proof explains why the balance term does not
bind for an ordinarily funded completed tournament.

Failed refund callbacks, under-budget actions, excess join value, and forced
ETH can only increase the balance relative to the lower bound. A rejecting
winner defers both payment and burn; the full balance remains available for a
permissionless retry. A tournament that finishes without a winner has no
terminal recovery path and retains its balance. Every recursive child is a
separate tournament with its own joins, reserve, and terminal accounting.
Recovery itself receives no progress refund: reclaiming the winner's own bond
is already self-interested, and subsidizing that call from the balance being
recovered would make the reserve argument circular.

The executable population and reserve models live in
[`RefundReserve.t.sol`](../prt/contracts/test/accounting/RefundReserve.t.sol).

## Terminal conservation

With exact-value joins, no forced ETH, and a successful winner payment:

```text
successful progress refunds + winner payment + residual burn = J * B_r(h)
winner payment = B_r(h) + floor(pre-recovery residual / 10)
pre-recovery residual = (J - 1) * B_r(h) - successful progress refunds
```

The winner receives one bond plus a one-tenth bounty on the pre-recovery
residual, rounded toward the burn. The remaining losing reserves have three
possible destinations:

```text
losing reserves = successful progress refunds
    + winner bounty
    + residual burn
```

with `residual burn >= 9 * winner bounty`, so at least nine tenths of the
terminal residual is destroyed. In undisputed operation `J = 1`, the balance
is exactly one bond, and the bounty is zero. The residual can be zero when
successful progress consumes every available configured match reserve; the
protocol does not guarantee a positive burn per loser.

## Economic interpretation

The refund system reduces the cost of altruistic validation. It is not an
endogenous incentive system and is not required for result-selection safety.

If an honest validator performs successful dispute work, the pooled reserves
subsidize that caller. If an adversary performs the work and receives the
refund, the corresponding Ethereum execution and blockspace were still
consumed. Capping the terminal winner payment prevents the winning claimer from
recovering unused losing reserves directly.

This is aggregate resource accounting, not an identity-level attacker-cost
theorem:

- the immediate caller, bond poster, refund recipient, and top-level gas payer
  can be different addresses;
- the refund formula prices a gross `gasleft()` delta, not a transaction
  receipt;
- batching, paymasters, storage refunds, and proposer relationships can change
  private cost; and
- transaction-intrinsic calldata and chain-specific fees are outside the
  promise.

Every successful refund accompanies real EVM work, but the contract does not
prove that the requested refund is less than the recipient's private cost.

Adding an independent attacker loss would be a new policy. Doubling the work
reserve without increasing refund liability would merely disguise that stake
and double the honest participant's capital requirement. Any such change
should introduce and justify the independent component explicitly.

## Policy boundaries

The current design deliberately leaves these as separate decisions:

- the finite state-transition proof and input envelope, if any, that a leaf
  subsidy promises to cover;
- selection of the work-price and priority-fee caps from deployment policy;
  and
- whether no-winner tournament balances should gain a permissionless burn
  path.

Changing one of these policies requires focused accounting tests and a new
review record. Gas allocation measurement follows
[`prt-refund-gas-calibration.md`](runbooks/prt-refund-gas-calibration.md).
The detailed reasoning and measurements from the 2026-07 review remain in the
[`REFUND-DESIGN.md`](reviews/2026-07-21-prt-dispute-game/REFUND-DESIGN.md)
archive.
