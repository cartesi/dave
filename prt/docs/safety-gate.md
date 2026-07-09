# Safety Gate

This document describes the Safety Gate, a delay middleware for PRT tournament
results, and the task abstraction that supports it.

The design gives a permissioned *Sentry* layer the power to **delay** — and
only delay — the settlement of an epoch, buying time for a higher-level
authority (e.g. a Security Council) to act on proof system or application bugs.
Intervention itself (pause, upgrade, output excision) happens at a different
layer and is out of scope here.

## Task abstraction

### `ITask`

A *task* is an asynchronous on-chain computation that eventually resolves to a
final machine state:

```solidity
interface ITask is IERC165 {
    function result() external view returns (bool finished, Machine.Hash finalState);
    function cleanup() external returns (bool cleaned);
}
```

- `result()` reports whether the task has finished and, if so, the final
  machine state hash.
- `cleanup()` is a best-effort post-settlement hook (e.g. bond recovery).
  It must be safe to call at any time, multiple times.

`ITournament` extends `ITask`: a root tournament's `result()` is the
projection of `arbitrationResult()` without the winner commitment, and its
`cleanup()` recovers the winner's bond. Consumers that only need the settled
state (like `DaveConsensus`) depend on `ITask` and stay agnostic to the
underlying proof system.

### `ITaskSpawner`

```solidity
interface ITaskSpawner {
    function spawn(Machine.Hash initial, IDataProvider provider) external returns (ITask);
}
```

`DaveConsensus` spawns one task per epoch through an `ITaskSpawner`.
`MultiLevelTournamentFactory` implements it by instantiating a root
tournament; `SafetyGateTaskSpawner` implements it by wrapping another
spawner's task in a safety gate.

Tasks implement ERC-165 so tooling and nodes can discover what stands behind
the `EpochSealed` task address.

## SafetyGateTask

A `SafetyGateTask` wraps an inner task (typically a PRT root tournament) and
gates its result behind a set of sentries, fixed per task instance.

Decision logic for `result()`:

1. If the inner task is unfinished, the gate is unfinished.
2. If **all** sentries voted and agree on the inner task's final state, the
   gate finishes immediately with that state.
3. Otherwise (missing votes, disagreement among sentries, or unanimous
   agreement on a state that differs from the inner result), the gate stays
   unfinished until a *fallback timer* is started and the *disagreement
   window* elapses — after which the inner result is accepted as-is.

Properties:

- **Delay-only.** `result()` only ever surfaces the inner task's state.
  Sentries decide *when* it becomes visible, never *what* it is.
- **1-of-N delay.** A single byzantine or fail-stop sentry forces the
  disagreement window. This is intentional: safety over liveness.
- **Walkaway-safe.** If every sentry disappears, anyone can start the
  fallback timer once the inner task finishes; the system degrades to the
  permissionless proof system plus a fixed delay.

Sentry voting rules (`sentryVote`):

- Only configured sentries can vote, each exactly once.
- The zero state is an invalid vote.
- A vote that conflicts with an earlier vote permanently marks the sentry
  set as disagreeing for this task instance.
- Votes cast after the gate has finished are accepted and harmless: the
  gate's `result()` is monotone and can never become unfinished again.

The aggregate voting state is exposed as `sentryStatus()`, which returns one
of three states — `VOTING` (accumulating, no conflict so far), `AGREED` (all
sentries voted the same claim, also returned), or `DISAGREED` (a conflict
was observed; absorbing).

The fallback timer (`startFallbackTimer`):

- Can be started by **anyone**, but only after the inner task has finished
  and only while the sentries do not corroborate the inner result.
- Is started at most once; `canStartFallbackTimer()` reports whether a call
  would succeed, and `fallbackTimer()` reports its state
  (started/start-instant/elapsed).
- The gate never starts it on its own, and **neither does the node**:
  starting the timer is a deliberate, monitored manual operation. Whoever
  operates the deployment should alert when `canStartFallbackTimer()`
  becomes true, investigate why the sentries are not corroborating, and —
  once satisfied that falling back is the right call — run:

  ```sh
  cast send $SAFETY_GATE_TASK "startFallbackTimer()" \
      --rpc-url $RPC_URL --private-key $ANY_FUNDED_KEY
  ```

  Note that in an adversarial scenario the attacker will call this at the
  earliest possible moment, so the disagreement window must be sized
  assuming the timer starts as soon as the inner task finishes.

## SafetyGateTaskSpawner and sentry rotation

`SafetyGateTaskSpawner` wraps an inner `ITaskSpawner` and deploys a
`SafetyGateTask` around every task it spawns, passing a snapshot of its
current sentry list and a fixed disagreement window.

Sentry rotation:

- `setSentries(address[])` replaces the whole list; only the *sentry
  manager* address (fixed at construction) may call it. In production this
  role is expected to be held by a high-threshold governance body (e.g. a
  security council); note its powers stop at rotating sentries for future
  tasks — it cannot affect results or in-flight tasks.
- The list is **mutable in the spawner, immutable per task**: a rotation
  affects the next spawned task (i.e. the next epoch), never in-flight ones.
- The spawner stores the list verbatim (readable via `getSentries()`); the
  spawned task deduplicates repeated addresses so that full participation
  stays achievable.

## Deployment

The sentry manager, sentry list and disagreement window are app-specific
parameters with no reasonable defaults, so no standalone gate spawner is
deployed as shared infrastructure. Instead, gates are deployed **per app,
at app-creation time**: `DaveAppFactory.newGatedDaveApp(templateHash,
withdrawalConfig, sentryManager, window, sentries, salt)` atomically
deploys an app-specific `SafetyGateTaskSpawner` (wrapping the factory's
bound proof system) and a `DaveConsensus` wired to it, emitting a distinct
`GatedDaveAppCreated` event. Ungated apps go through `newDaveApp` as usual.

Factory *events* are the canonical provenance check — they certify the
settlement mechanism (genuine consensus, gate and proof system) and
distinguish gated from bare apps; note this cannot be told from the factory
address alone. The gate's governance parameters remain app-declared and
inspectable on-chain, like the template hash.

### Deterministic addresses are first-come-first-served

Like any shared CREATE2 factory, the application address is a function of
`(templateHash, withdrawalConfig, salt)` only, so whoever calls first with a
given tuple occupies that address — this is pre-existing behaviour of
`newDaveApp`, not introduced by the gate. Because the gate's governance is
*not* part of the application salt, a gated and a bare deployment (or two
gated deployments with different sentries) that share the tuple compete for
the same application address; the first to land wins and the other reverts.

This is a griefing/address-prediction concern, never a fund-safety one: the
application that ends up deployed is always a genuine factory application,
its `DaveConsensus` address *does* bind the gate (so different governance
yields a different consensus), and the emitted event states the truth.
Deployers should therefore treat provenance as "which event did the factory
emit", not "which address did I predict", and use a fresh `salt` if a
collision is a concern.

## Node responsibilities

The epoch task address emitted in `EpochSealed` may be a tournament or a
safety gate. The node (epoch-manager) detects gates via ERC-165 using the
pinned `ISafetyGateTask` interface id (`0xf77c3559`, guarded by
`testInterfaceIdMatchesNodeConstant`):

- resolves `INNER_TASK()` and points the PRT player at the actual tournament;
- casts a sentry vote for the locally-computed final state, when its signer
  is in the task's sentry set and has not voted yet;
- settles through `DaveConsensus.canSettle()/settle()`, comparing the local
  `final_state` against the gate's reported state.

The node deliberately does **not** start the fallback timer; see the
fallback timer section above for the manual procedure and its rationale.

The node stores the epoch's final machine state (`final_state`) alongside the
computation hash in `settlement_info`, since `canSettle` now reports the
final state rather than the winner commitment.

## Threat scenarios

| Scenario | Effect | Outcome |
| --- | --- | --- |
| One sentry byzantine or fail-stop | Forces the disagreement window | Delay only |
| All sentries fail-stop | Anyone starts the fallback timer | Delay only |
| All sentries byzantine, matching a bad inner result | Gate provides no buffer | Rely on the proof system / higher-level authority |
| Proof system bug, honest sentries | Mismatch blocks settlement for the window | Time for intervention at a higher layer |
| Sentry manager key compromise | Can rotate sentries for future epochs | Delay only — cannot change results |

The sentry manager's power over the gate is limited to rotating sentries
for future epochs; even a fully compromised manager cannot use the gate to
change a result or to block settlement indefinitely. In particular the
sentry set is length-bounded (`MAX_SENTRIES`), which is the sole anti-brick
guarantee: an oversized rotation is the only way a rotation could exhaust gas
on the next spawn, and it is rejected. A zero address is also rejected and
duplicates are collapsed, but neither could freeze settlement anyway — at
worst they force the fallback window. The manager can delay, never freeze.

## Gas notes

Measured with `forge test --gas-report` (Foundry 1.5.1):

- `SafetyGateTaskSpawner.spawn` costs ~700k gas, of which ~577k is deploying
  the full `SafetyGateTask` bytecode. This happens once per epoch. Unlike
  tournaments (which are spawned as minimal-proxy clones), the gate is a
  full contract deployment; if epochs ever become much shorter, converting
  the gate to a clone with an initializer (clones cannot carry immutables)
  would save ~500k gas per epoch. Deferred deliberately, for simplicity.
- `sentryVote` costs 55–92k gas per sentry per epoch; `startFallbackTimer`
  ~69k; `result()` and the other views are free (off-chain) or negligible.
