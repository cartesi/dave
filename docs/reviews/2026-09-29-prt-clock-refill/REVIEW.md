# PRT clock refill and sling branch review

> Internal engineering review snapshot, completed 2026-09-29. This records
> the reviewed revision and its evidence; it is not a current specification
> or a third-party assurance report.

Reviewed tip: `935dc1335e36d02372d4e358131d5f7d1ddaa3cc`.

Comparison base: `79874c0a1b40678465daf533acc976c88301c6d4`.

Primary changes: `2c502f63` (child-return refill and derived clock budgets)
and `935dc133` (leaf-proof and timeout-win inclusion discounts).

## Assessment and scope

Keep the Solidity design. The capped child refill addresses the actual
failure mode: an adversary can force repeated commitment construction, so a
larger initial allowance alone only postpones exhaustion. The implementation
preserves the relevant expiry, parent-child, and accounting boundaries. No
additional confirmed Solidity implementation defect was found in the focused
second pass.

The proof-to-timeout handover below is a confirmed timing limitation, accepted
as an engineering tradeoff for the seven-day censorship budget. Its initial
P1 classification was withdrawn after assessing its significance under that
reserve. The STF coverage assertion remains an open P2 test-gate finding.

The review began across the sling branch and then concentrated on the Solidity
design and implementation. It traced clock helpers, public callers, recursive
composition, factory and deployment arguments, and refund accounting. The
Cartesi step implementation was not audited in full; four boundary FFI tests
were exercised. The node pass found no additional confirmed wrong-root or
wrong-proof regression, but did not establish dense two-level deployment
readiness.

Living owners are [dispute-game.md](../../dispute-game.md),
[dimensioning.md](../../dimensioning.md),
[prt-contract-testing.md](../../prt-contract-testing.md), and the
[two-level plan](../../plans/two-level-sling.md#clock-refill-review-follow-up-2026-09-29).

## Design reasoning

Let `C` be cumulative censorship, `T` the inner commitment construction
budget, `G` one action's inclusion budget, and `F = T + 2G`.

### Repayment composes across delegations

At sealing, both parent clocks are paused and the child receives their shared
envelope `E = max(r1, r2)`. Joining costs the honest participant at most
`T + G`, and propagation costs at most `G`. If the child consumes censorship
`c`, successful-action discounts and recursive repayment give a carried
remainder of at least `E - (T + G) - G - c`. The parent stores:

```text
returned = min(E, carried + F)
returned >= E - c
```

Thus ordinary construction, joining, and propagation do not accumulate as a
loss across repeated delegations. Since `E` is at least the honest parent's
snapshot, the shared envelope does not truncate that side's available budget.
This reasoning assumes actions remain admissible until inclusion, the timing
bounds hold, and the intermediate clocks remain live. CF-01 below is an
exception to that action assumption.

The initial reserve has a concrete purpose. With `D = L - 1` inner levels,
[ClockBudgets](../../../prt/contracts/src/arbitration-config/ClockBudgets.sol)
provisions `C + G + D * F`. After the root join and descent through `d` child
joins, a conservative balance is:

```text
remaining censorship + (D - d) * F + d * G
```

At the leaf, `D * G` remains for outstanding return inclusions. Successful
responses and terminal wins receive their own discounts; each return restores
one delegation's reserve. This explains the provisioning for the canonical
three-level and selected two-level configurations. It is not a proof for
arbitrary parameter tables or all client scheduling behavior.

### Repayment remains bounded

[MatchClocks.childReturnAllowance](../../../prt/contracts/src/tournament/libs/MatchClocks.sol)
replaces the selected side's clock within the original pair maximum. It may
increase that side's individual snapshot, but cannot exceed the delegated
envelope or the pair's original live clock mass.

The helper relies on `carried <= E`. That follows from the production path:
joins begin below the child allowance, responses and wins never increase their
prior stored balances, deeper returns obey their own pair caps, and
post-finish deduction only decreases the result. Parent clocks remain paused
while the child resolves.

This is a budgeted repayment, not a measurement of actual construction cost.
It can forgive some censorship when ordinary costs are smaller than their
budgets, and dishonest winners receive it too. Those are deliberate delay
tradeoffs. Bounded balances alone do not prove a global settlement-delay bound;
recursive population and scheduling arguments are still required.

## Implementation checks

- **Expiry before credit.** The timeout classifier requires a winner to
  survive its full cost before
  [Clock.pauseWinnerAt](../../../prt/contracts/src/tournament/libs/Clock.sol)
  discounts it. Leaf proofs require timeout classification `NONE`. Production
  callers cannot use the discount to revive an expired commitment.
- **One charge per interval.** A paused timeout winner pays the expired
  responder's overdue interval. A running leaf winner already pays that
  interval through its live elapsed time and receives no second deferred
  charge. A successful win forgives at most one `G` of the combined cost.
- **Authenticated, single-use child returns.**
  [Tournament.winInnerTournament](../../../prt/contracts/src/tournament/Tournament.sol)
  requires the recorded origin match to exist and be sealed before reading
  the child result. Settlement deletes the match and child link. Orphan
  children and replay cannot obtain another refill.
- **Settlement before callbacks.** The clone lock is acquired before
  refundable entrypoints run. Pairing and deletion complete before the bounded
  refund callback; child-result and state-transition reads are static calls.
  The inline finished check in `winMatchByTimeout` retains the previous guard.
- **Coherent wiring and reserves.** Root and inner factories both encode
  `commitmentBudget`; provider constructor arguments match deployment encoding.
  No successful action or terminal path was added, so the per-match refund
  reserve argument remains intact. Gas witnesses exercise the larger clone
  arguments. These encoding and bytecode changes require the already planned
  fresh deployment generation.

## Findings and decisions

### CF-01: Proof-to-timeout handover consumes another inclusion

Status: confirmed; accepted limitation on 2026-09-29, not a requested blocker
or contract change. The initial P1 severity was withdrawn.

The node selects proof and timeout transactions from its observed state. If
the shorter opposing leaf clock expires while a proof is in flight,
`winLeafMatch` rejects it even though the honest clock is still live. A timeout
claim then needs a separate inclusion window. The failed proof earns no
discount.

A temporary public-contract reproduction used the existing small two-level
trees and proof-selection stub. With the configured two-level devnet budgets
`C = 0`, `G = 25`, `T = 300`, and root allowance `375` blocks:

| Block | Event and remaining allowances |
| --- | --- |
| 100 | Root created. |
| 124 | Root claims join; the disputed pair seals and creates a child with allowance 351. |
| 447 | Honest child joins after 299 construction blocks and 24 inclusion blocks; it retains 28. |
| 452 | Opponent joins with 23; immediate bisection and sealing start the leaf race. |
| 475 | The honest proof lands after 23 blocks and reverts at the opponent's expiry. |
| 480 | Honest clock expires. |
| 498 | Timeout claim lands after another 23 blocks; both sides can now be eliminated. |

The reproduction continued through parent elimination and a different dangling
root claim winning. A control proved the honest leaf before the shorter
deadline. Construction and every honest inclusion were strictly below their
configured bounds. A second probe reproduced the same pattern with smaller
`G = 10`, `T = 20` parameters. These are clock-composition tests with an STF
stub, not full node/emulator E2Es.

Decision: keep the implementation simple. One extra five-minute inclusion is
about 0.05% of a seven-day reserve. This consumes some censorship tolerance;
it does not preserve the exact full-`C` guarantee for every schedule. Repeated
occurrences could accumulate, but the review did not establish practically
meaningful amplification or its resource cost. Revisit if that evidence
changes or the reserve is materially shortened. An execution-time choice
between proof and timeout is a possible remedy, not an approved change.

### CF-02: A sealed transition can be counted as proved without a STEP receipt

Severity: P2. Status: open test-gate finding; follow-up belongs to W2 in the
[two-level plan](../../plans/two-level-sling.md#clock-refill-review-follow-up-2026-09-29).

[run_epoch and run_steered_epoch](../../../test/e2e/rollups/test_env.lua)
collect `LeafMatchSealed` cycles and assert the expected target and correct
root settlement. A timeout win can satisfy both conditions without calling
the STF. Parent propagation does not distinguish a proof winner from a timeout
winner.

A temporary Lua harness exercised the actual helpers and Reader decoders with
stubbed external transport and actors. A transcript containing the expected
seal, a timeout-only deletion, and correct settlement passed; changing the
expected transition failed. This establishes the assertion weakness, not that
the current real-chain STF scenarios actually resolve by timeout.

Retain each sealed match ID and require its corresponding
`MatchDeleted.reason == STEP` before counting it as proved. Use a timeout-only
negative control and a successful-proof positive control.

## Remaining assurance work

1. **Independent honest-survival model.** Identify the correct commitment,
   model an eager honest strategy, and distribute one cumulative `C` across
   joins, responses, terminal wins, and propagation. Exercise repeated and
   nested matches, both orientations, tight reserves, and expiry boundaries.
   Declare whether the model excludes CF-01 or charges its retry cost;
   otherwise it would claim a property the current client does not provide.
   Existing local formulas and recursive examples do not establish this
   general property. The live follow-up is R19 in the two-level plan.
2. **Recursive delay qualification.** Retain the explicit non-claim of a general
   asynchronous delay theorem in [prt-delay-bound.md](../../prt-delay-bound.md)
   and [dispute-game.md](../../dispute-game.md). The cap is useful evidence,
   not a substitute for that theorem.
3. **Release evidence.** An accepted exact-tip gas calibration record, full E2E,
   active real-machine tall-leaf differentials, and dense height-37 performance
   were not established by this review. Their existing owners are the
   [gas runbook](../../runbooks/prt-refund-gas-calibration.md) and W4/W5,
   R6, and R12 in the two-level plan. Passing ordinary gas witnesses is not an
   accepted calibration. No allocation shortfall was demonstrated.

## Validation record

Executed against the reviewed tip, before this documentation change:

| Check | Result | Boundary |
| --- | --- | --- |
| PRT dispute suite | 319 passed | Excludes FFI; includes clock, lifecycle, accounting, and retained Tournament gas tests. |
| Selected STF boundary FFI tests | 4 passed | Accepted yield at the last budget cycle, maximum mcycle, and halt; rejected yield at the last budget cycle. |
| Focused Rust tests | 84 passed | Engine 44, Hero 30, schema 8, storage lifecycle 1, window-root folding 1; excludes integration/corpus and full workspace suites. |
| Lua client suite | 76 passed | Includes the pending-yield seam. |
| Devnet fingerprint regressions | Passed | Geometry-profile bundle isolation. |
| CF-01 temporary contract probes | 2 passed | Tests assert the adverse trace, not successful honest survival. |
| CF-02 temporary harness probe | Accepted timeout-only transcript; rejected wrong target | Stubbed external transport, real assertion helpers. |

Tools: Foundry 1.5.1, Solidity 0.8.30, Rust 1.95, external Cartesi Machine
v0.21.0 provider. Initial `just doctor` diagnosed missing worktree setup;
the prepared development shell, pinned step checkout, contract dependencies,
and generated bindings were then used. No production sources were changed
during the review.

Commands below run from the repository root with that environment prepared.
The two temporary probes were outside the repository and are not permanent
regressions; their observed traces and limits are recorded above.

```sh
just prt-contracts::test-disputes
forge test --root prt/contracts --match-contract StateTransitionFfiTest \
  --match-test 'testTransition(AcceptedYield|RejectedYieldOnLast)' --ffi --threads 1
cargo test -p cartesi-rollups-prt-node --lib engine::
cargo test -p cartesi-rollups-prt-node --lib hero::
cargo test -p cartesi-rollups-prt-node --lib storage::sql::schema::tests
cargo test -p cartesi-rollups-prt-node --lib storage::tests::test_state_access
cargo test -p cartesi-rollups-prt-node --lib storage::advance::tests::commit_advances_writes_final_window_roots
just test-lua-client
./script/tests/devnet-fingerprint.sh
```
