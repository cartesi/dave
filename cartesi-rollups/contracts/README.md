# Contracts for Dave PRT in Cartesi Rollups

This project focuses on supporting Dave PRT as a settlement module for Cartesi Rollups.
The main contract is the `DaveConsensus` contract, which implements the `IOutputsMerkleRootValidator` interface.
This contract instantiates a PRT tournament every epoch to settle on the new state of the machine.

## Features

- Integrates Dave PRT with Cartesi Rollups
- Contains a factory contract for `DaveConsensus` contracts
- Unit tests and deployment scripts in Solidity using Forge

## Installing dependencies

In order to install the Solidity dependencies, please run the following command.

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
You may want to consult the [Forge script documentation] for options.

```sh
./script/deploy.sh  # [options...]
```

Only Ethereum is supported. `./script/deploy-mainnets.sh` deploys to Ethereum
Mainnet and `./script/deploy-testnets.sh` to Ethereum Sepolia; the release's
`deployment-addresses` asset holds those two chains.
`./script/deploy-experimental.sh` deploys to the other registered chains, whose
addresses ship in the separate `deployment-addresses-experimental` asset. OP
Mainnet, Base and their Sepolia testnets are experimental. Arbitrum One and
Arbitrum Sepolia are experimental and the node does not start there: their
`block.number` is the parent chain's block number, so their clocks are
calibrated to its 12 s slot, their addresses equal Ethereum's and Sepolia's, and
an application's `DaveConsensus` claim staging period counts parent-chain
blocks. See the clock model in
[`docs/dispute-game.md`](../../docs/dispute-game.md#clock-model).

[Forge script documentation]: https://www.getfoundry.sh/reference/forge/script#forge-script
