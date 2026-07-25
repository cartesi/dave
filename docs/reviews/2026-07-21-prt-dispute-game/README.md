# PRT dispute-game internal review

Status: completed 2026-07-21; frozen historical record

This directory preserves the internal engineering review of the Solidity PRT
dispute game conducted from 2026-06-10 through 2026-07-21. It is not the current
protocol specification, a third-party audit, or an assurance report.

The code is the source of truth. Current protocol behavior and assumptions live
in [`dispute-game.md`](../../dispute-game.md), while timing and geometry policy
live in [`dimensioning.md`](../../dimensioning.md). This archive preserves the
findings, alternatives, implementation reasoning, measurements, and validation
evidence that explain how the reviewed code reached its current shape.

## Contents

Read in this order:

1. [`REVIEW.md`](REVIEW.md) - confirmed findings, decisions, deferred work, the
   chronological validation ledger, and clearly dated later errata.
2. [`TEST-REPORT.md`](TEST-REPORT.md) - the campaign test assessment, exact
   verification snapshot, limitations, and stop rule.
3. [`CLOCK-DESIGN.md`](CLOCK-DESIGN.md),
   [`MATCH-DESIGN.md`](MATCH-DESIGN.md), and
   [`REFUND-DESIGN.md`](REFUND-DESIGN.md) - compatibility fences and detailed
   implementation reasoning for the principal changes.
4. [`GAS-CALIBRATION.md`](GAS-CALIBRATION.md) - the accepted campaign-era
   calibration procedure and measurement context. The maintained procedure is
   [`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md).
5. [`MAP.md`](MAP.md) - the machine-generated audit-start source map and lead
   inventory. Its unannotated claims are leads, not established facts.

The final Solidity and test tree identified by the review is
`ac3bea0c5057702e5778b3ea00086bfc31cc68ea`. The clean release-calibration
candidate is `7565ec29797388a0108a267ba0b4676d09b63837`. The review ledger records
the exact toolchain, hashes, commands, and results.

## Living owners

Archive status must not hide unfinished work. The living owners are:

- implemented tournament behavior: [`dispute-game.md`](../../dispute-game.md);
- allowance, response-budget, delay, and geometry policy:
  [`dimensioning.md`](../../dimensioning.md);
- refund reserve and bond reasoning:
  [`prt-refund-accounting.md`](../../prt-refund-accounting.md);
- gas allocation measurement and update procedure:
  [`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md);
- Solidity test architecture and test-writing rules:
  [`prt-contract-testing.md`](../../prt-contract-testing.md);
- selected two-level integration work: [`constants.md`](../../measurements/constants.md)
  (moved from plans/ on 2026-07-25);
- state-transition halt and exception semantics: the separate state-transition
  workstream, outside this review's scope.

## Archive policy

Do not update these files to track later implementation changes. Correct the
living documentation with the production change instead. If this archive is
factually misquoted or its provenance is wrong, append a clearly dated erratum
rather than rewriting the historical conclusion silently.
