# Contracts audit, round two (2026-11-10)

Status: PRT phase complete 2026-11-10. The settlement phase
(`cartesi-rollups/contracts`) has a first read and a stateful model; the
factory and a re-read of the upstream seam wait for the rollups-contracts
alpha.11 adoption. This is internal engineering work, not a third-party
audit, and it describes the tree it ran on and nothing later.

Reviewed state: tree `2df1a3bbdfa7ac3bb4c7b62d00429cb60693511f`, main on
2026-11-10. Baseline before the review, all green: PRT disputes 447 tests,
rollups contracts 19, gas witnesses 22 + 13, state-transition FFI 42.

## Scope

In scope: everything under `prt/contracts/src` and `prt/contracts/script`,
and `cartesi-rollups/contracts/src`; the adapter
`CartesiStateTransition.sol` and its composition with `Tournament`; the
upstream `Application` and `InputBox` (rollups-contracts 3.0.0-alpha.10) as
a seam only, that is, what the three views of `DaveConsensus` authorize
(`isOutputsMerkleRootValid`, `getLastFinalizedMachineMerkleRoot`,
`wasInputFinalized`).

Out of scope: the internals of `machine/step`, the rest of
rollups-contracts, the node and the clients.

## Method

The 2026-10-13 campaign ran finder and refuter fleets and judged them
centrally. This round put the reading itself on the strongest model:

1. One full read of the PRT boundary by the orchestrating session: every
   file under `prt/contracts/src`, the function and standing documentation
   of `ITournament.sol`, and both deployment scripts.
2. Three independent reviewers on the same model, each in a fresh context
   holding the whole PRT tree, one lens each: clocks and liveness, structure
   and result selection, value flows. Their protocol: code only first, with
   the blind result written down before anything else; then the living
   documents; then the tests. `docs/reviews/`, `docs/plans/` and
   `docs/todo.md` were off limits to them, so the sample is not anchored on
   the October record. One reviewer reported that `AGENTS.md` files were
   injected into its context during the blind phase.
3. Reviewers wrote and ran tests only in private copies of `prt/contracts`.
   The orchestrator re-ran every reviewer test in a separate copy, read the
   trace behind N-01 line by line, and checked each lead against the code
   and the living documents.
4. Deduplication against the October record happened last.

No fleet ran.

## Result

No defect was found. No call sequence was found by which a wrong commitment
beats a correct one that acts within the documented bounds, by which a
foreign, stale or repeated child result is applied, by which a reported
root winner changes, or by which more value leaves a tournament than
entered it. Four independent reads converge on that and on the same short
list of leads.

The strongest item, N-01, is not new as a mechanism. It sharpens the
documented leaf handover (CF-01) with an executed trace at the deployed
two-level formula, a price, and a contract-level option.

## Leads

Ranked safety above liveness above resource; within a property, cheaper
triggers first. A lead is a candidate that breaks no property on a
deployable configuration under the documented assumptions.

### N-01: the leaf handover repeats after closure (documented CF-01, sharpened)

Property: result-selection safety when `C` is small; otherwise a drain on
`C` that needs no censorship. Documented as an accepted limitation
(dispute-game.md, "Resolution and winner re-entry"; dimensioning.md,
"Honest survival under the budgets"), where the safety statement requires
a leaf proof and its fallback timeout claim to land within one `G` of the
seal together.

Executed trace, two levels at `C + 2G + (L - 1)(T + 2G)` with `C = 0`,
`G = 10`, `T = 20`: the root reports a wrong `ROOT_WINNER` while every
honest action lands strictly inside its own bound (advance, proof and
claim 9 blocks each, child join 29). Every adversary call is legal and
every Sybil proof is of a correct transition. The honest leaf clock goes
22, then 14, then expires. A control with the claim one block after the
opponent's deadline survives both handovers.

What the trace adds to the documents:

- Occurrences are not confined to Sybils that pair just before closure. A
  Sybil that joins a leaf tournament in its last `G - 1` blocks holds a
  clock at or below `G - 1`, which in-time responses never reduce. It pairs
  as the paused side under a dangling full-clock Sybil and stays parked
  there. A leaf proof that ends the holder's match releases it after
  closure, and it re-pairs with the dangling correct commitment inside that
  call with its clock intact.
- Price: one leaf bond for the first occurrence in a leaf tournament, three
  for each further one (the parked Sybil, its holder, and the holder's
  partner). The trace used two root bonds and four leaf bonds.
- After the October reserve fix the correct leaf clock is `2G + 2` in the
  worst case, so at `C = 0` two occurrences suffice.
- Planning the claim instead of the proof does not remove the worst case.
  The claim cannot land before the opponent's deadline `seal + r` and is
  charged from the seal, so it costs `r + d2 - G` for a claim latency `d2`.
  The cost is zero exactly when proof and claim fit one `G` together.
- Canonical estimate, derived and not simulated: each occurrence costs at
  most `G - 2 = 23` blocks of `C`; exhausting the one-week `C` takes about
  2,200 occurrences, about 6,600 leaf bonds (0.513 ETH each, about 3,400
  ETH), across three to four forced delegations. The reviewer estimates a
  node at the documented proof-preparation bound (within `G / 2`) and a
  30 s poll lands proof and claim in 20 to 22 blocks of the 25.

A contract-level option exists, which dispute-game.md records as judged
not worth revising the disjoint verbs: let `winLeafMatch` succeed whenever
the proven side's own clock is live, even after the other side expired.
The winner and the clock charge are then those of the timeout win the
classifier already selects (`pauseWinnerAt` with a zero deferred charge in
both paths), and an expired side still cannot be proven for. The handover
disappears, per-action latency under `G` suffices, and the node needs no
predictive planning. The cost is the invariant "a leaf proof and a timeout
cleanup are never simultaneously valid", which becomes "they select the
same winner with the same charge", and a proof may then be used where a
cheaper claim would do, inside the match's terminal reserve.

Decision (2026-11-10): the limitation stays. Each occurrence charges the
correct side only its joint lateness beyond one `G`, the adversary pays at
least a leaf bond for it, and a guard would change the trust boundary for a
loss priced above the reference price. The argument, the three guards
considered and what would reopen it are in dispute-game.md, "Why the
handover stays". It is reasoning to re-run, not a ruling.

### N-02: the pinned compiler is inside a newly disclosed optimizer bug's range

Both projects pin solc 0.8.30 with via-IR and the optimizer. The Yul
optimizer bug `YulOptimizerKnowledgeBaseStaleBookkeeping` (announced
2026-10-22, affects 0.8.19 to 0.8.37, fixed in 0.8.38) can replace a load
with a stale value or remove a needed store. The announcement rates it low
severity and very unlikely, says any optimized via-IR code may be affected,
and says the trigger cannot be checked from Solidity or Yul source. The
other seven known 0.8.30 entries were re-checked against the compiled-in
sources (PRT, rollups, `machine/step`, the rollups-contracts libraries)
and do not apply: no named-parameter error construction, no `delete` on
the one transient variable, no custom storage layout, no recursion found.

Evidence: compiled with solc 0.8.38, every contract gate passes (disputes
447, gas witnesses 22 + 13, state-transition FFI 42, rollups 19).
Production bytecode differs between the two compilers, as expected across
eight releases; that says nothing about whether the 0.8.30 build was
affected. Nothing is deployed for production, so moving the pin answers
the question. The pin also lives in
`cartesi-rollups/contracts/script/measure-prt-gas.sh`. Tracked before this
round in todo.md and plans/audit-readiness.md; the fixed compiler now
exists.

### N-03: `instantiateInner` checks neither level nor allowance

Two reviewers reached this independently. The factory's `instantiateInner`
is permissionless, as documented, and bounds none of its arguments.

- With `_level == 0` it creates a root-kind clone with a nonzero nested
  dispute, a caller-chosen allowance and no `TournamentCreated` event.
  `ITournament.sol` says a level-0 tournament's nested dispute is zero, and
  `ITournamentFactory.sol` presents the event as the record of a root's
  creation. No parent and no consensus consumes such a clone.
- With a chosen allowance, the twin of October's L-15 (a clone created at
  a cached child address after a reorg) never closes, so a bond joined
  there is locked for good where L-15's twin returned it at closure. Needs
  a reorg, or a client that joins an address it has not re-read after
  finality; the node joins from finalized state.

Rejecting `_level == 0` and an allowance above the root row's
`maxAllowance` would remove both. Every legitimate call satisfies both
bounds: a parent passes its level plus one, and no clock exceeds the root
allowance. The row the factory already loads carries `maxAllowance`, so the
second check needs no extra call.

Decision (2026-11-10): document, no code. The node finds roots from the
consensus's `EpochSealed` and children from their parent's
`NewInnerTournament`, and never reads factory events (checked in
`cartesi-rollups/node/src/blockchain_reader` and
`cartesi-rollups/node/src/tournament/reader.rs`), so an orphan is invisible
to it. New machinery for clients that do otherwise was judged not worth its
code; the interface comments and dispute-game.md now say what an orphan
can look like.

### N-04: one-transaction provability is a safety assumption

A sealed leaf with no proof is decided by clock length, and a Sybil that
joins the child before the correct side holds the longer clock. So every
reachable correct transition must be provable in one transaction. The only
size-dependent transition is the input-window opening, whose proof embeds
the whole input, and an adversary can aim a divergence at it. The upstream
`CanonicalMachine.INPUT_MAX_SIZE` (64 KiB) is what keeps the largest
witness near 30% of the per-transaction gas cap.

The coupling is pinned: the leaf gas fixture expects `InputTooLarge` at
the first size above 65,536, so `just test-prt-gas` fails if upstream
raises the cap. What is missing is wording. The security statement lists
"can obtain the inputs, machine states, and proofs" and treats admission
headroom as a gas-calibration topic; it does not say that a proof which
cannot be admitted turns the match into a clock race.

### N-05: a consumed child keeps reporting a winner, then an expired one

After `winInnerTournament` deletes the parent link, the child still
reports `INNER_WINNER` until its carryover instant and
`INNER_ELIMINABLE_WINNER_EXPIRED` afterwards, although both parent verbs
now revert with `MatchDoesNotExist`. No on-chain effect. A client that
schedules from the child's standing alone would send reverting calls or
read a settled pair as eliminated. Neither `ITournament.sol` nor
dispute-game.md says so.

### N-06: the refund slack list omits storage-clearing credits

Refunds meter a `gasleft()` delta, which does not net EIP-3529 credits.
Measured on the retained witnesses, any plain account is refunded 17,500
to 35,700 units above its receipt cost on every match-deleting action,
with no batching or block building. Bounded by the action cap; the reserve
is unaffected. prt-refund-accounting.md names storage refunds as something
that changes private cost, but its enumerated "remaining slack" omits them.

The same probe gives the correct side's unrefunded cost: 12,280 units per
advance, 30,707 per leaf seal, 38,927 per inner seal, and 181,000 to
300,000 per join; roughly 0.9M to 1.1M units per forced root-plus-child
match before the leaf proof.

### N-07: "within G" is strict, and a one-level table has no slack otherwise

dimensioning.md says every bound is strict; the security statement in
dispute-game.md says "within `G`". At one level, a join and a response at
exactly `G` plus exactly `C` of censorship lose by one block. With strict
latencies the minimum slack on a running correct clock is
`(L - 1)(G + 1) + 2` blocks, observed exactly at one to four levels; the
canonical two-level table keeps a margin of `G` under either reading.
`ClockBudgets` floors seconds to blocks and adds no boundary slack.

### N-08: forced inclusion on the OP Stack rows probably earns no refund

Not executed. A deposit transaction is believed to report a zero gas
price, which makes the refund zero for every action sent that way while
the parent-chain data cost is paid in full. Inside the experimental-row
non-claim; one devnet transaction would settle it.

### N-09: `fineLeaves` makes claim families 2n and 2n + 1 identical

`TournamentDriver.fineLeaves` builds a leaf as
`(family << 8) | (0x100 + i)`, so the low family bit is always set.
Existing tests avoid the collision (family 1 against 2, 4 and `2 + 2k`),
but nothing says so, and a new test that picks adjacent families builds
the same commitment twice.

### Restated, already tracked

- Table shape is validated off-chain only, and the canonical provider
  accepts a zero response budget (dispute-game.md; todo.md).
- The root join has no build term, the closure floor of a delegation is
  the pair envelope, and the delay bound is a non-claim (October L-01,
  L-02, L-03).
- Base's 200 ms blocks against a 2,000 ms registry row (experimental).

## Worth stating: an invariant the code keeps and the documents omit

For every live commitment, its remaining allowance plus the instant it was
last paused, or its run start, is at least its tournament's closure. It
holds at the join, every response charges at most the elapsed time, and a
child return stays within an envelope that satisfies it. Consequences: no
clock expires before its tournament closes, no timeout fires while joins
are open, and a child never closes before its parent.

## Evidence produced

All of it passed on the reviewed tree in the reviewers' private copies.
It was then curated into the owning suites on the audit branch, under
`prt/contracts/test`: renamed to the testing guide's conventions, the
receipt probe and two leftover debugging tests dropped, every environment
knob removed, and the multi-level search restructured to one schedule per
fuzz run so that it passes under forge's default gas limit. The dispute
gate grew from 447 tests in 86 suites to 490 in 97.

| Evidence | File |
| --- | --- |
| Reserve and conservation with every refund cap binding at both levels, including the tightest case where every match consumes its whole reserve | `accounting/ReserveAtRefundCaps.t.sol` |
| The same identities after every step of random schedules, at one level and at two levels with real leaf children | `accounting/ProductionReserveSingleLevel.t.sol`, `accounting/ProductionReserveTwoLevel.t.sol` |
| Lock release on every recovery return path; a refund that a low gas limit cannot silently starve; a clone that rejects plain value | `accounting/PaymentBoundaries.t.sol` |
| N-03: the level-zero orphan, the two orphans that lock a bond, a parent that never calls or refunds an unrecorded child, and the provider's panic outside the table | `config/OrphanClones.t.sol`, `config/CanonicalTournamentGeometry.t.sol` |
| N-01: the wrong-winner trace at the formula with `C = 0`, and its control | `properties/LeafHandover.t.sol` |
| N-07: what an inclusive reading of "within `G`" costs at one and two levels | `properties/InclusiveLatencyBoundary.t.sol` |
| N-04: the one-block fast-forward to the leaf race, refuted, and an unproven race decided by the clocks | `properties/LeafRaceFastForward.t.sol` |
| Honest survival at one to four levels, the October handler generalized, with controls that lose where the closed form predicts | `properties/MultiLevelHonestSurvival.t.sol` |
| The model-based adversarial walk over two- and three-level clone trees: any caller, any verb, any clone, at boundary instants, against a model written from the code | `properties/AdversarialWalk.t.sol` |
| The defended walk, inclusive latencies at the formula, with a control one inclusion below it | `properties/DefendedWalk.t.sol` |
| N-09: one helper that keeps claim family and leaf index apart | `fixtures/TournamentDriver.sol` |

Campaigns during the review, on the reviewed tree:

- Reserve: 3,000 runs at one level and 2,500 at two.
- Survival: 14,400 schedules without a loss (seeds 1 to 300 for each of
  eight tables, three censorship budgets and two orientations; heights 1
  to 3, `G = 3`, `T = 6`, `C <= 5`). The clock and standing invariants
  added later ran at 80 to 100 seeds per configuration.
- Adversarial walk: 10,001 runs, about 43 calls each, and the defended
  walk 14,001, both under `FOUNDRY_FUZZ_SEED=0x5172756374757265`.
- Mutation: of 21 single-line mutants of `src`, 20 fail the adversarial
  walk; the survivor only drops an assert.

Campaigns on the promoted tests, on the audit branch with solc 0.8.38,
all passing under `FOUNDRY_FUZZ_SEED=0x2026111001`: 3,000 runs of each of
the eight survival fuzz tests (one run is one schedule), and 4,000 runs
of each walk and of each reserve fuzz. The promoted search stops a
schedule 24 moves after its root finishes, where the review's loop ran
its 300 to 500 moves out; after a finished root only time passes.

Not covered: the receipt-level cost of `winLeafMatch` through the real
adapter; canonical heights in any search; and the per-action reading of
the leaf resolution, since both survival searches resolve a sealed leaf in
one landing that picks the verb, the documented joint bound.

## Settlement boundary: first read and a stateful model

`DaveConsensus` and `DaveAppFactory` were read in full, and the upstream
`Application` paths they serve were read against alpha.10. Upstream main
changes `Application.sol` by one line since alpha.10, so these should
survive the bump; re-check the diff then.

- Acceptance settles the snapshot staging took and never re-reads the
  tournament, so settlement safety is exactly the finality of
  `ROOT_WINNER`. That holds by reading, by the lifecycle invariant at one
  level, and by the adversarial walk above at two and three.
- Refuted on reading the seam: inputs cannot be added before the
  application exists (`InputBox.addInput` reverts for an address without
  code), so epoch 0 seals empty through the factory; and a zero
  last-finalized root is the upstream convention for "nothing finalized",
  mapped to the template hash.
- After foreclosure the partition is consistent: inputs below the sealed
  epoch's lower bound are in the last finalized state, the rest are
  refundable, never both.
- The outputs proof compiles against the bundled step 0.15.0 and the
  tournament against 0.16.0. Their generated constants differ only in the
  architecture identifier and the pristine uarch hash.
- Coverage on the reviewed tree: one scenario test exercises foreclosure
  gating on all four mutators, the staging period and the sentry error
  paths. There was no stateful test, and `TournamentResultNotStaged` and
  `InputHashMismatch` were not exercised by selector.

### The stateful model

Added on the audit branch, under `cartesi-rollups/contracts/test`:

- `DaveConsensusLifecycleHandler.sol` and `DaveConsensusLifecycle.t.sol`:
  a model of one application's settlement over the production InputBox,
  Application, factory, consensus and a real one-level root tournament.
  The handler keeps its own ghost of epochs, inputs, sentry slots and
  claims, the staged snapshot, settled values and each root's clocks, and
  never reads a consensus getter to decide an expectation. A call the
  model allows must succeed, a call it forbids must revert with the exact
  error, and every view is compared with the model after each step. It
  runs under forge's invariant engine (three sentries, and none), as
  seeded walks at three sentry configurations that must reach every
  settlement operation, every root outcome and every refusal the model
  names outside the dispute moves, and as fifteen directed schedules.
  Acceptance also runs while the retiring tournament's standing is
  replaced by another winner, a failed root, or a revert: the staged
  snapshot settles regardless.
- `DaveConsensusErrorPaths.t.sol`: `TournamentResultNotStaged` in every
  state that has nothing staged, and `InputHashMismatch` for every way the
  bytes can differ, with the padding rule past the span.

The rollups gate grew from 19 tests in 5 suites to 61 in 13.

What the model does not own: the dispute itself, driven only as far as a
root result needs; machine validity proofs, which come from the upstream
emulator model rather than a machine; and a backlog beyond one epoch,
written into the InputBox length slot, so those inputs have no bytes.

Mutation: 55 single-statement mutants of `DaveConsensus.sol`. The new
suites fail under 52. The other three (the ERC-165 advertisement, the
constructor's sentry validation, the application-address check of
`isOutputsMerkleRootValid`) are outside what the model claims and fail the
older suites. Eight of the 55 pass the suites that existed before, among
them input bytes not checked against the InputBox hash, acceptance without
a staged result, acceptance ignoring its epoch argument, and a claim
bitmap shared by all epochs. Most rows ran one edit before the final test
files; five were re-run on the final files with the same verdicts (the
snapshot replaced by the current standing, zero sentries counted as
unanimous, unchecked input bytes, the shared claim bitmap, and the
unchecked position of S-02).

Campaigns, all passing: forge's invariant engine at 1,500 runs of depth
256 under seeds 20261110 and 7 (384,000 calls per configuration and seed,
no revert); seeded walks of 3,000 by 256 steps, 6,000 by 128, and 1,500
by 256, at each of the three configurations; and, once the walk became a
fuzz test, 4,000 runs per configuration under
`FOUNDRY_FUZZ_SEED=0x2026111001`.

Two leads came out of it, neither a defect.

### S-01: the readiness views do not reflect foreclosure

`canStageTournamentResult` and `canAcceptStagedTournamentResult` read the
live tournament and the block number, foreclosed or not. After foreclosure
`isClaimStagingPeriodOver` still turns true while the call it advertises
reverts with `ApplicationForeclosed`. epoch-lifecycle.md documents the
freeze and the node reads foreclosure separately; the interface comments
told validators when to call without saying so, and now do.

### S-02: an index whose position overflows panics instead of padding

`provideMerkleRootOfInput` adds the epoch's lower bound to the index with
checked arithmetic, so an index above `2^256 - 1` minus the lower bound
reverts with an arithmetic panic where the padding rule would answer zero.
A tournament cannot reach it: `CartesiStateTransition` rejects a counter
outside the epoch and derives a 24-bit index. The sum must stay checked,
since a wrapped position would land on a settled input and bind its bytes;
the tests pin that an index of this kind never binds. Recorded in the
directory's agent guidance; no code change.

## Follow-ups

Landed on the audit branch after this record was first written:

- N-01 and N-03, decided above, as documentation: the argument in
  dispute-game.md and the factory and tournament interface comments.
- N-02: both projects and the gas script pin solc 0.8.38, and every gate
  passes on it. Every production bytecode moved; the ABI and storage
  layouts of `Tournament` and the factory did not. The pinned Foundry
  cannot download this compiler on Linux arm64, which the release build
  for that platform showed; the tool setup now installs Solidity's
  official build there by its checksum (build-system.md).
- The wording for N-04, N-05, N-06, N-07 and the clock-floor invariant, in
  dispute-game.md, prt-refund-accounting.md and `ITournament.sol`.
- The fixture of N-09.
- The evidence, as listed under "Evidence produced".
- The settlement model and the two error paths, with the wording for S-01
  and S-02.

Open:

- One gas recalibration at the end of the cycle, after every bytecode
  change has landed (todo.md).
- N-08: one devnet transaction.
- Settlement phase after the alpha.11 adoption: the factory's reserved
  CREATE2, and a re-read of the upstream diff against the model.

## Reproduction

Run inside the nix devshell. The gates are `just prt-contracts::test-disputes`,
`just rollups-contracts::test`, `just test-prt-gas` and
`just prt-contracts::test-stf`. The deeper campaigns set `FOUNDRY_FUZZ_RUNS`
and `FOUNDRY_FUZZ_SEED` as each test's contract comment shows. N-02 was
first checked with the same forge commands under `--use 0.8.38` and
artifacts outside the tree, before the pin moved. Per the repository rule
no commit hash is written here; the tree hash above identifies the reviewed
state.
