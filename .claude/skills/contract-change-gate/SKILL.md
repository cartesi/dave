---
name: contract-change-gate
description: Pre- and post-change gate for production Solidity changes under prt/contracts or cartesi-rollups/contracts. Use before editing any src/ contract file there, and again before declaring the change done.
---

# Contract change gate

The authoritative context is the directory's `AGENTS.md`
(`prt/contracts/AGENTS.md` or `cartesi-rollups/contracts/AGENTS.md`):
its reading table, invariants, and guardrails. This skill is the
mechanical checklist wrapped around them.

Before editing:

1. Read the directory's `AGENTS.md` reading-table rows for your change
   type, and the docs they name.
2. For `prt/contracts`: run
   `just prt-contracts::compatibility-hashes` and save the output.

After editing, before declaring done:

1. `prt/contracts`: re-run `just prt-contracts::compatibility-hashes`
   and inspect EVERY difference against the change's intent. Hashes are
   comparison aids, not approval to update a snapshot mechanically.
2. Run the directory's gate:
   - `just prt-contracts::check-fmt` and `just prt-contracts::test-all`
     (or the focused suites the AGENTS.md lists), or
   - `just rollups-contracts::check-fmt` and
     `just rollups-contracts::test`.
3. Match the change to its required extra evidence (from AGENTS.md):
   Clock changes need the one-clock tests, the MatchClocks matrix, and
   Tournament composition; Match changes need white-box representation tests
   and an independent oracle; gas-affecting changes need the
   gas-calibration skill; geometry changes need the whole-table
   validator plus coordinated cross-implementation work.
4. If the ABI, events, errors, or clone-argument encoding changed, stop and
   confirm the task explicitly authorizes a new deployment generation;
   regenerate bindings (`just bind`) and deployment artifacts. If storage or
   raw Match or Clock encodings changed, inspect the impact and update
   white-box probes without treating the old representation as a
   wire-compatibility promise.
5. Cross-implementation seams (state transition, commitment geometry,
   provider behavior): confirm the Rust node, the Lua client, and the
   docs were updated in the same change, or say explicitly why not.
