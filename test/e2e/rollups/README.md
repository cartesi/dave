# End-to-end tests

End-to-end tests for the rollups Rust node. A Lua orchestrator spawns an
honest node in the background to advance the rollups state and defend the
application, plus dishonest sybil players (built from the Lua client, see
`../support/runners/`) that tamper with commitments and must lose.

How the harness works, what the scenarios cover, and how to add one:
see [docs/test-harness.md](../../../docs/test-harness.md).

## Setup

Clone with `--recurse-submodules`, or run
`git submodule update --recursive --init` after cloning, then follow the
setup in the [root README](../../../README.md).

The honeypot scenarios are opt-in and not in CI. Build the image from the
pinned honeypot commit, or from any other (unreleased ones included), then run
a scenario on it; the build needs docker and a current devnet:

```bash
just programs::build-honeypot            # the commit pinned in test/programs/justfile
just programs::build-honeypot <commit>   # any other honeypot commit
just e2e honeypot simple
```

## Running

From the repository root:

```bash
just e2e-smoke                     # the smoke CI runs; node logs in _smoke/
just e2e echo simple               # one scenario: just e2e <program> <scenario>
CHAOS_SEED=5 just e2e echo chaos   # chaos at another seed (the smoke keeps 1)
just e2e-logs                      # follow the node's dave.log
```

Machine programs live in [test/programs](../../../test/programs/); the
scenario scripts live in [scenarios](./scenarios/).
