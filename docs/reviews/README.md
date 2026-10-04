# Internal engineering reviews

This directory contains completed, dated review records. They preserve findings,
alternatives, evidence, measurements, and validation history that would be lost
if only the final code remained.

These records are:

- historical evidence, not current specifications;
- internal engineering work, not third-party audits or assurance reports; and
- frozen at completion, except for clearly dated provenance corrections or
  errata.

Current behavior belongs in the living documents indexed by
[`docs/README.md`](../README.md). Unfinished work from a completed review must
have a line in [`docs/todo.md`](../todo.md) or an owner in a current design
document or runbook. Do not use a dated review directory as a hidden backlog.

Records cite pull requests and commit subjects, not this repository's commit
hashes: it merges by rebase, which rewrites every hash. For an exact measured
state, give the tree hash (`git rev-parse <commit>^{tree}`), which a rebase
onto an unchanged main keeps. Older records keep the hashes they were written
with, and some of those name nothing on main.

## Reviews

- [`2026-07-09-e2e-suite-economics/`](2026-07-09-e2e-suite-economics/) - e2e
  suite measurements and incident case studies, moved verbatim from
  docs/test-harness.md; the living summary stays there.
- [`2026-07-21-prt-dispute-game/`](2026-07-21-prt-dispute-game/) - Solidity PRT
  dispute-game security, correctness, documentation, testing, and abstraction
  review.
- [`2026-07-23-prt-timeout-gas-calibration/`](2026-07-23-prt-timeout-gas-calibration/)
  - accepted follow-up gas calibration for the cumulative-censorship timeout
  fix and Match readability refactor.
- [`2026-07-23-prt-leaf-proof-gas-calibration/`](2026-07-23-prt-leaf-proof-gas-calibration/)
  - full-stack leaf-proof subsidy calibration through the production InputBox,
  DaveConsensus provider, state transition, and Tournament entry point.
- [`2026-07-26-prt-post-refactor-gas-calibration/`](2026-07-26-prt-post-refactor-gas-calibration/)
  - accepted post-refactor calibration and reproducible dependency provenance
    for the retained Tournament and full-stack leaf witnesses.
- [`2026-08-01-prt-role-specific-bond-calibration/`](2026-08-01-prt-role-specific-bond-calibration/)
  - accepted role-specific leaf and non-leaf terminal maxima, work reserves,
    and join bonds.
- [`2026-08-11-prt-v021-stf-gas-calibration/`](2026-08-11-prt-v021-stf-gas-calibration/)
  - accepted Cartesi Machine v0.21 state-transition calibration, proof-growth
    evidence, propagated leaf reserves, and regenerated deployment identities.
- [`2026-08-16-prt-v021-post-274-gas-calibration/`](2026-08-16-prt-v021-post-274-gas-calibration/)
  - accepted post-#274 v0.21 recalibration, stable production allocations, and
    final-candidate compatibility and admission evidence.
- [`2026-08-17-prt-stf-composition-gas-calibration/`](2026-08-17-prt-stf-composition-gas-calibration/)
  - accepted explicit state-transition recalibration, retained allocations,
    and current deployment and admission impact.
- [`2026-08-27-prt-leaf-gas-recalibration/`](2026-08-27-prt-leaf-gas-recalibration/)
  - accepted `WIN_LEAF_MATCH` recalibration after the machine-yield check and
    the alpha-9 rollups-contracts bump, with the re-pinned leaf-gate
    dependency digest.
- [`2026-09-29-prt-clock-refill/REVIEW.md`](2026-09-29-prt-clock-refill/REVIEW.md)
  - child-return refill and terminal-win discount review, accepted inclusion
    handover limitation, STF evidence-gate finding, and remaining assurance work.
- [`2026-10-02-prt-calldata-refund-calibration/`](2026-10-02-prt-calldata-refund-calibration/)
  - calldata counted in refunded units, every allocation remeasured, one-sided
    witnesses, and the re-pinned alpha-10 leaf-gate dependency digest.
