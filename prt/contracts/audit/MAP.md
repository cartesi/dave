# PRT Contracts - Audit System Map (Stage 1)

> **Provenance.** Generated 2026-06-10 by the stage-1 mapping workflow
> (`prt-audit-map`, run `wf_60452ddc-ea6`): 6 parallel subsystem mappers read all
> 23 in-scope Solidity files, then a consolidator re-read code to adjudicate
> disagreements. ~723k tokens, 7 agents.
>
> **Status: machine-generated, to be verified.** This is the audit's working model,
> not gospel. The **code is the source of truth**; treat every claim here -
> especially anything marked "confirmed" or "verified" - as a lead to re-check, not
> a fact to rely on. Line numbers are deliberately omitted (they drift); symbols are
> cited instead. Scope: Solidity under `prt/contracts/src/`. Out of scope: off-chain
> clients, `machine/step` execution semantics, the concrete `IDataProvider`.

---

## 1. System model

PRT (Permissionless Refereed Tournaments) is Cartesi's on-chain fraud-proof dispute
resolution. It decides the canonical result of a rollup computation by playing an
interactive, multi-party, multi-level bisection game under chess-clock timing.

### One contract, cloned per level

There is a single `Tournament` contract (`tournament/Tournament.sol`) with **no
constructor, no initializer, not abstract**. It is deployed as an ERC-1167
clone-with-immutable-args (OZ Clones 5.5.0 `cloneWithImmutableArgs`, **plain `CREATE`,
nonce-based, NOT CREATE2**). All per-instance configuration lives in immutable
calldata-appended `TournamentArguments` (`ITournament.sol`): `{commitmentArgs{initialHash,
startCycle, log2step, height}, level, levels, startInstant, allowance, maxAllowance,
matchEffort, provider, nestedDispute{contestedCommitmentOne/Two, contestedFinalStateOne/Two},
stateTransition, tournamentFactory}`. Read via `_tournamentArgs()` =
`abi.decode(fetchCloneArgs(),(TournamentArguments))`. On the bare impl (no appended args)
`fetchCloneArgs` does `code.length - 0x2d` and reverts on underflow, so impl-direct calls
fail safely.

Roles are pure predicates: `_isRootTournament` = `level == 0`; `_isLeafTournament` =
`level == levels - 1`. `levels == 1` is simultaneously root AND leaf. **`levels - 1`
underflows uint64 if `levels == 0`**, but the factory/provider always set
`levels = ArbitrationConstants.LEVELS (=3)`; the contract never validates `levels` itself.

`L` (= `levels`) is a **deployment parameter** from `CanonicalTournamentParametersProvider`,
which returns `ArbitrationConstants.LEVELS` for every level and per-level
`log2step = [44,27,0]` / `height = [48,17,27]` (fixed-size `uint64[3]` arrays indexed by
level; `level >= 3` reverts with Panic 0x32 array-OOB, **not** a named error). The generic
logic (`level+1` recursion, leaf/root detection, bond sizing via `commitmentArgs.height`) is
genuinely L-agnostic; the **only** baked-in `L=3` is in `ArbitrationConstants`. `matchEffort`
and `maxAllowance` are level-independent. For L=3: L0 = root+non-leaf, L1 = inner+non-leaf,
L2 = inner+leaf. The deployment target is L=2, so these tables must be regenerated and validated.

### Lifecycle (per tournament instance)

1. **Join** (`joinTournament`, `withLock` + `tournamentOpen`): require
   `msg.value >= bondValue()`; `commitmentRoot = leftNode.join(rightNode)`;
   `requireFinalState` binds `finalState` to the rightmost leaf via `getRootForLastLeaf`
   (full-height proof); `requireValidContestedFinalState` (root accepts ANY final state,
   non-root only the two inherited contested states); `finalStates[root] = finalState`;
   `clocks[root].requireNotInitialized` then `setNewPaused(startInstant, allowance)`
   (allowance reduced by elapsed since `startInstant`; reverts
   `InitializedClockCannotHaveZeroAllowance` if `elapsed >= allowance`, though
   `tournamentOpen` already blocks when closed); emit `CommitmentJoined`; `pairCommitment`;
   `claimers[root] = msg.sender`. Excess ETH is retained in the pooled balance
   and is subject to progress refunds, capped terminal payout, and residual burn.
   `requireNotInitialized` blocks re-joining the same commitment root (two distinct
   participants with the identical tree collide; only the first joins. First-claimer ownership is
   intended because all progress calls are permissionless; PRT-008 caps the
   terminal payout consequence).

2. **Async pairing** (`pairCommitment`): single `danglingCommitment` slot (`ZERO_NODE`
   sentinel). `assert(leftNode.join(rightNode) == rootHash)`. If a dangling exists:
   `createMatch(dangling = commitmentOne, newcomer = commitmentTwo, seeded from newcomer's
   children, otherParent = dangling)`; BOTH clocks `addMatchEffort(matchEffort capped at
   maxAllowance)`; the DANGLING clock `advanceClock()` (starts running first); `clearDangling`;
   `matchCount++`. Else store newcomer as dangling.

3. **Bisect** (`advanceMatch`, `refundable(ADVANCE_MATCH)` + `tournamentNotFinished`):
   `requireExist` + `requireCanBeAdvanced(currentHeight > 1)`. `Match.advanceMatch` verifies
   `otherParent == join(suppliedLeft, suppliedRight)`; if supplied left != stored leftNode ->
   descend LEFT, else descend RIGHT; updates `otherParent` to the chosen child of the
   just-exposed tree, `leftNode`/`rightNode` to the new children, `currentHeight--`, and
   (right only) `runningLeafPosition += 1 << currentHeight` (post-decrement, so an EVEN add
   >= 2). Then BOTH clocks `advanceClock()` - toggles each, swapping the turn (exactly one
   runs). Refund to `msg.sender` inside the lock.

4. **Seal** (`currentHeight` reaches 1):
   - **Leaf** (`sealLeafMatch`, `refundable(SEAL_LEAF_MATCH)`): require leaf;
     `requireExist` + `requireCanBeSealed`; for BOTH clocks `setPaused()` then
     `advanceClock()` -> BOTH end RUNNING (the deliberate exception; a clock already timed
     out reverts via `advanceClock`, forcing the timeout path). `Match.sealMatch` pins the
     divergent leaf (left/right via `agreesOnLeftNode`), repurposes `leftNode`/`rightNode`
     to hold the two contested final states and `otherParent` to hold the agree-state hash;
     proves agreeState against `commitmentOne` (if height odd) or `commitmentTwo` (if height
     even) at position `runningLeafPosition - 1`, or `== initialHash` when position 0.
   - **Non-leaf** (`sealInnerMatchAndCreateInnerTournament`, `refundable(SEAL_INNER...)`):
     require non-leaf; `requireCanBeSealed` ONLY (**no `requireExist`** - relies on a zeroed
     `State` having `currentHeight 0` failing `canBeSealed`); both clocks `setPaused()`;
     `_maxDuration = Clock.max(allowance1, allowance2)`; `sealMatch`; `instantiateInner`
     spawns a child at `level+1` seeded with `agreeHash` as `initialHash`, the two contested
     commitments + final states, `allowance = _maxDuration`, `startCycle =
     toCycle(runningLeafPosition)`; `matchIdFromInnerTournaments[child] = matchId`; match
     persists sealed (not deleted) until resolved.

5. **Resolve:**
   - **Leaf** (`winLeafMatch`, `refundable(WIN_LEAF_MATCH)`): require leaf; both clocks
     `requireInitialized`; `requireExist` + `requireIsSealed`; `getDivergence` returns
     (agreeHash from `otherParent`, `agreeCycle = toCycle`, `finalStateOne`, `finalStateTwo`);
     calls `stateTransition.transitionState(agreeHash, agreeCycle, proofs, provider)` (a
     STATICCALL - view); the commitment (selected by caller-supplied children joining to
     `commitmentOne/Two`) whose contested final state == computed post-state WINS (else
     `WrongFinalState`/`WrongNodesForStep`); winner clock `setPaused`, `pairCommitment(winner)`,
     `deleteMatch(STEP, ONE/TWO)`. **No clock time-left check here** - once sealed, the
     objective step decides regardless of remaining clock.
   - **Non-leaf win** (`winInnerTournament`, `refundable(WIN_INNER_TOURNAMENT)`): require
     non-leaf; `matchId` from `matchIdFromInnerTournaments[child]`; `requireExist` +
     `requireIsSealed`; require `!child.canBeEliminated()`; `(finished, winner, , innerClock)
     = child.innerTournamentWinner()`; require `finished`; `winner.requireExist`; supplied
     children must join to `winner`; parent `clock[winner].requireInitialized` then
     `reInitialized(innerClock)` (carryover = `timeLeft` of the deducted inner clock, paused;
     reverts if zero); `pairCommitment(winner)`; `deleteMatch(CHILD_TOURNAMENT, ONE/TWO)`;
     delete mapping; `child.tryRecoveringBond()`. The returned boolean is ignored, so a rejected
     child payment does not revert parent progress and leaves the child claimer and balance
     retryable. All child calls run inside the parent's lock.
   - **Non-leaf eliminate** (`eliminateInnerTournament`): require non-leaf; require
     `child.canBeEliminated()`; `deleteMatch(CHILD_TOURNAMENT, NONE)` eliminating both parent
     commitments; delete mapping. It does not settle or burn the no-winner child's balance.
   - **Timeout win** (`winMatchByTimeout`, `refundable(WIN_MATCH_BY_TIMEOUT)`): exactly one
     of (clockOne hasTimeLeft, clockTwo hasTimeLeft) (else `NeitherClockHasTimedOut`);
     winner's children verified; winner `clock.deducted(loser.timeSinceTimeout())` - penalty
     for claiming late; reverts `InitializedClockCannotHaveZeroAllowance` if it would zero
     the winner, forcing the eliminate path; `pairCommitment(winner)`; `deleteMatch(TIMEOUT,
     ONE/TWO)`.
   - **Timeout eliminate** (`eliminateMatchByTimeout`, `refundable(ELIMINATE_MATCH_BY_TIMEOUT)`):
     `(!clockOne.hasTimeLeft && !clockTwo.timeLeft().gt(clockOne.timeSinceTimeout()))` ||
     symmetric; else `AtLeastOneClockHasNotTimedOut`. `deleteMatch(TIMEOUT, NONE)`, both
     claimers deleted.

6. **Result & terminal balance settlement:** `isClosed = now >= startInstant + allowance` (`timeoutElapsed`,
   inclusive at equality). `isFinished = isClosed && matchCount == 0`. The surviving dangling
   commitment is the result. Root: `arbitrationResult` returns `(true, dangling,
   finalStates[dangling])` or reverts `TournamentFailedNoWinner` if finished-with-no-dangling.
   Non-root: parent reads `innerTournamentWinner` (returns contested-parent commitment matching
   winner's final state + winner + winner clock deducted by `now - finishedTime`; asserts the
   second branch) and `canBeEliminated` (finished+no-dangling OR finished+winner's allowance
   window elapsed since `winnerCouldHaveWon`; reverts on root). `tryRecoveringBond` (`withLock`,
   public) pays `min(address(this).balance, bondValue())` to `claimers[dangling]` once
   `isFinished` and a dangling exists. A zero balance skips that call. If a nonzero recipient
   call fails, it returns `false` with the claimer and full balance unchanged. After success,
   it burns the actual post-callback residual and deletes the claimer. A parent calls it on the
   child after consuming the result. PRT-007 made a second call after success an idempotent
   no-op; ETH forcibly sent after that completion stays stranded. A no-winner child has no
   corresponding payout or burn path.

### Timing / chess clocks (`Time.sol` + `Clock.sol`)

All time is in **block numbers** (`currentTime = uint64(block.number)`); cannonfile /
`Deployment.s.sol` convert seconds->blocks dividing by `chainAvgBlockTime`. `Clock.State =
{Duration allowance, Instant startInstant}`. Two disjoint sentinels: `startInstant == 0` <=>
PAUSED (a paused clock **always** `hasTimeLeft == true`); `allowance == 0` <=> NOT INITIALIZED.
`_setNewPaused` (the single storage initializer, funnel for `setNewPaused`/`reInitialized`/
`deducted`/`addMatchEffort`) reverts on zero allowance, keeping the sentinels disjoint.
`advanceClock` banks `timeLeft` into `allowance` then toggles `startInstant` (reverts
`CannotAdvanceTimedOutClock` if zero). Within a bisecting match exactly one clock runs;
`advanceMatch` toggles both per step. `addMatchEffort` grants `matchEffort` per pairing capped
at `maxAllowance`. The memory `deduct` (used by `innerTournamentWinner`) is the **only** path
that can produce a zero-allowance clock without reverting - the zero is caught later when
`reInitialized` writes it in the parent. `timeSinceTimeout` reverts on a paused clock (guarded
by short-circuit `&&` in both timeout callers). Mainnet: `maxAllowance = 7d+1h`, `matchEffort =
5min x 92` (= sum of heights 48+17+27) ~ 7.67h, `MAX_GAS_PRICE = 50 gwei`, `PRIORITY_FEE_CAP =
10 gwei`.

### Bond economics (`Gas.sol` + `refundable`)

`bondValue() = _totalGasEstimate() * MAX_GAS_PRICE (50 gwei)`. `_totalGasEstimate =
Gas.ADVANCE_MATCH * commitmentArgs.height + max(SEAL_LEAF + WIN_LEAF, SEAL_INNER + WIN_INNER)`.
Each Gas constant includes a fixed `TX = 25000` overhead. `refundable(gasEstimate)` acquires
the lock, runs, then refunds `msg.sender` `min(contract balance, bondValue * gasEstimate /
_totalGasEstimate, (Gas.TX + gasBefore - gasAfter) * min(tx.gasprice, basefee +
PRIORITY_FEE_CAP))`, emits `PartialBondRefund`, releases lock. A rejecting recipient gets
`success = false` but the call does NOT revert. The bond is sized for ~height advances + one
seal + one win per participant; a commitment that keeps winning re-enters and plays many
matches, each triggering `refundable` calls - **the global bound (is one bond's refundable
share, summed across all matches a single commitment plays, capped below the posted bond?) is
the central economic property to prove and is NOT locally enforced.**

Terminal settlement reserves no bond against those refunds. It pays the winning claimer at most
the lesser of the then-current balance and one bond, then burns the post-payment residual. A
rejecting claimer leaves the entire balance unchanged for retry.

### Trust boundaries

1. **Merkle commitment** (`Commitment.sol` + `Tree.sol`): order-sensitive keccak (OZ
   `Hashes.efficientKeccak256`, raw 64 bytes, **NO domain separation** between leaf and
   internal node, NO length prefix). `getRoot` folds a leaf+siblings using bits of `position`;
   **HIGH bits of position (>= treeHeight) are silently ignored** -> positions congruent mod
   `2^treeHeight` share a proof; soundness pushed onto callers to keep `position < 2^height`.
   `requireFinalState` hard-codes the rightmost (all-ones) path. `toMachineHash` is an
   unchecked `bytes32 -> Machine.Hash` reinterpret, safe only because Match descended to
   height 0 (true leaf).
2. **Bisection parity** (`Match.sol`): `runningLeafPosition` is EVEN until the final seal
   (every interior right-descent adds `1 << currentHeight` with `currentHeight >= 1`, i.e.
   even; the only odd `+1` is `_setDivergenceOnRightLeaf`). Hence `getDivergence`'s
   `runningLeafPosition % 2` reconstructs exactly the left/right choice `sealMatch` made via
   the live `agreesOnLeftNode` comparison. Three `height % 2` uses (agree-proof commitment
   selection in `sealMatch`; `_getDivergenceOnLeftLeaf`; `_getDivergenceOnRightLeaf`) decide
   who wins; their mutual consistency is the prime safety target (tests `Match.t.sol` pin the
   four divergence tables for heights 2/3).
3. **State transition** (`state-transition/*`): leaf `winLeafMatch` delegates the disputed
   step entirely to `IStateTransition.transitionState` (`CartesiStateTransition`). It
   bit-decodes `counter` into one of three branches (input boundary: `counter & INPUT_MASK ==
   0`, `INPUT_MASK = 2^68-1`; big-step boundary: `(counter+1) & BIG_STEP_MASK == 0`,
   `BIG_STEP_MASK = 2^20-1`; else plain uarch step) and composes RISC-V step / uarch reset /
   CMIO checkpoint+sendCmio+revertIfNeeded over an in-memory `AccessLogs.Context`, returning
   `currentRootHash`. Every step-lib read/write is proof-gated against `machineState`'s root,
   so a wrong proof reverts; the returned hash is taken as ground truth with **NO second
   opinion**. The provider (`IDataProvider`, threaded unchanged from root into every child)
   supplies the input Merkle root (`bytes32(0)` = out-of-bounds -> CMIO injection skipped).
   `RiscVStateTransition.step` **DISCARDS the `UArchStepStatus`** (Success / CycleOverflow /
   UArchHalted) returned by `UArchStep.step` (verified in `machine/step`), so a step at
   uarch-cycle-max or on a halted uarch is a silent no-op on the root. `inputLength` (uint64
   from attacker-controlled `proofs[:8]`) is bounded by the slice and `SafeCast.toUint32`, and
   `SendCmioResponse` reverts if the write exceeds `AR_CMIO_RX_BUFFER_LOG2_SIZE`. Machine
   version is NOT pinned on-chain ("TODO add CM_MARCHID").
4. **Factory** (`MultiLevelTournamentFactory`): `instantiate` (root) is permissionless;
   `instantiateInner` is **fully permissionless with NO validation** (no `msg.sender` gate, no
   level-range check, no link to a real parent match). Orphan inner tournaments are inert
   against honest parents because a parent only ever consumes children recorded in its own
   `matchIdFromInnerTournaments`. Factory keeps no registry; emits `TournamentCreated` only for
   roots (inner creation is announced by the parent's `NewInnerTournament` event). No
   zero-address/sanity checks in either constructor; `matchEffort`/`maxAllowance == 0` would
   deploy fine but brick clocks at first use.

### Reentrancy

A single transient `locked` flag guards `withLock` (`joinTournament`, `tryRecoveringBond`) and
`refundable` (advance/seal/win/eliminate). All external ETH moves (`tryRecoveringBond`'s
capped payout and residual burn, `refundable`'s refund) and the cross-contract child calls in
`winInnerTournament` (`canBeEliminated`, `innerTournamentWinner`, `tryRecoveringBond`) run
inside the lock. The lock is per-instance and transient (resets each tx). Cross-contract VIEW
calls to a DIFFERENT contract instance do not take this instance's lock, so trust in child view
results rests on the parent-child binding being unforgeable.

### Safety anchor (emergent, not locally enforced)

The surviving dangling commitment at the root is the canonical result; an incorrect commitment
can never be that survivor. This emerges from: `winLeafMatch` (only the commitment whose final
state equals the on-chain step result wins), the bisection parity mapping, the contested-state
forwarding to children, the clock carryover, and the recursive propagation via
`winInnerTournament`. `arbitrationResult` merely reads the survivor. **This is the property the
whole audit must prove.**

---

## 2. Invariant ledger

Each: statement * where enforced * how it could break.

- **SAFE-1 - Root survivor = correct result.** The surviving dangling commitment at the ROOT
  is the canonical correct result; a commitment to an incorrect computation can never be the
  root survivor.
  - *Enforced:* emergent across `winLeafMatch`, `Match.getDivergence`/`_getDivergenceOn{Left,
    Right}Leaf` parity, `validContestedFinalState` forwarding, `winInnerTournament` recursion,
    `arbitrationResult` (just reads dangling). NOT a single `require`.
  - *Breaks if:* any parity flaw (winner mis-attribution); inconsistency between the agree-proof
    commitment selection in `sealMatch` (odd->One, even->Two) and the winner mapping; wrong
    contested-state forwarded to a child; `transitionState` returning a wrong-but-self-consistent
    post-state; a counter-decode branch error; `runningLeafPosition` parity desync.
- **SAFE-2 - `runningLeafPosition` parity.** Even at every point before the final leaf seal;
  becomes odd iff divergence is on the right leaf; `getDivergence`'s `% 2` reconstructs exactly
  the branch `sealMatch` chose via live `agreesOnLeftNode`.
  - *Enforced:* `_goDownRightTree` adds `1 << currentHeight` (post-decrement >= 1 -> even >= 2);
    `_setDivergenceOnRightLeaf` adds exactly 1 (sole odd increment); `getDivergence` branches on
    `% 2`.
  - *Breaks if:* any interior right-descent adds an odd value (off-by-one making the shift
    `1 << 0`); `advanceMatch` reachable at `currentHeight == 1`; the final right seal adds an even
    value. High-value deep-tree fuzz target.
- **SAFE-3 - Agree-proof vs winner-mapping cross-consistency.** The agree-state-proof commitment
  selection (odd->One, even->Two, at `runningLeafPosition - 1`) is mutually consistent with the
  winner mapping (`_getDivergenceOn*Leaf` `% 2`) for ALL heights and BOTH divergence sides.
  - *Enforced:* `sealMatch` (`if (height % 2 == 1)`) + `_getDivergenceOn{Left,Right}Leaf`; tests
    pin heights 2/3 only.
  - *Breaks if:* an adversary asserts an agree state its opponent never committed because the
    agree proof is checked against the wrong commitment relative to which leaf is bound as
    `finalStateOne/Two`. The geometric justification is nowhere derived in code; only small-height
    tests cover it. **Independent derivation required across odd/even height x left/right
    divergence.**
- **SAFE-4 - Leaf verdict = one on-chain step, taken as ground truth.** The disputed step's
  post-state is computed once and never cross-checked.
  - *Enforced:* `winLeafMatch` single `transitionState` call + `WrongFinalState` equality;
    `CartesiStateTransition` proof-gates every read/write.
  - *Breaks if:* `transitionState` returns a wrong hash undetectably - (a) malicious/incorrect
    `IDataProvider`; (b) a step-lib accepting a wrong root; (c) `RiscVStateTransition.step`'s
    discarded `UArchStepStatus` making a CycleOverflow/UArchHalted step a silent no-op while still
    returning an authoritative hash; (d) counter mis-decode; (e) machine-version drift (CM_MARCHID
    not pinned).
- **SAFE-5 - Parent-child binding.** Only a child tournament THIS tournament created can be
  consumed by win/eliminate `InnerTournament`.
  - *Enforced:* `matchIdFromInnerTournaments[child]` set only in
    `sealInnerMatchAndCreateInnerTournament`; consumers look it up and `requireExist` (unknown
    child -> `Id{0,0}` -> `ZERO_ID` -> `MatchDoesNotExist`); mapping deleted in both consume paths.
  - *Breaks if:* two distinct real matches hash to the same `Match.IdHash` (keccak collision);
    mapping not cleared (it is); a path writing the mapping for an attacker child (none found).
    Permissionless `instantiateInner` mints orphans, harmless only while no honest parent
    references them.
- **SAFE-6 - Commitment identity & proof shape.** Root = `join(left,right) = keccak(left||right)`;
  submitted `finalState` is the rightmost leaf; proofs must have `length == height`.
  - *Enforced:* `joinTournament` (`requireFinalState` via `getRootForLastLeaf`), re-derived in
    win paths / `pairCommitment` assert / `winMatchByTimeout` verify; `getRoot*` require
    `siblings.length == treeHeight`.
  - *Breaks if:* keccak collision/second-preimage (assumed infeasible); **no domain separation**
    leaf vs internal (safe only under fixed agreed per-level height); `getRoot` ignoring position
    high bits (callers MUST keep `position < 2^height` - relied on by `requireState`'s
    `runningLeafPosition - 1`); off-chain builder placing final state somewhere other than the
    rightmost leaf.
- **INV-CLK-1 - Sentinel disjointness.** `startInstant == 0` <=> paused; `allowance == 0` <=>
  uninitialized; an initialized clock always has `allowance > 0`.
  - *Enforced:* `_setNewPaused` reverts on zero (funnel for all initializers); `advanceClock`
    reverts before leaving 0; `addMatchEffort` only adds with `matchEffort > 0`.
  - *Breaks if:* `Clock.deduct` (memory) returns a zero-allowance State without reverting and it
    reaches storage other than via `reInitialized`/`_setNewPaused`; a future direct
    `allowance = 0` write; `maxAllowance` configured 0.
- **INV-CLK-2 - One clock runs per live match; turns alternate.** Both toggle each advance.
  - *Enforced:* `pairCommitment` pauses both via `addMatchEffort` then advances only the dangling
    clock; `advanceMatch` advances both (toggling); `sealLeafMatch` is the SANCTIONED exception
    (both run); `sealInner` pauses both.
  - *Breaks if:* a path toggling only one clock (other than the single creation-time advance); a
    clock entering a match already running; an odd number of advances on one clock. Would corrupt
    timeout math.
- **INV-CLK-3 - Timeout-claim fairness coupling.** `winMatchByTimeout` succeeds only if deducting
  the loser's `timeSinceTimeout` from the winner leaves > 0; otherwise the only resolution is
  `eliminateMatchByTimeout` (both eliminated). The two conditions must partition the post-timeout
  space.
  - *Broken:* `winMatchByTimeout`'s `deducted` reads banked `.allowance`, while
    `eliminateMatchByTimeout` compares live `timeLeft`. After leaf sealing both clocks run, creating
    an overlap where both entry points succeed. At equality only eliminate-both is intended.
    Confirmed as PRT-002 and retained as a boundary fuzz target.
- **INV-CLK-4 - Deadline semantics.** At `elapsed == allowance` the clock is TIMED OUT
  (`hasTimeLeft` false via strict `gt`; `timeLeft` 0; `timeSinceTimeout` 0); tournament closure
  uses inclusive `timeoutElapsed` (`!gt`). They agree at equality but anchor to different instants
  and durations.
  - *Enforced:* `Clock.hasTimeLeft` (strict); `Clock.timeLeft`/`timeSinceTimeout` (monus);
    `Time.timeoutElapsed` (`!(t+d).gt(now)`); `isClosed` uses `timeoutElapsed`.
  - *Breaks if:* a one-block window where a match clock is timed out but the tournament not yet
    closed (or vice-versa) given different anchors; mismatched strict-vs-inclusive across
    `canBeEliminated`, `setNewPaused` monus at join.
- **INV-CLK-5 - Inner-clock carryover never silently bricks parent resolution.**
  `winInnerTournament` re-initializes the parent clock from the inner winner's remaining time,
  reverting if zero.
  - *Enforced:* `winInnerTournament`'s `reInitialized(innerClock)` -> `_setNewPaused` reverts on
    zero; `innerTournamentWinner` returns `clock.deduct(now - finishedTime)` (memory, can be zero);
    `canBeEliminated` gates whether `winInnerTournament` is even allowed.
  - *Breaks if:* a window where child is NOT yet eliminable (so `winInnerTournament` is allowed)
    YET `deduct()` floors the carried clock to ~0, causing `reInitialized` to revert - **bricking
    the legitimate winner's propagation up.** Reconcile `canBeEliminated`'s
    `timeoutElapsed(clock.allowance)` window vs `innerTournamentWinner`'s `deduct(now -
    finishedTime)`.
- **INV-MATCH-1 - Lifecycle monotonicity.** `currentHeight` starts at `args.height`, decreases by
  exactly 1 per advance and per seal, reaching 0 only at seal; never increases. Predicates
  (`canBeAdvanced > 1`, `canBeSealed == 1`, `isSealed == 0`) partition the lifecycle.
  - *Enforced:* `_goDown*` `assert(currentHeight > 1)` then `--`; `_setDivergence*`
    `assert(currentHeight == 1)` then `= 0`; predicates gate entrypoints.
  - *Breaks if:* a new internal caller decrements without the assert, or allows advance at height 1
    / seal at height > 1. Asserts Panic (hard abort) - fine for safety, fragile for new callers.
- **INV-MATCH-2 - Slot semantics across seal.** `otherParent` holds `join(children)` until seal,
  then is repurposed to the agree-state hash; `leftNode`/`rightNode` hold children until seal,
  then the two contested final-state leaves.
  - *Enforced:* `requireParentHasChildren` checks `otherParent == join(left,right)` each step;
    `_goDown*` set `otherParent` to the chosen child; `_setAgreeState` overwrites post-seal;
    `_setDivergence*` write the divergent leaf into the opposite-named slot.
  - *Breaks if:* a reader interprets `otherParent` as a parent node after seal (none do today);
    alternation ever sets `otherParent` to the wrong child - `requireParentHasChildren` on the
    NEXT step still passes (only checks the join relation) but bisection tracks the wrong subtree.
- **INV-MATCH-3 - Order-sensitive match identity.** Keyed by `keccak(abi.encode(Id{commitmentOne,
  commitmentTwo}))`; pairing always assigns dangling = One, newcomer = Two.
  - *Enforced:* `Match.hashFromId`; `pairCommitment`/`createMatch` ordering; `requireExist` on
    idHash.
  - *Breaks if:* a caller constructs `Id` with swapped order -> `getMatch` misses and the
    One/Two->final-state mapping inverts. `Match.sol` does NOT enforce ordering; it trusts
    `Tournament`.
- **INV-LIFE-1 - `matchCount` accuracy.** Tracks live matches; `isFinished` requires
  `matchCount == 0`.
  - *Enforced:* `pairCommitment` increments on creation; `deleteMatch` (sole decrement, once per
    resolution) decrements. Distinct from observability counters.
  - *Breaks if:* a match created without `++` or deleted without `--` (or twice). Underflow needs
    ROI-impossible counts.
- **INV-LIFE-2 - Single dangling slot.** `ZERO_NODE` = "none"; `setDanglingCommitment` only reached
  when none exists.
  - *Enforced:* single slot; `pairCommitment` consumes (`clearDangling`) or sets;
    `hasDanglingCommitment` treats non-zero as present.
  - *Breaks if:* a legitimate root equal to `ZERO_NODE` (keccak->0, negligible) read as "no
    dangling"; any path calling `setDanglingCommitment` while one exists (none currently).
- **INV-FUND-1 - Fund safety and terminal payout.** The first claimer of the winning commitment
  receives at most one terminal bond; the post-payment residual is burned (PRT-008).
  - *Enforced:* `_refundableAfter` caps each action refund; `tryRecoveringBond` pays
    `min(balance, bondValue())`, burns the actual post-callback residual, and removes the winning
    claimer only after success; `deleteMatch` removes losers' claimers.
  - *Breaks if:* the sum of per-function refund shares a single commitment triggers ACROSS MANY
    MATCHES (a repeatedly-winning commitment re-enters) exceeds `_totalGasEstimate`, draining the
    pooled terminal balance. **Multi-match accounting is unproven here.** Also the `+Gas.TX`
    overhead in the gasUsed term could over-refund vs real gas in adversarial conditions.
- **INV-FUND-2 - `tryRecoveringBond` reentrancy-safe and retry-safe.** The capped payment and burn
  occur inside `withLock`; a rejecting recipient retains its claimer and full balance for retry.
  - *Enforced:* `withLock`; failed payment returns before burn or deletion; successful payment is
    followed by residual burn and claimer deletion in the same transaction.
  - *Enforced after PRT-007:* a missing claimer on a finished tournament with a winner means
    recovery already succeeded, so later root settlement or parent propagation returns true
    without another transfer. ETH forcibly sent after that point remains stranded.
- **INV-REENT-1 - No re-entry into a state-mutating entrypoint.** Mid-execution external ETH
  transfers and child calls cannot re-enter.
  - *Enforced:* transient `locked`; `withLock` + `refundable`; all ETH moves and
    `winInnerTournament`'s child calls inside the lock.
  - *Breaks if:* a state-dependent VIEW on a DIFFERENT instance (`child.canBeEliminated`/
    `innerTournamentWinner`) trusted while not under this instance's lock - reachable only if SAFE-5
    were bypassed.
- **INV-CFG-1 - Immutable config.** Every clone configured entirely via immutable args; no
  constructor/initializer/setter.
  - *Enforced:* factory builds args once -> `cloneWithImmutableArgs`; Tournament reads only via
    `_tournamentArgs`; no constructor/initializer/abstract.
  - *Breaks if:* an initializer/setter added; `abi.encode`/`abi.decode` layouts diverge (both share
    the struct, compiled together - sound); the immutable-args region being mutable (it is not).
- **INV-CFG-2 - Per-level shape & level count consistent.** `levels` copied verbatim from the
  provider (identical at all levels); `log2step`/`height` per level from the same entry; join
  proofs `length == height`.
  - *Enforced:* factory copies `params.levels`/`log2step`/`height`;
    `CanonicalTournamentParametersProvider` returns `ArbitrationConstants.LEVELS`; `getRoot*`
    require `siblings.length == height`.
  - *Breaks if:* a non-canonical provider returns different `levels` per level, or mismatched
    `log2step`/`height`; `ArbitrationConstants` arrays regenerated inconsistently for a different L;
    `instantiateInner` with `_level >= LEVELS` (OOB Panic) - masked legitimately because
    `_isLeafTournament` blocks `instantiateInner` at the leaf.
- **INV-STF-1 - Counter decomposition total & exclusive.** Exactly one of {input boundary, big-step
  boundary, plain uarch step} runs for any counter; the 20/48 span split must match the off-chain
  commitment cycle layout and leaf `log2step == 0`.
  - *Enforced:* `CartesiStateTransition.transitionState` if/else-if/else on `counter & INPUT_MASK`
    and `(counter+1) & BIG_STEP_MASK`; `LOG2_UARCH_SPAN_TO_BARCH = 20`,
    `LOG2_BARCH_SPAN_TO_INPUT = 48`.
  - *Breaks if:* the 20/48 constants drift out of sync with `ArbitrationConstants.log2step` (leaf
    must be 0) - nothing links the two in code; a future L change touching one without the other.

---

## 3. Disagreements / prime leads

Cross-checks between mappers; most resolved-but-flagged.

1. **height%2 parity cross-consistency** *(resolved to the extent code allows; cross-consistency
   proof remains OPEN - the #1 audit lead)*. The left/right-selector consistency between
   `sealMatch`'s live `agreesOnLeftNode` and `getDivergence`'s `runningLeafPosition % 2` was proven
   (runningLeafPosition even until the final seal). The agree-PROOF commitment selection
   (odd->One/even->Two at `runningLeafPosition - 1`) vs the winner-MAPPING
   (`_getDivergenceOn*Leaf` `% 2`) consistency is **not provable from in-scope code + tests alone**
   (tests pin only heights 2/3). *Why it matters:* SAFE-2/SAFE-3 - the mechanism that decides who
   wins. Needs independent derivation / exhaustive fuzz across odd/even height x left/right.
2. **`sealInnerMatchAndCreateInnerTournament` omits `requireExist()`** (only `requireCanBeSealed`),
   unlike `sealLeafMatch` (both). **Confirmed.** Benign today: a zeroed State has `currentHeight ==
   0` and `canBeSealed` requires `== 1`; `createMatch` is the only writer of a nonzero
   `currentHeight`. *Why it matters:* INV-MATCH-1 latent fragility - flag for regression-guarding.
3. **`RiscVStateTransition.step` discards `UArchStepStatus`.** **Confirmed** in `machine/step`:
   `step()` returns `{Success, CycleOverflow, UArchHalted}`; `RiscVStateTransition.step` does
   `UArchStep.step(a); return a;` discarding it. A CycleOverflow/UArchHalted step is a silent no-op
   on `currentRootHash`, yet `transitionState` returns a hash `winLeafMatch` treats as
   authoritative. *Why it matters:* SAFE-4. Fixed-point identity is consistent with commitment
   padding, but reachability at halt, overflow, reset, and exception boundaries is not discharged.
   Deferred to the state-transition semantics workstream as STF-TODO-001 in `REVIEW.md`.
4. **`eliminateMatchByTimeout` boundary** - code `timeLeft <= timeSinceTimeout`, NatSpec phrases
   `timeSinceTimeout >= timeLeft`. **Confirmed identical** (`a <= b <=> b >= a`), inclusive at
   equality - NatSpec-vs-code is a non-issue. The real lead is the off-by-one INTERACTION with
   `winMatchByTimeout`'s monus-based `deducted` (reverts on zero) at the equality block: a block
   where a match is neither winnable nor eliminable, or both? **Resolved:** both entry points can
   succeed in a sealed-leaf overlap because `deducted` uses stale stored allowance. PRT-002 requires
   equality and the full overlap to classify as eliminate-both.
5. **`arbitrationResult` lacks a root-only guard despite NatSpec "ROOT ONLY".** **Confirmed:** no
   `_isRootTournament` check; would return the survivor for an inner tournament too, whereas
   `canBeEliminated`/`innerTournamentWinner` revert `RequireNonRootTournament`. Not obviously
   exploitable (parents read `innerTournamentWinner`), but any consumer expecting a revert on
   non-root would be wrong. OPEN interface-contract lead.
6. **`pairCommitment` double-grants `matchEffort` to a freshly-joined newcomer.** **Confirmed:**
   `joinTournament` sets the clock via `setNewPaused(allowance)`, then `pairCommitment` calls
   `addMatchEffort` on both, so a newcomer pairing on join gets ~`allowance + matchEffort` (capped).
   *Why it matters:* it lets a late fresh claim recover a bounded delay tail and breaks clock-mass
   conservation. Planned non-bankable per-response replacement is PRT-009.
7. **`Time.sub` appears unused / dead code.** **Confirmed** via grep: no `src` file outside
   `Time.sol` references `Time.sub` (non-saturating subtraction next to saturating `monus`). Minor
   footgun for future edits - low-priority cleanup.

---

## 4. Gaps / out-of-scope trust

1. **Concrete `IDataProvider` is out of `src/`** (only the interface is in scope). SAFE-4 depends
   entirely on the real provider re-hashing `input`, comparing to a canonical input box, and
   returning `bytes32(0)` exactly for out-of-bounds indices. Injected at instantiate-time, threaded
   unchanged into every child. **The single biggest external trust assumption** - locate the real
   provider (likely `cartesi-rollups/`) and audit it separately.
2. **`machine/step` execution semantics** are out of scope. The interface contract is mapped
   (proof-gated root checks, discarded `UArchStepStatus`, RX-buffer bound, pristine-hash reset), but
   the internal correctness of those libs is unverified here. The coupling between the on-chain
   counter bit-layout (20/48) and off-chain leaf spacing (`log2step = [44,27,0]`) is asserted, not
   proven.
3. **Global bond-sufficiency (INV-FUND-1)** - whether one bond's summed refundable share across ALL
   matches a single repeatedly-winning commitment plays stays below the posted bond - needs a global
   worst-case match-count analysis tying re-pairing, the delay bound, and the refundable cap.
4. **Clock-carryover boundary (INV-CLK-5)** - whether a window exists where child is not-yet-
   eliminable yet `deduct` floors the carried clock to 0, reverting `reInitialized`. Reconcile
   `canBeEliminated`'s window with `innerTournamentWinner`'s `deduct` arithmetic.
5. **Identical-commitment-tree front-running** - `requireNotInitialized` locks out the second
   submitter of the same root. **Decision:** first-claimer ownership is intended because defense is
   permissionless. PRT-008 resolved the historical full-sweep recycling path by changing the
   payout and residual handling, not commitment uniqueness.
6. **`_refundableAfter` gas interplay** - the `+Gas.TX = 25000` added to measured gas vs real ETH
   spent; whether the refund can exceed real gas in any block-condition corner (bounded by balance
   and bond-share caps, but not exhaustively checked).
7. **No zero-address / sanity validation** in `MultiLevelTournamentFactory` or
   `CanonicalTournamentParametersProvider` constructors; `matchEffort`/`maxAllowance == 0` would
   deploy fine and brick clocks. `Deployment.s.sol`/cannonfile partly constrain this, but not every
   chain-kind path was traced (could any registered chain round `maxAllowance`/`avgBlockTime` to 0
   blocks?).
8. **Existing test coverage** of deep-tree parity, multi-match bond accounting, and the timeout
   boundary is unknown - worth checking during find (not as a target, but to see what's exercised).
9. **`BaseDeploymentScript.sol`** (referenced by `Deployment.s.sol`, provides
   `_create2`/`_storeDeployment`) was not read - outside the core trust boundary, low priority.

---

## 5. Coverage plan for the find stage

One finder per surface, using the listed vantages.

1. **Bisection parity & divergence mapping (the who-wins core)** - `tournament/libs/Match.sol`.
   SAFE-1/2/3. *Vantages:* property/parity finder (exhaustively derive agree-proof-vs-winner
   consistency across odd/even height x left/right; fuzz deep trees up to height 48 tracking
   `runningLeafPosition` parity vs `agreesOnLeftNode`); adversarial-input finder (can re-pairing
   reach `createMatch`'s `assert(verify)` with inconsistent leaves - Panic DoS?); `otherParent`
   wrong-subtree where `requireParentHasChildren` still passes (INV-MATCH-2).
2. **Tournament lifecycle & resolution state machine** - `tournament/Tournament.sol`. SAFE-1/4/5,
   INV-LIFE-1/2, INV-FUND-1/2, INV-REENT-1, leaf/non-leaf segregation, `arbitrationResult`
   root-guard, `sealInner` missing `requireExist`, `winLeafMatch` no-clock-check. *Vantages:*
   state-machine finder (reachable (match,clock,dangling) states; `matchCount` conservation;
   single-dangling; delete-once); reentrancy finder (lock covers every ETH move + child call;
   cross-instance view trust); access-control finder (leaf/non-leaf/root guards; `arbitrationResult`
   impact); economic finder (multi-match refund vs one bond).
3. **Chess-clock timing primitives** - `tournament/libs/Clock.sol`, `Time.sol`. INV-CLK-1..5; `Time.sub`
   dead code; monus saturation asymmetry; `deduct` zero-allowance escape. *Vantages:* boundary/
   off-by-one finder (equality block neither-winnable-nor-eliminable; strict-vs-inclusive
   mismatches; whether `winMatchByTimeout`'s winner can be the running clock); carryover finder
   (INV-CLK-5); liveness finder (matchEffort double-grant vs delay bound).
4. **Merkle commitment construction & proofs** - `tournament/libs/Commitment.sol`, `types/Tree.sol`.
   SAFE-6: no domain separation; ignored position high bits; `getRootForLastLeaf` duplicate fold;
   `toMachineHash` unchecked reinterpret; assert-vs-require inconsistencies. *Vantages:* crypto/
   second-preimage finder (can missing domain separation + ignored high bits alias a leaf into a
   position, given Match supplies `runningLeafPosition - 1`?); equivalence finder (`getRoot` vs
   `getRootForLastLeaf` for the all-ones path); confirm every call site passes children in original
   order.
5. **State-transition trust boundary (leaf step verifier)** - `state-transition/*`,
   `IStateTransition.sol`. SAFE-4, INV-STF-1: counter decode totality; 20/48 vs `log2step` linkage;
   discarded `UArchStepStatus`; attacker `inputLength` into `sendCmio`; `bytes32(0)` provider
   sentinel as control flow; checkpoint/revert spanning two calls; CM_MARCHID unpinned. *Vantages:*
   boundary finder (exactly one branch per counter; leaf `log2step == 0` => counter is a meta-cycle);
   adversarial-proofs finder (crafted counter reaching the discarded-status no-op; `inputLength`
   near 2^32 / RX-buffer rounding); trust-model finder (enumerate everything trusted with no second
   opinion).
6. **`IDataProvider` boundary** - `IDataProvider.sol`. SAFE-4 hinges on the real provider; only the
   interface is in scope. *Vantages:* interface-contract finder (document exact obligations: verify
   input matches canonical box, return canonical root or 0 only for true OOB; flag the concrete
   provider must be audited separately; note the overloaded-zero-return control-flow risk).
7. **Factory & inner-tournament instantiation** - `tournament/factories/*`, `ITournamentFactory.sol`.
   SAFE-5, INV-CFG-1/2: permissionless `instantiateInner` with no validation; non-deterministic
   CREATE clones; no zero-address checks; no inner-creation event; `tournamentFactory` blind-cast.
   *Vantages:* access-control/abuse finder (can an orphan inner with attacker-chosen provider ever
   be consumed by a legitimate parent - trace every writer of `matchIdFromInnerTournaments`? orphan
   spam / event-spoofing confusing off-chain clients? `_level >= LEVELS` OOB masked?); config finder
   (zero-param deployment bricking).
8. **Arbitration config & parameters** - `arbitration-config/*`, `types/TournamentParameters.sol`.
   INV-CFG-2, INV-STF-1: hardcoded `LEVELS = 3` + magic arrays whose NatSpec formula is wrong for
   level 0; per-level array OOB Panic; the L=3 <-> 20/48 linkage with no compiler enforcement; the
   future L=2 migration risk. *Vantages:* config/invariant finder (verify constants tile the
   computation - sum heights = 92, leaf `log2step = 0`; what breaks if L changes without regenerating
   arrays; level-vs-LEVELS sourced from two places never disagree; note the height NatSpec formula
   error).
9. **Core types & gas constants** - `types/Machine.sol`, `tournament/libs/Gas.sol`. `Machine.Hash`
   `ZERO_STATE` sentinel collision; Gas constants size the bond + refund shares. *Vantages:*
   economic finder (validate each Gas constant vs actual measured gas; bond covers worst-case at the
   configured gas price); sentinel finder (a real machine state can never be `ZERO_STATE`).
10. **Tournament interface & error/event contract** - `ITournament.sol`. Defines `TournamentArguments`/
    `NestedDispute` layout (must match factory encode + Tournament decode), every error/event, and
    drifted NatSpec. *Vantages:* interface-consistency finder (`abi.encode`/`decode` round-trip
    stable; cross-check every NatSpec claim - `arbitrationResult` guard mismatch, `MatchAdvanced`
    field meaning pre-vs-post-seal; event indexing supports lineage reconstruction, only roots get
    `TournamentCreated`).
11. **Deployment wiring & parameter conversion (context, lower priority)** - `cannonfile.toml`,
    `script/Deployment.s.sol`. Converts seconds -> blocks; wires the stack via CREATE2 zero-salt.
    *Vantages:* config finder (every registered chain's `avgBlockTime` vs durations cannot round any
    `Time.Duration` to 0; cannonfile and `Deployment.s.sol` agree; CREATE2 zero-salt doesn't enable
    deployment front-running/address-squat; note `BaseDeploymentScript.sol` unread).
