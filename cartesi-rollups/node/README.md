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
./target/release/cartesi-sling-node
```

## Run

Running the node requires an Ethereum JSON-RPC gateway and a funded wallet.
Reads use `--blockchain-http-endpoint`. Raw signed transactions use
`--blockchain-http-submit-endpoint`, which defaults to the read endpoint and
may instead name a private relay with revert protection: honest nodes that
share a commitment race on every step, and without it each pays for its
reverted copies of the steps another node landed first. The relay must not
land reverting transactions and must reach builders covering most blocks. For
example, MEV Blocker's `/noreverts` endpoint qualifies, while its default
endpoint lands reverts, and Flashbots Protect's default endpoint reaches only
the Flashbots builder. The signer must be exclusive to
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
checks the `--template-path` image against the application's on-chain initial
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

Put `--data-dir` on a filesystem with reflinks (APFS, btrfs, or XFS with
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
The sling node: a PRT validator for Cartesi Rollups applications

Usage: cartesi-sling-node [OPTIONS] --app-address <APP_ADDRESS> --template-path <TEMPLATE_PATH> --data-dir <DATA_DIR> <COMMAND>

Commands:
  pk       private-key signer
  aws-kms  AWS KMS signer
  help     Print this message or the help of the given subcommand(s)

Options:
      --app-address <APP_ADDRESS>
          address of application [env: CARTESI_SLING_APP_ADDRESS]
      --template-path <TEMPLATE_PATH>
          path to machine template image [env: CARTESI_SLING_TEMPLATE_PATH]
      --blockchain-http-endpoint <BLOCKCHAIN_HTTP_ENDPOINT>
          blockchain read gateway endpoint URL [env: CARTESI_SLING_BLOCKCHAIN_HTTP_ENDPOINT] [default: http://127.0.0.1:8545]
      --blockchain-http-submit-endpoint <BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT>
          raw-transaction submission endpoint URL; defaults to the read gateway [env: CARTESI_SLING_BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT]
      --blockchain-id <BLOCKCHAIN_ID>
          blockchain chain id [env: CARTESI_SLING_BLOCKCHAIN_ID] [default: 31337]
      --polling-interval <POLLING_INTERVAL>
          polling interval in seconds [env: CARTESI_SLING_POLLING_INTERVAL] [default: 30]
      --snapshot-gap-inputs <SNAPSHOT_GAP_INPUTS>
          execute and durably publish open-epoch inputs in batches of N; 1 processes each input immediately, and sealing flushes a shorter final batch [env: CARTESI_SLING_SNAPSHOT_GAP_INPUTS] [default: 64]
      --data-dir <DATA_DIR>
          node state (database, snapshots, dispute scratch); keep it across restarts, on a filesystem with reflinks [env: CARTESI_SLING_DATA_DIR]
  -h, --help
          Print help
```

## Operator notes

- The node's HTTP client honors the `HTTP_PROXY`, `HTTPS_PROXY` and
  `ALL_PROXY` environment variables (and macOS's system proxy settings), and
  on Linux it needs the system's CA certificates even for a plain-http
  endpoint: without them it stops at startup with an error saying so.
- Supported chains are Ethereum mainnet and Sepolia. OP Mainnet, Base and
  their Sepolia testnets have experimental deployments: the node runs there
  but is not validated, and refunds leave out the L1 data fee. On Arbitrum
  the node stops at startup: contracts there measure clocks in the parent
  chain's block numbers, while logs and the node's heads use Arbitrum's own.
- A fresh state directory replays every input since the application's
  deployment. To upgrade across a change that requires one, start the new
  node on a new directory with its own funded signer, let it catch up, then
  stop the old one; never wipe the only node's directory in place. The new
  node recovers only its own signer's bonds and never revisits an epoch it
  has completed, even when restarted under another signer. The old signer's
  outstanding bonds stay recoverable by anyone: a direct `tryRecoveringBond`
  call on each such tournament pays the recorded claimer, whoever sends it.
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
