# Contracts for Dave PRT in Cartesi Rollups

This project focuses on supporting Dave PRT as a settlement module for Cartesi Rollups.
The main contract is the `DaveConsensus` contract, which implements the `IOutputsMerkleRootValidator` interface.
This contract instantiates a PRT tournament every epoch to settle on the new state of the machine.

## Features

- Integrates Dave PRT with Cartesi Rollups
- Contains a factory contract for `DaveConsensus` contracts
- Unit tests in Solidity using Forge
- Cannonfile for modular deployments

## Installing dependencies

In order to install the Node.js and Solidity dependencies, please run the following command.

```sh
just install-deps
```

## Building

In order to compile the contracts and generate Rust bindings, you may run the following command.

```sh
just build
```

## Testing

You can run the unit tests with the following command.

```sh
just test
```

## Deploying an application

Besides the `DaveAppFactory` contract,
you may also want to deploy an application contract
that is validated by a `DaveConsensus` contract.
In order to do so, you need to first build your application machine
and compute its initial hash (also known as its _template hash_).
Depending on whether you wish to deploy this application
to a local, development network (like `anvil` or `reth`)
or to a live production network (like a mainnet or a testnet),
there are different sets of commands you may want to run.
Nevertheless, they all share the same options and environment variables:

| Option | Description | Environment variable |
| :-: | :-: | :- |
| `--rpc-url <URL>` | RPC URL | `CANNON_RPC_URL` |
| `--private-key <PK>` | Private key | `CANNON_PRIVATE_KEY` |
| `--write-deployments <DIR>` | Deployments diretory | |
| `--dry-run` | Simulate deployment on a local fork | |
| `--impersonate <ADDR>` | Impersonate address (requires `--dry-run`) | |
| `--impersonate-all` | Impersonate all addresses (requires `--dry-run`) | |

### Local deployment (dev)

In order to deploy the contracts to a local development network (e.g. Anvil), you may run the following command.
This command receives a positional argument, the initial machine state hash of the application.

```sh
just deploy-instance-dev $INITIAL_HASH
```

Additional arguments are forwarded to the [`cannon build`](https://usecannon.com/learn/cli#build) command.

### Live deployment (prod)

Deploying the contracts to a production network is also simple to do through the following command.
This command takes the same positional argument as the development-mode variant.

```sh
just deploy-instance $INITIAL_HASH
```

If, instead, you wish to deploy just the core contracts, you can run the following command.

```sh
just deploy-core
```

Both commands require an RPC URL and private key to be specified, or may be simulated through a dry run.
