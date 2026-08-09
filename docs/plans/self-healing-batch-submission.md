# Self-healing batch transaction submission

Status: IMPLEMENTED 2026-08-05 and tightened 2026-08-08. Hero and cleanup
retain nonce-ordered batch submission; settlement remains a stable-content
step; recovery moved out of wave tails onto a finalized, idle cadence so
maintenance cannot occupy a future urgent nonce.

## Motivation

Before batching, the node's transaction lane held one in-memory replacement
slot at the latest mined nonce and submitted at most one mutation per tick.
Because a mutation only changes observed state once included, the planner
re-derived the same intent until inclusion, fixing cleanup throughput at the
chain's inclusion rate: one action per included transaction.

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

1. Plan the complete dispute wave: the hero decision (0 or 1 actions,
   protocol-serial) followed by the deterministic innermost-first GC
   intent list. Position in the list IS priority: hero-first nonce order is
   the hero-before-cleanup invariant.
2. Filter intra-wave dependencies: an innermost-first GC list can
   invalidate its own suffix (eliminating a child deletes the parent
   match a later intent targets). The filter is a pure function over
   the composed list; reverts remain the safety net.
3. Assign nonces from the transaction count at the latest block, sign,
   submit all in order without waiting, and forget.

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

## Settlement stays one guarded step

Settlement actions (the sentry claim, result staging, acceptance) are
in a different consistency class: a wrong vote computed from an
observation that later reorgs SUCCEEDS wrongly - reverts cannot heal
a semantic commitment - so their CONTENT must derive from finalized
data (it already does: settlement_info comes from finalized
ingestion), and nothing hurries them. The whether-still-needed check
reads latest state - a reorg there only causes a harmless guarded
resubmit - which is what stops resubmission within a block or two of
inclusion rather than a finality lag later. No stored attempts:
re-derive the step each tick, sign at the fresh quote, send. The
calldata is deterministic, the nonce admits at most one inclusion,
and the contracts' guards admit at most one successful effect - duplicate
transactions are safely rejected. This gives exactly-once action effects with
zero lane state.

Coexistence on one signer account: when the settlement module wants a
step this tick, that step takes the base nonce and any same-observation
cleanup fills strictly above it; otherwise the dispute wave starts at the
base. Recovery is never appended behind either class.

## Recovery uses idle finalized cadence

Wave position cannot preserve low priority across ticks. Once an earlier nonce
lands, a pending recovery tail becomes the account head and a new Hero action
must replace or wait behind it. Recovery therefore runs only when no dispute
or settlement mutation is ready, and at most once per newly observed finalized
head.

The recovery tree and every terminal classification are read at one finalized
hash. This makes retirement coherent: a child absent from the finalized event
tree cannot be hidden behind a root state observed from a newer block. A latest
read may suppress the one recovery candidate if it has already been mined, but
never contributes to retirement. All sealed epochs are re-walkable, so epoch
rotation and restart preserve pending work without a durable queue. Recovery
also waits while Latest exposes a newer sealed epoch than finalized storage;
the next epoch's join therefore gets the lane before maintenance.

## Fees

Stateless: every transaction bids the fresh market estimate, every
tick. No retained floors, no bump-on-replacement ratchet, and no
dedup memo either: the mempool (or builder) already holds the pending
set and arbitrates duplicates and replacements, so the lane re-signs
and resends the whole wave every tick and treats "already known" and
"replacement underpriced" as trace-level no-ops. The lane carries
zero mutable state - it is a function from the planned wave to sends.
With a KMS signer the re-signing chatter is bounded by the wave
length per tick; revisit only if metrics complain.

The previously recorded `max(estimate, 1.1 * last-sent)` guard is
dropped, for two reasons. Generalized per nonce it becomes a
compounding hazard: wave rebuilds re-plan different actions onto
still-pending nonces (every opponent inclusion can do this), and each
swap must outbid the pending transaction by the mempool's
at-least-10%-on-both-legs replacement rule - a ratchet paced by
dispute events. And the corner it defended - a market drifting inside
the band above a pending cap - cannot strand an includable
transaction under the 2x-base-fee headroom the node's estimator
quotes; the residual case (base more than doubles while tips stay
flat) parks the pending transaction until the spike cools, which is
allowance territory: genuine congestion is priced by the clock model
(docs/dimensioning.md), not by lane heroics. Fee exposure is bounded
by the fresh quote by construction, so no ceiling machinery is needed
either.

In production the wave is expected to submit through a block builder
with revert protection (Flashbots-style): no public-mempool
replacement rules, no stale-action revert fees, and races among
several honest validators cost nothing. Builder trust affects
performance only, never correctness; the public-mempool path with
bounded revert fees remains the fallback and is what the e2e harness
exercises. The submission backend is therefore a transport seam - the
wave produces an ordered list of signed transactions - and builder
integration is a recorded follow-up, not part of this campaign.

## Details for the implementation campaign

- Balance exposure: k in-flight transactions bound k * gas_limit of
  fees plus the reverts of raced stale actions; both are small and
  bounded by the list length per wave.
- Bond recovery uses this lane only while it is idle; see
  [bond-recovery-redesign.md](bond-recovery-redesign.md). It is gated on the
  node being the winning claimer and submits at most one candidate per cadence.
- Reorg stance unchanged: finalized prefix persisted, tail disposable,
  mutators revalidate.
