# Epoch lifecycle

How inputs become epochs, epochs become tournaments, and tournaments become
settled results. This is the rollups-level view; the implemented tournament
protocol is specified in [`dispute-game.md`](dispute-game.md), while commitment
construction is specified in [`computation-hash.md`](computation-hash.md).

## On-chain actors

- `InputBox` (from `cartesi-rollups-contracts`): applications receive
  inputs here; every input gets a global, monotonically increasing index.
- `DaveConsensus` (`cartesi-rollups/contracts/src/DaveConsensus.sol`): the
  consensus contract for one application. It partitions the input stream
  into epochs, and for each sealed epoch instantiates a root tournament
  (via the PRT tournament factory) that will decide the epoch's final
  machine state.
- Tournaments (`prt/contracts/`): resolve which commitment (computation
  hash) is correct for the sealed epoch.

The `EpochSealed` event is the pivot. It carries the epoch number, the
input index lower and upper bounds (exclusive upper, global indexing),
the initial machine state hash, the settled previous epoch's outputs
Merkle root (zero at genesis), and the root tournament address.

## Epoch states, from the node's perspective

1. Open: inputs are accumulating in the InputBox; the current epoch has no
   tournament yet.
2. Sealed: `DaveConsensus` emitted `EpochSealed`; the input set is frozen
   and a root tournament exists. Validators compute their commitment over
   the sealed inputs and join the tournament to defend it.
3. Staged: the tournament finished and anyone called
   `stageTournamentResult(epochNumber, outputsMerkleRoot, proof)` - the
   outputs proof is validated here, and `EpochStaged` carries the staged
   post-epoch machine state hash and outputs root. Sentries (0..N
   addresses fixed at deployment, rotatable by the sentry manager) may
   independently `submitSentryClaim` the post-epoch machine state hash
   they computed themselves.
4. Settled: anyone called `acceptStagedTournamentResult(epochNumber)`,
   allowed once the result is staged AND (every sentry claimed the staged
   hash OR the claim staging period elapsed - with zero sentries, only
   the period path exists). Accepting settles the epoch and seals the
   next one; `EpochSealed` fires here.

All four mutating entry points (stage, sentry claim, accept, sentry
rotation) are gated by `notForeclosed(appContract)`: a foreclosed
application freezes epoch progress entirely. Check foreclosure status
before debugging an unexpected revert on any settlement call. Deeper
contract context: `cartesi-rollups/contracts/AGENTS.md`.

## Node data flow

Three worker threads share one SQLite database (see
`docs/node-architecture.md` for the concurrency model):

```
                    finalized logs                    txs
  Ethereum  ------------------------>  blockchain-reader
     ^                                       |
     |  settle / dispute txs                 |  inputs, epochs
     |                                       v
  epoch-manager  <---- settlement,  ----  SQLite  <---- leaves, ----  machine-runner
     |                 inputs, leaves                   snapshots         |
     |                                                                    |
     +-- Hero (src/hero) ------------- quartet cache + machine snaps -----+
```

- blockchain-reader (`cartesi-rollups/node/src/blockchain_reader`): polls
  finalized blocks only, reads `InputAdded` and `EpochSealed` logs, assigns
  each input to an epoch by comparing its global index against sealed
  boundaries, and writes both tables transactionally together with the
  last-processed block number.
- machine-runner (`cartesi-rollups/node/src/machine_runner`): replays inputs
  through the Cartesi Machine as they appear, producing level-0 commitment
  leaves per input (accepted inputs advance state; rejected inputs revert
  to the pre-input snapshot). When it learns an epoch was sealed, it rolls
  the epoch: stores the settlement info (computation hash, post-epoch
  machine state hash, output merkle, output proof) and the epoch-boundary
  snapshot.
- epoch-manager (`cartesi-rollups/node/src/epoch_manager`): each iteration
  runs the dispute tick first - for the last sealed epoch, instantiate a
  `Hero` with the epoch's inputs, leaves, and snapshot, and let it react
  to the tournament - then submits through the one transaction lane it
  owns (docs/plans/self-healing-batch-submission.md). A dispute wave contains
  the Hero's action followed by every currently legal cleanup intent,
  innermost-first; one pending settlement step may take the base nonce when
  the dispute is no longer contested. Position is priority: cleanup never
  sits ahead of defense. Bond recovery is separate low-priority work: only
  when no higher-priority mutation is ready, at most one recovery is planned
  for a newly observed finalized head.
  While machine-runner has not yet written the sealed epoch's
  settlement info, the tick reports Preparing and no mutation is submitted.
  Settlement plans at most one guarded, idempotent step per
  tick: submit a sentry claim when the signer is a sentry (always the
  locally computed post-epoch hash, never the staged value - claims
  stay an independent check); stage the finished tournament's result
  after asserting the on-chain winner matches the local settlement
  (commitment root AND post-epoch state); accept the staged result once
  every sentry agrees or the staging period elapses. Recovery walks every
  unretired sealed epoch, so pending old bonds survive epoch rotation and
  restart without a stored queue. If Latest already exposes the next epoch
  while finalized ingestion still ends at the previous one, recovery waits;
  maintenance cannot occupy the nonce needed by the next finalized join. The
  lane itself is stateless: every send rebuilds from fresh observation at
  fresh market fees, and the mempool arbitrates duplicates and replacements.

## The dispute loop (Hero)

`cartesi-rollups/node/src/hero`. Once per polling iteration (a tick):

1. Advance one finalized, event-derived recursive `Dispute`, persist it, then
   clone and extend it over the disposable latest tail. Events supply
   tournaments, commitments, matches, child links, and match-elimination
   schedules; the node does not fetch every clock or live match.
2. React recursively from the root tournament:
   - Build (or load from the dispute db) the commitment for this
     tournament's level.
   - Not joined yet: use latest only to suppress an already-mined or no-longer
     possible join, then derive the commitment root and last-leaf proof from
     the finalized Solid dispute.
   - In a match at height > 1: bisect (`advanceMatch`) toward the first
     divergent leaf.
   - At height 1: seal (leaf match or inner match). Sealing a non-leaf
     match spawns a child tournament one level deeper; recurse into it.
   - Sealed leaf match: compute the transition proof for the divergent
     meta-cycle (`Ruler::prove_transition`, `engine/ruler.rs`) and call
     `winLeafMatch`.
   - Opponent out of time: win by timeout.
3. When the tick selected no Hero action and the root is still running, propose
   at most one garbage-collection intent (`hero/gc_planner.rs`). Match cleanup
   compares event schedules with the sampled latest block number; child
   cleanup consumes the tournament standing overlay. Deeper work wins, and no
   cleanup transaction queues behind a Hero response.
4. A won inner tournament propagates to the parent match; losing the root
   tournament is reported (and should page a human: it means our
   commitment is wrong or we were censored beyond the protocol's bound).

The reader retains one in-memory Solid dispute between iterations. Its raw
recognized events and finalized watermark are persisted; on restart the node
reconstructs Solid from chain and disk. Latest Foam never survives a tick. The
quartet cache (`sling_nodes`) and machine snapshots remain the computation
cache.

## Settlement invariant

`EpochManager::try_settle_epoch` asserts that the tournament winner's
commitment equals the locally computed computation hash. Today a mismatch
panics the node (see the debts list in `docs/node-architecture.md`); the
intended semantics is "this is a critical incident: either our node is
buggy or the protocol was defeated" - it must never be silently ignored.
