# Dave - agent context

Dave is Cartesi's permissionless, interactive fraud-proof system, currently
implemented on top of the Permissionless Refereed Tournaments (PRT) algorithm.
This repository holds the on-chain dispute contracts, two off-chain clients
(a prototype Rust node and a Lua testing node), the Cartesi Machine
integration, and the test infrastructure that ties them together.

> The code is the source of truth. The papers, the comments, and these docs
> have drifted before and will drift again. Where they disagree, trust the
> code, and prefer verifying a claim over relying on any document's specifics.

## Repository map

```
prt/contracts/       Solidity dispute contracts - SECURITY-CRITICAL trust
                     boundary. Deep context in prt/contracts/AGENTS.md.
prt/client-lua/      PRT client in Lua. Testing node, sybil actor, and
                     executable reference for commitment construction.
prt/tests/           Lua-orchestrated end-to-end tests. Spawns the real Rust
                     node plus dishonest sybils against anvil.
prt/docs/            The original PRT paper (prt.pdf).
dave/docs/           The Dave paper (dave.pdf), a liveness improvement over
                     PRT. NOT what the current contracts implement.
cartesi-rollups/
  contracts/         Rollups consensus contracts (DaveConsensus, app factory).
  node/              The rollups node, a single crate: worker modules
                     synchronize through the storage module (the only
                     SQL surface); the dispute engine lives in the
                     engine/hero/tournament modules, and the shared
                     primitives (merkle, arithmetic, kms) are folded-in
                     modules, not separate crates.
machine/             Cartesi Machine: emulator + solidity-step submodules and
                     the Rust bindings that link against the emulator.
test/programs/       Machine images used by tests (echo, yield, honeypot).
docs/                The knowledge base. Start at docs/README.md.
```

## What matters where

- `prt/contracts/` is on-chain and trust-bearing: it decides which computation
  result is canonical. Bugs there are consensus bugs. See
  `prt/contracts/AGENTS.md` before touching anything.
- The node (`cartesi-rollups/node/`) is the honest
  validator's sword. A node bug does not break the protocol, but it can
  forfeit a dispute the honest party should have won: wrong commitments or
  missed deadlines lose tournaments. Treat commitment construction and proof
  generation as correctness-critical, not just liveness-critical.
- The Lua client and the Solidity state-transition tests double as
  cross-implementation oracles for the Rust code. Tests compare their outputs;
  keep all implementations in agreement.

## Where knowledge lives

- `docs/computation-hash.md` - how commitments are built: the meta-cycle
  coordinate system, uarch spans, checkpoints, and revert. Read this before
  touching anything under `cartesi-rollups/node/src/engine/` or
  `cartesi-rollups/node/src/storage/rollups_machine.rs`.
- `docs/dimensioning.md` - the trust model (who may be adversarial) and
  the worst-vs-average dimensioning rule with its reasoning. Read before
  touching clocks, spans, timeouts, or tournament constants.
- `docs/epoch-lifecycle.md` - inputs, epochs, sealing, disputes, settlement.
- `docs/node-architecture.md` - the prototype node's threads, database, and
  known technical debts.
- `docs/test-harness.md` - how the Lua e2e orchestration works and how to add
  scenarios.
- `docs/glossary.md` - the project vocabulary (ustep, ureset, barch,
  meta-cycle, dangling commitment, and the span-vs-mask naming trap).
- `docs/build-system.md` - how setup and builds work, and open design
  questions (bindings generation, emulator dependency).

## Build and test

Requires: git, docker, just, GNU make, foundry, and for native runs a C++
toolchain, Lua 5.4, Rust, and the Cartesi Machine. See the root `README.md`
and `docs/build-system.md`.

```bash
just doctor           # diagnose the checkout; every problem names its fix
just setup            # one-time: submodules, deps, emulator build
just build            # contracts + bindings + rust workspace
just check            # THE pre-commit gate: fmt, lints, clippy, unit tests
just test-rust-workspace       # rust unit tests
just test-smart-contracts      # forge test suites (consensus + prt)
just test-rollups-echo         # e2e: honest node, echo machine
just test-rollups-honeypot     # e2e: full honeypot scenario suite
```

When something fails mysteriously, run `just doctor` before debugging: it
checks tools, submodules, bindings, machine images, and devnet artifacts,
and prints the fixing command for anything missing.

For long commands, prefer `just logged <file> <cmd...>`: it writes the
full output to the file and reports the TRUE exit code. Piping through
`tail`/`grep`/`head` reports the last pipe stage's status and has
laundered real failures into green output more than once.

At the end of a work session, run `just worktrees-sweep` (and
`just rollups-tests::sweep` after reading e2e results): session worktrees
accumulate regenerable bulk - build caches and e2e state - that outlives
their sessions by months. `just worktrees-report` shows the damage.

The Rust workspace does not build with plain `cargo` from a fresh clone: the
Solidity bindings are generated (not committed), so run `just bind` (or any
just cargo recipe) at least once. The emulator is linked from
`LIBCARTESI_PATH` when set (the nix devshell exports it); without it,
`cartesi-machine-sys` builds the `machine/emulator` submodule from source.

## Conventions

Comments and prose:

- Do not use unicode inside comment phrases and prose. Plain ASCII.
- Keep comments concise. Avoid redundant and excessive inline commentary.
- Comment the non-obvious, not the self-evident. Do not restate what the code
  already expresses. Explain the why, edge cases, invariants, and subtle
  behaviors that cannot be inferred from reading the code alone.

These apply to documentation files as well. When writing docs, prefer stating
invariants and reasons (stable) over restating code structure (volatile), and
mark uncertain claims as leads to verify rather than facts.

Code:

- Rust is formatted with `cargo fmt` (`just check-fmt-rust-workspace`).
- Solidity is formatted with `forge fmt` (run `just check-fmt` inside the
  contracts directory you touched).
- Match the surrounding code's style and idiom; this is a multi-author
  codebase with history.

## Current state (written 2026-07)

- `main` holds the released 2.x line; `next/3.0` is the base branch for the
  next version. New work targets `next/3.0`.
- The Rust node is an acknowledged prototype. It works and passes the e2e
  suites, but it is scheduled for an incremental rewrite (the "sling node").
  Recon and characterization tests come first; avoid opportunistic
  refactoring of node internals until that harness exists.
- An external security audit of `prt/contracts` is ongoing. Be conservative
  with contract changes.
