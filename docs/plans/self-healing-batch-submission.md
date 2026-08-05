# Self-healing batch transaction submission

Status: RECORDED 2026-08-04 (design settled in discussion with Gabriel,
not yet scheduled). A node-only campaign: no ABI coupling, so it does
not ride the contract-interface branch. Question and re-evaluate
everything here when it is picked up.

## Motivation

The node's transaction lane holds one in-memory replacement slot at the
latest mined nonce and submits at most one mutation per tick. Because a
mutation only changes observed state once it is included, the planner
re-derives the same intent until inclusion, so cleanup throughput is
fixed at the chain's inclusion rate: one action per included
transaction.

Eliminations are not hygiene. `matchCount -> 0` gates tournament
finish, so sybil-vs-sybil timeout cleanup sits on the critical path of
the hero's own progress at the parent level: result availability, child
elimination, settlement. The population bound in
[dispute-game.md](../dispute-game.md) assumes prompt cleanup and treats
transaction capacity as available when needed; the serial lane
self-limits a K-match cleanup wave to O(K) blocks when a batch would
drain it in O(1). Under the trust model's realistic assumption - the
hero is the only live honest actor - this is a gap between what the
delay analysis assumes and what the node delivers.

The batch only helps cleanup throughput. The hero's own defense actions
are inherently serial (each depends on the state the previous one
created), so hero latency stays at inclusion rate regardless. That is
the protocol's shape, not a defect.

## The model

Exact-once submission is hard; at-least-once is easy. Here duplicates
are safe by construction: every mutator fully revalidates current
state, so an action either correctly progresses the dispute or reverts.
That makes the decision-to-action pipeline self-healing and lets the
node react at the tip.

Each tick, from one accepted observation:

1. Plan the hero decision and the complete deterministic
   innermost-first GC intent list (both planners already produce this;
   the executor today retains only the first GC intent).
2. Assign nonces from the transaction count at the latest block: the
   hero action takes the base nonce; GC intents take the following
   nonces in planner order. Hero-first nonce order IS the
   hero-before-GC invariant: a stuck cleanup can never sit ahead of a
   defense action.
3. Sign, submit all in order without waiting, and forget.

The next tick re-derives everything from fresh state:

- Nothing included: the same transactions are rebuilt at the same
  nonces; identical bytes are no-ops to the mempool, repriced ones
  either replace or fail with "replacement underpriced" - both
  harmless.
- A prefix included (nonce order guarantees inclusion is prefix
  shaped): the new plan drops completed work, and the new batch's head
  lands on the first unincluded nonce, replacing or racing the stale
  tail. A stale transaction that lands anyway reverts; bounded gas
  loss, no wrong action.

The sibling sequencer project uses the same approach.

## Fee handling

Largely self-healing as well: rebuilding each tick with fresh
market-rate estimates means replacements normally clear the mempool's
+10% replacement rule whenever repricing matters (if the market moved
enough that the pending transaction cannot be included, the fresh
estimate exceeds it by more than the bump threshold). The one residual
corner is a market drifting slowly upward inside the ~10% band above a
pending transaction's cap: the pending transaction is unincludable and
the resubmission is rejected as underpriced until the market moves out
of the band. Deriving each nonce's fees as
`max(market estimate, 1.1 * last sent)` removes that corner; the
last-sent values are already in memory, and none of this needs to be
durable across restart (the market-rate rebuild converges, the same
stance as today's non-durable slot).

## Details for the implementation campaign

- Intra-batch dependencies: an innermost-first GC list can invalidate
  its own suffix (eliminating a child deletes the parent match a later
  intent targets). Either filter the known dependencies at planning
  time or accept the bounded revert fees.
- Balance exposure: k in-flight transactions bound k * gas_limit of
  fees plus the reverts of raced stale actions; both are small and
  bounded by the list length per wave.
- Bond recovery rides this lane: recovery intents (see
  [bond-recovery-redesign.md](bond-recovery-redesign.md)) are cleanup
  like any other, gated on the node being the winning claimer.
- Reorg stance unchanged: finalized prefix persisted, tail disposable,
  mutators revalidate.
