# PRT contracts: Cyber Verification review record

Status: completed 2026-10-14; internal engineering review, not a
third-party assurance report. Findings and leads are in FINDINGS.md, the
brief that seeded the work in THREAT-MODEL.md, and the validator-side
composition contract in HONEST-NODE-CONTRACT.md. The executable evidence
lives in the owning suites under `prt/contracts/test/`; the evidence table
below and FINDINGS.md name each file.

The code is the source of truth. This record describes the campaign's
revision; later changes are not covered.

## Scope

In scope: everything under `prt/contracts/src`, including the adapter
`CartesiStateTransition.sol` and its composition with `Tournament`, the
factory, the canonical provider, `ClockBudgets`, `ArbitrationConstants`, and
the deployment script's conversion of wall-clock budgets to blocks. Assumed
correct: the `machine/step` library and the emulator. Deferred to later
campaigns: `DaveConsensus` and the data provider, the off-chain clients.

## Method

Three phases, each a workflow of subagents with the session model reading,
judging and writing between them.

1. Threat model. One full read of the boundary, the four living documents
   and the two prior review records, producing THREAT-MODEL.md: the three
   properties as an attacker sees them, a one-page mechanism, the
   known-closed baseline, the reader's own conclusions marked as targets,
   and twenty attack dimensions.
2. Finder swarm. One finder per dimension, then two more rounds in which
   each dimension was replayed from an adversary role (a dishonest claimant
   who knows the honest tree, a censoring builder, a stakeless griefer, a
   Sybil swarm), with every earlier title excluded. Candidates were
   clustered, then each cluster was judged by three independent lenses:
   does the trace execute on the code, is it inside the model at a real
   price, and is it already covered by a prior record or a passing test.
   A candidate was killed by the code lens, filed as known by the prior
   lens, or kept. 113 agents, 28 candidates, 17 clusters, 6 kept.
3. Deep modalities, from a completeness critic's list: an adversarial
   honest-survival search (the R19 plan), adapter composition against an
   independent coordinate model, mutation testing, the deferred STF status
   discard, a NatSpec and normative-prose sweep, exploit-class transfer from
   other fraud-proof systems, deployment and chain-assumption hygiene, and
   the honest-node composition contract; plus one FFI agent composing the
   real adapter at the capacity extremes. Each ran in an isolated copy of
   the contracts project. 53 agents, 15 candidates, 4 kept, all documentary
   or test gaps.

The finding gate: a candidate became a finding only when an exploit test
on the current tree passed while the defect was present. When the campaign
closed, its tests were placed in their owning suites and renamed by what
they establish: `testTrace...` for a priced schedule, `testRefuted...` for a
refuted attempt, `testRegression...` for the fixed finding. Everything else
is a lead with its trace, or a refutation with its sharpest attempt kept
as a `testRefuted`.

## Results

One finding, F-01: at a one-level table the root allowance `C + G` is one
inclusion short, because the root join's latency is deducted with no
discount and a response must fit its in-flight latency before the `G`
discount applies. Reproduced at `C = 0` and `C > 0`. No deployable table is
affected; the fix is one `G` in the formula or rejecting single-level
tables. Low severity.

Sixteen leads, L-01 to L-16: a missing root build term whose trigger is in
`DaveConsensus`; the price of delay and of post-closure honest work per
Sybil bond on the canonical table; CF-01 as the binding margin of the
honest-survival argument; documentation and NatSpec mismatches; test gaps
now pinned; deployment hygiene; and the experimental L2 rows priced under a
censoring sequencer.

No in-model schedule was found that eliminates the honest commitment or
lets a wrong final state win on the canonical or devnet tables. The
honest-survival invariant at exactly-formula budgets, in both orientations
and at `C` of 0, 2 and 5, found none in 6 x 256 runs of depth 250, and its
mutation control fails as it should. The adapter receives exactly the
predecessor state and the output-leaf counter the documentation defines, in
every descent tried and at every boundary of the 92-bit epoch, with the
real adapter and real proofs at the extremes. The deferred STF-TODO-001 has
a written discharge argument with synthetic pins. Known Merkle and
fraud-proof exploit classes do not apply.

## Assurance evidence and its limits

| Evidence | Establishes | Does not establish |
| --- | --- | --- |
| `HonestSurvivalInvariant.t.sol` | No honest elimination under `C` in the searched two-level box, both orientations, formula budgets; the refill is load-bearing | Three or more levels, the node's own scheduling, optimized honest latencies, refunds |
| `AdapterComposition.t.sol`, `TournamentStateTransitionExtremesFfi.t.sol` | The `(machineState, counter)` pair and the child descriptors match the documented coordinates in every descent and at every epoch boundary; the real adapter accepts real proofs there | A real parent sealed through the canonical root at stride 38, a contiguous last-slot epoch |
| `StfStatusDiscard.t.sol` | The status discard cannot change the root on honest paths; a status-gated adapter would reject honest halting steps | Emulator-backed vectors for the halting ustep of active and idle spans and for the off-path classes |
| Mutation campaign | 67 of 72 single-site mutants of the clock, match, commitment, gate and dispatch logic are killed by the dispute suite; the three proof-length survivors and the nine thinly killed mutants have deterministic pins in their owning suites since the campaign closed | Higher-order mutants |
| `MerkleDomainSeparation.t.sol` | The four sharpest tree-shape and second-preimage attempts fail | Hash collisions |
| NatSpec sweep | Four NatSpec mismatches found and corrected in the sources; the normative prose of dispute-game.md holds; the sweep's pins duplicated existing boundaries and were not kept | Claims resting on `machine/step` or `DaveConsensus` |
| `CanonicalPathCensorship.t.sol`, `DeploymentChainBudgets.t.sol`, `DeploymentsImport.t.sol`, `FactoryNonceReorg.t.sol` | Priced L2 censorship, exact conversions, import behavior, reorg-consistent identity | Live L2 forced-inclusion parameters |
| HONEST-NODE-CONTRACT.md, `HonestNodeObligations.t.sol` | 31 validator requirements with consequences and citations, six pinned | Node behavior itself |

## Follow-ups

Contracts:

- Fix F-01 through the contract-change gate: one `G` in
  `ClockBudgets.maxAllowance` with the rule stated, or reject
  `levels == 1`; update the validator's bound and its pins.
- NatSpec and prose fixes from L-04, L-05, L-13; the threat-model scoping
  of "acting for the honest side only helps".

Documentation:

- dimensioning.md: the pre-built-root assumption (L-01), the in-flight
  latency rule (F-01), the measured worst instruction (L-12), the slot-time
  dependency (L-09), the L2 numbers beside the experimental statement
  (L-16).
- prt-delay-bound.md and dispute-game.md: the per-delegation floor and the
  two-level price (L-02), the post-closure work regime (L-03), the shared
  proof-plus-fallback budget (L-11).
- audit-readiness.md: the deployment runbook lines (L-08, L-15); the
  compiler re-evaluation at the freeze.

Later campaigns:

- DaveConsensus: input volume against the root window (L-01), the provider
  contract the adapter assumes (zero exactly when no input, stable answers
  for the dispute's life).
- Node: the composition contract in HONEST-NODE-CONTRACT.md, the revert
  protecting endpoint as a requirement (L-06), in-flight supersession
  (L-10), the two planner leads recorded there.

## Validation record

Run from the campaign worktree under the nix devshell, Foundry 1.5.1,
solc 0.8.30, via-IR, Prague:

```sh
just prt-contracts::test-disputes
just prt-contracts::test-stf
just rollups-contracts::test
```

The dispute suite passed 360 tests before the campaign and the FFI suite 29;
with the campaign's files in their owning suites the FFI gate passes 42,
the dispute suite 447, and the rollups suite 14 once its allowance fixture
followed the new formula.
Where each file went is in the campaign log of FINDINGS.md. Raw swarm output, journals and
logs are kept out of tree in the campaign's scratch record. Per the
repository rule, no commit hash is written here; the tree hash of the
reviewed state should be recorded by whoever commits it.
