# Permissionless Refereed Tournaments

The PRT dispute system: on-chain tournament contracts plus the off-chain
clients that play them.

- [contracts/](contracts/) - the Solidity dispute contracts
  (security-critical; deep context in [contracts/AGENTS.md](contracts/AGENTS.md)).
- [client-rs/](client-rs/) - the Rust dispute engine used by the rollups
  node.
- [client-lua/](client-lua/) - the Lua client: reference implementation
  and test actor.
- [tests/](tests/) - the Lua-orchestrated end-to-end suites
  (see [docs/test-harness.md](../docs/test-harness.md)).
- [docs/](docs/) - the original PRT paper. Note the implemented variant
  differs; see the variant note in [contracts/AGENTS.md](contracts/AGENTS.md).
- [measure_constants/](measure_constants/) - tooling to measure the
  commitment-building constants that size tournament levels.

This project uses git submodules. Clone with `--recurse-submodules`, or
run `git submodule update --recursive --init` after cloning.

To run the end-to-end tests, follow [tests/rollups/README.md](tests/rollups/README.md).
