# Dave Rollups Node

The prototype PRT validator node, one crate: it follows an application's
inputs, recomputes its state, and defends the correct result in disputes.
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

The Rust node is the reference implementation. The Lua client
(`prt/client-lua/`) mirrors the same commitment construction and honest
strategy as a testing companion - the e2e tests cross-check the two
every epoch, and the Lua module shape makes sybil actors cheap to
script. Keep them in agreement.

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
may instead name a private relay with revert protection. The signer must be exclusive to
one node process because the node owns its nonce sequence. Each tick batches
the applicable dispute or cleanup action, settlement step, and all available
bond recoveries at consecutive nonces from the latest mined count. The next
tick rebuilds the batch from chain state without waiting for receipts.

The node completes epochs in order: it waits for finalized settlement and its
winning bond recoveries before participating in the next epoch. It resumes the
same unfinished epoch after restart. Other participants may advance meanwhile;
the operating timing assumption allows a modest delay while refunds finish.
The completion cursor is bound to one claimant, so changing signer requires a
fresh state directory. A changed node version or schema also requires a fresh
directory under the node's rebuild policy.

Fund the whole pending batch. With the default
`CARTESI_SLING_BLOCKCHAIN_GAS_LIMIT=15_000_000`, a pool
may require each transaction's full gas limit at its max fee, plus its call
value. These requirements accumulate across the batch, and nested tournaments
each require their own join bond.

Here are its arguments:

```
Arguments of Cartesi PRT

Usage: cartesi-sling-node [OPTIONS] --app-address <APP_ADDRESS> --template-path <TEMPLATE_PATH> <COMMAND>

Commands:
  pk       private-key signer
  aws-kms  AWS KMS signer
  help     Print this message or the help of the given subcommand(s)

Options:
      --app-address <APP_ADDRESS>
          address of application [env: CARTESI_SLING_APP_ADDRESS=]
      --template-path <TEMPLATE_PATH>
          path to machine template image [env: CARTESI_SLING_TEMPLATE_PATH=]
      --blockchain-http-endpoint <BLOCKCHAIN_HTTP_ENDPOINT>
          blockchain read gateway endpoint URL [env: CARTESI_SLING_BLOCKCHAIN_HTTP_ENDPOINT=] [default: http://127.0.0.1:8545]
      --blockchain-http-submit-endpoint <BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT>
          raw-transaction submission endpoint URL; defaults to the read gateway [env: CARTESI_SLING_BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT=]
      --blockchain-id <BLOCKCHAIN_ID>
          blockchain chain id [env: CARTESI_SLING_BLOCKCHAIN_ID=] [default: 31337]
      --polling-interval <POLLING_INTERVAL>
          polling interval in seconds [env: CARTESI_SLING_POLLING_INTERVAL=] [default: 30]
      --snapshot-gap-inputs <SNAPSHOT_GAP_INPUTS>
          execute and durably publish open-epoch inputs in batches of N; 1 processes each input immediately, and sealing flushes a shorter final batch [env: CARTESI_SLING_SNAPSHOT_GAP_INPUTS=] [default: 64]
      --data-dir <DATA_DIR>
          [env: CARTESI_SLING_DATA_DIR=] [default: /tmp]
      --long-block-range-error-codes <LONG_BLOCK_RANGE_ERROR_CODES>
          error codes to retry `get_logs` with shorter block range [env: CARTESI_SLING_LONG_BLOCK_RANGE_ERROR_CODES=] [default: -32005 -32600 -32602 -32616]
  -h, --help
          Print help
```
