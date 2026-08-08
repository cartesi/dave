# Security Disclosure Report

## PRT Tournament Liveness Bug — Permanent App Freeze via `winMatchByTimeout` Clock Deduction

| Field | Value |
|---|---|
| **Date** | 2026-08-08 |
| **Target** | Cartesi PRT Honeypot v3 (Ethereum Mainnet) |
| **Component** | `dave` — PRT tournament contracts (`cartesi/dave` @ v2.0.0) |
| **Affected contract** | `Tournament.sol` (deployed via `MultiLevelTournamentFactory`) |
| **Severity** | **Medium — Liveness / Denial-of-Service** (permanent freeze, NOT fund theft) |
| **Classification** | Liveness failure; no safety/asset-loss impact |
| **Researcher** | Independent security research (AI-assisted) |
| **Status** | Full audit conducted; no extraction path exists. Report submitted in good faith. |

---

## 1. Executive Summary

The Permissionless Refereed Tournament (PRT) dispute system contains a **liveness bug** in `winMatchByTimeout`. When a match winner collects a timeout victory, the contract deducts the opponent's *unbounded* overtime from the winner's own clock. If the winner is slow to claim the win — specifically, slower than their own remaining allowance after the opponent timed out — the deduction saturates the winner's clock to zero and the call **reverts permanently**.

The only remaining resolution path (`eliminateMatchByTimeout`) then destroys **both** bonds with **no winner**. If the tournament is already closed, `arbitrationResult()` reverts with `TournamentFailedNoWinner`, making `DaveConsensus.settle()` impossible **forever**. The application — and the funds it escrows — become **permanently frozen**.

**This is a liveness/DoS bug. It cannot be used to withdraw funds.** It locks the prize rather than releasing it. The honest Cartesi node must also be offline or slow beyond a threshold for the freeze to occur, so it is not a unilateral attacker exploit.

---

## 2. Root Cause

### 2.1 The faulty deduction

In `Tournament.sol::winMatchByTimeout` (lines 175–223), when commitment ONE wins because commitment TWO timed out:

```solidity
// Tournament.sol:192-205
if (_clockOne.hasTimeLeft() && !_clockTwo.hasTimeLeft()) {
    require(
        _matchId.commitmentOne.verify(_leftNode, _rightNode),
        WrongChildren(1, _matchId.commitmentOne, _leftNode, _rightNode)
    );

    _clockOne.deducted(_clockTwo.timeSinceTimeout());   // <-- line 198
    pairCommitment(_matchId.commitmentOne, _clockOne, _leftNode, _rightNode);

    deleteMatch(_matchId, MatchDeletionReason.TIMEOUT, WinnerCommitment.ONE);
}
```

The mirrored branch deducts in the opposite direction (line 212):

```solidity
_clockTwo.deducted(_clockOne.timeSinceTimeout());       // <-- line 212
```

### 2.2 `timeSinceTimeout` grows unboundedly

`Clock.sol:59-70`:

```solidity
function timeSinceTimeout(State memory state) internal view returns (Time.Duration) {
    if (state.startInstant.isZero()) {
        revert("a paused clock can't timeout");
    }
    return Time.timeSpan(Time.currentTime(), state.startInstant)
        .monus(state.allowance);
}
```

Once the losing clock passes its allowance, `timeSinceTimeout` increases by **one block for every block that passes**. There is no cap.

### 2.3 Deduction saturates to zero, then reverts

`Clock.sol:121-124`:

```solidity
function deducted(State storage state, Time.Duration deduction) internal {
    Time.Duration _timeLeft = state.allowance.monus(deduction);
    _setNewPaused(state, _timeLeft);
}
```

`Time.sol:72-80` — `monus` is saturating subtraction:

```solidity
function monus(Duration left, Duration right) internal pure returns (Duration) {
    uint64 l = Duration.unwrap(left);
    uint64 r = Duration.unwrap(right);
    return Duration.wrap(l < r ? 0 : l - r);   // saturates to 0
}
```

`Clock.sol:169-178` — a zero allowance is rejected:

```solidity
function _setNewPaused(State storage state, Time.Duration allowance) private {
    if (allowance.isZero()) {
        revert("can't create clock with zero time");   // <-- line 173
    }
    state.allowance = allowance;
    state.startInstant = Time.ZERO_INSTANT;
}
```

So when `timeSinceTimeout(opponent) >= winner.allowance`, `deducted()` computes `0`, and `_setNewPaused` **reverts**. Crucially, this condition only worsens over time (the overtime keeps growing while the winner's allowance is fixed), so **the revert becomes permanent** — `winMatchByTimeout` can never succeed for this match again.

---

## 3. Trigger Scenario

1. Honest node joins the tournament with a valid claim.
2. Attacker joins with a fraudulent claim. A match is created; clocks are initialized and one starts ticking (chess-clock model).
3. The attacker goes silent. The attacker's clock runs out after `maxAllowance` blocks.
4. The honest node is entitled to call `winMatchByTimeout`. If it does so **promptly**, the deduction is small and it wins normally.
5. **But if the honest node delays** calling `winMatchByTimeout` for longer than its own remaining allowance after the opponent timed out, then:
   - `timeSinceTimeout(attackerClock) > honestClock.allowance`
   - `deducted()` → `monus` → `0` → `_setNewPaused` reverts with `"can't create clock with zero time"`.
6. The win is now permanently unreachable. The only fallback is `eliminateMatchByTimeout` (lines 225–251), which deletes the match with `WinnerCommitment.NONE` — **both bonds are destroyed and there is no winner**.
7. Once the tournament is closed (`isClosed() && matchCount == 0`) and no dangling commitment remains, `arbitrationResult()` (lines 379–395) reverts:
   ```solidity
   require(_hasDanglingCommitment, TournamentFailedNoWinner());   // line 391
   ```
8. `DaveConsensus.settle()` (`DaveConsensus.sol:111-143`) requires a finished tournament with a winner:
   ```solidity
   (bool isFinished,, Machine.Hash finalMachineStateHash) = _tournament.arbitrationResult();
   require(isFinished, TournamentNotFinishedYet());
   ```
   `arbitrationResult()` reverts → `settle()` always reverts → **the epoch can never be settled and the application is frozen permanently.**

---

## 4. Impact

- **Type:** Liveness / Denial-of-Service.
- **Effect:** The tournament — and by extension the rollup application and the funds it escrows — can be rendered permanently unable to settle.
- **Attacker profit:** **None.** The attacker cannot extract funds; they can only destroy both bonds and freeze the app. This is a griefing outcome, not theft.
- **Preconditions:** The honest Cartesi node must be offline or slow beyond its remaining allowance window. This is outside the attacker's direct control, which is why this is a liveness robustness flaw rather than a reliable exploit.

---

## 5. Recommended Fix

The deduction should be **bounded** so it can never drive the winner's clock to zero, or the win should be allowed to proceed even when the opponent's overtime exceeds the winner's allowance. Options:

1. **Cap the deduction** at the winner's allowance minus one unit, guaranteeing a non-zero result:
   ```solidity
   Time.Duration deduction = _clockTwo.timeSinceTimeout();
   Time.Duration maxDeduction = _clockOne.allowance.sub(Time.Duration.wrap(1));
   deduction = deduction.gt(maxDeduction) ? maxDeduction : deduction;
   _clockOne.deducted(deduction);
   ```
2. **Skip the deduction** (or clamp to a minimum remaining time) when it would zero the clock, since the winner has already proven the opponent timed out.
3. Ensure `eliminateMatchByTimeout` (or a recovery path) can still produce a valid arbitration result so the app is never irrecoverably frozen.

Any fix should preserve the anti-delay intent (a late winner should not gain extra time) while guaranteeing that a legitimate winner is never reverted into a no-winner terminal state.

---

## 6. Scope Clarification — Why This Is NOT a Fund-Theft Vector

This report is submitted transparently. It is important to state what this bug does **not** do:

- It does **not** let an attacker emit a withdrawal voucher to their own address.
- The withdrawal destination is a compile-time constant in the dApp guest binary (`honeypot.cpp`, `ERC20_WITHDRAWAL_ADDRESS`); no input can alter it.
- Producing a valid settlement requires winning a PRT tournament whose on-chain RISC-V step emulator reproduces the honest execution trace — which encodes the hardcoded withdrawal address.
- This bug only **freezes** the escrow. It is the opposite of draining it.

The full independent audit found **no exploitable path to withdraw the honeypot funds** across the application logic, the tournament mechanics, and the on-chain/off-chain emulator boundary.

---

## 7. References

- `dave` v2.0.0 — `prt/contracts/src/tournament/abstracts/Tournament.sol`
- `dave` v2.0.0 — `prt/contracts/src/tournament/libs/Clock.sol`
- `dave` v2.0.0 — `prt/contracts/src/tournament/libs/Time.sol`
- `dave` v2.0.0 — `cartesi-rollups/contracts/src/DaveConsensus.sol`
- Related prior incident (different root cause): Cartesi "Honeypot is Dead, Long Live Honeypot" postmortem — https://cartesi.io/blog/prt_honeypot_postmortem/
- Mainnet deployments: App `0xfDDF68726a28e418fA0c2a52c3134904a8c3e998`, DaveConsensus `0xF0D8374F8446E87e013Ec1435C7245E05f439259`

---

*This report is provided in good faith as responsible disclosure. No on-chain transaction was submitted. The described bug was identified through static audit of the public source and verified against deployed bytecode.*
