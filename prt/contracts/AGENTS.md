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
  factor after joining closes. With multiple levels, slow child tournaments nest
  inside that elimination tree. The intended two-level resource model has the
  balanced leading factor `log^2(N) / 4`; the more general
  `(log(N) / L)^L` expression is a dimensioning model, not a substitute for
  checking the implemented clock and refund rules.

  Do not confuse timeout delay with work. Asynchronous arrival can skew the
  bracket into a list and force a correct survivor through a linear number of
  matches even though late claims cannot each manufacture a full clock window.
  Blockspace, transaction count, and aggregate refunds therefore need separate
  bounds. Background - the Felten/augusto exchange:
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
  (The `*Tournament.t.sol` test files exercise that one contract at each level.)
- **Factory.** `tournament/factories/MultiLevelTournamentFactory` deploys the
  root (level 0) via `instantiate`; deeper tournaments are created at `level + 1`
  when a non-leaf match is sealed. `instantiateInner` is also permissionless, so
  callers can create orphan inner tournaments. A parent only consumes a child
  recorded from one of its own sealed matches.
- **Role split** (well documented in `Tournament.sol`'s header NatSpec):
  - *root* (`level == 0`) vs *inner/non-root* (`level > 0`)
  - *non-leaf* (`level < levels - 1`) vs *leaf* (`level == levels - 1`)
  - The **level count `L` is a deployment parameter** (`ArbitrationConstants.LEVELS`
    / the parameters provider). The checked-in constants currently use **3**;
    the deployment target is **2**. The contract logic is meant to hold for
    *any* L, but a new layout must regenerate and validate its height and stride
    tables consistently. At the checked-in L=3:
    L0 = root + non-leaf, L1 = inner + non-leaf, L2 = inner + **leaf** (the only
    level that verifies a machine step on-chain).
- **Libraries**: `Match` (bisection state machine), `Clock` (chess-clock timing),
  `Commitment` + `types/Tree` (Merkle commitment construction & proofs), `Time`
  (block-number-based time), `Gas` (gas constants used to size the bond).
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
   commitment trees toward the first divergent leaf; both clocks `advanceClock()`
   each step (which swaps the one that is running).
3. **Seal** (once the match bottoms out / becomes sealable):
   - *leaf*: `sealLeafMatch` - both clocks are set running (a race to prove).
   - *non-leaf*: `sealInnerMatchAndCreateInnerTournament` - spawns a child
     tournament at `level + 1`, seeded with the contested states and the
     `max` of the two clocks' allowances.
4. **Resolve**:
   - *leaf*: `winLeafMatch` - submit the on-chain state-transition proof; the
     commitment whose claimed final state matches the computed one wins.
   - *non-leaf*: `winInnerTournament` / `eliminateInnerTournament` - propagate
     the child's result up to the parent match.
   - *timeout*: `winMatchByTimeout` (one clock out of time) /
     `eliminateMatchByTimeout` (both effectively out -> **both** eliminated).
5. The surviving **dangling** commitment is the tournament's result; the root's
   is read via `arbitrationResult`, an inner's via `innerTournamentWinner`.
   Bonds are swept by the winner via `tryRecoveringBond`.

## Mechanisms (verified against the code - *not* a correctness claim)

- **Clock** (`Clock.sol`): a *paused* clock (`startInstant == 0`) always reports
  `hasTimeLeft == true`, including the uninitialized mapping value.
  `advanceClock` toggles run/pause, so within an active bisection exactly one
  clock runs at a time; `sealLeafMatch` deliberately runs both. `addMatchEffort`
  grants a bankable response budget to both sides per pairing, including a fresh
  newcomer, capped at `maxAllowance`. This changes finite delay constants and is
  under redesign. A storage clock cannot be initialized or paused with zero
  allowance.
- **Timeout charging**: `winMatchByTimeout` attempts to deduct the loser's
  `timeSinceTimeout` from the winner; if the deduction consumes the winner's
  clock, only `eliminateMatchByTimeout` can eliminate both commitments. The
  current `Clock.deducted` uses stored allowance rather than live remaining time,
  so a sealed-leaf timeout can restore the running winner's elapsed time. Track
  this as PRT-002 in `audit/REVIEW.md`.
- **Bond and partial refunds**: `bondValue() = _totalGasEstimate() *
  MAX_GAS_PRICE` (50 gwei), where
  `_totalGasEstimate = ADVANCE_MATCH * height + max(leaf seal+win, inner
  seal+win)` (see `Gas.sol`). The `refundable` modifier refunds the caller
  `min(contract balance, this function's bond-share, gas used x min(tx.gasprice,
  basefee + PRIORITY_FEE_CAP))`. This is a capped execution-gas payment, not a
  guarantee of full transaction cost or profit, and it does not model every L2
  data fee. The bond-share term also caps reimbursement at 50 gwei even when
  base fee is higher. Today the first claimer of the winning commitment sweeps
  the residual balance via `tryRecoveringBond`; the agreed redesign caps that
  terminal payment at one bond and burns the rest so losing Sybil deposits
  cannot be recycled.
- **Reentrancy**: a transient `locked` flag guards state-mutating entrypoints -
  `withLock` on `joinTournament` and `tryRecoveringBond`, and `refundable`
  (which also takes the lock) on `advanceMatch` / the seal / win / eliminate
  functions. The external ETH transfers (`tryRecoveringBond`'s balance sweep,
  `refundable`'s refund) and the external child calls in `winInnerTournament`
  (`child.canBeEliminated`, `child.tryRecoveringBond`) all execute inside the
  lock. (Mechanism only - stress-testing it is exactly an audit's job.)
- **Termination**: `isClosed` = `now >= startInstant + allowance`;
  `isFinished` = `isClosed && matchCount == 0`; `canBeEliminated` (non-root only)
  = finished with no winner, **or** finished and the winner's allowance window
  has elapsed.
- **Leaf-proof ordering**: `winLeafMatch` verifies match existence and the state
  transition, but does not reject an expired clock. A proof can resolve the
  match until a timeout transaction actually eliminates it.
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
  3-level/30-minute model or the target 2-level/60-minute model. It is also the
  per-clock cap; child tournament allowances may be smaller.
- `matchEffort` = 5 minutes x sum of tournament heights (48+17+27 = 92, so
  about 7.67 hours) - same on every chain kind
- `MAX_GAS_PRICE` = 50 gwei, `PRIORITY_FEE_CAP` = 10 gwei (`Tournament.sol`)

## Subtle areas worth understanding before touching anything

*Comprehension aids - deliberately framed as "understand this," not "this is fine."*

- **Double-bisection parity**: `Match.getDivergence` and
  `_getDivergenceOn{Left,Right}Leaf` use `height % 2` to map the first divergent
  leaf back to the correct commitment (`commitmentOne` vs `commitmentTwo`). The
  parity bookkeeping is easy to get wrong and decides *who wins* a match.
- **Clock alternation vs the leaf race**: bisection keeps one clock running;
  `sealLeafMatch` intentionally starts **both**. The double-run is by design,
  but every later charge must start from each clock's live remaining time.
- **The multi-level delay bound** (see the threat model above) - the property
  that is least captured by a one-line summary.
- **Inner-clock carryover**: `winInnerTournament` re-initializes the parent
  clock from the inner winner's remaining time, and `innerTournamentWinner`
  deducts the time elapsed since the inner tournament finished.
- **No fixed-level assumptions**: the level count `L` is configurable, but
  `ArbitrationConstants` hardcodes the per-level `log2step` / `height` arrays at
  `LEVELS = 3`. A deployment with a different L must regenerate those
  consistently, and the generic logic (`level + 1` recursion, leaf/root
  detection, bond sizing) must hold for any L - worth checking for accidental
  "== 3" assumptions.

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
```

`just test-disputes` is the pure-Solidity tournament suite (no FFI);
`just test-stf` and `just test-stf-fuzzy` cover the state transition and require
`--ffi` plus the `machine/step` submodule.
