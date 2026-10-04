# PRT client (Lua)

The Lua implementation of the PRT client. It predates the Rust client -
it was the first prototype - and remains the Rust node's testing
companion, not a second production client. Its roles:

1. Commitment oracle: `computation/` is an independent, readable
   implementation of commitment construction, and the e2e tests cross-check
   the Rust node's commitments against it every epoch.
2. Test actor: the sybil (dishonest) players in `test/e2e/` are `player/`'s
   honest strategy driven with a patched commitment builder. It only needs
   to agree with the node well enough to steer e2e disputes; cleanup (match
   and child elimination) is the node's job, tested in its harness.
3. Executable documentation: when the Rust code is unclear, this is
   usually the fastest way to understand the intended behavior.

Layout:

- `computation/` - machine driving and commitment building (the Lua twin
  of the Rust node's commitment construction: `cartesi-rollups/node/src/engine/`
  plus `merkle/`).
- `player/domain.lua`, `fold.lua`, and `adapter.lua` - the typed semantic
  boundary over structural events and observer views.
- `player/semantic_reader.lua` - one latest-head observation: structural logs
  through the sampled head, EIP-1898 point calls pinned to it, and a final
  canonicality check. It proves no ancestry; the e2e anvil does not reorg.
- `player/context.lua`, `planner.lua`, `fulfiller.lua`, and `dispatcher.lua` -
  actor-relative projection, pure policy, local material construction, and
  the single transaction dispatch seam.
- `player/actor.lua` - the orchestration loop: observe, assemble, plan,
  fulfill, and dispatch at most one mutation per tick.
- `player/sender.lua` - transaction transport.
- `cryptography/` - keccak hashing and incremental merkle builders.
- `utils/` - process and time helpers used by the test harness.

Requires Lua 5.4, a local Cartesi Machine installation, and `cast`
(foundry) on the PATH. It is exercised through the test suites (see
`docs/test-harness.md`), not as a standalone daemon.
