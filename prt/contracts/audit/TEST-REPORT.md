# Dispute-game test assessment

Status: campaign test goals met within the stated scope; remaining gaps are
explicit non-claims

Last reviewed: 2026-07-21

Solidity and test tree: `ac3bea0c5057702e5778b3ea00086bfc31cc68ea`

Post-rebase release-calibration candidate:
`7565ec29797388a0108a267ba0b4676d09b63837`

The first revision contains the last Solidity or test change. The second adds
the exact official-Foundry calibration guard and runbook alignment without
changing that Solidity and test tree. Earlier snapshots survive in the
`REVIEW.md` validation entries. This report revision changes documentation only.

This report assesses the tests added or reorganized during the contract review.
It is a current assessment, not a chronological change log. Findings and their
history remain in [`REVIEW.md`](REVIEW.md); the Clock, Match, and refund design
records explain the associated implementation decisions.

## Conclusion

The suite now meets the bounded goals of this campaign:

- every contract defect fixed here has a focused regression at the relevant
  boundary;
- the back-loaded Clock policy is covered independently at the one-clock,
  pair-policy, and public Tournament layers;
- the Match refactor has unusually strong triangulation across raw
  compatibility, independent sparse-tree semantics, validation failures, and
  public lifecycle composition;
- behavioral tests no longer inherit the checked-in tournament geometry merely
  because it is the default configuration;
- refund, callback, gas-cap, and bond-reserve policy have executable algebra and
  production-path witnesses; and
- the ordinary fuzz run count is explicit rather than a local Foundry default.

This is strong evidence over named domains, not a proof of the complete PRT
security or liveness argument. In particular, the campaign did not prove the
unbounded multi-level attacker-versus-honest delay bound, validate a node
against the selected two-level table, audit state-transition semantics, or
establish a universal leaf-proof gas ceiling. Those gaps are explicit below and
are not reasons to keep adding unrelated tests to this branch.

## Scope and counting

The assessed scope is the Solidity dispute game under `prt/contracts` plus four
downstream `rollups-contracts` integration tests. The following remain out of
scope:

- the implementation semantics of the state-transition function;
- the Rust node and Lua client;
- real-node and Lua end-to-end conformance;
- non-Ethereum base-layer time conformance; and
- regenerated deployment and CREATE2 artifacts.

The initial dispute gate contained 42 tests. The current gate contains 231.
That growth is useful context, not the quality argument: four of the 231 are
non-FFI state-transition smoke properties, and many important claims are made
by one exhaustive or stateful test rather than by a large case count. The rest
of this report evaluates domains, oracles, and failure sensitivity instead.

## Goal assessment

| Goal | Assessment |
| --- | --- |
| Protect the Clock fixes and back-loaded response budget | Met strongly |
| Preserve intended Match behavior through the refactor | Met strongly within the compatibility fence |
| Decouple behavioral tests from canonical constants | Met |
| Exercise configurable level recursion | Met for injected one, two, and four levels; canonical and historical three-level behavior remains isolated |
| Cover public lifecycle composition | Strong at one level and representative at multiple levels |
| Validate refund and bond accounting under the selected policy | Met |
| Establish universal gas upper bounds | Not a campaign requirement; seven actions have retained ceilings and leaf proof remains provisional |
| Prove adversarial multi-level liveness | Not met and not claimed |
| Establish cross-client and deployment conformance | Outside this campaign |

## Test layers and ownership

| Layer | Principal owners | Evidence | Limitation |
| --- | --- | --- | --- |
| Deterministic regressions | `Tournament.t.sol`, `MatchValidation.t.sol`, recursive lifecycle suites | Exact timeout boundaries, rollback, revert precedence, winner mapping, carryover, deletion, and re-pairing | Selected traces do not exhaust arrival schedules |
| Fuzz properties | Clock, MatchClocks, Match phase/parity, configuration, accounting, and timing suites | Arithmetic partitions, symmetry, geometry, caps, and bounded timing domains | Random inputs are not completeness claims |
| Stateful invariants | `TournamentLifecycleInvariant.t.sol` | 32,768 positive-handler invocations and 16,384 mixed legal/rejection-handler invocations; companion traces pin selectors | One-level height-three fixture; no recursive stateful scheduler |
| Finite exhaustive models | `BoundedOneLevelDelay.t.sol`, `SmallFullTree.t.sol`, and Match position exhaustion | Every stated small configuration or position | Finite domains; the delay model selects proof winners independently |
| Characterization | `test/characterization/` | Frozen historical three-level behavior | Compatibility fossils, not preferred semantic specifications |
| Compatibility | Match snapshots, events, errors, hashes, and public precedence tests | ABI, storage, raw encoding, selectors, and observable ordering | Hash comparison remains a manual release check |
| Mutation sensitivity | Four targeted manual mutations | Each mutation was killed by a named test family | No automated mutation score or systematic campaign |
| Gas | 18 retained witnesses plus exact formula and callback suites | Release-pinned measurements and enforced caps | Leaf proof is a provisional subsidy, not a retained maximum |
| Downstream integration | `rollups-contracts` | Factory wiring, staged-result acceptance, sentry rotation, capped payout, residual burn, and callback exhaustion | No real validator node or Lua client |
| Coverage map | `just coverage` | Points to source locations worth investigation | IR-minimum mappings are directional and exclude several special-purpose suites |

Each layer has one job. Characterization should not become the semantic oracle;
coverage should not replace invariants; and a fuzz run should not be described
as exhaustive unless its generator actually enumerates the complete domain.

## Clock assessment

The production abstraction is appropriately split:

- `Clock` owns one-clock representation, arithmetic, and storage transitions;
- `MatchClocks` owns policy involving two clocks;
- `Match` owns commitment existence and bisection/sealed phase; and
- `Tournament` composes those responsibilities.

The initial review judged that no further production Clock refactor was
needed. The subsequent simplification batch deliberately reopened that
decision at the maintainer's request and went one step further:
`_pauseResponderAt` gives the three bisection exits one response-discount
implementation while still returning the idle side explicitly, and
`pausedAllowance` closes the one place where `MatchClocks` read `Clock`'s raw
representation. Both preserved the explicit two-orientation policy this report
originally defended; the generalized active-side abstraction remains rejected.

The tests mirror this boundary. `Clock.t.sol` has a one-clock harness and 20
cases, including the `pausedAllowance` guard matrix. `MatchClocks.t.sol` has a
pair-policy harness and 16 cases. Together they contain 12 fuzz properties.
The split makes two subtle invariants visible:

1. Each mutating `MatchClocks` transition validates its required local clock
   shape, not complete structural Match phase. The pure timeout classifier
   assumes a legal caller-supplied shape. Two paused clocks can mean either a
   pair ready to start bisection or a sealed inner match waiting on its child.
   Tournament's preceding Match operation or guard owns that distinction.
2. `deductPaused` may return zero in memory. Storing that result through
   `replaceWithPaused` must fail because zero allowance is the uninitialized
   storage sentinel. Changing replacement to reject the source earlier would
   alter this intentional error boundary without improving the invariant.

The pair rejection matrix covers uninitialized, two-paused,
exactly-one-running, and two-running shapes for every transition helper.
Proven-leaf settlement separately pins equal race starts, a non-`NONE` winner,
validation precedence, and all timeout outcomes. Tournament integration proves
the missing structural composition, strict response deadlines, rollback, late
entry, winner re-pairing, child carryover, and proof/timeout convergence.

The intended response-budget behavior has one arithmetic seam:
`pauseAfterResponseAt`. Since the simplification batch, the three eligible
pair transitions reach it through one private `_pauseResponderAt` call, so the
once-per-response rule is structural rather than a per-verb review
obligation. Tests cover the formula, both orientations, leaf and inner
sealing, deadlines, and the absence of pairing or re-entry grants.

## Match assessment

The Match test campaign separates four concerns:

1. raw characterization pins the externally observable tuple, events, errors,
   and legacy sealed encoding;
2. an independent sparse-Merkle model owns divergence, parity, agree-proof
   ownership, and fixed-side winner attribution;
3. focused validation tests own malformed children and proof failures; and
4. Tournament integration owns clocks, phase composition, deletion,
   re-pairing, recursion, and terminal results.

The 24 focused phase, identity, parity, and validation tests include complete
phase partition fuzzing, both ordered and all-zero identity vectors, every
stored phase guard, the zero-height creation assert, valid zero-valued payloads,
leftmost-divergence precedence, every position through height eight, boundary
and representative paths through height 55, and both commitment orders. The
sparse-tree oracle derives the final responder by turn alternation instead of
copying Match's height-parity table.

The compatibility checks establish the deployed ABI, storage layout, raw state
encoding, events, and selectors exactly. The semantic and integration tests
provide strong evidence over the reviewed domains that protocol outcomes were
preserved while phase and parity responsibilities became local; they do not
establish universal outcome equivalence. The refactor also does not promise
source compatibility for third-party Solidity code that imported the removed
internal library helpers; the simplification batch extends that non-promise to
the renamed Match guards, the height-narrowed `create` signature, and the
deleted dead `Time` duration helpers. Deployed ABI and storage remain the
compatibility surface.

## Configuration independence

Behavioral suites inject the geometry needed by the property under test.
Test imports of the production `ArbitrationConstants` library are confined to
configuration conformance tests. The former Top/Middle/Bottom suites remain
under `test/characterization/` against a frozen test-owned provider, where
changes to the canonical table cannot silently rewrite their purpose.

The suite now exercises:

- one level for the stateful lifecycle and bounded delay models;
- two levels for parent/child timing, propagation, re-pairing, and concurrent
  child populations;
- three levels for historical and checked-in canonical conformance; and
- four levels for a strict three-child-seam production trace.

This demonstrates that the contract shape is not hard-coded to Top/Middle/
Bottom. It does not establish that the node agrees with the selected two-level
table; that remains the CFG-001 integration gate.

## Oracle independence

The strongest suites do not merely replay production storage:

- the Match oracle constructs its own sparse trees and tracks the revealer by
  alternation;
- the lifecycle ghost model independently tracks population, topology,
  coordinates, clocks, claimers, and counters;
- the bounded delay search uses a separate packed state and enumerates its
  stated small domain; and
- refund and bond properties derive the algebra from joins, matches, actions,
  caps, and balances rather than comparing two production getters.

Independence is not absolute. The simple Clock timeout model necessarily
restates the selected arithmetic policy, and all Solidity integration tests use
the same EVM implementation. Symmetry, exact boundary tables, state rollback,
independent lifecycle composition, and mutation checks reduce that correlated
error risk. Cross-client conformance would require the excluded node and Lua
work.

Test settlement stubs select a claimed leaf outcome; they are not oracles for
the real machine transition. Coordinate-coherent fixtures prove that tournament
spans and contested states line up, not that either computation is correct.

## Mutation evidence

Four manual mutations were introduced locally, run against the focused suites,
and reverted:

- front-loading the response budget was killed by
  `testFuzzResponseBudgetDiscountsElapsedWithoutMinting` and
  `testResponseBudgetBoundaryTable`;
- charging stored allowance instead of live remaining time was killed by
  `testFuzzChargeUsesLiveRemainingTime` and
  `testSealedLeafTimeoutChargesLiveWinnerTime`;
- reversing the final responder parity was killed by the exhaustive parity and
  agree-proof-owner tests; and
- reversing leftmost branch selection was killed by both leftmost-divergence
  tests.

This proves sensitivity to four plausible regressions. It is not a mutation
score and should not be presented as systematic mutation coverage.

## Verification snapshot

The current ordinary configuration pins 256 fuzz runs. Deeper runs record both
their override and seed.

| Check | Result |
| --- | --- |
| Full `test-disputes` gate, official Forge 1.5.1 | 231 passed |
| Clock and MatchClocks focused suites, seed `0x5eed` | 36 passed; all 12 fuzz properties passed 10,000 runs |
| Match phase, identity, parity, and validation, seed `0x5eed` | 24 passed; both fuzz properties passed 10,000 runs |
| Positive lifecycle invariant | 256 runs x 128 depth = 32,768 handler invocations; 0 handler reverts or discards |
| Rejection lifecycle invariant | 128 runs x 128 depth = 16,384 mixed handler invocations; 0 handler reverts or discards |
| Clean post-rebase gas checkpoint, official Forge 1.5.1 | 18 of 18 passed on the exact release-calibration candidate; reproduced the 125,000 and 363,000 recommendations exactly; see [REVIEW.md](REVIEW.md#release-calibration-checkpoint-after-rebase) |
| Clean pre-rebase gas checkpoint, Forge 1.4.3 | 18 of 18 passed on the candidate-equivalent tree recorded in [REVIEW.md](REVIEW.md#release-calibration-checkpoint-before-rebase); reproduced the 125,000 and 363,000 recommendations exactly |
| Downstream `rollups-contracts`, official Forge 1.5.1 | 4 of 4 passed; all three fuzz properties used 256 runs |
| Coverage map, official Forge 1.5.1 | 204 included tests passed |

The coverage summary mapped 693/705 lines, 715/727 statements, 65/138
branches, and 145/145 functions. `Clock`, `Match`, and `Time` each mapped every
line, statement, and function. `MatchClocks` mapped 54/55 lines, 53/54
statements, and every reported branch and function. Clock mapped 4/8 reported
branches and Match 10/26. An lcov
detail pass during the coverage follow-up classified every remaining
uncovered production line as an IR-minimum mapping artifact contradicted by
function-level coverage and demonstrably executing tests; the same follow-up
removed the dead `Time` helpers that the uncovered-function signal exposed.
Foundry warns that IR-minimum can produce inaccurate source mappings. These
values prioritize investigation and do not override the semantic evidence
above.

The coverage recipe excludes FFI tests, retained gas witnesses, the exact
refund-formula suite, state-transition tests, and both stateful invariant
executors. Deterministic companion traces map the principal invariant paths;
the ordinary gate, not coverage, owns the stateful campaigns.

The compatibility witnesses at this snapshot are:

```text
Tournament ABI sha256:
67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a

Semantic Tournament storage-layout sha256:
952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329

Tournament creation bytecode without metadata sha256:
a638837b16a7cb21139706ff3aaecbb79a2f3b663d1b1dbb50f1e0243735ed4c

Tournament runtime bytecode without metadata sha256:
631eb0908dfce360f6b6d85fb827ff4c5fe201b9e48e6af74b99f0cd35d2d5d3
```

The simplification batch intentionally changed production bytecode; the
dead-helper removal and every follow-up test change left these hashes
byte-identical. Deployment and CREATE2 artifacts still need regeneration
before release.

## Known gaps and non-claims

- No unbounded attacker-versus-honest liveness theorem was established.
- No stateful recursive adversarial-arrival model was built.
- The concurrent-child test is a fixed balanced-arrival characterization.
- The one-level floor-half-running-clock invariant is not a multi-level delay
  proof.
- No non-Ethereum time-source conformance was performed.
- No node agreement with the selected two-level table was tested.
- No conclusion was reached on halt and exception state-transition semantics.
- No comprehensive `winLeafMatch` gas ceiling was retained.
- No real-node, Lua, or deployment-artifact conformance was run.
- Coverage branch totals are investigative, not semantic assurance.

## Stop rule

The test campaign is complete for this branch once the final contract-only gate
and documentation consistency check pass. Further tests should be added only
when they protect a new production change, reproduce a new finding, or attack
one of the explicit deferred questions above as its own scoped task. More fixed
lifecycle traces or higher headline counts, by themselves, would now have
diminishing audit value.

The final `test-disputes` gate passed all 231 tests on release-calibration
candidate `7565ec29797388a0108a267ba0b4676d09b63837`, whose Solidity and test tree
ends at `ac3bea0c5057702e5778b3ea00086bfc31cc68ea`. The documentation consistency
checks also passed. This satisfies the stop rule and closes the campaign. The
simplification batch and its coverage follow-up reopened the closed campaign
under this rule's own terms: each added test protects a new production change or
pins a behavior the follow-up established, and this revision restores the report
through the current tested contract and test tree.
