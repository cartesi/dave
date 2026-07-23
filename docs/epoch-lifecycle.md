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
input index upper bound (exclusive, global indexing), the root tournament
address, and the initial machine state hash.

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
- epoch-manager (`cartesi-rollups/node/src/epoch_manager`): two duties per
  iteration. (a) Settle, in three guarded steps per tick: submit a sentry
  claim when the signer is a sentry (always the locally computed
  post-epoch hash, never the staged value - claims stay an independent
  check); stage the finished tournament's result after asserting the
  on-chain winner matches the local settlement (commitment root AND
  post-epoch state); accept the staged result once every sentry agrees or
  the staging period elapses, after asserting the staged values match the
  local ones. (b) Defend: for the last sealed epoch, instantiate a `Hero`
  with the epoch's inputs, leaves, and snapshot, and let it react to the
  tournament.

## The dispute loop (Hero)

`cartesi-rollups/node/src/hero`. Once per polling iteration (a tick):

1. Fetch the full tournament tree state from chain (`StateReader`,
   `tournament/reader.rs`): tournaments, commitments, matches, clocks.
2. Garbage-collect: eliminate dead matches and inner tournaments to free
   bonds (`hero/gc.rs`).
3. React recursively from the root tournament:
   - Build (or load from the dispute db) the commitment for this
     tournament's level.
   - Not joined yet: join with the commitment root and last-leaf proof.
   - In a match at height > 1: bisect (`advanceMatch`) toward the first
     divergent leaf.
   - At height 1: seal (leaf match or inner match). Sealing a non-leaf
     match spawns a child tournament one level deeper; recurse into it.
   - Sealed leaf match: compute the transition proof for the divergent
     meta-cycle (`MachineInstance::get_logs`) and call `winLeafMatch`.
   - Opponent out of time: win by timeout.
4. A won inner tournament propagates to the parent match; losing the root
   tournament is reported (and should page a human: it means our
   commitment is wrong or we were censored beyond the protocol's bound).

The player is stateless between iterations apart from the quartet cache
(`sling_nodes` in the node database) and machine snapshots; on restart it
rebuilds its view from chain and disk.

## Settlement invariant

`EpochManager::try_settle_epoch` asserts that the tournament winner's
commitment equals the locally computed computation hash. Today a mismatch
panics the node (see the debts list in `docs/node-architecture.md`); the
intended semantics is "this is a critical incident: either our node is
buggy or the protocol was defeated" - it must never be silently ignored.
