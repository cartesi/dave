# Permissionless Refereed Tournaments

The PRT dispute system: on-chain tournament contracts plus the off-chain
clients that play them.

- [contracts/](contracts/) - the Solidity dispute contracts
  (security-critical; deep context in [contracts/AGENTS.md](contracts/AGENTS.md)).
- [cartesi-rollups/node/](../cartesi-rollups/node/) - the Rust rollups node,
  including the dispute actor and tournament synchronization code.
- [client-lua/](client-lua/) - the Lua client: reference implementation
  and test actor.
- [test/e2e/rollups/](../test/e2e/rollups/) - the Lua-orchestrated
  end-to-end suites
  (see [docs/test-harness.md](../docs/test-harness.md)).
- [The original PRT paper](../docs/papers/prt.pdf) - an architectural
  ancestor, not the contract specification; see the implemented-game
  description in [docs/dispute-game.md](../docs/dispute-game.md).
- [measure_constants/](measure_constants/) - the independent emulator-level
  stress-ng benchmark for commitment-building geometry.

This project uses git submodules. Clone with `--recurse-submodules`, or
run `git submodule update --recursive --init` after cloning.

To run the end-to-end tests, follow the
[rollups harness README](../test/e2e/rollups/README.md).
