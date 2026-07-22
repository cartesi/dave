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

- `machine/` - commitment construction: driving the Cartesi Machine
  through meta-cycles, building leaf sequences, generating on-chain step
  proofs (`get_logs`). Read `docs/computation-hash.md` first; this is the
  arcane part.
- `sling/` - the quartet cache, the ruler geometry engine, and the
  dispute source serving every tree query a dispute needs; the design
  lives in `docs/plans/sling-design.md`.
- `strategy/` - the `Player`: the react loop that joins tournaments,
  bisects matches, seals, proves, and wins timeouts. Plus the garbage
  collector that frees bonds.
- `tournament/` - chain interface: `StateReader` (reconstructs the full
  tournament tree from events and calls) and `ArenaSender` (transaction
  wrappers, revert-tolerant).

The Lua client (`prt/client-lua/`) implements the same commitment
construction and honest strategy; the e2e tests assert both agree. Keep
it that way.

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
one node process because the node owns its mined nonce and replacement slot.
Here are its arguments:

```
Arguments of Cartesi PRT

Usage: cartesi-rollups-prt-node [OPTIONS] --app-address <APP_ADDRESS> --machine-path <MACHINE_PATH> <COMMAND>

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
          keep every Nth input-boundary machine snapshot (1 keeps all); the disk-vs-dispute-replay knob [env: SNAPSHOT_GAP_INPUTS=] [default: 64]
      --state-dir <STATE_DIR>
          [env: STATE_DIR=] [default: /var/folders/kf/1rg78mtx0c7f81_n7t6x6c6r0000gn/T/]
      --long-block-range-error-codes <LONG_BLOCK_RANGE_ERROR_CODES>
          error codes to retry `get_logs` with shorter block range [env: LONG_BLOCK_RANGE_ERROR_CODES=] [default: -32005 -32600 -32602 -32616]
  -h, --help
          Print help
```
