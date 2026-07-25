---
name: gas-calibration
description: Run or validate PRT refund-gas calibration. Use when changing Gas.sol allocations, Bond.sol formulas, anything that shifts measured action gas (contract logic on refunded paths), or when a gas witness test fails. Also when asked to "calibrate gas" or "measure gas".
---

# PRT refund-gas calibration

The maintained procedure is `docs/runbooks/prt-refund-gas-calibration.md`.
Read it before acting; this skill only routes and states the gate.

Non-negotiables:

- A gas-affecting change must follow the runbook even when the selected
  allocation remains unchanged. Never calibrate under coverage
  instrumentation.
- The accepted gate is `just measure-prt-gas` under the pinned release
  environment the runbook describes. It combines the PRT Tournament-only
  matrix with the serialized full-stack FFI leaf-proof matrix.
- Witness validation (fast, no re-measurement): `just test-prt-gas`.
- Trace any allocation change through `Bond.sol` into bonds and
  deployment artifacts; the runbook shows how.
- Accepted calibrations are archived as dated records under
  `docs/reviews/` (see the 2026-07-23 gas-calibration records for the
  expected shape of the evidence).

Use `just logged <file> <cmd...>` for the measurement runs so a display
pipeline cannot hide the real exit code.
