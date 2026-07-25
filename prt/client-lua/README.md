# PRT client (Lua)

The Lua implementation of the PRT client. It predates the Rust client -
it was the first prototype - and remained as the Rust node's testing
companion. The Rust node is the reference implementation; this client
mirrors it with the same module "ingredients" so that dishonest actors
are cheap to script. It may yet graduate into a second production
implementation: fraud proofs need only one working validator, so more
independent clients is strictly better, never a weakest link. Its three
roles today:

1. Cross-implementation oracle: an independent, readable implementation
   of commitment construction (`computation/`) and the honest dispute
   strategy (`player/`). The strategy observes the same semantic contract
   interface as the Rust node, but its domain adapter and planner are an
   independent implementation. The e2e tests cross-check the Rust node
   against it every epoch.
2. Test actor: the sybil (dishonest) players in `prt/tests/` are this
   client's honest strategy driven with a patched commitment builder.
3. Executable documentation: when the Rust code is unclear, this is
   usually the fastest way to understand the intended behavior.

Layout:

- `computation/` - machine driving and commitment building (the Lua twin
  of the Rust node's commitment construction: `cartesi-rollups/node/src/engine/`
  plus `merkle/`).
- `player/domain.lua`, `fold.lua`, and `adapter.lua` - the typed semantic
  boundary over structural events and observer views.
- `player/semantic_reader.lua` - one finalized/latest observation with
  exact-hash tail logs, EIP-1898 point calls, and a final canonicality check.
- `player/context.lua`, `planner.lua`, `fulfiller.lua`, and `dispatcher.lua` -
  actor-relative projection, pure policy, local material construction, and
  the single transaction dispatch seam.
- `player/actor.lua` - the orchestration loop: observe, assemble, plan,
  fulfill, and dispatch at most one mutation per tick.
- `player/gc_planner.lua` - pure, actor-neutral cleanup policy over an
  accepted dispute observation.
- `player/reader.lua` - the structural log reader; production reads go
  through `semantic_reader.lua`, this one feeds the e2e harness's
  introspection seam (`prt/tests/rollups/dave/reader.lua`).
- `player/sender.lua` - transaction transport.
- `cryptography/` - keccak hashing and incremental merkle builders.
- `utils/` - process and time helpers used by the test harness.

Requires Lua 5.4, a local Cartesi Machine installation, and `cast`
(foundry) on the PATH. It is exercised through the test suites (see
`docs/test-harness.md`), not as a standalone daemon.
