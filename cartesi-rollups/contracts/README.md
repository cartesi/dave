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

## Deploying the core contracts

In order to deploy the core contracts, you may run the following command.
You may want to consult the [Cannon CLI documentation] for deployment options.

```sh
just deploy-core  # [options...]
```

[Cannon CLI documentation]: https://usecannon.com/learn/cli
