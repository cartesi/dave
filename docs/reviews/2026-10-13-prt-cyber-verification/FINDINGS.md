# PRT contracts: Cyber Verification findings

Status: campaign complete 2026-10-14; see REVIEW.md for method, evidence
and follow-ups. Scope, trust assumptions, the known-closed baseline, and the
finding gate are in THREAT-MODEL.md.

A finding is a defect reproduced by a Foundry test on the current tree,
passing while the defect is present; the campaign named these
`testExploit...`, and they were renamed `testTrace...` or `testRegression...`
when placed in their owning suites. A lead is a candidate that survived refutation without breaking
a property on a deployable configuration: a priced regime the docs state
differently, a system-level gap whose trigger is outside this scope, a
documentation mismatch, or a test gap. Leads with a `testTrace` or
`testRefuted` trace name it.

Severity: safety above liveness above resource; within a property, cheaper
triggers rank higher. Each entry names the property, the trigger price, the
reproduction, and what the honest party must fail to do.

## Findings

### F-01: the single-level root allowance is one inclusion short (low)

Property: result-selection safety under the documented model, for a
one-level table only. Trigger: one Sybil root bond, no censorship at
`C = 0`, exactly `C` otherwise; the honest party fails nothing outside the
documented latencies.

`ClockBudgets.maxAllowance(model, 1)` is `C + G`. The root join deducts its
own latency `j0` and earns no discount. A response is accepted only while
`elapsed < balance`, and the `G` discount applies after acceptance. The
honest clock must therefore hold `j0 + l + c` at once, with `j0 < G` and
`l < G` each inside the documented bounds. At `C = 0`, any `j0 + l >= G`
eliminates the honest commitment, and the Sybil's wrong final state wins
the root. At `L >= 2` the `(L - 1)(T + 2G)` reserve carries the in-flight
latency, since the pending delegation's propagation inclusion is unspent
while the honest party plays; the control test survives the same worst
latencies with a margin.

Reproduction: `test/config/RootAllowanceReserve.t.sol`,
`testTraceOneLevelAllowanceWithoutReserveZeroCensorship` and
`testTraceOneLevelAllowanceWithoutReserveFullCensorship`, on `SmallSingleLevelTournament`
at `G = 5`. Control: `test/config/RootAllowanceReserve.t.sol`.

Exposure: no deployable configuration. The canonical table has two levels,
the devnet table three, and the node refuses a single-level table because
its root stride must lie between one big cycle and one input window. The
defect lives in the formula and its pins: `ClockBudgets.maxAllowance`,
`testSingleLevelAllowanceHasNoRefill`, the validator's lower bound
`G + (L - 1)(T + 2G)`, and dimensioning.md's rule that every honest action
gets one inclusion, which omits that the balance must also hold the latency
of the action in flight.

Fix: one in-flight inclusion added to the allowance,
`C + 2G + (L - 1)(T + 2G)`, in `ClockBudgets.maxAllowance`, the validator's
bound, their pins, and the documents, on this branch after the campaign
closed. The cost at `L >= 2` is five minutes on a week. The former budget is
kept as a lead trace in the same test file, and the regression drives the
same schedule through the corrected formula. The shortfall is a one-time
reserve, not a per-Sybil drain: once a response lands its latency is
forgiven and the balance returns to its level before the response, so the
reserve is reused at every action. The per-Sybil charge of this family is
CF-01's handover, recorded as L-11.

## Leads

### L-01: the root join window has no build term (system level)

The root allowance `C + G + (L - 1)(T + 2G)` assumes the level-0 commitment
exists when the root is created. The input author is untrusted, so an
epoch's total compute `N * P` is adversarial even when every input respects
the per-input compute contract. Inputs placed before the predictable
permissionless acceptance block make the honest root join miss closure at
about `N = (C + T + 2G - finality) / P`: roughly 89,000 inputs at the default
snapshot gap, about 4,000 at gap 1, for about 1.2e8 to 2.7e9 gas of InputBox
calls, far below the 5e11-gas flood the docs price. A closed root with one
Sybil dangling is `ROOT_WINNER` with a wrong final state. The trigger is
`DaveConsensus` sealing with no input cap or minimum notice, deferred to that
campaign; guardian foreclosure during staging is the only backstop. In scope
here: `ClockBudgets` and dimensioning.md should state the pre-built-root
assumption and price input volume against it.

### L-02: delay per root bond on the canonical table

On `[38, 0] / [54, 38]` at Ethereum budgets, two root bonds and no child
bonds buy about `3A + 52G` of extra settlement, 21.5 days on top of 7.1,
with no censorship and the honest party fully responsive. A child's closure
floor is `E = max(r1, r2)`, the honest side's own preserved remainder
whatever the Sybil spent, the refill restores `r_H` so the floor repeats,
and the root's dangling slot holds the second Sybil's full clock for free. A
Sybil that joins `G + 1` blocks before closure still buys about `A`. This
sits inside the delay non-claim and the accepted vandalism limitation; the
documented two-level attack shape omits the per-delegation floor and is
about twice optimistic at small populations. Fix is documentary, in
prt-delay-bound.md and the vandalism paragraph of dispute-game.md. Trace:
`test/properties/DelayPerRootBond.t.sol`.

### L-03: the linear honest-work regime runs after closure

dispute-game.md says only the claims that fit the join window meet the
survivor one by one and later claims add matches logarithmically. Sybil
pairs formed inside the window can burn their clocks together and release
their survivors one at a time after closure; a Sybil-versus-Sybil timeout
re-pairs its survivor with the dangling honest commitment inside the same
call. The regime is bounded by settlement, about
`(A + (h - 2)G) / ((h / 2) delta + G + 1)` honest matches at two root
bonds each: on the canonical root, about 988 sequential honest matches at
one-block responses, 75 at `delta = G`, in roughly one week after closure.
Delay and clocks are unchanged and every honest action is refunded within
its cap. Fix is documentary; the count is a sizing input for node throughput
and provider capacity. Trace: `test/properties/StaggeredReleaseWork.t.sol`.

### L-04: `tryRecoveringBond` NatSpec on the non-root arm

The implementation NatSpec says a child's winner is the one the parent will
use. Recovery pays any finished child's dangling claimer, including one whose
carryover window expired and whom the parent eliminated. The child's own
reserve pays it, so no property breaks and the interface NatSpec is right;
reword the implementation comment. Trace:
`test/accounting/TerminalRecovery.t.sol`, `testExpiredChildWinnerStillRecovers`.

### L-05: `CommitmentStandingView.claimer` is zeroed on every elimination

The interface NatSpec names terminal recovery as the event that zeroes
`claimer`; `deleteMatch` zeroes the claimer of every eliminated commitment.
An observer reading `joined && claimer == 0` as "recovered winner"
misclassifies every loser with a paused clock. Wording fix in
`ITournament.sol` and dispute-game.md.

### L-06: identical-copy front-running costs the honest node its reverted gas

Every progress action is permissionless, so an adversary who orders
transactions can land an identical copy of each honest action first. Protocol
state is unaffected and the copy's refund comes from the pool, but the honest
copy reverts at the honest node's expense: up to the EIP-7623 floor of a
maximum-input leaf proof, about 3.76M gas, 0.19 ETH at 50 gwei, 37% of a leaf
bond, with no extra bond for the adversary. node-architecture.md documents
the cost for honest-versus-honest races and recommends a revert-protecting
submit endpoint; the adversarial case should make that endpoint an operating
requirement. The campaign's trace was not kept: its two assertions are
pinned by existing suites and its numbers are above.

### L-07: a third-party seal removes a seal-timing overlap

A height-one responder may seal for free up to `G` blocks after its turn
opens. A strategy that starts building its child commitment at that point
and seals late gains up to `G` of child clock; a third party sealing at once
removes the gain. The documented strategy and the node measure `T + G` from
the seal, so nothing in budget is lost. Scope note for THREAT-MODEL.md.

### L-08: another chain's parameter set replays at its published address

Every address is CREATE2 over chain-independent initcode, so anyone can
deploy the devnet (`C = 0`) or Sepolia (`C = 8 h`) provider and factory at
their published addresses on mainnet for about 0.88M gas. A developer who
wires DaveConsensus to a wrong-chain address then runs disputes silently
with a short `C` where an empty address would have failed loudly. Inside
the trusted-wiring assumption; a line for the deployment runbook, and the
node could compare the provider's budgets with its chain's registration.

### L-09: block-number clocks under a slot-time change

Budgets are block counts pinned in an immutable provider at 12 s. An
Ethereum slot-time reduction halves `C`, `G`, and `T` with no on-chain or
node signal: `C` to 3.5 days, `T` to its 60-minute derivation floor, `G` to
150 s. Not an adversary power; a deployment-generation trigger the docs
should name. Numbers: `test/DeploymentChainBudgets.t.sol`.

### L-10: pre-empted in-flight honest actions (node)

When an adversary performs the honest party's action after the node sent its
own transaction, the node's submission lane waits out its doomed transaction
and the next action starts late. In contract terms the honest side is never
charged more than its own latency; the cost is the node's inclusion
scheduling. Generalizes CF-01's assumption; a node-campaign item: supersede
the pending transaction when intent changes.

### L-11: CF-01 is the binding margin of the honest-survival argument

At the formula budget and `C = 0`, the honest child clock after the worst
in-bound join (`T + G - 1` after the seal, following a root join at
`G - 1`) is `G + 2` blocks. A Sybil that joins the child one block before
closure with a clock of one and seals in the block it is paired forces the
proof-to-timeout handover at any honest proof latency of one block or more.
The proof and its fallback timeout claim must then land within `G + 2`
blocks in total, not within `G` each: at `G = 25`, 27 blocks for both. The
docs already state the assumption that proof plus fallback land within one
`G` of the seal; the search shows that assumption is the theorem's real
margin rather than a side case, and the operator requirement in todo.md
should be phrased as a shared budget. Trace:
`test/properties/HonestSurvivalSchedule.t.sol`.

### L-12: dimensioning.md overstates the worst instruction's uarch cost

The doc says an honest program occasionally executes the worst instruction
"near the 2^20 bound". Measured on v0.21 through the devshell's Lua module,
the heaviest instruction is `sfence.vma` at 17,595 usteps, against an
executed budget of `2^20 - 1` per big cycle (the closing slot is always a
fixed point). The headroom is about 60x in the safe direction. It matters
for closing STF-TODO-001: uarch cycle overflow is unreachable on honest
paths by a wide margin, and the doc should cite the measurement. Script in
the campaign scratch record; re-measure under the validator-grade run.

### L-13: NatSpec and documentation wording

From the systematic sweep of `ITournament.sol`, the implementation NatSpec,
and the normative sections of dispute-game.md. None changes behavior.
Found by the sweep and corrected in the sources; its pins duplicated
existing boundaries and were not kept. `MatchDeletionReason.TIMEOUT`
says double elimination needs both clocks to time out, but in bisection it
fires while the opponent is paused with time left; `CHILD_TOURNAMENT` omits
the expired-winner elimination; the `winner` field of
`WrongTournamentWinner` is the parent commitment, not the child's winning
root; `TournamentFailedNoWinner` is declared and never raised. Six smaller
wording leads are listed in the sweep's test comments. Also: the local name
`agreeCycle` in `winLeafMatch` is the counter of the leaf being proven.

### L-14: test gaps found by mutation and composition

Of 72 single-site mutants of the clock, match, commitment, tournament gate
and adapter dispatch logic, the dispute suite killed 67; two were
equivalent; three real survivors are all proof-length checks that do not
affect which commitment wins: `Co4` (the last-leaf proof length check in
`getRootForLastLeaf`), and `A5` and `A8` (the full-consumption checks in the
adapter's opening and closing branches), which only the FFI suite killed.
After the campaign all three got deterministic non-FFI pins in their owning
suites, `test/Commitment.t.sol` and `test/StateTransition.t.sol`, the
closing one through a synthetic step-plus-reset access log. The campaign's
driver reported nine mutants killed by a single test; re-checking showed
four of those (`M6`, `A2`, `A4`, `Tn22`) were also killed by fuzz or
invariant tests the driver's regex missed, so five were truly single-killed
(`C9`, `Ma4`, `Co5`, `A3`, `A6`). All nine now have a second deterministic
pin in their owning suites. The 2 s OP Stack rows had no conversion test
and the canonical table's extent was not tied to the step-derived adapter
span in Solidity; `DeploymentChainBudgets.t.sol` and
`AdapterComposition.t.sol` now pin both.

### L-15: deployment import and client-side identity notes

`BaseDeploymentScript`'s import fails closed on a planted duplicate name
but silently imports stale extra names and wires a lone stale factory file
when Dave's script runs without the PRT step
(`test/DeploymentsImport.t.sol`). Child clone addresses come from the
factory's shared CREATE nonce, so a one-block reorg can hand a cached
address to a byte-identical twin; on chain the parent records its child in
the creating call and rejects twins, and the node joins only from finalized
state, so this is a note for third-party client authors
(`test/config/FactoryNonceReorg.t.sol`).

### L-16: experimental L2 rows under a censoring sequencer (out of model)

With forced inclusion of about 24 h per transaction on Arbitrum One and 12 h
on OP Mainnet, charged against one `C` of a week, a correct commitment on the
canonical root-to-leaf path (50 honest actions) lands 7 and 14 actions
respectively before losing; the 8-hour testnets cannot land the root join.
The uniform per-action latency the root segment survives is about 6.2 h.
These rows are documented as experimental; put the numbers beside that
statement. The forced-inclusion parameters are leads to verify.
Trace: `test/properties/CanonicalPathCensorship.t.sol`.

## Refuted candidates worth remembering

- Mandatory child joins are unrefunded honest work: true and documented;
  the price per Sybil bond already counts it.
- Orphan clones with crafted arguments reach asserts: a documented
  non-claim; no parent or consensus trusts them.
- Merkle domain separation: `Tree.join` and both commitment proof walks hash
  64 bytes with no prefix, and `Match.hashFromId(one, two)` equals
  `Tree.join(one, two)`, but no node is ever compared or proven at a depth
  other than its own, both proof walks require exactly `height` siblings,
  and the two hashes live in separate mappings. Four sharpest attempts are
  kept as `testRefuted` in `test/properties/MerkleDomainSeparation.t.sol`: a
  commitment rooted at a live match id, a seal proving the agree state at
  the wrong position, a parent tree entered as a child commitment, and the
  `uint64` cast of the sibling count.
- Several precision corrections to THREAT-MODEL.md's first read, folded into
  its "What the first read checked" section.

## Assurance evidence produced

These are executable records that something holds on the current tree, not
proofs; each names what it does not cover.

- Honest survival under `C` (the R19 plan): a stateful invariant on
  `SmallTwoLevelTournament` with budgets exactly at the formula, an eager
  honest actor whose every obligation is derived from production state and
  lands below its bound plus censorship from one ledger capped at `C`, and
  an adversary that joins Sybils at either level in either final-state
  class, stalls, seals, claims, proves in its own leaves, propagates, acts on
  the honest side's behalf and orders within blocks. Six configurations
  (`C` in 0, 2, 5; both root orientations) at 256 runs of depth 250 found no
  schedule that eliminates the honest commitment or finishes the root with a
  wrong state. The mutation control, removing the child-return refill, fails
  every configuration within 19 to 203 runs. Not covered: more than two
  levels, the node's planning-time choices, optimized honest latencies,
  refunds and recovery. `test/properties/HonestSurvivalInvariant.t.sol`,
  `HonestSurvivalSchedule.t.sol`, `HonestSurvivalSample.t.sol`.
- Adapter composition: what `Tournament` hands the adapter equals an
  independent model derived from docs/computation-hash.md in 808
  small-geometry descents over ten tables and at ten canonical boundary
  counters in four orientations, with the sealed divergence and every child
  descriptor recomputed independently; the real adapter wins by real proof
  at the epoch's last counter, the last input slot with and without an
  input, a position-zero plain step and a child's last position on both
  leaf heights. `test/properties/AdapterComposition.t.sol`, `test/TournamentStateTransitionExtremesFfi.t.sol`.
- STF-TODO-001, the adapter's discard of the uarch step status: the status
  is a pure function of the uarch cycle and halt words, the access-log root
  carries every write in every status, the fixed points only read, and the
  builder's identity condition is a sub-case of the step's; a status-gated
  adapter would reject the honest post-state of every span's halting ustep.
  Twelve synthetic pins in `test/StfStatusDiscard.t.sol`; the vector
  classes that would make the discharge executable with the emulator are
  listed in REVIEW.md.
- Mutation testing: 67 of 72 mutants killed; survivors in L-14.
- Known exploit classes from other fraud-proof systems mapped onto the code
  one by one, with the Merkle attempts above as the sharpest.
- The honest node's composition contract: 31 requirements the contracts
  impose on a validator, each with its consequence and citation, in
  HONEST-NODE-CONTRACT.md beside this file, with six pins in
  `test/properties/HonestNodeObligations.t.sol`.

## Checked and sound

- Toolchain: the solc bug list for 0.8.30 under via-IR was checked against
  the sources. The transient-storage clearing collision needs `delete` on a
  transient variable; the lock is only assigned. The two spill bugs need
  mutual recursion with stack relocation; `src/` has no recursion. The
  `require` custom-error ordering bug needs named-parameter construction;
  none is used. One Yul optimizer entry fixed after 0.8.37 cannot be
  excluded by reading; re-evaluate the pinned compiler at the audit freeze.
- The baseline dispute suite passes in the campaign worktree: 360 tests.
  The FFI state-transition suite passes too, 29 tests, with the yield image
  verified against its fingerprint, so composition tests against the real
  adapter can run here.
- Adapter composition at the capacity extremes: `test/TournamentStateTransitionExtremesFfi.t.sol` drives
  the real `Tournament.winLeafMatch` through the real `CartesiStateTransition`
  with Lua-generated proofs at the epoch's last counter `2^92 - 1` (closing
  step plus reset), the opening of the last input slot with and without an
  input, a position-zero divergence on the plain-step branch with the
  child's `initialHash` as agree state, a child's last position, and a
  rejected-input closing, on both leaf heights (38 and 27) and both
  orientations. The counter Tournament passes is asserted by exact calldata
  and equals `startCycle + position`; the adapter branch is asserted by the
  provider call and by a probe showing only that branch accepts the proof.
  All pass, and the serial FFI gate passes with them: 42 tests.
  Observations: every input opening is a child's position zero
  under any in-table geometry, since each leaf tile divides `2^68`; the
  adapter uses the counter only to select the branch and the input index,
  so an interior counter error that keeps the branch is invisible to it,
  which is why the boundary matrix is the right surface; and
  `Tournament.sol`'s local name `agreeCycle` is the counter of the leaf
  being proven, as the adapter's own comment says.
- Span coupling: the adapter's `48 + 20 + 24 = 92` from step's
  `EmulatorConstants` equals `ArbitrationConstants` `54 + 38`, the levels
  tile to stride zero, and the largest counter the canonical table can
  produce is `2^92 - 1`, the last the adapter accepts.
- Deployment: every registered row converts exactly at 12 s and 2 s; the
  provider's constructor arguments match the script's encoding; the refill
  equality with `winInnerTournament` holds on a real canonical-geometry
  dispute; the CREATE2 skip-if-code-exists is identity-safe; clone
  arguments are 17 words, under the Clones limit; one canonical
  root-to-leaf path is 50 honest actions.

## Campaign log

- 2026-10-13: threat model written after one full read of the boundary;
  baseline `just prt-contracts::test-disputes` passes 360 tests in the
  campaign worktree under the nix devshell; phase 2 finder swarm launched:
  20 dimensions, three rounds, the second and third from adversary roles,
  dedup, three refuter lenses per candidate.
- 2026-10-14: phase 2 complete: 113 agents, 28 raw candidates, 17 clusters,
  6 survivors, 9 duplicates of the baseline, 2 refuted. F-01 reproduced in
  tree; leads L-01 to L-10 recorded with their traces; the threat model
  corrected. Phase 3 launched: adversarial honest-survival search, adapter
  composition against an independent model, mutation testing, the deferred
  STF status discard, a NatSpec sweep, exploit-class transfer, deployment
  hygiene, and the honest-node composition contract; one FFI agent for the
  capacity extremes.
- 2026-10-14: phase 3 complete: 53 agents, 15 candidates, 4 survivors (all
  documentary or test gaps), 6 duplicates, 5 refuted; the FFI composition
  suite passes at every extreme. Leads L-11 to L-16 and the assurance
  evidence recorded; every artifact promoted into the tree, at first under a
  campaign directory. That directory passed 82 tests in the worktree, the six honest-survival invariants at 256 runs of depth 250
  each with no reverts.
- 2026-10-14, after the campaign: F-01 fixed on this branch through the
  contract-change gate. `ClockBudgets.maxAllowance` and the validator's
  bound gain the in-flight inclusion, their pins and the deployment tests
  follow, the documentation states the rule, and the honest-survival
  argument moved into dimensioning.md with the R19 plan deleted. The
  Tournament and factory metadata-free fingerprints are unchanged (the
  NatSpec edits move only the metadata-included ones); the provider's
  initcode moves with the formula. With the mutation pins of L-14 moved and
  added to their owning suites, the dispute suite passes 454 tests, FFI 42,
  gas witnesses 22, format check clean. The NatSpec and documentation leads
  L-04, L-05, L-13, and the documentary parts of L-01, L-02, L-03, L-06,
  L-08, L-09, L-11, L-12, L-15 and L-16 are applied in the living
  documents.
- 2026-10-14, placement: the campaign's tests moved to their owning suites.
  The match driver is `test/fixtures/TournamentDriver.sol` with its own
  test; the honest-survival invariant, schedule and sample, the adapter
  composition model, the delay and work traces, the canonical-path
  censorship trace, the Merkle refutations and the honest-node obligations
  are under `test/properties/`; the reserve regression with its two-level
  control and the factory reorg trace under `test/config/`; the deployment
  budget and import pins and the status-discard pins at the `test/` root;
  terminal recovery under `test/accounting/`; the FFI composition beside the
  existing composition FFI test. The front-running probe and the NatSpec
  sweep pins were dropped as duplicates. `testLead` became `testTrace`,
  `testProbe` lost its prefix, `testRefuted` stayed. Gate after the move: 447 dispute
  tests, FFI 42, format clean.
