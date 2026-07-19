# PRT Contracts - Architecture & Agent Context

**Security-critical.** The Solidity implementation of Permissionless Refereed
Tournaments (PRT): the on-chain dispute resolution that decides the canonical
result of a Cartesi rollup computation.

> This file is orientation, not gospel. The **code is the source of truth**;
> comments and papers have drifted before. Treat every specific claim below as a
> lead to verify, not a fact to rely on - and especially never read it as
> asserting that a given mechanism is *correct*. Verifying that is the work.

## What the system must guarantee (the properties to protect)

- **Safety** - provided that a correct commitment joins and its participant can
  act within the configured clock and censorship bounds, an incorrect
  computation result must not win the root tournament. This also assumes the
  configured state-transition contract and data provider are correct, hashes
  have their expected security properties, and the application is disputable
  within the configured dimensions.
- **Liveness / bounded delay** - under those assumptions, a party committing to
  the correct result can make progress and ultimately win within the time and
  economic budget. With `K` live commitments, there are `floor(K / 2)` matches
  and at most one dangling commitment. At a leaf level, at least one clock runs
  in every match. A sealed non-leaf match pauses both parent clocks and delegates
  population reduction to a child tournament; the child deadline alone does not
  finish live child matches. At one level, capped per-match clock mass and prompt
  cleanup make each bounded window reduce the live population by a constant
  factor after joining closes. The safe local leaf bound is
  `W <= b1 + b2 + h * G`, not one allowance: a reachable pair can take
  `2A - 1`, and adding one same-time dangling claim can extend completion to
  `3A - 1`. With multiple levels, slow child tournaments nest inside that
  elimination tree. The intended two-level resource model has the
  balanced leading factor `log^2(N) / 4`; the more general
  `(log(N) / L)^L` expression is a dimensioning model, not a substitute for
  an unbounded proof over adversarial arrival schedules.

  Do not confuse timeout delay with work. Asynchronous arrival can skew the
  bracket into a list and force a correct survivor through a linear number of
  matches. Clock conservation, structural population reduction, transaction
  work, and wall-clock serialization therefore need separate bounds.
  Background - the Felten/augusto exchange:
  <https://research.arbitrum.io/t/solutions-to-delay-attacks-on-rollups/692>
- **Sybil / resource-exhaustion resistance** - an adversary pays one bond per
  commitment in each tournament it joins. Clock, refund, and re-pairing rules
  must bound the time and funds an adversary can force other participants to
  spend; this is a property to prove, not an automatic consequence of bonding.
- **Censorship bound** - holds while the honest party is not censored past its
  allowance. The intended mainnet value is about 7 days + 1 hour, but the
  wall-clock duration also depends on the chain's `block.number` semantics and
  deployment conversion.

The durable description of the implemented game and its assumptions is
[`docs/dispute-game.md`](../../docs/dispute-game.md). The original PRT and Dave
papers do not specify these contracts exactly.

## Architecture

- **One contract does it all.** `tournament/Tournament.sol` is instantiated at
  every level as an ERC-1167 clone with immutable args
  (`cloneWithImmutableArgs`). There are **no** separate Top/Middle/Bottom
  contracts - "top/middle/bottom" are the *same code* at levels 0/1/2,
  distinguished only by the `level` in the clone's immutable `TournamentArguments`.
  The historical three-level suites under `test/characterization/` exercise
  that one contract in each of those roles against a frozen test profile.
  Geometry-independent economic models live under `test/accounting/`; they use
  production gas allocations without importing canonical tournament constants.
- **Factory.** `tournament/factories/MultiLevelTournamentFactory` deploys the
  root (level 0) via `instantiate`; deeper tournaments are created at `level + 1`
  when a non-leaf match is sealed. `instantiateInner` is also permissionless, so
  callers can create orphan inner tournaments. A parent only consumes a child
  recorded from one of its own sealed matches. Factory construction rejects a
  no-code tournament implementation, parameters provider, or state transition;
  it does not validate a generic provider's returned table on every read.
- **Role split** (well documented in `Tournament.sol`'s header NatSpec):
  - *root* (`level == 0`) vs *inner/non-root* (`level > 0`)
  - *non-leaf* (`level < levels - 1`) vs *leaf* (`level == levels - 1`)
  - The **level count `L` is a deployment parameter** (`ArbitrationConstants.LEVELS`
    / the parameters provider). The checked-in constants currently use **3**;
    the selected deployment layout uses **2** with
    `log2step = [37, 0]` and `height = [55, 37]`. That switch is planned but
    integration-gated on the coordinated node change; it is not live in these
    contracts. The contract logic is meant to hold for *any* L, but a new
    layout must regenerate and validate its height and stride tables
    consistently. A test-only whole-table validator pins those shape rules, and
    a strict four-level production trace exercises three recursive child seams.
    Neither proves that an off-chain node uses the same table, so the selected
    L=2 layout retains its integration gate. At the checked-in L=3:
    L0 = root + non-leaf, L1 = inner + non-leaf, L2 = inner + **leaf** (the only
    level that verifies a machine step on-chain).
- **Libraries**: `Match` (bisection state machine), `Clock` (one-clock
  arithmetic and transitions), `MatchClocks` (legal two-clock match phases),
  `Commitment` + `types/Tree` (Merkle commitment construction & proofs), `Time`
  (block-number-based time), `Gas` (action work allocations), and `Bond`
  (economic policy plus work-reserve accounting).
  Types: `Machine`, `Tree`, `TournamentParameters`.
- **Leaf resolution** calls `IStateTransition` (`CartesiStateTransition` ->
  `RiscVStateTransition` + `CmioStateTransition`) to verify a single machine
  step. The step *semantics* live in the `machine/step` submodule and are out of
  scope as a contract here.

## Lifecycle of one tournament

1. **Join** (`joinTournament`) - post a bond (`bondValue()`) and a commitment
   (Merkle root over machine-state hashes). `pairCommitment` either pairs it
   with the current dangling commitment (-> a new match) or makes it dangling.
   Inner tournaments only accept commitments whose final state matches one of
   the two *contested* final states inherited from the parent match.
2. **Bisect** (`advanceMatch`) - alternating double-bisection descends both
   commitment trees toward the first divergent leaf; `MatchClocks.switchTurnAt`
   discounts the valid response, pauses its clock, and starts the other at the
   same instant.
3. **Seal** (once the match bottoms out / becomes sealable):
   - *leaf*: `sealLeafMatch` - `startLeafRaceAt` moves the active bisection
     into a two-running-clock race to prove.
   - *non-leaf*: `sealInnerMatchAndCreateInnerTournament` - spawns a child
     tournament at `level + 1`, seeded with the contested states and the
     maximum of the two clocks' snapshotted allowances; both parent clocks are
     paused.
4. **Resolve**:
   - *leaf*: `winLeafMatch` - submit the on-chain state-transition proof; the
     commitment whose claimed final state matches the computed one wins only if
     the shared timeout status permits that side. A matching single-winner
     timeout outcome also charges the expired opponent's overdue duration.
   - *non-leaf*: `winInnerTournament` / `eliminateInnerTournament` - propagate
     the child's result up to the parent match.
   - *timeout*: `winMatchByTimeout` when one commitment survives the expired
     side's overdue charge / `eliminateMatchByTimeout` when neither survives
     that accounting (both eliminated).
5. The surviving **dangling** commitment is the tournament's result; the root's
   is read via `arbitrationResult`, an inner's via `innerTournamentWinner`.
   `tryRecoveringBond` attempts to pay the registered winning claimer at most
   one bond. An accepting recipient is paid before the remaining tournament
   balance is burned.

## Mechanisms (verified against the code - *not* a correctness claim)

- **Clock phases and response budget** (`Clock.sol` + `MatchClocks.sol`):
  `allowance == 0` is uninitialized. An initialized clock is paused when
  `startInstant == 0` and running otherwise. Operations that observe elapsed
  time take an explicit instant. Uninitialized live-time queries revert.
  `MatchClocks` asserts the source phase for each pair transition: active
  bisection has exactly one running clock, a sealed leaf has two running clocks
  with the same start instant, and a sealed inner match has two paused clocks.
  Pairing never changes balances. For each successful advance or final seal,
  `pauseAfterResponseAt` requires `elapsed < balance` and leaves
  `balance - max(elapsed - responseBudget, 0)`. The discount never increases a
  balance or revives an expired clock. A height-`H` match has exactly `H` such
  responses. A storage clock cannot be initialized or paused with zero
  allowance.
- **Timeout charging**: `MatchClocks.classifyTimeoutAt` compares the prospective
  winner's `remainingAt(current)` with the expired side's
  `overdueByAt(current)`. A strictly positive post-charge remainder produces a
  single winner; equality or a larger overdue duration produces double
  elimination, even while the nominal winner still has live time. The
  classifier supplies that four-way outcome and winner charge to the capability
  view, both timeout mutation paths, and proven-leaf settlement.
  `canWinMatchByTimeout` is true only for an existing match with one viable
  timeout winner. PRT-002 fixed the former sealed-leaf time restoration, and
  PRT-004 fixed the prior view/mutation mismatch.
- **Bond and partial refunds**: `Bond` derives each join deposit directly from
  the refundable work reserve. For positive height `h`, `bondValue = ((h - 1) *
  ADVANCE_MATCH + terminalMaximum) * WORK_PRICE_CAP`. For
  `units = Gas.TX + gasBefore - gasAfter`, the modifier
  requests `min(balance, allocation * WORK_PRICE_CAP, units *
  min(tx.gasprice, basefee + PRIORITY_FEE_CAP))`. The refund event records that
  requested value; a failed nonzero recipient call transfers nothing and leaves
  it in the pool. This is a bounded gross-EVM work subsidy, not a guarantee of
  receipt-exact cost or profit. It excludes transaction-intrinsic calldata and
  L2 data fees, while proof copying after the snapshot remains in the measured
  delta. Seven action caps have retained measured ceilings; `WIN_LEAF_MATCH`
  deliberately uses a provisional ordinary-proof subsidy. Exact reimbursement
  is not a correctness assumption or an endogenous validator incentive.
  Zero-value payments skip recipient code; nonzero refund and
  terminal-payment recipients receive at most 50,000 gas, and return data is not
  copied. For `J` paid joins, at most `J - 1` matches consume configured work
  reserves. An accepting winner recovers one minimum join bond. For a tournament
  that reaches successful winner recovery, aggregate losing reserves are either
  paid as bounded subsidies for successful progress or remain for terminal
  burning; no positive burn per loser is guaranteed. This is aggregate resource
  accounting, not a receipt-exact or identity-level attacker-cost theorem.
  See [`audit/REFUND-DESIGN.md`](audit/REFUND-DESIGN.md) for the design and
  [`audit/GAS-CALIBRATION.md`](audit/GAS-CALIBRATION.md) for the reproducible
  measurement and update procedure.
- **Reentrancy**: each clone has its own transient `locked` flag.
  `withLock` guards `joinTournament` and `tryRecoveringBond`; `refundable` also
  locks advance, seal, win, and eliminate functions. The external ETH transfers
  and child calls execute while the source clone is locked. A nested mutation of
  that clone reverts with `ReentrancyDetected`, while a payment callback may
  mutate a different clone whose independent lock is free if the nested work
  fits the 50,000-gas callback ceiling. Child balance recovery is a separate
  permissionless operation and is not part of parent progress. A failed action
  refund leaves its requested value in the pool; a failed terminal payment
  preserves the full balance and claimer for retry. Tournament-result staging
  keeps its synchronous best-effort recovery attempt. It ignores both `false`
  and a recovery revert, so recipient failure cannot undo staging or block later
  acceptance. (Mechanism only - stress-testing it is exactly an audit's job.)
- **Termination**: `isClosed` = `now >= startInstant + allowance`;
  `isFinished` = `isClosed && matchCount == 0`; `canBeEliminated` (non-root only)
  = finished with no winner, **or** finished and the winner's allowance window
  has elapsed.
- **Leaf-proof ordering**: `winLeafMatch` follows the shared timeout
  classification after validating the objective state-transition result. With
  `NONE`, it pauses the proven winner with its live remainder. With the matching
  single-winner outcome, it applies the same overdue charge as timeout victory.
  An opposite timeout winner or `ELIMINATE_BOTH` rejects the proof. At the same
  observation instant, successful proof and timeout resolutions cannot select
  different survivors: a compatible proof enters re-pairing with the same
  survivor and charged clock balance, while an incompatible proof rejects.
  Objective proof correctness does not override a missed clock.
- **Access control**: `MultiLevelTournamentFactory.instantiateInner` is
  **permissionless** - anyone can mint an orphan inner tournament not linked to
  any parent match. Legitimacy is established off-chain by following the
  `NewInnerTournament` event chain from the root; on-chain, a parent only ever
  consumes inner tournaments *it* created (tracked in
  `matchIdFromInnerTournaments`).

## Deployment parameters

From `script/Deployment.s.sol` (the chain-kind registry) - durations are
converted to **block counts** using a registered average block time. The
conversion is valid only when it matches that chain's `block.number` semantics.
Ethereum is the supported deployment target; other base chains are
experimental until validated. The current Arbitrum entries do not match the
`NUMBER` opcode's parent-chain coordinate, as tracked by PRT-001 in
`audit/REVIEW.md`.

- `maxAllowance` = 1 week + 1 hour (mainnet), 9 hours (testnet), 1 hour (devnet).
  The intended formula is `censorship + (levels - 1) * inner commitment time`;
  the same checked-in mainnet value corresponds either to the historical
  3-level/30-minute model or the target 2-level/60-minute model. It is the
  structural upper bound for parent-linked clocks; child tournament allowances
  may be smaller, and no response operation raises a clock toward the bound.
  The canonical provider rejects zero; before that guard a zero-allowance root
  was immediately closed and rejected every join.
- `matchEffort` = 5 minutes per successful bisection response, including the
  final seal. One root-to-leaf descent with one match at each level spans 92
  heights and can earn at most 7 hours 40 minutes, one response at a time;
  re-pairing creates a new match with new discounts. On Ethereum the scalar is
  25 blocks.
- `WORK_PRICE_CAP` = 50 gwei, `PRIORITY_FEE_CAP` = 10 gwei (`Bond.sol`)

## Subtle areas worth understanding before touching anything

*Comprehension aids - deliberately framed as "understand this," not "this is fine."*

- **Double-bisection parity**: `Match.sealDivergence` derives the final revealing
  side once from total-height parity. The sealed position's low bit records the
  final left/right branch; `_decodeDivergence` reconstructs revealing and waiting
  leaves, and `_fixedSideFinalStates` orders them by `commitmentOne` and
  `commitmentTwo`. Sparse-tree properties exhaust every position through height
  eight and cover boundary, representative, and fuzzed paths through height 55;
  this bookkeeping decides *who wins* a match.
- **Raw Match phase predicates**: `Match.isSealed` checks only that the stored
  height is zero, so it is also true for an uninitialized mapping slot. Establish
  `exists()` first, or use the existence-aware `phase`, whenever absence is
  possible. Production callers preserve that ordering; tests must not make a
  vacuous sealed-state assertion.
- **Clock alternation vs the leaf race**: bisection keeps one clock running;
  `MatchClocks.startLeafRaceAt` intentionally starts **both** from one explicit
  instant. The double-run is by design, and timeout charging starts from the
  winner's live remaining time at that same operation instant.
- **The multi-level delay bound** (see the threat model above) - the property
  that is least captured by a one-line summary. The fixed four-root trace in
  `test/properties/ConcurrentRecursivePopulation.t.sol` pins coexisting child
  obligations and parent re-pairing, not the adversarial asynchronous upper
  bound. `LeafPopulationDelay.t.sol` pins reachable `2A - 1` and `3A - 1`
  lower-bound schedules. `BoundedOneLevelDelay.t.sol` exhausts a proof-inclusive
  clock-only envelope for `N <= 6`, `A <= 4`, `G <= 2`, and `H <= 3` under
  prompt timeout cleanup. It independently chooses proof winners and has no
  honest strategy, so the unbounded attacker-versus-honest proof or
  counterexample remains open.
- **Inner-clock carryover**: `innerTournamentWinner` returns a paused clock
  after deducting the time elapsed since the inner tournament finished;
  `winInnerTournament` replaces the paused parent clock with that state.
- **No fixed-level assumptions**: the level count `L` is configurable, but
  `ArbitrationConstants` hardcodes the per-level `log2step` / `height` arrays at
  `LEVELS = 3`. CFG-001 in `audit/REVIEW.md` records the selected two-level
  replacement and its cross-implementation gate. A deployment with a different
  L must regenerate those consistently and run the test-only table validator.
  The generic logic (`level + 1` recursion, leaf/root detection, bond sizing)
  must hold for any L; `FourLevelRecursiveLifecycle.t.sol` protects one strict
  four-level path without claiming arbitrary-table or node conformance.

## Build / test

From the repo root, init the state-transition submodule:

```bash
git submodule update --init machine/step
```

Then from `prt/contracts/`:

```bash
just install-deps   # forge soldeer install
just build          # forge build + generate Rust bindings
just test-all       # dispute tests + STF tests + STF fuzz tests
just test-gas       # validate retained refund-gas witnesses
just measure-gas    # release-pinned report; see GAS-CALIBRATION.md
just coverage       # instrumented dispute-game coverage summary
```

`just test-disputes` runs every non-FFI Solidity test. The focused state
transition and gas recipes select their respective subsets; `just test-stf` and
`just test-stf-fuzzy` require `--ffi` plus the `machine/step` submodule. Gas
calibration must use the plain test runner, not coverage instrumentation; follow
`audit/GAS-CALIBRATION.md`.
The coverage recipe excludes FFI, gas-calibration, exact refund-formula, and
state-transition tests and sources. Coverage instrumentation changes the
measured refund units and can make an action cap bind, invalidating both gas
observation suites. It also skips the stateful invariant executors: the ordinary
test gate runs those campaigns, while deterministic companion traces map their
production paths without slow IR instrumentation. Coverage uses IR-minimum
source maps as a stack-depth workaround, so branch totals are directional rather
than a correctness claim. Foundry's noisy IR anchor warnings are suppressed by
default; set `COVERAGE_RUST_LOG=warn` only when debugging the mapper itself.
