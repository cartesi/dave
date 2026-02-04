# Stage 1 Architecture for Cartesi Rollups

This document describes the Stage 1 design implemented in this repository, alongside the proof system itself that can be deployed as Stage 2.
It is written to be audit-friendly for external reviewers and to align with the L2Beat Stages Framework.

The design intentionally trades some decentralization for safety and agility during early-stage deployments.
It introduces:
* a Security Council with pause and upgrade powers; and
* a permissioned Sentry layer that adds a safety delay without giving it the ability to change the outcome of the proof system.

## Goals

- Reduce catastrophic risk from application bugs or proof system bugs.
- Preserve liveness without requiring continuous Security Council action (walkaway test).
- Allow upgrades by the Security Council.

## Components

### 1) DaveConsensus (this repo)

- Tracks epoch boundaries and validates outputs against finalized machine state.
- Spawns a task for each epoch, exposes `canSettle`, and finalizes via `settle`.
- Implements the **Upgrade Primitive** (`upgrade(newInitialState, newTaskSpawner)`), only callable
  by the Security Council.

### 2) Task Interface (`ITask` / `ITaskSpawner`)

- Minimal interface that lets the application stay agnostic to which proof system is used.
- Enables swapping proof systems or wrapping them with middleware.

### 3) Proof System Task (Dave / PRT tournaments)

- Permissionless dispute system that resolves to a final machine hash.
- Configured with a challenge period, state-transition function and on-chain rules for resolving disagreements.

### 4) Safety Gate Task (optional middleware)

- A wrapper task that requires sentry agreement before returning results.
- Implements a *disagreement buffer* that only delays settlement.
- Multiple sentries are supported; all must agree on the same non-zero claim.

### 5) Security Council

- High-threshold multisig (e.g., 6-of-8) of cold keys.
- Recommended: >=8 signers with >=75% threshold, and membership diversity across entities and jurisdictions.
- Holds "break-glass" powers: upgrade, pause, and output-tree excision (app-specific).

### 6) Sentries

- Hot EOAs or low-threshold multisigs that can attest to the correct final state.
- Designed to be fast and replaceable.
- Designed to have minimal powers (i.e. delay only).

## Protocol Flow (Normal Operation)

1. DaveConsensus spawns a task for the current epoch using the current task spawner.
2. The task resolves to a final machine hash.
3. DaveConsensus validates the outputs Merkle root against that final hash.
4. The epoch is sealed and the next epoch task is spawned.

If the Safety Gate is used, `result()` is mediated by sentries and a disagreement window.

## Pause Primitive (DaveConsensus)

Function (DaveConsensus):

- `pause()` / `unpause()` by Security Council only.

Behavior:

- While paused, `settle()` reverts and no new epoch can be sealed.
- The current task continues to run off-chain; the pause only blocks finalization on L1.

Rationale:

- Buys time to diagnose issues and coordinate an upgrade during live incidents.


## Upgrade Primitive

Function (DaveConsensus):

- `upgrade(newInitialState, newTaskSpawner)` by Security Council only.

Behavior (in-flight task swap):

- The task spawner is swapped immediately.
- A new task is spawned for the *current epoch bounds* (a "replay") using the new initial state.
- The old task is ghosted (a "zombie"); its result is ignored.

Rationale:

- Allows recovery from proof system bugs or application bugs.
- Keeps the application logic minimal and agnostic to the proof system implementation.

Operational note:

- Validators must have the new upgraded machine snapshot.


## Safety Gate Task

Decision logic:

- All sentries vote and agree on a claim.
- If any sentry (1-of-N) disagrees or fails to vote, anyone can start a fallback timer once the inner task
  is finished.
- After the disagreement window elapses, the inner task result is accepted.

Properties:

- Sentries can delay settlement, but cannot change the result.
- One byzantine or fail-stop sentry can force delay; this is intentional to prioritize safety.
- Sentry set is immutable per task; Security Council can update it for future tasks.

## Stage 1 Alignment (L2Beat)

Our design fulfills the Stage 1 requirements in the following ways:

- **Permissionless Proof System**: <TODO: PRT, etc>
- **Challenge period**: The dispute window is configured to be >=7 days.
- **Single point of emergency authority**: Only the Security Council can upgrade the task spawner and change the rollup trajectory. All other roles can only delay.
- **Upgrade window**: There are no non-SC upgrade paths in this design.
- **Walkaway test**: If the Security Council becomes inactive, the system still resolves by falling back to the permissionless proof system. Moreover, the Sentry cannot halt the chain.

The Security Council configuration above is intended to satisfy the robustness guidelines of the
L2Beat framework.

## Threat Scenarios and Outcomes

This section lists key failure modes and why funds remain safe (or not).

### Sentry failures

- **Single sentry byzantine**:
  - Effect: Forces disagreement path and delays settlement by the disagreement window.
  - Outcome: No safety loss. Security Council can rotate sentries.

- **Single sentry fail-stop**:
  - Effect: Missing votes trigger fallback timer, adding delay.
  - Outcome: Liveness degradation only.

- **All sentries fail-stop**:
  - Effect: Same as above; anyone can start fallback after inner task finishes.
  - Outcome: Liveness degradation; no safety loss.

- **All sentries byzantine**:
  - Effect: They can delay (by disagreeing) or agree with a bad result.
  - Outcome: If they agree with a bad result, the safety gate offers no protection. We rely
    on the proof system (or Security Council).

### Proof system failures (Dave/PRT bug)

- **PRT bug + honest sentries**:
  - Effect: Mismatch between sentry claim and inner result triggers buffer.
  - Outcome: Security Council can pause/upgrade before settlement.

- **PRT bug + all sentries compromised to match bad result**:
  - Effect: No buffer; bad result proceeds.
  - Outcome: Funds are safe only if the Security Council intervenes in time (pause and upgrade).

### Security Council failures

- **Security Council fail-stop**:
  - Effect: No upgrades or emergency actions.
  - Outcome: Chain still resolves via proof system; liveness preserved (walkaway test).

- **Security Council byzantine (>= threshold)**:
  - Effect: Can upgrade to arbitrary state, pause, or censor withdrawals.
  - Outcome: This is the explicit Stage 1 trust assumption.

## What Must Go Wrong for Funds to Be Stolen

At least one of the following must occur:

1. A Security Council threshold is compromised (>=75% of SC signers), or
2. A proof-system bug exists *and* all sentries fail to raise a discrepancy *and* the Security Council fails to intervene before outputs are executed, or

In other words, safety is compromised only if a bug aligns with a governance failure, or the Security Council itself is compromised.

## Operational Practices

- Maintain at least one independent, always-on validator per ecosystem stakeholder.
- Monitor disagreements and ensure the fallback timer is started when needed.
- Run periodic key-rotation exercises for sentries.
- Require multi-party signing ceremonies for upgrades.
- Maintain a tested playbook for pause and upgrade procedures.

## Current Implementation Scope

Implemented in this repo:

- Task interface (`ITask` / `ITaskSpawner`).
- DaveConsensus with Security Council upgrade primitive.
- Safety Gate Task with multi-sentry disagreement buffer.

## References

- https://forum.l2beat.com/t/the-stages-framework/291
- https://forum.l2beat.com/t/stages-update-a-high-level-guiding-principle-for-stage-1/338
