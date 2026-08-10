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
setup in the [root README](../../../README.md). Building the honeypot
machine image requires docker.

## Running

From the repository root:

```bash
just test-rollups-echo             # echo program, simple scenario
just test-rollups-honeypot        # full honeypot scenario suite
just test-rollups-honeypot-case gc_match   # one scenario
just view-rollups-logs             # tail the node's dave.log
```

Machine programs live in [test/programs](../../../test/programs/); the
scenario scripts live in [scenarios](./scenarios/).
