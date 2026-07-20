# PRT Contracts - Architecture & Agent Context

**Security-critical.** The Solidity implementation of Permissionless Refereed
Tournaments (PRT): the on-chain dispute resolution that decides the canonical
result of a Cartesi rollup computation.

> This file is orientation, not gospel. The **code is the source of truth**;
> comments and papers have drifted before. Treat every specific claim below as a
> lead to verify, not a fact to rely on - and especially never read it as
> asserting that a given mechanism is *correct*. Verifying that is the work.

## What the system must guarantee (the properties to protect)

- **Safety** - a commitment to an *incorrect* computation result can never win
  the root tournament.
- **Liveness / bounded delay** - a party committing to the *correct* result can
  always make progress and ultimately win, within the time and economic budget.
  The *delay* an adversary can impose is the key liveness metric, and it is
  governed by **L = the number of levels** (a deploy-time configuration - see
  Architecture, *not* a fixed 3). For an adversary who can afford `N` claims the
  delay scales as `(log N / L)^L = log^L(N) / L^L`: `log N` at L=1, `log^2 N / 4`
  at L=2, `log^3 N / 27` at L=3. So the choice of L trades **delay** against
  **commitment-generation cost** - more levels make generating commitments
  tractable but raise the delay bound; the planned move from 3 -> 2 levels lowers
  it (`log^3 N/27 -> log^2 N/4` for the `N` that matter). The honest party's *cost*
  stays low regardless - one bond and a logarithmic number of matches per level.
  Don't reduce this to a flat "O(log N)". Background - the Felten/augusto
  exchange:
  <https://research.arbitrum.io/t/solutions-to-delay-attacks-on-rollups/692>
- **Sybil / resource-exhaustion resistance** - an adversary pays one bond per
  commitment and gains no advantage; there is no way to drain the honest party's
  gas, time, or funds.
- **Censorship bound** - holds while the honest party is not censored past its
  allowance (~7 days + 1 hour on mainnet).

## Architecture

- **One contract does it all.** `tournament/Tournament.sol` is instantiated at
  every level as an ERC-1167 clone with immutable args
  (`cloneWithImmutableArgs`). There are **no** separate Top/Middle/Bottom
  contracts - "top/middle/bottom" are the *same code* at levels 0/1/2,
  distinguished only by the `level` in the clone's immutable `TournamentArguments`.
  (The `*Tournament.t.sol` test files exercise that one contract at each level.)
- **Factory.** `tournament/factories/MultiLevelTournamentFactory` deploys the
  root (level 0) via `instantiate`; deeper tournaments are created at `level + 1`
  when a non-leaf match is sealed.
- **Role split** (well documented in `Tournament.sol`'s header NatSpec):
  - *root* (`level == 0`) vs *inner/non-root* (`level > 0`)
  - *non-leaf* (`level < levels - 1`) vs *leaf* (`level == levels - 1`)
  - The **level count `L` is a deployment parameter** (`ArbitrationConstants.LEVELS`
    / the parameters provider), currently **3**, with deployments targeting **2**;
    the contract logic is meant to hold for *any* L. At the current L=3:
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
  `hasTimeLeft == true`. `advanceClock` toggles run/pause, so within a match
  exactly one clock runs at a time (they alternate); `sealLeafMatch` is the
  deliberate exception that runs both. `addMatchEffort` grants `matchEffort` per
  pairing, capped at `maxAllowance`. A clock can never be (re)initialized to zero
  allowance - it reverts.
- **Timeout fairness**: `winMatchByTimeout` deducts the winner's clock by the
  loser's `timeSinceTimeout` (a penalty for claiming late); if that would zero
  the winner's clock the call reverts, leaving only `eliminateMatchByTimeout`,
  which eliminates **both** commitments (the Sybil-vs-Sybil garbage-collection
  path).
- **Bond**: `bondValue() = _totalGasEstimate() * MAX_GAS_PRICE` (50 gwei), where
  `_totalGasEstimate = ADVANCE_MATCH * height + max(leaf seal+win, inner
  seal+win)` (see `Gas.sol`). The `refundable` modifier refunds the caller
  `min(contract balance, this function's bond-share, gas used x min(tx.gasprice,
  basefee + PRIORITY_FEE_CAP))`. The winner sweeps the residual balance via
  `tryRecoveringBond`.
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
- **Access control**: `MultiLevelTournamentFactory.instantiateInner` is
  **permissionless** - anyone can mint an orphan inner tournament not linked to
  any parent match. Legitimacy is established off-chain by following the
  `NewInnerTournament` event chain from the root; on-chain, a parent only ever
  consumes inner tournaments *it* created (tracked in
  `matchIdFromInnerTournaments`).

## Deployment parameters

From `script/Deployment.s.sol` (the chain-kind registry) - note all durations
are converted to **block counts** using the chain's average block time:

- `maxAllowance` = 1 week + 1 hour (mainnet), 9 hours (testnet), 1 hour (devnet)
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
  `sealLeafMatch` intentionally starts **both**. The double-run is by design.
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
