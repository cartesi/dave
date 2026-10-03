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
5. Locally complete: settlement and every remaining bond payment owed to this
   node are resolved in finalized state. Only then does its durable completion
   cursor advance to the next epoch. Other participants may already be working
   on that epoch while this node finishes its refunds.

## Consensus layer: staging, sentries and foreclosure

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

A terminal application (halted, or yielded with an exception, on any
input) ends its epoch in a state no machine validity proof accepts, so that
epoch can never be staged. The node still defends that true state in the
root tournament: an undefended root would let a fabricated, stageable claim
win by timeout. Having won, the node holds the epoch with an error log, like
a no-winner result, and foreclosure is how the application moves on. A
template already terminal is refused at startup instead: the engine starts
every epoch from a state awaiting input, so the node cannot defend such an
application at all, and its epochs are the guardian's alone.

Settlement never touches the tournament's bond path: staging and
acceptance move no value, and nothing on the consensus path calls
`tryRecoveringBond`. No recipient code runs inside a settlement transaction.
The node explicitly recovers its winning bonds from the root and linked inner
tournaments. Its local epoch lifecycle includes those refunds; the contract's
settlement lifecycle remains independent. A foreign claimant's payment and a
no-winner tournament's retained balance do not prevent local completion.

The trust at this layer, in one place. Under the tournament's assumptions
(dispute-game.md), one live honest node makes the honest claim win the root.
DaveConsensus stages that claim only if its final state settles (a manual
`RX_ACCEPTED` yield) and accepts it once every sentry agrees or the claim
staging period ends; sentries shorten the wait and can neither veto nor
corrupt it. Everything the tournament cannot settle or may have gotten
wrong belongs to the application's guardian: a root without a winner, a
terminal application's epoch (defended, never stageable), and a result
decided outside the tournament's model, such as censorship beyond `C`. The
guardian calls `Application.foreclose()` (rollups-contracts,
`onlyGuardian`), which freezes the application irreversibly; the claim
staging period is its reaction window. This section and
cartesi-rollups/contracts/AGENTS.md move with DaveConsensus if it leaves
this repository.

## Node data flow

Three worker threads share one SQLite database (see
`docs/node-architecture.md` for the concurrency model):

```
                 finalized input/epoch logs
  Ethereum  ---------------------------------->  blockchain-reader
     ^                                                  |
     | consecutive-nonce batch                          | inputs, epochs
     |                                                  v
  epoch-manager  <-------- settlement data ---------  SQLite
     |                                                  ^
     +-- Hero <--- tournament logs + pinned views --- Ethereum
     |       \--- quartet queries ------------------> SQLite
     |
     +-- settlement + recoveries + completion cursor

  machine-runner  ---- snapshots, window-root quartets -------> SQLite
```

- blockchain-reader (`cartesi-rollups/node/src/blockchain_reader`): polls
  finalized blocks only, reads `InputAdded` and `EpochSealed` logs (none when
  the chain's input count and sealed epoch at the finalized head show nothing
  new), assigns each input to an epoch by comparing its global index against
  sealed boundaries, and writes both tables transactionally together with the
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
- epoch-manager (`cartesi-rollups/node/src/epoch_manager`): follows the durable
  `epoch_completion` cursor rather than the latest sealed epoch. Until that
  epoch settles, its Hero uses the locally computed settlement material to
  choose a dispute action or one cleanup. A won root permits the next
  settlement step: claim as a sentry, stage the verified result, or accept it
  after agreement or the staging period. These calls target only the cursor's
  epoch. Every available refund joins the same batch, even while the root is
  running. Settled historical epochs need no Hero or local execution before
  the manager can finish their refund obligations and advance.

Recovery starts from the ingested epoch root and follows that tournament's
`NewInnerTournament` descendants. It reads their bond dispositions at one
finalized hash: our recoverable bonds produce calls; recovered, foreign, and
no-winner dispositions need no further payment; running or unknown dispositions
prevent completion. Latest only suppresses already-mined payments. Restart
resumes the durable cursor, which is bound to the configured claimant.

The lane rebuilds each batch from current observations and assigns consecutive
nonces from the signer's latest mined count, with fresh market fees. The node
accepts ordinary races, retries, and modest participation delay while finishing
the previous epoch. The signer's funding floor is in the
[node README](../cartesi-rollups/node/README.md); the lane's rules are in
[node architecture](node-architecture.md#mutation-scheduling-and-transaction-submission).

Completion releases the old Hero before advancing the cursor. The machine
runner then collects older snapshots and dispute scratch during its next plan,
even when idle. It collects only epochs below both the completion cursor and
its newest machine epoch. A different claimant or incompatible schema needs a
fresh state directory under the node's rebuild policy.

Sentry-claim and settlement calldata are semantic commitments, so their
contents come from finalized inputs and stored settlement data. Latest may
only suppress a call that is already done or no longer needed. This is stricter
than permissionless cleanup: an inapplicable cleanup reverts and any cleanup
that still succeeds is a valid transition, while a stale vote or staged result
could succeed and cannot be repaired by a later retry.

## The dispute loop (Hero)

`cartesi-rollups/node/src/hero`. Once per polling iteration (a tick):

1. Advance one finalized, event-derived recursive `Dispute`, then clone and
   extend it over the disposable latest tail. Events supply
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
   cleanup is selected only when that tick has no Hero response. Cleanup
   plans eliminations only: the node never propagates a Sybil-versus-Sybil
   child's winner, which may linger until its carryover window ends (up to
   `T + 2G` more per child, one Sybil bond each).
4. A won inner tournament propagates to the parent match; losing the root
   tournament is reported (and should page a human: it means our
   commitment is wrong or we were censored beyond the protocol's bound).

The reader retains one in-memory Solid dispute between iterations and persists
none of it; on restart, or after a finalized event fails to fold onto it, the
node refolds Solid from the chain, starting at the root tournament's creation
block. Latest Foam never survives a tick. The main quartet cache
(`sling_nodes`) and machine snapshots remain the computation cache.

## Settlement invariant

Staging is planned only after the local Hero reports the root won. It then
asserts that the winner's commitment and final state equal the locally
computed ones, and acceptance asserts the same of the staged final state and
outputs root; a mismatch there means a node bug or corrupt local state, so it
panics (node-architecture.md, failure policy). Every settlement read is
pinned to the latest block where the Hero observed its win, and the contract
derives the stageable winner from the same standing the Hero reads, so both
sides describe one block and a tip reorg cannot fire an assert. A lost root or
a root without a winner is an error log every tick and is never staged; a
lost root should page a human. A won root whose final state does not settle
is held with an error (the terminal case above).
