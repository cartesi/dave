# PRT client (Lua)

The Lua implementation of the PRT client. It predates the Rust client and
now serves three roles:

1. Reference implementation: an independent, readable implementation of
   commitment construction (`computation/`) and the honest dispute
   strategy (`player/`). The e2e tests cross-check the Rust node against
   it every epoch.
2. Test actor: the sybil (dishonest) players in `prt/tests/` are this
   client's honest strategy driven with a patched commitment builder.
3. Executable documentation: when the Rust code is unclear, this is
   usually the fastest way to understand the intended behavior.

Layout:

- `computation/` - machine driving and commitment building (the Lua twin
  of `cartesi-rollups/node/src/machine/`).
- `player/` - honest strategy, tournament state fetching, tx sending.
- `cryptography/` - keccak hashing and incremental merkle builders.
- `utils/` - process and time helpers used by the test harness.

Requires Lua 5.4, a local Cartesi Machine installation, and `cast`
(foundry) on the PATH. It is exercised through the test suites (see
`docs/test-harness.md`), not as a standalone daemon.
