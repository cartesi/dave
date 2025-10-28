# PRT Core Contracts

This directory contains the Solidity implementation the PRT fraud-proof algorithm.
The entrypoint is the tournament factory, which instantiates tournament contracts.
The interfaces can be seen as implementing a sort of a task primitive,
which spawns and eventually resolves with a result.

## Features

- **Decentralization**: Anyone can permissionlessly propose the correct state and defend it with moderate funds and compute power.
- **Sybil Resistance**: Malicious actors can inflict delay attacks, but they are ineffective. Moreover, there is no resource-exhaustion attack.
- [**Integration with Cartesi Rollups**](../../cartesi-rollups/contracts): PRT can be used to protect and decentralize Cartesi Rollups apps.

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
just test-all
```

## Deploying the core contracts

In order to deploy the core contracts, you may run the following command.
You may want to consult the [Cannon CLI documentation] for deployment options.

```sh
just deploy-core  # [options...]
```

[Cannon CLI documentation]: https://usecannon.com/learn/cli
