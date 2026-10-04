# R19: an independent honest-survival model

Status: open, written 2026-10-02 as a brief for a follow-up PR in a fresh
session; linked from [`docs/todo.md`](../todo.md). When it lands, its result
moves into [`dispute-game.md`](../dispute-game.md) and this file is deleted.
Line numbers are at the commit that added this file; re-check them.

## Why

The clock rules are tested one at a time: a response or a win is discounted
by `G`, a child return refills its winner by up to `T + 2G`, and the root
allowance is `C + G + (L - 1)(T + 2G)` (dimensioning.md, "Tournament clock
budgets"). Nothing composes them into the security claim. dispute-game.md:28
lists "a correct participant can submit required transactions before its
clocks ... expire" as a safety assumption rather than deriving it from
per-action latencies and `C`.

That gap has already cost one defect: before the child-return refill
(cartesi/dave#287) each sealed parent match against a new Sybil cost the
correct party one build, so once `C` was spent a few Sybil bonds eliminated
it. It was found by reasoning in the 2026-09-28 robustness review, not by a
test. No release tag contains the refill or the same PR's terminal-win
discount yet. A counterexample found after the contracts are frozen for the
audit costs a new deployment generation.

## The claim to establish

Fix the correct computation and the correct commitment at every level. If
the honest party follows the strategy below, and the adversary's total
censorship of the honest party's transactions across the root and all its
linked descendants is at most `C`, then:

1. the honest commitment's clock never expires in any tournament it enters,
   and it is never eliminated; and
2. if the root finishes, its winner carries the correct final state.

Both are safety: no wrong root can win. Whether the root finishes at all
(termination) and how long it takes (the delay bound) are liveness, and stay
separate non-claims (dispute-game.md:845-849, prt-delay-bound.md).

The model must exercise the scenarios the claim quantifies over: budgets
exactly at the formula (no loose reserve), children contested by Sybils, the
honest commitment in both orientations, and one censorship allowance `C`
shared by the root and all its descendants.

## The honest strategy

Model the Rust node as an eager actor, abstracted to latencies:

- It joins the root within `G` of the root's start; the root join's
  finality wait is censorship and draws on `C` (dimensioning.md, the
  finality paragraph).
- It joins each child it is delegated to within `T + G` of the seal that
  created the child: a build within `T`, then one inclusion.
- It lands every advance, seal, leaf proof, timeout claim and child-winner
  propagation within `G` of the action becoming available.
- It claims a timeout before considering a proof when the opponent has
  expired (`plan_engagement`, cartesi-rollups/node/src/hero/planner.rs:200).

Every latency is a strict bound: consumption must stay below the configured
duration, because a clock expires at equality (dimensioning.md). Lateness
beyond these latencies is censorship, charged to `C`. The latencies assume a
signer funded to the node README's floor; the max-tip replacement's overpay
and the races among honest nodes cost the signer ETH, not clock time
(node-architecture.md, transaction submission).

## Adversary powers

- Enters any number of Sybils, one bond each, at any level and time, and
  into either contested final-state class, the honest one's included: a
  child commitment maps back to a parent side by final state, not by root or
  claimer (dimensioning.md, the shared-maximum paragraph).
- Chooses its own timing: slow responses, letting its own clocks run out,
  sealing wherever its commitments allow, re-pairing survivors.
- Controls both sides of a Sybil-versus-Sybil match, so it chooses which
  Sybil survives and which remainder the shared envelope preserves.
- Orders transactions within a block and censors the honest party's
  transactions over any intervals whose total is at most `C`.
- Cannot prove a wrong leaf and cannot make the honest commitment wrong.

## The single cumulative `C` ledger

One ghost ledger per root dispute, shared by the root and every linked
descendant. Every block in which a due honest action is held back beyond
its latency draws from it, and nothing refills it. A model that resets `C`
per tournament, match, level or action proves the wrong theorem
(dimensioning.md, "Base-layer censorship model"). The ledger must not charge
one interval twice: during a sealed leaf both clocks run, and the survivor's
live remainder has already paid for every elapsed block.

## Existing evidence: what it covers and what it misses

Paths under `prt/contracts/` unless stated.

| Evidence | Covers | Misses |
| --- | --- | --- |
| `test/fixtures/BoundedOneLevelDelayModel.sol:16-20, 30-33` with `test/properties/BoundedOneLevelDelay.t.sol` | Exhaustive one-level search, `N <= 6`, `A <= 4`, `G <= 2`, `H <= 3`; witnesses replayed against `Tournament` | No designated honest commitment; each proof may pick either side; every response is the scheduler's; no `C`; one level |
| `test/properties/TournamentLifecycleInvariant.t.sol:26-31` (1,539 lines) | One-level stateful legality and clock accounting (`runningClocks >= floor(K / 2)`) | No survival property; no inner tournaments |
| `test/properties/RecursiveTournamentLifecycle.t.sol:366-397`, `testFuzzRepeatedDelegationsWithinBudgetDoNotDrain` | Two delegations return the pre-seal clock | Each child is uncontested (`_winChildAloneAfter`, :980-999, joins alone and waits for the deadline); no responses or leaf race in the child; no censorship; one orientation (`CLAIM_ONE`); a loose reserve (`MAX_ALLOWANCE = 200` against `G + F = 35`, :43-50) |
| Same file, :123 and :344 | The other envelope side, for single delegations | As above |
| `test/properties/ConcurrentRecursivePopulation.t.sol:101`, `FourLevelRecursiveLifecycle.t.sol:96` | Fixed recursive plumbing traces | Adversarial schedules |
| `test/Tournament.t.sol:1072` | One censorship scenario (a sacrificial leaf cannot amplify censorship) | Everything else |
| [Clock refill review](../reviews/2026-09-29-prt-clock-refill/REVIEW.md):66-76 | The balance `remaining censorship + (D - d) * F + d * G` | Reasoning, not a checked invariant |
| The e2e smoke (`test/e2e/rollups/scenarios/simple.lua:26-29`, and the two-level smoke) | The real node beats an eager Sybil at `C = 0` | Scenario evidence, not adversarial schedules |
| CF-01 probes (refill review :142-160) | The adverse handover trace at `C = 0` | Temporary Foundry probes with a state-transition stub, not retained; nothing in the repository pins that trace |

No evidence combines an honest actor, Sybil-populated children, one `C`
ledger, both orientations end to end, and reserves set exactly at the
formula. The living docs say so: dispute-game.md:845-849,
prt-contract-testing.md:143-148, dimensioning.md:360-364, and
prt-delay-bound.md:156-160 (no honest-validator strategy is imposed). The
devnet's own claim, that with `C = 0` "clocks cover only the honest path"
(`script/Deployment.s.sol:166-168`), is what the model checks at `C = 0`.

## Recommended approach

1. A paper argument first: an inductive potential argument per tournament
   and per delegation, starting from the review's balance, with every
   latency assumption explicit, CF-01's included. It covers any level count
   and any population.
2. Then a Foundry stateful invariant on production bytecode:
   - A handler over `SmallTwoLevelTournament` (test/fixtures) with
     `ProofSelectedStateTransition`, so the honest commitment's leaves are
     the provable ones. Reuse `TournamentLifecycleInvariant`'s handler
     patterns.
   - Budgets exactly at the formula, through `ClockBudgets` (no loose
     constant), with `T` and `G` small enough for deep runs.
   - The honest actor fires each due action at a latency below `G` (a join
     below `T + G`), plus censorship drawn from a ghost ledger capped at `C`.
   - Adversary actions: join Sybils at either level and in either
     final-state class, respond slowly, time out, seal, re-pair, censor.
   - Invariants: the honest commitment is never eliminated, and its clock
     covers the ghost obligation of its pending actions; whenever the root
     finishes, its winner carries the honest final state.
   - Runs at `C = 0`, where any leak is a loss, and at a small positive `C`;
     with the honest commitment as commitment one and as commitment two.
3. Escalate to an exhaustive model (extending `BoundedOneLevelDelayModel` to
   two levels, an honest designation and a ledger) or to TLA+ (TLC ships in
   the development flake; the repository has no `.tla` file) only if random
   search proves too weak: each adds a second specification to maintain.

Two levels first: it is the shape of the generation to be audited (the
canonical switch is a later PR). The paper argument should not depend on
`L`.

## CF-01: the accepted tradeoff and its latency assumption

A leaf proof in flight when the opponent's shorter clock expires reverts,
and the survivor needs a separate timeout claim (dispute-game.md, CF-01).
It stays the accepted tradeoff: nothing is added to eliminate it. The model
states its latency assumption explicitly instead: the honest proof plus its
fallback timeout claim land within `G` of the seal (proof-plus-fallback
latency `< G`), under which CF-01 costs nothing. That assumption is a
measured operator requirement (todo.md, before a two-level release); the
worst case today is estimated at 2 to 2.5 minutes against a five-minute `G`
(a lead, not measured). Beyond it, each occurrence would cost
`max(0, d1 + d2 - G)` of `C`, for one Sybil leaf match and one bond each,
which the claim does not cover.

## Acceptance criteria

- The argument is written into dispute-game.md with the claim, the strategy,
  the adversary, the ledger, the CF-01 latency assumption and every other
  assumption, and someone other than its author has reviewed it.
- The invariant lives under `prt/contracts/test/properties/`, runs in
  `just prt-contracts::test-disputes` (so in CI) at `C = 0` and at a small
  positive `C`, with formula budgets, Sybil-contested children, both
  orientations and one `C` ledger across all levels, with its runs and depth
  recorded.
- It fails a mutation control: with the child-return refill removed (the
  rule before cartesi/dave#287), a short schedule eliminates the honest
  commitment.
- A counterexample is a contract finding: stop, reproduce it as a
  regression, and route the fix through the contract-change gate before the
  contracts are frozen for the audit.

## Where the results land

- dispute-game.md: split "Remaining liveness work" (:820-824) into a safety
  result (honest survival, and a correct winner if the root finishes, under
  `C`, with its assumptions) and the liveness non-claims (termination and
  the delay bound), and restate the assumption at :28 as derived from the
  latency bounds.
- prt-contract-testing.md: replace the "No current model combines ..."
  paragraph (:139-144) with the new invariant.
- dimensioning.md:360-364 and prt-delay-bound.md, where they call the
  general result open.
- [audit-readiness.md](audit-readiness.md): mark R19 done or name what the
  auditor receives instead.
- docs/todo.md: delete the R19 line; delete this file.
