# Dave knowledge base

Prose documentation for things the code cannot say on its own: domain
invariants, cross-component protocols, and design rationale. Code-level
detail belongs in code comments; agent-facing directives belong in
`AGENTS.md` files. Everything here follows the repo's documentation
stance: the code is the source of truth, and these files state invariants
and reasons, not restatements of code structure.

Reading order for newcomers:

1. [glossary.md](glossary.md) - the vocabulary (ustep, meta-cycle,
   dangling commitment, ...).
2. [dispute-game.md](dispute-game.md) - the implemented PRT tournament,
   clocks, recursive disputes, economics, and paper differences.
3. [epoch-lifecycle.md](epoch-lifecycle.md) - inputs, epochs, tournaments,
   settlement; the system end to end.
4. [computation-hash.md](computation-hash.md) - how commitments are built;
   the micro-architecture gymnastics. The most load-bearing document here.
5. [dimensioning.md](dimensioning.md) - the trust model and the
   worst-vs-average dimensioning rule; the reasoning behind every clock,
   span, and constant.
6. [node-architecture.md](node-architecture.md) - the Rust node's workers,
   SQLite boundary, dispute engine, and known-debts inventory.
7. [test-harness.md](test-harness.md) - the Lua e2e orchestration, the
   cross-implementation oracle, and coverage gaps.
8. [build-system.md](build-system.md) - setup/build pipeline and open
   design questions (bindings, emulator dependency).

Related, elsewhere in the repo:

- `prt/contracts/AGENTS.md` - deep context on the dispute contracts (the
  security-critical core).
- `prt/docs/prt.pdf`, `dave/docs/dave.pdf` - the papers. Beware: neither
  matches the implemented variant exactly; see
  [dispute-game.md](dispute-game.md#relationship-to-the-papers).

PRT contract engineering:

- [prt-refund-accounting.md](prt-refund-accounting.md) - the work-reserve,
  population, terminal-payment, and conservation argument.
- [prt-contract-testing.md](prt-contract-testing.md) - Foundry test ownership,
  geometry independence, oracle design, and coverage discipline.
- [plans/prt-client-interface.md](plans/prt-client-interface.md) - active
  typed-view, event-fold, domain-model, and planner campaign between the PRT
  contracts and clients.
- [plans/prt-client-interface-decisions.md](plans/prt-client-interface-decisions.md)
  - design reasoning, alternatives, parked event-stream proposals, and
  reopening conditions for the contract-client interface.
- [runbooks/prt-refund-gas-calibration.md](runbooks/prt-refund-gas-calibration.md)
  - the maintained procedure for measuring action allocations and tracing their
  effects into bonds and deployment artifacts.
- [plans/prt-timeout-alignment.md](plans/prt-timeout-alignment.md) - the open
  release gate for aligning Rust and Lua clients with the contract's
  phase-aware timeout policy.

Historical internal reviews live under [reviews/](reviews/README.md). They preserve
findings and evidence, but they are not current specifications or third-party
assurance reports. The completed 2026-07 PRT campaign is archived at
[reviews/2026-07-21-prt-dispute-game/](reviews/2026-07-21-prt-dispute-game/).

Plans: [plans/](plans/) contains dated design and implementation snapshots.
Read each status header before relying on it. Plans are intent and history, not
current knowledge; archive or delete them when the work completes.

Maintenance: when a change makes one of these files wrong, fixing the file
is part of the change. If a document keeps drifting, that is a sign its
content should move closer to the code (comments, asserts, or tests) or be
deleted.
