# PRT Contracts - Audit System Map (Stage 1)

> **Provenance.** Generated 2026-06-10 by the stage-1 mapping workflow
> (`prt-audit-map`, run `wf_60452ddc-ea6`): 6 parallel subsystem mappers read all
> 23 in-scope Solidity files, then a consolidator re-read code to adjudicate
> disagreements. ~723k tokens, 7 agents.
>
> **Status: audit-start map with manual resolution annotations.** This is not the
> current findings or test backlog; use `REVIEW.md` for those. The **code is the
> source of truth**; treat every unannotated claim here - especially anything
> marked "confirmed" or "verified" - as a lead to re-check, not a fact to rely on.
> Line numbers are deliberately omitted (they drift); symbols are cited instead.
> Scope: Solidity under `prt/contracts/src/`. Out of scope: off-chain clients,
> `machine/step` execution semantics, the concrete `IDataProvider`.

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
L2 = inner+leaf. CFG-001 selects L=2 with `log2step = [37,0]` and
`height = [55,37]`. Solidity test decoupling is complete; implementation
remains gated on the coordinated stride-37 node change.

### Lifecycle (per tournament instance)

1. **Join** (`joinTournament`, `withLock` + `tournamentOpen`): require
   `msg.value >= bondValue()`; `commitmentRoot = leftNode.join(rightNode)`;
   `requireFinalState` binds `finalState` to the rightmost leaf via `getRootForLastLeaf`
   (full-height proof); `requireValidContestedFinalState` (root accepts ANY final state,
   non-root only the two inherited contested states); `finalStates[root] = finalState`;
   `clocks[root].initializePausedAt(startInstant, allowance, current)` (one-shot;
   allowance reduced by elapsed since `startInstant`; reverts
   `InitializedClockCannotHaveZeroAllowance` if `elapsed >= allowance`, though
   `tournamentOpen` already blocks when closed); emit `CommitmentJoined`; `pairCommitment`;
   `claimers[root] = msg.sender`. Excess ETH is retained in the pooled balance
   and is subject to progress refunds, capped terminal payout, and residual burn.
   `initializePausedAt` blocks re-joining the same commitment root (two distinct
   participants with the identical tree collide; only the first joins. First-claimer ownership is
   intended because all progress calls are permissionless; PRT-008 caps the
   terminal payout consequence).

2. **Async pairing** (`pairCommitment`): single `danglingCommitment` slot (`ZERO_NODE`
   sentinel). `assert(leftNode.join(rightNode) == rootHash)`. If a dangling exists:
   `createMatch(dangling = commitmentOne, newcomer = commitmentTwo, seeded from newcomer's
   children, otherParent = dangling)`; both clocks retain their existing balances;
   `MatchClocks.startBisectionAt` starts the DANGLING clock first; `clearDangling`;
   `matchCount++`. Else store newcomer as dangling.

3. **Bisect** (`advanceMatch`, `refundable(ADVANCE_MATCH)` + `tournamentNotFinished`):
   `requireExist` + `requireCanBeAdvanced(currentHeight > 1)`. `Match.advanceMatch` verifies
   `otherParent == join(suppliedLeft, suppliedRight)`; if supplied left != stored leftNode ->
   descend LEFT, else descend RIGHT; updates `otherParent` to the chosen child of the
   just-exposed tree, `leftNode`/`rightNode` to the new children, `currentHeight--`, and
   (right only) `runningLeafPosition += 1 << currentHeight` (post-decrement, so an EVEN add
   >= 2). `MatchClocks.switchTurnAt` requires exactly one clock running, applies the
   non-bankable response discount, pauses it, and starts the other at the same `current`
   instant. Refund to `msg.sender` inside the lock.

4. **Seal** (`currentHeight` reaches 1):
   - **Leaf** (`sealLeafMatch`, `refundable(SEAL_LEAF_MATCH)`): require leaf;
     `requireExist` + `requireCanBeSealed`; `MatchClocks.startLeafRaceAt` requires the active
     bisection phase, discounts the final responder, then starts BOTH at the same instant (the
     deliberate exception; an already timed-out running clock reverts while pausing, forcing
     the timeout path). `Match.sealMatch` pins the
     divergent leaf (left/right via `agreesOnLeftNode`), repurposes `leftNode`/`rightNode`
     to hold the two contested final states and `otherParent` to hold the agree-state hash;
     proves agreeState against `commitmentOne` (if height odd) or `commitmentTwo` (if height
     even) at position `runningLeafPosition - 1`, or `== initialHash` when position 0.
   - **Non-leaf** (`sealInnerMatchAndCreateInnerTournament`, `refundable(SEAL_INNER...)`):
     require non-leaf; `requireExist` + `requireCanBeSealed`;
     `MatchClocks.pauseForInnerAt` requires the active bisection phase, discounts the final
     responder, leaves both paused, and returns their maximum allowance; `sealMatch`; `instantiateInner`
     spawns a child at `level+1` seeded with `agreeHash` as `initialHash`, the two contested
     commitments + final states, `allowance = _maxDuration`, `startCycle =
     toCycle(runningLeafPosition)`; `matchIdFromInnerTournaments[child] = matchId`; match
     persists sealed (not deleted) until resolved.

5. **Resolve:**
   - **Leaf** (`winLeafMatch`, `refundable(WIN_LEAF_MATCH)`): require leaf; both clocks
     `requireInitialized`; `requireExist` + `requireIsSealed`; `getDivergence` returns
     (agreeHash from `otherParent`, `agreeCycle = toCycle`, `finalStateOne`, `finalStateTwo`);
     calls `stateTransition.transitionState(agreeHash, agreeCycle, proofs, provider)` (a
     STATICCALL - view); caller-supplied children select `commitmentOne/Two`, whose contested final
     state must equal the computed post-state (else `WrongFinalState`/`WrongNodesForStep`);
     `settleProvenLeafWinnerAt` then requires the leaf-race phase and applies the shared timeout
     status. `NONE` charges zero; a matching single-winner status charges its `winnerCharge`; an
     opposite winner or `ELIMINATE_BOTH` rejects the proof. The permitted survivor is paired at
     that same instant, then `deleteMatch(STEP, ONE/TWO)`. At the same observation instant,
     successful proof and timeout resolutions cannot conflict: a compatible proof enters identical
     re-pairing with the same survivor and charged clock balance, while an incompatible proof
     rejects (PRT-010).
   - **Non-leaf win** (`winInnerTournament`, `refundable(WIN_INNER_TOURNAMENT)`): require
     non-leaf; `matchId` from `matchIdFromInnerTournaments[child]`; the loaded match state must
     exist and be sealed; require `!child.canBeEliminated()`; `(finished, winner, , innerClock)
     = child.innerTournamentWinner()`; require `finished`; `winner.requireExist`; supplied
     children must join to `winner`; parent `clock[winner].requireInitialized` then
     `replaceWithPaused(innerClock)` (the returned inner clock is already paused after carryover;
     reverts if zero); `pairCommitment(winner)`; `deleteMatch(CHILD_TOURNAMENT, ONE/TWO)`;
     delete mapping. Child balance recovery is independent and permissionless; propagation does
     not invoke the winning claimer or burn the child's residual balance. The child result reads
     run inside the parent's lock.
   - **Non-leaf eliminate** (`eliminateInnerTournament`): require non-leaf; load the child-linked
     match ID and require its stored state to exist and be sealed; require
     `child.canBeEliminated()`; `deleteMatch(CHILD_TOURNAMENT, NONE)` eliminating both parent
     commitments; delete mapping. It does not settle or burn the no-winner child's balance.
   - **Timeout win** (`winMatchByTimeout`, `refundable(WIN_MATCH_BY_TIMEOUT)`): at one explicit
     `current`, `MatchClocks.classifyTimeoutAt` must return `ONE_WINS` or `TWO_WINS` (else the
     legacy `NeitherClockHasTimedOut` selector); winner's children verified;
     `chargeAndPauseAt(status.winnerCharge, current)` charges the classified overdue duration
     from the winner's live remainder and pauses the survivor; `pairCommitment(winner)`;
     `deleteMatch(TIMEOUT, ONE/TWO)`.
   - **Timeout eliminate** (`eliminateMatchByTimeout`, `refundable(ELIMINATE_MATCH_BY_TIMEOUT)`):
     the same classifier must return `ELIMINATE_BOTH`; else
     `AtLeastOneClockHasNotTimedOut`. `deleteMatch(TIMEOUT, NONE)`, both claimers deleted.

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
   it burns the actual post-callback residual and deletes the claimer. PRT-007 made a second call
   after success an idempotent no-op; ETH forcibly sent after that completion stays stranded.
   Child recovery is a separate permissionless operation independent of parent propagation. A
   no-winner child has no corresponding payout or burn path.

### Timing / chess clocks (`Time.sol` + `Clock.sol` + `MatchClocks.sol`)

All time is in **block numbers** (`currentTime = uint64(block.number)`); cannonfile /
`Deployment.s.sol` convert seconds->blocks dividing by `chainAvgBlockTime`. `Clock.State =
{Duration allowance, Instant startInstant}` keeps its external two-field shape. `allowance == 0`
means NOT INITIALIZED. An initialized clock is PAUSED when `startInstant == 0` and RUNNING
otherwise. `remainingAt` and `overdueByAt` are pure calculations at a caller-supplied instant;
both reject uninitialized clocks, and `overdueByAt` also rejects paused clocks. Tournament
operations read `currentTime()` once for each related transition.

`Clock` owns one-clock transitions: one-shot `initializePausedAt`, `startAt`, non-bankable
`pauseAfterResponseAt`, `chargeAndPauseAt`, and paused-state carryover. For response balance `b`,
elapsed time `e`, and budget `G`, response pausing requires `e < b` and stores
`b - max(e - G, 0)`. Pairing cannot increase a balance. `_setPaused` rejects zero allowance,
keeping storage sentinels disjoint. `Clock.deductPaused` can return zero in isolation. For finish
time `F` and stored allowance `A`, `innerTournamentWinner` calls it for a winner only while
`current < F + A`, so a parent-visible carried clock is strictly positive. `replaceWithPaused`
defensively rejects zero storage allowance.
`MatchClocks` owns pair phases
and asserts its source phase: an active bisection has exactly one running clock, a sealed leaf has
two running clocks with the same start instant, and a sealed inner match has two paused clocks.
Its pure timeout classifier returns `NONE`, one of two single-winner outcomes with a winner
charge, or `ELIMINATE_BOTH`; the capability view and both timeout mutations consume that status.
Proven leaf settlement consumes it too and asserts the sealed-leaf phase. Mainnet:
`maxAllowance = 7d+1h`, the legacy-named `matchEffort = G = 5min` (25 Ethereum blocks),
`WORK_PRICE_CAP = 50 gwei`, `PRIORITY_FEE_CAP = 10 gwei`. Across the 92 height units in one
root-to-leaf descent with one match at each level, the maximum cumulative response discount is
7 hours 40 minutes. Re-pairing creates a new match with new discounts.

### Bond economics (`Bond.sol` + `Gas.sol` + `refundable`)

`Bond` defines one common `SYBIL_PRINCIPAL`, a 50-gwei `WORK_PRICE_CAP`, and
`bondValue(h) = principal + ((h - 1) * ADVANCE_MATCH + terminalMaximum) * WORK_PRICE_CAP`.
Each `Gas` allocation includes a fixed `TX = 25000` overhead. `refundable(gasEstimate)` acquires
the lock, runs, then refunds `msg.sender` `min(contract balance, gasEstimate * WORK_PRICE_CAP,
(Gas.TX + gasBefore - gasAfter) * min(tx.gasprice, basefee + PRIORITY_FEE_CAP))`, emits
`PartialBondRefund`, and releases the lock. A rejecting recipient gets `success = false` but the
call does NOT revert. Recipient execution is capped at 50,000 gas, return data is not copied, and
a zero refund skips the callback while reporting success. A height-`h` match has at most `h - 1`
advances and at most the common terminal allocation, so it consumes at most its configured work
reserve.

With `J` unique paid joins, pairing and resolution create at most `J-1` matches even when a
winner repeatedly re-enters. The pre-recovery balance is therefore at least one full join deposit
plus one explicit principal per loser. Terminal settlement returns the winning deposit and burns
the residual if the recipient accepts. The current 0.00450875 ETH principal preserves inherited
behavior but still lacks economic calibration. A rejecting claimer leaves the entire balance
unchanged for retry. Its recipient execution has the same 50,000-gas ceiling.
Tournament-result staging ignores both `false` and a recovery revert, preserving the staged
result while leaving the old tournament retryable. See `REFUND-DESIGN.md` for the proof and fee
boundary.

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
   zero-address/sanity checks in either constructor. `maxAllowance == 0` would deploy fine but
   brick clocks at first use; `matchEffort == 0` is mechanically valid and disables the response
   discount.

### Reentrancy

A single transient `locked` flag guards `withLock` (`joinTournament`, `tryRecoveringBond`) and
`refundable` (advance/seal/win/eliminate). All external ETH moves (`tryRecoveringBond`'s
capped payout and residual burn, `refundable`'s refund) and the cross-contract child reads in
`winInnerTournament` (`canBeEliminated`, `innerTournamentWinner`) run inside the lock. The lock
is per-instance and transient (resets each tx). Cross-contract VIEW
calls to a DIFFERENT contract instance do not take this instance's lock, so trust in child view
results rests on the parent-child binding being unforgeable. Recipient payment calls are
gas-bounded and use no return-data output buffer; the zero-address residual burn has no untrusted
code boundary.

### Safety anchor (conditional and emergent, not locally enforced)

Under the one-honest-validator, responsiveness, and censorship-bound assumptions, the surviving
dangling commitment at the root is the canonical result. This emerges from: `winLeafMatch` (only
the commitment whose final state equals the on-chain step result wins while its clock remains
viable), the bisection parity mapping, the contested-state forwarding to children, clock
carryover, and recursive propagation via `winInnerTournament`. `arbitrationResult` merely reads
the survivor. If the correct participant misses its clock, timeout policy may preserve an
incorrect commitment; objective proof correctness does not override that deadline. **The
conditional root-survivor property is what the whole audit must prove.**

---

## 2. Invariant ledger

Each: statement * where enforced * how it could break.

- **SAFE-1 - Responsive root survivor = correct result.** Under the responsiveness and
  censorship-bound assumptions, the surviving dangling commitment at the ROOT is the canonical
  correct result.
  - *Enforced:* emergent across `winLeafMatch`, `Match.getDivergence`/`_getDivergenceOn{Left,
    Right}Leaf` parity, `validContestedFinalState` forwarding, `winInnerTournament` recursion,
    `arbitrationResult` (just reads dangling). NOT a single `require`.
  - *Breaks if:* any parity flaw (winner mis-attribution); inconsistency between the agree-proof
    commitment selection in `sealMatch` (odd->One, even->Two) and the winner mapping; wrong
    contested-state forwarded to a child; `transitionState` returning a wrong-but-self-consistent
    post-state; a counter-decode branch error; `runningLeafPosition` parity desync; the correct
    participant missing its clock.
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
- **SAFE-4 - Leaf verdict = one on-chain step, subject to clock viability.** The disputed step's
  post-state is computed once and never cross-checked; the proven side advances only if the
  shared timeout status still permits it.
  - *Enforced:* `winLeafMatch` single `transitionState` call + `WrongFinalState` equality;
    `settleProvenLeafWinnerAt` applies the timeout status; `CartesiStateTransition` proof-gates
    every read/write.
  - *Breaks if:* `transitionState` returns a wrong hash undetectably - (a) malicious/incorrect
    `IDataProvider`; (b) a step-lib accepting a wrong root; (c) `RiscVStateTransition.step`'s
    discarded `UArchStepStatus` making a CycleOverflow/UArchHalted step a silent no-op while still
    returning an authoritative hash; (d) counter mis-decode; (e) machine-version drift (CM_MARCHID
    not pinned); (f) the classifier-to-proven-side mapping permits a side incompatible with the
    timeout outcome.
- **SAFE-5 - Parent-child binding.** Only a child tournament THIS tournament created can be
  consumed by win/eliminate `InnerTournament`.
  - *Enforced:* `matchIdFromInnerTournaments[child]` set only in
    `sealInnerMatchAndCreateInnerTournament`; consumers look it up and require the corresponding
    stored `Match.State` to exist (an unknown child maps to the default ID, whose state is absent);
    mapping deleted in both consume paths.
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
- **INV-CLK-1 - Sentinel disjointness.** `allowance == 0` <=> uninitialized. For an initialized
  clock, `startInstant == 0` <=> paused; an initialized clock always has `allowance > 0`.
  - *Enforced:* `_setPaused` rejects zero for every storage write that pauses a clock;
    `startAt` requires initialized paused state and a nonzero instant;
    `pauseAfterResponseAt` rejects elapsed time at or after the original deadline.
  - *Breaks if:* `Clock.deductPaused` (memory) returns a zero-allowance State and it reaches
    storage other than via `replaceWithPaused`/`_setPaused`; a future direct
    `allowance = 0` write; `maxAllowance` configured 0.
- **INV-CLK-2 - Match clock phases are explicit.** Active bisection has exactly one running
  clock; turns alternate. A sealed leaf has two running clocks with the same start instant, and a
  sealed inner match has two paused clocks.
  - *Enforced:* `startBisectionAt`, `switchTurnAt`, `startLeafRaceAt`, `pauseForInnerAt`, and
    `settleProvenLeafWinnerAt` in `MatchClocks`; each asserts the required source phase and uses one
    supplied instant. Proven-leaf settlement additionally asserts the shared start instant.
  - *Breaks if:* a tournament path bypasses the pair transition helpers; a clock enters a match
    running; sealed-leaf start instants differ; a new helper silently accepts or repairs an illegal
    source phase. Any such break can corrupt timeout math.
- **INV-CLK-3 - Shared match-resolution classification.** `winMatchByTimeout` succeeds only if
  deducting the loser's `overdueByAt(current)` from the winner's `remainingAt(current)` leaves > 0;
  otherwise the only timeout resolution is `eliminateMatchByTimeout` (both eliminated). A proven
  leaf side may settle under `NONE` or its matching single-winner outcome; it rejects under the
  opposite winner or `ELIMINATE_BOTH`. Thus successful proof and timeout resolutions cannot select
  different survivors at the same observation instant.
  - *Enforced after PRT-002, PRT-004, and PRT-010:* `classifyTimeoutAt` makes
    `remaining > overdue` a single-winner outcome and the inclusive inverse
    `remaining <= overdue` an `ELIMINATE_BOTH` outcome. The capability view and both timeout
    mutation paths consume that status; `settleProvenLeafWinnerAt` also requires `NONE` or the
    proven side's matching winner outcome. `chargeAndPauseAt` applies the status's winner charge
    to the live remainder.
    Deterministic and symmetric model fuzzing covers the exact deadline, equality, both proven
    sides and commitment orderings, and the former sealed-leaf overlap.
  - *Breaks if:* a capability or mutation path reconstructs the condition independently; the
    outcome-to-side mapping is inverted; settlement ignores `winnerCharge`; proof settlement
    accepts an incompatible outcome.
- **INV-CLK-4 - Deadline semantics.** At `elapsed == allowance` the clock is TIMED OUT:
  `remainingAt(current) == 0` and `overdueByAt(current) == 0`. Tournament closure uses inclusive
  `timeoutElapsed` (`!gt`). They agree at equality but anchor to different instants and durations.
  - *Enforced:* `Clock.remainingAt`/`overdueByAt` (monus at an explicit instant);
    `pauseAfterResponseAt` requires `elapsed < allowance`; `Time.timeoutElapsed`
    (`!(t+d).gt(now)`); `isClosed` uses `timeoutElapsed`.
  - *Breaks if:* a one-block window where a match clock is timed out but the tournament not yet
    closed (or vice-versa) given different anchors; mismatched strict-vs-inclusive across
    `canBeEliminated`, `initializePausedAt` monus at join.
- **INV-CLK-5 - Inner-clock carryover never silently bricks parent resolution.**
  `winInnerTournament` replaces the paused parent clock with the inner winner's remaining time,
  reverting if zero. The returned balance cannot exceed the delegated child allowance, and
  re-pairing cannot refill it.
  - *Enforced:* `winInnerTournament`'s `replaceWithPaused(innerClock)` -> `_setPaused` rejects
    zero; `innerTournamentWinner` returns `clock.deductPaused(now - finishedTime)` only while
    `canBeEliminated` is false.
  - *Established boundary:* if finish time is `F` and stored allowance is `A`, propagation is
    valid through `F + A - 1`, where the returned balance is one. At `F + A`, winner retrieval is
    suppressed and elimination is valid. Algebra and deterministic boundary traces pin the
    partition; fuzzing exercises varied positive carryover and post-close charging inside it.
  - *Breaks if:* winner retrieval and elimination stop sharing that strict/inclusive boundary,
    elapsed time is charged from a different finish instant, or re-pairing refills carryover.
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
  - *Enforced:* `Match.hashFromId`; `pairCommitment`/`createMatch` ordering; existence checks on
    the stored `Match.State`.
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
  receives one full terminal bond under the configured work-reserve invariant; the post-payment
  residual is burned (PRT-008).
  - *Enforced:* `_refundableAfter` caps each action refund; `tryRecoveringBond` pays
    `min(balance, bondValue())`, burns the actual post-callback residual, and removes the winning
    claimer only after success; `deleteMatch` removes losers' claimers.
  - *Global bound:* `J` joins create at most `J-1` matches; each match consumes at most its
    configured work reserve, leaving at least `bondValue()+(J-1)*SYBIL_PRINCIPAL` before recovery.
    Re-pairing does not add a match without a newly joined opponent. This configured-reserve proof
    does not establish that actual transaction fees are fully reimbursed or that the checkpoint
    principal is economically adequate.
- **INV-FUND-2 - `tryRecoveringBond` reentrancy-safe and retry-safe.** The capped payment and burn
  occur inside `withLock`; a rejecting recipient retains its claimer and full balance for retry.
  - *Enforced:* `withLock`; recipient execution is capped at 50,000 gas and its return data is not
    copied; failed payment returns before burn or deletion; successful payment is followed by
    residual burn and claimer deletion in the same transaction.
  - *Enforced after PRT-007:* a missing claimer on a finished tournament with a winner means
    recovery already succeeded, so later recovery or tournament-result staging returns true without
    another transfer. ETH forcibly sent after that point remains stranded. Parent propagation
    does not depend on recovery.
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

1. **height%2 parity cross-consistency. Resolved.** The left/right-selector consistency between
   `sealMatch`'s live `agreesOnLeftNode` and `getDivergence`'s `runningLeafPosition % 2` was proven
   (runningLeafPosition stays even until the final seal). An independent sparse-Merkle model now
   exhausts both commitment orders and every position through height 8, covers boundary and
   alternating paths through height 55, and derives agree-proof ownership without copying Match's
   parity table. A multi-difference comparator pins leftmost-divergence precedence.
2. **`sealInnerMatchAndCreateInnerTournament` omitted `requireExist()`.** **Resolved:** the inner
   and leaf seal paths now both require stored-state existence before sealability. The regression
   pins the accurate `MatchDoesNotExist` selector for a fabricated match.
3. **`RiscVStateTransition.step` discards `UArchStepStatus`.** **Confirmed** in `machine/step`:
   `step()` returns `{Success, CycleOverflow, UArchHalted}`; `RiscVStateTransition.step` does
   `UArchStep.step(a); return a;` discarding it. A CycleOverflow/UArchHalted step is a silent no-op
   on `currentRootHash`, yet `transitionState` returns a hash `winLeafMatch` treats as
   authoritative. *Why it matters:* SAFE-4. Fixed-point identity is consistent with commitment
   padding, but reachability at halt, overflow, reset, and exception boundaries is not discharged.
   Deferred to the state-transition semantics workstream as STF-TODO-001 in `REVIEW.md`.
4. **`eliminateMatchByTimeout` boundary** - `MatchClocks.classifyTimeoutAt` compares
   `remainingAt(current) <= overdueByAt(current)`, equivalent to the NatSpec's overdue-time-first
   phrasing and inclusive at equality. PRT-002 made the mutation paths disjoint, and PRT-004 now
   derives both timeout mutations, the capability view, and proven-leaf settlement from that
   shared classification: timeout win succeeds iff `remaining > overdue`; elimination succeeds
   iff `remaining <= overdue`; a proven side must match any single timeout winner. Equality
   eliminates both. This remains a permanent boundary fuzz target.
5. **`arbitrationResult` has generic behavior.** **Confirmed:** there is no
   `_isRootTournament` check, so it returns the survivor for an inner tournament too, while
   `canBeEliminated`/`innerTournamentWinner` are non-root views. PRT-005 decided to keep this
   behavior and correct its documentation rather than add a guard or break the selector.
6. **`pairCommitment` double-granted `matchEffort` to a freshly joined newcomer.**
   **Resolved by PRT-009:** pairing now changes neither balance. `advanceMatch` and the final seal
   instead discount at most one `G` from elapsed response time without increasing the responder's
   action-start balance. Late joins and repeated winners cannot recover time through re-pairing.
7. **`Time.sub` was unused dead code.** **Resolved:** the strict helper and its test-only wrapper
   were removed. Intentional saturating differences use the explicitly named `Time.monus`.

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
3. **Sybil-principal dimensioning (INV-FUND-1)** - the global match-count analysis proves that
   configured refunds reserve one winning bond and burn at least the explicit principal per
   eliminated commitment. The current 0.00450875 ETH literal preserves the inherited one-advance
   margin but is not an economically calibrated parameter. PRT-012 and `REFUND-DESIGN.md` keep
   that final policy decision open.
4. **Clock-carryover boundary (INV-CLK-5). Resolved.** Let `F` be `timeFinished()` and `A` the
   paused winner allowance. `innerTournamentWinner` can return a winner only while
   `current < F + A`; therefore `current - F < A`, and `deductPaused` remains strictly positive.
   At equality `canBeEliminated` is already true and deduction is skipped. Historical inner tests
   pin the final propagation block and the inclusive elimination boundary.
5. **Identical-commitment-tree front-running** - `initializePausedAt` locks out the second
   submitter of the same root. **Decision:** first-claimer ownership is intended because defense is
   permissionless. PRT-008 resolved the historical full-sweep recycling path by changing the
   payout and residual handling, not commitment uniqueness.
6. **`_refundableAfter` gas interplay** - the `+Gas.TX = 25000` added to measured gas vs real ETH
   spent; whether the refund can exceed real gas in any block-condition corner (bounded by balance
   and direct action caps, but not exhaustively checked). PRT-013 separately bounded recipient
   execution and removed return-data copying; callback work remains outside the measurement.
7. **No zero-address / sanity validation** in `MultiLevelTournamentFactory` or
   `CanonicalTournamentParametersProvider` constructors; `maxAllowance == 0` would deploy fine
   and brick clocks. A zero `matchEffort` charges full response latency and is safe, though it may
   violate the selected liveness policy. `Deployment.s.sol`/cannonfile partly constrain this, but
   not every chain-kind path was traced (could any registered chain round
   `maxAllowance`/`avgBlockTime` to 0 blocks?).
8. **Recursive test coverage is partially landed.** Deep-tree parity, pooled bond accounting,
   and single-level lifecycle composition have independent property campaigns. Two-level traces
   cover child linkage, both winner mappings, late entry, post-close resolution, strict carryover
   boundaries, parent re-pairing, and two sequential children. A fixed one-child stateful oracle
   was rejected as duplicative. The remaining gap is a multi-population delay model with
   concurrent matches and children under adversarial arrival schedules.
9. **`BaseDeploymentScript.sol`** (referenced by `Deployment.s.sol`, provides
   `_create2`/`_storeDeployment`) was not read - outside the core trust boundary, low priority.

---

## 5. Historical coverage plan from the find stage

This plan records how the audit-start leads were generated. `REVIEW.md` tracks
which campaigns subsequently landed and what remains.

1. **Bisection parity & divergence mapping (the who-wins core)** - `tournament/libs/Match.sol`.
   SAFE-1/2/3. *Vantages:* property/parity finder (exhaustively derive agree-proof-vs-winner
   consistency across odd/even height x left/right; fuzz deep trees up to height 48 tracking
   `runningLeafPosition` parity vs `agreesOnLeftNode`); adversarial-input finder (can re-pairing
   reach `createMatch`'s `assert(verify)` with inconsistent leaves - Panic DoS?); `otherParent`
   wrong-subtree where `requireParentHasChildren` still passes (INV-MATCH-2).
2. **Tournament lifecycle & resolution state machine** - `tournament/Tournament.sol`. SAFE-1/4/5,
   INV-LIFE-1/2, INV-FUND-1/2, INV-REENT-1, leaf/non-leaf segregation, generic
   `arbitrationResult` behavior, symmetric seal existence checks, and the resolved
   leaf-proof/timeout compatibility policy. *Vantages:*
   state-machine finder (reachable (match,clock,dangling) states; `matchCount` conservation;
   single-dangling; delete-once); reentrancy finder (lock covers every ETH move + child call;
   cross-instance view trust); access-control finder (leaf/non-leaf/root guards; generic
   `arbitrationResult` consumer impact); economic finder (make the global reserve theorem and
   explicit Sybil principal executable across repeated matches).
3. **Chess-clock timing primitives** - `tournament/libs/Clock.sol`, `MatchClocks.sol`, `Time.sol`.
   INV-CLK-1..5; monus saturation boundaries; paused carryover zero-allowance rejection;
   pair-phase assertions. *Vantages:* boundary/
   off-by-one finder (preserve the PRT-002 running-winner and equality regressions;
   strict-vs-inclusive mismatches in remaining views); carryover finder
   (INV-CLK-5); liveness finder (response-coupon bound, no-refill invariant, and bracket model).
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
   INV-CFG-2, INV-STF-1: hardcoded `LEVELS = 3` + magic arrays; per-level array OOB Panic; the
   L=3 <-> 20/48 linkage with no compiler enforcement; the future L=2 migration risk. The height
   NatSpec now states that levels above zero are stride gaps while level zero is independently
   dimensioned. *Vantages:* config/invariant finder (verify constants tile the computation - sum
   heights = 92, leaf `log2step = 0`; what breaks if L changes without regenerating arrays;
   level-vs-LEVELS sourced from two places never disagree).
9. **Core types & gas constants** - `types/Machine.sol`, `tournament/libs/Gas.sol`. `Machine.Hash`
   `ZERO_STATE` sentinel collision; Gas constants size the bond + refund shares. *Vantages:*
   economic finder (validate each Gas constant vs actual measured gas; bond covers worst-case at the
   configured gas price); sentinel finder (a real machine state can never be `ZERO_STATE`).
10. **Tournament interface & error/event contract** - `ITournament.sol`. Defines `TournamentArguments`/
    `NestedDispute` layout (must match factory encode + Tournament decode), every error/event, and
    drifted NatSpec. *Vantages:* interface-consistency finder (`abi.encode`/`decode` round-trip
    stable; cross-check every NatSpec claim - generic `arbitrationResult` behavior, `MatchAdvanced`
    field meaning pre-vs-post-seal; event indexing supports lineage reconstruction, only roots get
    `TournamentCreated`).
11. **Deployment wiring & parameter conversion (context, lower priority)** - `cannonfile.toml`,
    `script/Deployment.s.sol`. Converts seconds -> blocks; wires the stack via CREATE2 zero-salt.
    *Vantages:* config finder (every registered chain's `avgBlockTime` vs durations cannot round any
    `Time.Duration` to 0; cannonfile and `Deployment.s.sol` agree; CREATE2 zero-salt doesn't enable
    deployment front-running/address-squat; note `BaseDeploymentScript.sol` unread).
