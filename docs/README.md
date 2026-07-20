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
2. [epoch-lifecycle.md](epoch-lifecycle.md) - inputs, epochs, tournaments,
   settlement; the system end to end.
3. [computation-hash.md](computation-hash.md) - how commitments are built;
   the micro-architecture gymnastics. The most load-bearing document here.
4. [dimensioning.md](dimensioning.md) - the trust model and the
   worst-vs-average dimensioning rule; the reasoning behind every clock,
   span, and constant.
5. [node-architecture.md](node-architecture.md) - the prototype node:
   threads, SQLite, and its known-debts inventory (the rewrite worklist).
6. [test-harness.md](test-harness.md) - the Lua e2e orchestration, the
   cross-implementation oracle, and coverage gaps.
7. [build-system.md](build-system.md) - setup/build pipeline and open
   design questions (bindings, emulator dependency).

Related, elsewhere in the repo:

- `prt/contracts/AGENTS.md` - deep context on the dispute contracts (the
  security-critical core).
- `prt/docs/prt.pdf`, `dave/docs/dave.pdf` - the papers. Beware: neither
  matches the implemented variant exactly; see the variant notes in
  `prt/contracts/AGENTS.md`.

Plans: [plans/](plans/) holds working documents for in-flight efforts
(currently [plans/characterization.md](plans/characterization.md),
[plans/sling-design.md](plans/sling-design.md) for the dispute core,
and [plans/node-refactor.md](plans/node-refactor.md) for the
whole-node simplification campaign above it). They are snapshots of
intent, not knowledge; archive or delete them when the work completes.

Maintenance: when a change makes one of these files wrong, fixing the file
is part of the change. If a document keeps drifting, that is a sign its
content should move closer to the code (comments, asserts, or tests) or be
deleted.
