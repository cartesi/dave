# Dave Rollups Node

The PRT validator node (the sling node), one crate: it follows an
application's inputs, recomputes its state, settles epochs, and defends the
correct result in disputes. It is a focused validator and stays one: it
keeps no outputs and serves no output or voucher proofs, and any reader
feature belongs in a separate executable.
Architecture and known debts: [docs/node-architecture.md](../../docs/node-architecture.md).
How epochs and disputes flow: [docs/epoch-lifecycle.md](../../docs/epoch-lifecycle.md).

## Layout (`src/`)

Worker modules - one thread each, synchronizing through the node
database: `blockchain_reader` (chain logs to db), `machine_runner`
(inputs to machine execution to leaf hashes and snapshots),
`epoch_manager` (settlement and disputes). `storage` is the single
view of that database and the only module that speaks SQL.

The dispute engine (formerly the `cartesi-prt-core` crate):

- `engine/` - commitment construction and geometry: driving the Cartesi
  Machine through meta-cycles (`machine_stf`, `stf`), the
  `Structure`/`Position` coordinate system (`structure`), the quartet
  cache and the ruler (`cache`, `ruler` - `Ruler::prove_transition`
  generates on-chain step proofs), and the dispute source serving every
  tree query a dispute needs (`dispute`). Read
  `docs/computation-hash.md` first; this is the arcane part.
- `hero/` - the honest player: per tick it observes, plans, and
  dispatches either one dispute action - join, bisect, seal, prove, or
  win by timeout - or one timeout/child cleanup (`gc_planner`).
- `tournament/` - the semantic chain interface: `dispute` owns the recursive,
  event-derived tournament tree; `domain` defines wire-independent values;
  `observer` performs the narrow pinned point reads; `reader` maintains the
  finalized Solid prefix and builds a disposable Latest Foam; and `sender`
  prepares contract mutation requests.
- `merkle/` - the tree builders shared by commitment construction.

The Rust node is the only honest dispute client. The Lua client
(`prt/client-lua/`) is its testing companion: its commitment construction
is an independent oracle that the e2e tests cross-check every epoch and
that must agree with the node's, and its player is the e2e sybil actor,
which needs to agree with the node only well enough to steer disputes.

## Build (release)

Run at the repository root:
```
just build-release-rust-workspace
```

The executable will appear at:
```
./target/release/cartesi-rollups-prt-node
```

## Run

Running the node requires an Ethereum JSON-RPC gateway and a funded wallet.
Reads use `--web3-rpc-url`. Raw signed transactions use
`--web3-submit-rpc-url`, which defaults to the read endpoint and may instead
name a private relay with revert protection: honest nodes that share a
commitment race on every step, and without it each pays for its reverted
copies of the steps another node landed first. The signer must be exclusive to
one node process because the node owns its nonce sequence. Each tick batches
the applicable dispute or cleanup action, settlement step, and all available
bond recoveries at consecutive nonces from the latest mined count. The next
tick rebuilds the batch from chain state without waiting for receipts.

The node completes epochs in order: it waits for finalized settlement and its
winning bond recoveries before participating in the next epoch. It resumes the
same unfinished epoch after restart. Other participants may advance meanwhile;
the operating timing assumption allows a modest delay while refunds finish.
Changing the signer keeps the state directory: the node recovers the bonds of
its current signer, and a previous signer's bonds stay recoverable by anyone
through `tryRecoveringBond`, which pays the recorded claimer. A changed node
version, schema, or commitment semantics requires a fresh directory under the
node's rebuild policy. The first
start pins a directory to its application, chain and template, and every start
checks the `--machine-path` image against the application's on-chain initial
hash; a mismatch is refused before anything is written, and so is a matching
image that is not paused at a manual accepted yield, from which no epoch can
start.

One node process owns a state directory: startup locks its `node.lock` and
refuses a directory another process holds, or one on a filesystem without
file locks. The lock does not cover the signer: nodes on different
directories must still not share a key.

Stop the node with SIGTERM or SIGINT. Ingestion stops at once and machine
execution before its next input or epoch roll, dropping an unfinished batch
that a restart replays. A dispute tick in flight finishes, so a prepared
action still goes out, while the dispute's machine work stops early and
resumes after the restart. Give the stop timeout room for one input's
execution and one tick's RPC calls; under three levels a dispute's leaf and
middle commitment builds also run to completion. A second stop signal exits at
once, as safely as SIGKILL. A restart refetches the live tournaments' logs.
Upgrade or rebuild the state directory between disputes: a fresh directory
rebuilds every engaged level's commitment on the dispute clock.

Put `--state-dir` on a filesystem with reflinks (APFS, btrfs, or XFS with
`reflink=1`). Every input clones a stored machine; a reflinked clone shares
unchanged extents, while elsewhere (ext4) the emulator falls back to sparse
copies, which stay correct but cost disk and clone time in proportion to the
machine. Performance is the operator's to size. The node aims to add no work
over the emulator's own (work-count tests guard the algorithms; a comparison
against the emulator on the same host is a release measurement), and the Hero
logs how long each action took from reading the chain through commitment
builds and proving (`prepared ... in ...`), plus any slow tick that built
without acting, for comparison with the deployed response and commitment
budgets.

Each transaction's gas limit is its estimate at the latest block plus half
again, at least 150,000 (a join that pairs on inclusion needs 117,262 more
than its estimate), and stops at the EIP-7825 cap of 16,777,216 when the
estimate fits under it; the largest action, a maximum-input leaf proof,
estimates about 5.1M. A call that already reverts there is not sent. When
estimation fails for another reason the node falls back to 15M. A transaction
the pool turns down on price is sent once more with its priority fee raised
to its max fee, which displaces a pending transaction the base fee has
outrun.

Fund the signer for a whole batch. A pool admits a transaction only while the
balance covers every pending transaction's gas limit at its max fee plus its
value, and the node logs an error on each tick whose batch reserves more than
the signer holds. A dispute posts a join bond at every level it reaches, each
the level's match work allocation at 50 gwei (`Bond.sol`), and a bond comes
back only once its tournament's result is finalized, so a level whose next
join comes due sooner holds two. With the canonical table (heights 48, 17,
27) and a peak base fee of 100 gwei, twice the contracts' 50 gwei work-price
cap, which the node quotes as a max fee of about 200 gwei (twice the base fee
plus the tip):

```
floor = root bond + 2 x each inner level's bond
        + (leaf-proof gas limit + 1M) x peak max fee
      = 0.3353 + 2 x (0.1369 + 0.4512) + (7.62M + 1M) x 200 gwei
      = about 3.2 ETH
```

The 1M covers the settlement step and bond recoveries that share the leaf
proof's batch. A slot whose estimate fails other than by a revert reserves
15M, 3 ETH at that fee. Above the work-price cap an action's refund falls short
of its cost, and a replaced transaction pays its whole max fee, so a long
dispute during a fee spike draws the balance down: the per-tick error is the
signal to top up. These are Ethereum L1 numbers from `Bond.sol`, `Gas.sol` and
the deployed table; recompute them when any of them changes.

Here are its arguments:

```
Arguments of Cartesi PRT

Usage: cartesi-rollups-prt-node [OPTIONS] --app-address <APP_ADDRESS> --machine-path <MACHINE_PATH> --state-dir <STATE_DIR> <COMMAND>

Commands:
  pk       private-key signer
  aws-kms  AWS KMS signer
  help     Print this message or the help of the given subcommand(s)

Options:
      --app-address <APP_ADDRESS>
          address of application [env: APP_ADDRESS=]
      --machine-path <MACHINE_PATH>
          path to machine template image [env: MACHINE_PATH=]
      --web3-rpc-url <WEB3_RPC_URL>
          blockchain read gateway endpoint URL [env: WEB3_RPC_URL=] [default: http://127.0.0.1:8545]
      --web3-submit-rpc-url <WEB3_SUBMIT_RPC_URL>
          raw-transaction submission endpoint URL; defaults to the read gateway [env: WEB3_SUBMIT_RPC_URL=]
      --web3-chain-id <WEB3_CHAIN_ID>
          blockchain chain id [env: WEB3_CHAIN_ID=] [default: 31337]
      --sleep-duration-seconds <SLEEP_DURATION_SECONDS>
          polling sleep interval [env: SLEEP_DURATION_SECONDS=] [default: 30]
      --snapshot-gap-inputs <SNAPSHOT_GAP_INPUTS>
          execute and durably publish open-epoch inputs in batches of N; 1 processes each input immediately, and sealing flushes a shorter final batch [env: SNAPSHOT_GAP_INPUTS=] [default: 64]
      --state-dir <STATE_DIR>
          node state (database, snapshots, dispute scratch); keep it across restarts, on a filesystem with reflinks [env: STATE_DIR=]
      --long-block-range-error-codes <LONG_BLOCK_RANGE_ERROR_CODES>
          error codes to retry `get_logs` with shorter block range [env: LONG_BLOCK_RANGE_ERROR_CODES=] [default: -32005 -32600 -32602 -32616]
  -h, --help
          Print help
```

## Operator notes

- Read the levels as the failure policy defines them
  ([node-architecture.md](../../docs/node-architecture.md#failure-policy)):
  an ERROR asks an operator to act; a WARN means the node carries on. A WARN
  that repeats every tick is a stall to investigate: the node keeps retrying
  one step while the dispute clocks run.
- A steady-state tick refuses an incomplete log response before committing
  and heals on the next tick. During a cold-start catch-up, a chunk that ends
  before the finalized head is checked for contiguity only, so an input or
  epoch dropped at its tail surfaces later as an index or epoch error that
  does not heal. Either failure logs an error once it repeats on the next
  tick: point the node at a provider that serves complete logs, and if the
  error persists, rebuild the state directory.
- Every epoch settles no sooner than its root tournament's allowance, plus
  the application's claim staging period unless every sentry agrees. With the
  canonical three-level table that allowance is about one week and 85 minutes
  on mainnets and about 9 hours 25 minutes on testnets.
- A lost root, a root without a winner, and a won epoch whose final state
  cannot settle (a terminal application) each log an error every tick: they
  are the application guardian's to resolve, by foreclosure if need be
  ([epoch-lifecycle.md](../../docs/epoch-lifecycle.md#consensus-layer-staging-sentries-and-foreclosure)).
  A foreclosed application settles nothing more: let the node finish
  recovering its winning bonds, then stop it.
