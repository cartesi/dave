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

- [prt-delay-bound.md](prt-delay-bound.md) - the derivation record behind
  dispute-game.md's delay-bound invariants: potential-function bound,
  adversarial traces, finite-state model, multi-level attack shapes.
- [prt-refund-accounting.md](prt-refund-accounting.md) - the work-reserve,
  population, terminal-payment, and conservation argument.
- [prt-contract-testing.md](prt-contract-testing.md) - Foundry test ownership,
  geometry independence, oracle design, and coverage discipline.
- [plans/prt-client-interface.md](plans/prt-client-interface.md) - the
  implemented Campaign 1 record for the typed views, event fold, domain models,
  planners, disposable live-tail reader, and transaction lane.
- [plans/prt-client-interface-decisions.md](plans/prt-client-interface-decisions.md)
  - the frozen Campaign 1 decision record: reasoning, alternatives, parked
  event-stream proposals, reopening conditions, and one retained fail-closed
  empirical watch.
- [plans/recursive-dispute-reader.md](plans/recursive-dispute-reader.md) - the
  implemented follow-up for a recursively owned dispute, event-derived match
  cleanup, bounded point reads, one solid boundary, and disposable latest
  quantum foam.
- [runbooks/prt-refund-gas-calibration.md](runbooks/prt-refund-gas-calibration.md)
  - the maintained procedure for measuring action allocations and tracing their
  effects into bonds and deployment artifacts.
- [plans/prt-timeout-alignment.md](plans/prt-timeout-alignment.md) - the
  completed cross-implementation record for the phase-aware timeout policy and
  exact sealed-leaf boundary evidence.

Historical internal reviews live under [reviews/](reviews/README.md). They preserve
findings and evidence, but they are not current specifications or third-party
assurance reports. The completed 2026-07 PRT campaign is archived at
[reviews/2026-07-21-prt-dispute-game/](reviews/2026-07-21-prt-dispute-game/).

Plans: [plans/](plans/) contains dated design and implementation snapshots.
Read each status header before relying on one. Plans are intent and history,
not current knowledge. By status:

- Active records: [plans/stf-upgrade.md](plans/stf-upgrade.md), the draft plan
  for the emulator bump and the state-transition halt/exception gap. The frozen
  prt-client-interface decision log retains one non-reproduced same-head
  contradiction as a fail-closed empirical watch.
- Recorded for a later node campaign:
  [plans/self-healing-batch-submission.md](plans/self-healing-batch-submission.md) -
  the batch-nonce transaction lane and its reasoning - and
  [plans/bond-recovery-redesign.md](plans/bond-recovery-redesign.md), whose
  contract side is implemented and whose node-side recovery action rides
  that campaign.
- Implemented, with closeout provenance retained:
  [plans/prt-client-interface.md](plans/prt-client-interface.md) and
  [plans/recursive-dispute-reader.md](plans/recursive-dispute-reader.md).
- Complete: [plans/prt-timeout-alignment.md](plans/prt-timeout-alignment.md).
- Seed material, no work order: [plans/simplification.md](plans/simplification.md),
  [plans/resource-model.md](plans/resource-model.md), and
  [plans/node-audit.md](plans/node-audit.md) (Round 1 complete; re-run
  triggers noted inline).
- Completed and frozen: [plans/characterization.md](plans/characterization.md),
  [plans/sling-design.md](plans/sling-design.md),
  [plans/node-refactor.md](plans/node-refactor.md),
  [plans/one-engine.md](plans/one-engine.md), and
  [plans/snapshots.md](plans/snapshots.md) - the node-rewrite corpus. These
  stay in place because code comments and living docs cite their sections as
  design provenance; each header names its living successor. Only dated
  errata may touch them. When nothing cites a frozen plan any longer,
  delete it - git history is the archive.

Measurements: generated baselines live in [measurements/](measurements/) -
`measurements.md` and `measurements-stress.md` (`just measure`,
`just measure-stress --full`) and `constants.md` (`just measure-constants`).
Regenerate on the machine that matters and commit the diff; each file
carries its own caveats and density labels.

Maintenance: when a change makes one of these files wrong, fixing the file
is part of the change. If a document keeps drifting, that is a sign its
content should move closer to the code (comments, asserts, or tests) or be
deleted.
