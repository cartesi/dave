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
   `stageTournamentResult(epochNumber, proof)` - the machine validity proof is
   validated here, and `EpochStaged` carries the staged post-epoch machine
   state hash and outputs root. Sentries (0..N addresses fixed at deployment,
   rotatable by the sentry manager) may independently `submitSentryClaim` the
   post-epoch machine state hash they computed themselves.
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

The staging period is not only a sentry window: it is the reaction
interval in which the application-layer foreclosure switch can stop a
decided-but-wrong result from ever finalizing. Foreclosure freezes the
epoch exactly where it stands: a staged result is never accepted, the
input-index lower bound never advances, and `wasInputFinalized` keeps
reporting the frozen epoch's inputs as never finalized - the signal the
application layer's deposit-refund path keys on, while withdrawals fall
back to the last finalized state. The freeze is an intended terminal
state, not a stranded-value bug.

Settlement never touches the tournament's bond path: staging and
acceptance move no value, and nothing on the consensus path calls
`tryRecoveringBond`. The decoupling is deliberate - consensus liveness
must not depend on the tournament payment path, and no recipient code
runs inside a settlement transaction. Its cost is an obligation: every
node implementation owns driving bond recovery for each retired
tournament as a permanent background duty, or every retired
tournament's balance - the root's and each inner tournament's - stays
locked with no error reported anywhere. The reference driver walks
unretired sealed epochs and their inner descendants; see the node data
flow below.

## Node data flow

Three worker threads share one SQLite database (see
`docs/node-architecture.md` for the concurrency model):

```
                 finalized input/epoch logs
  Ethereum  ---------------------------------->  blockchain-reader
     ^                                                  |
     | one serial mutation                              | inputs, epochs
     |                                                  v
  epoch-manager  <-------- settlement data ---------  SQLite
     |                                                  ^
     +-- Hero <--- tournament logs + pinned views --- Ethereum
     |       \--- Solid events + quartet queries ----> SQLite
     |
     +-- settlement / one GC / recovery

  machine-runner  ---- leaves, snapshots, window quartets ----> SQLite
```

- blockchain-reader (`cartesi-rollups/node/src/blockchain_reader`): polls
  finalized blocks only, reads `InputAdded` and `EpochSealed` logs, assigns
  each input to an epoch by comparing its global index against sealed
  boundaries, and writes both tables transactionally together with the
  last-processed block number.
- machine-runner (`cartesi-rollups/node/src/machine_runner`): executes complete
  `--snapshot-gap-inputs` batches while an epoch is open, leaving a shorter
  tail unexecuted. Once the epoch is sealed, it executes the remaining tail
  before rolling. Each input produces one level-0 window-subtree root from its
  stride leaves; accepted inputs advance state, while rejected inputs restore
  the batch's current pre-input checkpoint. The batch publishes only its final
  machine boundary and commits it together with all window roots. Rolling
  stores the settlement info (computation hash, post-epoch machine state hash,
  and the three machine leaf proofs for `iflags_Y`, HTIF tohost, and the first
  TX-buffer block) together with the next epoch's initial snapshot. The TX
  block itself is the outputs Merkle root.
- epoch-manager (`cartesi-rollups/node/src/epoch_manager`): each iteration
  runs the dispute tick first - for the last sealed epoch, instantiate a
  `Hero` with the epoch's inputs, leaves, and snapshot, and let it react
  to the tournament - then submits through the one transaction lane it
  owns; see
  [node architecture](node-architecture.md#mutation-scheduling-and-transaction-submission).
  A running dispute tick chooses either the Hero's action or, only when the
  Hero has none, one cleanup intent; it never submits both. Settlement runs
  only when no dispute is being contested, and bond recovery runs only when no
  higher-priority mutation is ready. Thus the production loop submits at most
  one mutation per tick through one serial nonce owner.
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
  restart without a stored queue. Candidate discovery starts from epoch roots
  recorded from finalized DaveConsensus events and follows only their
  `NewInnerTournament` descendants; it never scans attacker-writable candidates
  by submitter. If Latest already exposes the next epoch
  while finalized ingestion still ends at the previous one, recovery waits;
  the node submits no new maintenance into that observed rotation window. The
  lane itself is stateless: every send rebuilds from fresh observation at fresh
  market fees, and the mempool arbitrates duplicates and replacements.

Sentry-claim and settlement calldata are semantic commitments, so their
contents come from finalized inputs and stored settlement data. Latest may
only suppress a call that is already done or no longer needed. This is stricter
than permissionless cleanup: an inapplicable cleanup reverts and any cleanup
that still succeeds is a valid transition, while a stale vote or staged result
could succeed and cannot be repaired by a later retry.

## The dispute loop (Hero)

`cartesi-rollups/node/src/hero`. Once per polling iteration (a tick):

1. Advance one finalized, event-derived recursive `Dispute`, persist it, then
   clone and extend it over the disposable latest tail. Events supply
   tournaments, commitments, matches, child links, and match-elimination
   schedules. The tournament reader fetches these logs directly from the
   chain, while the narrow observer reads only the pinned standing and live
   match projections the Hero needs; the node does not fetch every clock or
   every match.
2. React recursively from the root tournament:
   - Build (or load from the main database's quartet cache) the commitment for
     this tournament's level.
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
   cleanup consumes the tournament standing overlay. Deeper work wins, and a
   cleanup is selected only when that tick has no Hero response.
4. A won inner tournament propagates to the parent match; losing the root
   tournament is reported (and should page a human: it means our
   commitment is wrong or we were censored beyond the protocol's bound).

The reader retains one in-memory Solid dispute between iterations. Its raw
recognized events and finalized watermark are persisted in the main database;
on restart the node reconstructs Solid from chain and disk. Latest Foam never
survives a tick. The main quartet cache (`sling_nodes`) and machine snapshots
remain the computation cache.

## Settlement invariant

`EpochManager::try_settle_epoch` asserts that the tournament winner's
commitment equals the locally computed computation hash. Today a mismatch
panics the node (see the debts list in `docs/node-architecture.md`); the
intended semantics is "this is a critical incident: either our node is
buggy or the protocol was defeated" - it must never be silently ignored.
