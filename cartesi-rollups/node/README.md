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
name a private relay with revert protection. The signer must be exclusive to
one node process because the node owns its nonce sequence. Each tick batches
the applicable dispute or cleanup action, settlement step, and all available
bond recoveries at consecutive nonces from the latest mined count. The next
tick rebuilds the batch from chain state without waiting for receipts.

The node completes epochs in order: it waits for finalized settlement and its
winning bond recoveries before participating in the next epoch. It resumes the
same unfinished epoch after restart. Other participants may advance meanwhile;
the operating timing assumption allows a modest delay while refunds finish.
The completion cursor is bound to one claimant, so changing signer requires a
fresh state directory. A changed node version, schema, or commitment semantics
also requires a fresh directory under the node's rebuild policy.

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

Each transaction's gas limit is half again its estimate at the latest block;
the largest action, a maximum-input leaf proof, estimates about 5.1M. A call
that already reverts there is not sent. When estimation fails for another
reason the node falls back to 15M. Fund the whole pending batch: a pool may
require each transaction's full gas limit at its max fee, plus its call value.
These requirements accumulate across the batch, and nested tournaments each
require their own join bond.

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
