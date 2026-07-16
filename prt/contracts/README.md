# PRT Core Contracts

This directory contains the Solidity implementation of the PRT dispute game.
The tournament factory instantiates root and inner tournament clones, which
asynchronously pair commitments and eventually produce a result.

This code is security-critical. Read [AGENTS.md](AGENTS.md) before changing it
and use [the dispute-game documentation](../../docs/dispute-game.md) for the
implemented protocol and its assumptions. The original PRT paper is background,
not the contract specification. Active review findings are tracked in
[audit/REVIEW.md](audit/REVIEW.md).

## Features

- **Permissionless participation**: Anyone can join, progress, resolve, and
  clean up tournaments, subject to bonds, clocks, and valid proofs.
- **Sybil resistance**: Every joined commitment posts a tournament-level bond.
  The intended clock and refund bounds limit adversarial delay and resource
  cost; these are security properties that require analysis and tests.
- **Recursive disputes**: Non-leaf matches create linked inner tournaments;
  leaf matches resolve one state transition on-chain.
- [**Integration with Cartesi Rollups**](../../cartesi-rollups/contracts): PRT can be used to protect and decentralize Cartesi Rollups apps.

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
just test-all
```
