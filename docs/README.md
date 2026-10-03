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
8. [build-system.md](build-system.md) - setup/build pipeline, the open
   bindings question, and the resolved emulator-provider policy.

Related, elsewhere in the repo:

- `prt/contracts/AGENTS.md` - deep context on the dispute contracts (the
  security-critical core).
- The [original PRT paper](papers/prt.pdf) and [Dave paper](papers/dave.pdf).
  Beware: neither matches the implemented variant exactly; see
  [dispute-game.md](dispute-game.md#relationship-to-the-papers).

PRT contract engineering:

- [prt-delay-bound.md](prt-delay-bound.md) - the derivation record behind
  dispute-game.md's delay-bound invariants: potential-function bound,
  adversarial traces, finite-state model, multi-level attack shapes.
- [prt-refund-accounting.md](prt-refund-accounting.md) - the work-reserve,
  population, terminal-payment, and conservation argument.
- [prt-contract-testing.md](prt-contract-testing.md) - Foundry test ownership,
  geometry independence, oracle design, and coverage discipline.
- [runbooks/prt-refund-gas-calibration.md](runbooks/prt-refund-gas-calibration.md)
  - the maintained procedure for measuring action allocations and tracing their
  effects into bonds and deployment artifacts.

Historical internal reviews live under [reviews/](reviews/README.md). They preserve
findings and evidence, but they are not current specifications or third-party
assurance reports. The completed 2026-07 PRT campaign is archived at
[reviews/2026-07-21-prt-dispute-game/](reviews/2026-07-21-prt-dispute-game/).

To-do: [todo.md](todo.md) is the one live list of agreed work; each item
names the living doc that owns its reasoning, and a done item is deleted. A
campaign too large for a few lines may open a plan under [plans/](plans/),
linked from todo.md; when it ends, its lasting invariants move into the living
docs and the plan is deleted. Git and pull-request history preserve the
exploration. The five earlier campaign plans still under plans/
(`stf-upgrade`, `two-level-sling`, `collect-hashes-migration`,
`test-strategy-reset`, `tooling-footguns`) are already folded into the living
docs and todo.md; they stay only until the code comments that cite them are
re-pointed, so do not add to them.

Measurements: generated baselines live in [measurements/](measurements/) -
`measurements.md` and `measurements-stress.md` (`just measure`,
`just measure-stress --full`), `constants.md` (`just measure-constants`),
`two-level-leaf.md` (`just measure-two-level-leaf`), and
`node-vs-emulator.md` (`just measure-node-vs-emulator`, the runbook check
that the node adds no overhead over the emulator).
Regenerate on the machine that matters and commit the diff; each file
carries its own caveats and density labels.

Maintenance: when a change makes one of these files wrong, fixing the file
is part of the change. If a document keeps drifting, that is a sign its
content should move closer to the code (comments, asserts, or tests) or be
deleted.
