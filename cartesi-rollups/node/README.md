# Dave Rollups Node

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
Here are its arguments:

```
Arguments of Cartesi PRT

Usage: cartesi-rollups-prt-node [OPTIONS] --app-address <APP_ADDRESS> --machine-path <MACHINE_PATH> <COMMAND>

Commands:
  pk       private‐key signer
  aws-kms  AWS KMS signer
  help     Print this message or the help of the given subcommand(s)

Options:
      --app-address <APP_ADDRESS>
          addresss of application [env: APP_ADDRESS=]
      --machine-path <MACHINE_PATH>
          path to machine template image [env: MACHINE_PATH=]
      --web3-rpc-url <WEB3_RPC_URL>
          blockchain gateway endpoint url [env: WEB3_RPC_URL=] [default: http://127.0.0.1:8545]
      --web3-chain-id <WEB3_CHAIN_ID>
          blockchain chain id [env: WEB3_CHAIN_ID=] [default: 13370]
      --sleep-duration-seconds <SLEEP_DURATION_SECONDS>
          polling sleep interval [env: SLEEP_DURATION_SECONDS=] [default: 30]
      --state-dir <STATE_DIR>
          [env: STATE_DIR=] [default: /var/folders/kf/1rg78mtx0c7f81_n7t6x6c6r0000gn/T/]
      --long-block-range-error-codes <LONG_BLOCK_RANGE_ERROR_CODES>
          error codes to retry `get_logs` with shorter block range [env: LONG_BLOCK_RANGE_ERROR_CODES=] [default: -32005 -32600 -32602 -32616]
  -h, --help
          Print help
```
