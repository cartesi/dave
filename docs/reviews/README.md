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
have a living owner, such as a plan, issue, runbook, or current design document.
Do not use a dated review directory as a hidden backlog.

## Reviews

- [`2026-07-21-prt-dispute-game/`](2026-07-21-prt-dispute-game/) - Solidity PRT
  dispute-game security, correctness, documentation, testing, and abstraction
  review.
- [`2026-07-23-prt-timeout-gas-calibration/`](2026-07-23-prt-timeout-gas-calibration/)
  - accepted follow-up gas calibration for the cumulative-censorship timeout
  fix and Match readability refactor.
- [`2026-07-23-prt-leaf-proof-gas-calibration/`](2026-07-23-prt-leaf-proof-gas-calibration/)
  - full-stack leaf-proof subsidy calibration through the production InputBox,
  DaveConsensus provider, state transition, and Tournament entry point.
