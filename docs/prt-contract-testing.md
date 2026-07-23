# PRT contract testing

This document describes how the Foundry dispute-game tests divide
responsibility and how new tests should be designed. It covers
`prt/contracts`; [`test-harness.md`](test-harness.md) separately owns the Lua
and real-node end-to-end harness.

Exact campaign counts, hashes, mutation experiments, and release results are
historical evidence in the
[`TEST-REPORT.md`](reviews/2026-07-21-prt-dispute-game/TEST-REPORT.md) archive.

## Commands

Run from the repository root:

```bash
just prt-contracts::test-disputes
just prt-contracts::test-gas
just prt-contracts::coverage
just rollups-contracts::test
```

The state-transition suites require the `machine/step` submodule and FFI:

```bash
just prt-contracts::test-stf
just prt-contracts::test-stf-fuzzy
```

`just prt-contracts::test-all` combines the dispute and state-transition gates.
Gas calibration has stricter toolchain and clean-tree requirements; follow
[`prt-refund-gas-calibration.md`](runbooks/prt-refund-gas-calibration.md)
instead of treating an ordinary gas-test pass as an accepted calibration.

## Directory ownership

| Location | Responsibility |
| --- | --- |
| `test/*.t.sol` | Focused library tests and public `Tournament` composition |
| `test/accounting/` | Reserve algebra, exact refund formula, and callback behavior |
| `test/characterization/` | Frozen historical three-level behavior |
| `test/config/` | Canonical and generic parameter-table validation |
| `test/fixtures/` | Injected geometry, small trees, independent models, and test-only transitions |
| `test/gas/` | Retained production refund witnesses |
| `test/properties/` | Match parity, lifecycle, recursion, population, and delay properties |
| `test/step/` and FFI suites | Solidity-step and external state-transition oracles |

Characterization is a compatibility fossil, not the preferred semantic oracle.
New behavior tests should use the smallest injected geometry that exposes the
property under review.

## Test layers

Each layer has one job:

| Layer | What it establishes | What it does not establish |
| --- | --- | --- |
| Deterministic regressions | Exact boundaries, selectors, rollback, precedence, and lifecycle traces | Exhaustive arrival schedules |
| Fuzz properties | Arithmetic partitions, symmetry, geometry, caps, and bounded input domains | Completeness outside the generator |
| Stateful invariants | Legal and rejected operation sequences against an independent ghost model | Recursive adversarial scheduling unless modeled explicitly |
| Finite exhaustive models | Every state in a stated small domain | An unbounded theorem |
| Characterization | Historical observable behavior | The desired semantics of new code |
| Compatibility witnesses | ABI, storage, encoding, events, selectors, and bytecode identity | Correctness of an unchanged interface |
| Gas witnesses | Production refund-seam work for a declared execution envelope | Receipt gas or unbounded proof classes |
| Downstream integration | Rollups factory and staged-consensus composition | Real validator or Lua conformance |
| Coverage mapping | Production locations that deserve investigation | Semantic assurance or branch completeness |

Do not use a higher test count as a substitute for independent oracles and
failure-sensitive assertions.

## Clock ownership

The tests mirror the production abstraction:

- `Clock` owns one-clock representation, arithmetic, and storage transitions.
- `MatchClocks` owns policy involving two clocks.
- `Match` owns commitment existence and structural phase.
- `Tournament` proves that those local responsibilities compose correctly.

One-clock properties should cover elapsed time, remaining time, overdue time,
strict deadlines, charging, replacement, and zero-sentinel rejection at an
explicit observation instant.

Pair-clock tests should cover every supported local shape: uninitialized, two
paused, exactly one running, and two running. Each transition needs both
orientations and a rejection matrix. The shared timeout classifier must remain
exhaustive and disjoint, with equality assigned explicitly. Its independent
oracle must distinguish a paused winner's deferred overdue charge from a running
winner's zero deferred charge. Tournament tests own the strict verb partition:
a leaf proof is valid only under `NONE`, single-winner statuses select timeout
victory, and `ELIMINATE_BOTH` selects elimination. Response-budget tests must
prove that a successful response discounts elapsed time once without increasing
the prior balance; pairing and ordinary same-tournament survivor re-entry must
not grant time. Recursive integration separately owns the shared pair envelope:
a child return may exceed the selected side's snapshotted remainder, but not
`max(r1, r2)` or the post-discount live pair mass.

Tournament integration owns the structural distinctions that pair clocks alone
cannot infer, including ready-to-bisect versus sealed-inner states when both
clocks are paused.

The living clock evidence map is:

| Concern | Primary evidence |
| --- | --- |
| One-clock arithmetic, strict deadlines, and zero sentinel | `test/Clock.t.sol` |
| Legal pair shapes, timeout partition, equality, and orientation symmetry | `test/MatchClocks.t.sol` |
| Public proof, timeout, pairing, and rollback composition | `test/Tournament.t.sol` |
| Independent one-level topology and clock ghost state | `test/properties/TournamentLifecycleInvariant.t.sol` |
| Reachable lower bounds and exhaustive small one-level schedules | `test/properties/LeafPopulationDelay.t.sol` and `test/properties/BoundedOneLevelDelay.t.sol` |
| Shared child envelopes, propagation, concurrent children, and generic depth | `test/properties/RecursiveTournamentLifecycle.t.sol`, `ConcurrentRecursivePopulation.t.sol`, and `FourLevelRecursiveLifecycle.t.sol` |
| Ethereum and local-devnet block conversion for response and allowance budgets | `test/Deployment.t.sol` |

Within `RecursiveTournamentLifecycle.t.sol`,
`testChildWinnerSelectsParentSideByFinalStateNotByRoot` pins final-state
classification, while `testChildReturnUsesSharedParentPairEnvelope` pins the
asymmetric clock return. Together they establish the mechanics behind the
simplification; they do not identify an optimal attacker schedule or prove a
general recursive delay bound.

The one-level invariant establishes the exact parity-aware relation
`runningClocks >= floor(K / 2)` for leaf tournaments. It is not a recursive
clock theorem: sealed inner parents pause both clocks and delegate the
obligation to a linked child. No current model combines an identified correct
commitment, an eager correct strategy, an adversarial scheduler, and one shared
censorship ledger `C`; that general recursive result remains open.

## Match ownership

Match tests deliberately triangulate four independent concerns:

1. raw characterization pins the externally observable tuple, events, errors,
   and sealed encoding;
2. an independent sparse-Merkle model owns divergence, parity, agree-proof
   ownership, and fixed-side winner attribution;
3. focused validation tests own malformed children, proof failures, and phase
   guards; and
4. Tournament integration owns clocks, deletion, re-pairing, recursion, and
   terminal outcomes.

The sparse-tree oracle must derive turn ownership independently. Copying the
production parity table into the test would create correlated evidence rather
than an oracle. Exercise both commitment orders, valid zero-valued payloads,
leftmost divergence, every small-tree position, and the supported large-height
boundaries.

## Configuration independence

Behavioral tests inject the geometry they require. Imports of production
`ArbitrationConstants` belong in canonical conformance tests, not in generic
Clock, Match, Tournament, or accounting properties.

The suite uses one-, two-, and four-level fixtures to exercise generic
structure. Historical Top/Middle/Bottom suites use a frozen test-owned provider
under `test/characterization/`. None of these fixtures proves that an off-chain
client uses a selected deployment table; that requires coordinated node and Lua
conformance.

## Oracle independence

Prefer evidence that does not replay production storage or branch tables:

- the Match oracle constructs its own sparse trees and tracks the revealer by
  alternation;
- the lifecycle ghost model tracks population, topology, coordinates, clocks,
  claimers, and counters independently;
- finite schedulers use their own packed state and enumerate a declared domain;
  and
- refund and reserve properties derive the algebra from joins, matches, caps,
  and balances instead of comparing two production getters.

Settlement stubs select a claimed leaf outcome. They are not oracles for the
real machine transition. Coordinate-coherent fixtures prove that tournament
spans and contested states line up, not that either computation is correct.

## Fuzz and stateful reproducibility

The ordinary Foundry fuzz budget is pinned in `foundry.toml`. A deeper campaign
must record its run count, depth where applicable, and seed. Do not describe a
fuzz campaign as exhaustive unless its generator enumerates the entire stated
domain.

Stateful handlers must account for reverts and discarded inputs. A green
invariant with most operations rejected is weak evidence; retain counters or
companion traces that prove the intended operations executed.

## Coverage discipline

Coverage instrumentation changes gas and cannot run the retained gas witnesses
or exact refund-formula measurements faithfully. FFI and state-transition tests
have separate execution requirements, and the slow stateful executors are owned
by the ordinary dispute gate. Deterministic companion traces map their principal
production paths.

The coverage recipe uses IR-minimum mappings as a stack-depth workaround.
Reported branch totals are directional and can disagree with demonstrably
executing tests. Use uncovered lines and functions as investigation leads, not
as a correctness score.

## Compatibility checks

The deployed compatibility surface includes:

- the Tournament ABI;
- semantic storage layout;
- raw Match encoding;
- event and error selectors; and
- metadata-free creation and runtime bytecode when exact code identity matters.

Run:

```bash
just prt-contracts::compatibility-hashes
```

Hashes are comparison aids. Inspect every unexpected difference rather than
updating a recorded value mechanically. Internal Solidity library helpers are
not an external source-compatibility promise.

## When to add tests

Add a test when it:

- protects a production change;
- reproduces a concrete finding;
- validates a new supported geometry, proof, or fee envelope; or
- attacks an explicitly scoped open question.

Do not add fixed lifecycle traces or fuzz volume solely to improve headline
counts. Current non-claims include a general recursive adversarial-arrival
proof, node and Lua agreement with a future geometry, state-transition halt and
exception semantics, a universal leaf-proof gas ceiling, and semantic meaning
for IR branch percentages.
