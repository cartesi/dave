# PRT contracts - agent guidance

This directory is the security-critical Solidity boundary for Permissionless
Refereed Tournaments. It selects the canonical computation result and enforces
the clocks, accounting, and recursive dispute rules that make participation
possible.

These instructions extend the root `AGENTS.md`. The code is the source of
truth. Treat comments, papers, dated plans, and review records as context to
verify, never as evidence that a mechanism is correct.

## Read before editing

Choose the narrowest relevant living document:

| Work | Required context |
| --- | --- |
| Any dispute-game behavior | [`docs/dispute-game.md`](../../docs/dispute-game.md) |
| Clocks, timeouts, allowances, geometry, or level constants | [`docs/dimensioning.md`](../../docs/dimensioning.md) |
| Bonds, refunds, terminal payments, or burns | [`docs/prt-refund-accounting.md`](../../docs/prt-refund-accounting.md) |
| Gas allocation changes | [`docs/runbooks/prt-refund-gas-calibration.md`](../../docs/runbooks/prt-refund-gas-calibration.md) |
| Foundry tests or fixtures | [`docs/prt-contract-testing.md`](../../docs/prt-contract-testing.md) |
| Commitment coordinates or machine spans | [`docs/computation-hash.md`](../../docs/computation-hash.md) |
| Historical findings or refactor rationale | [`docs/reviews/2026-07-21-prt-dispute-game/`](../../docs/reviews/2026-07-21-prt-dispute-game/) |

The PRT and Dave papers are background, not specifications for these contracts.

## Trust boundary and assumptions

Distinguish the property affected by a change:

- Result-selection safety assumes at least one correct commitment joins, its
  participant can act within the clock and censorship bounds, and the
  configured hashes, provider, and state transition are correct. The
  censorship budget is global and non-rechargeable across the modeled dispute,
  not fresh per action or match.
- Liveness depends on clock conservation, legal progress, cleanup, chain-time
  semantics, and the participant not being censored past its allowance.
- Resource resistance depends on population reduction, work reserves, bounded
  refunds, and callback isolation. A posted bond is not by itself a proof of a
  delay or cost bound.

Ethereum is the supported timing and fee environment. Other registered chains
remain experimental until their `block.number`, fee, and upgrade assumptions
are validated.

Instruction semantics are owned by `machine/step`. The Solidity adapters and
their composition with `Tournament` remain in this directory; changes across
that seam require the Solidity, machine, and client implementations to agree.

## Source map

- `src/tournament/Tournament.sol` composes joins, pairing, bisection, sealing,
  recursive children, proofs, timeouts, refunds, and recovery.
- `src/tournament/libs/Match.sol` owns Match existence, phase, bisection, and
  sealed-divergence encoding.
- `src/tournament/libs/Clock.sol` owns one-clock arithmetic and storage
  transitions.
- `src/tournament/libs/MatchClocks.sol` owns legal two-clock transitions,
  response discounts, phase-aware timeout classification, and deferred charges.
- `src/tournament/libs/Gas.sol` contains reviewed action allocations.
- `src/tournament/libs/Bond.sol` derives refund caps, terminal work, and join
  bonds from those allocations and fee policy.
- `src/tournament/factories/MultiLevelTournamentFactory.sol` creates root and
  inner ERC-1167 clones.
- `src/arbitration-config/` owns the checked-in canonical parameter table and
  provider.
- `src/state-transition/` adapts leaf proof verification.
- `src/ITournament.sol` and provider/factory interfaces define external
  compatibility surfaces.
- `script/Deployment.s.sol` converts deployment policy into chain-specific
  parameters.

Every tournament level uses the same `Tournament` implementation. Root versus
inner and leaf versus non-leaf behavior derive from clone arguments and the
configured level count; there are no production Top/Middle/Bottom contracts.

## Invariants to protect

- Match existence comes from initialized mapped state, not from a hash sentinel.
  Uninitialized and deleted matches must fail before phase-specific decoding.
- Match phase is derived from the existing representation. Do not add storage or
  reshape the raw external tuple without an explicit compatibility change.
- Active bisection has exactly one running clock. A sealed leaf has two clocks
  running from one instant. A sealed inner match has two paused clocks while its
  linked child resolves.
- Pairing and survivor re-entry never increase clock balances. Each successful
  advance or final seal applies the response discount exactly once and cannot
  revive an expired clock.
- One shared timeout classification drives the capability view and both
  timeout mutations. Leaf proofs are valid only while that classification is
  `NONE`; once a timeout begins, callers must use the selected timeout verb.
- A running timeout winner receives no extra overdue charge because its live
  remainder already reflects elapsed time. A paused winner may receive a
  deferred charge to subtract for the expired responder's overdue interval.
  Never charge one censorship interval twice.
- A parent consumes only a child it recorded from its own sealed match.
  Permissionless orphan child creation does not establish parent legitimacy.
- Objective proof correctness does not erase a missed deadline. A leaf proof
  and timeout cleanup must never be simultaneously valid.
- Each paid join contributes one height-derived match work reserve. Progress
  refunds are bounded subsidies; terminal recovery pays at most one bond and
  burns the residual only after successful payment.
- Refund and winner callbacks are bounded, copy no return data, and cannot make
  completed progress depend on recipient acceptance. A failed terminal payment
  preserves the full state for retry.

The checked-in canonical table remains the historical three-level geometry.
The selected two-level table is integration-gated and must not be enabled here
without coordinated node, Lua, deployment, and conformance work.

## Change guardrails

- Preserve the deployed ABI, storage layout, clone arguments, raw Match and
  Clock tuples, event signatures, and error selectors unless the task explicitly
  authorizes a compatibility break.
- Use braces for every Solidity control-flow body, including a single
  statement.
- Run `just prt-contracts::compatibility-hashes` before and after production
  changes and inspect every unexpected difference. Hashes are comparison aids,
  not approval to update a snapshot mechanically.
- A Clock change needs one-clock arithmetic tests, the full MatchClocks shape
  and orientation matrix, and public Tournament composition.
- A Match change needs raw compatibility tests, an independent sparse-tree or
  parity oracle, malformed-input tests, and public lifecycle composition.
- Behavioral tests must inject the geometry they require. Production constants
  belong only in conformance tests.
- A gas-affecting change must follow the calibration runbook even when the
  selected allocation remains unchanged. Never calibrate under coverage.
- Geometry changes must validate the complete table and coordinate every
  commitment producer and consumer. Do not hide a production switch in a test
  fixture or deployment-only commit.
- Time-source or chain-registration changes must state the exact EVM coordinate
  and fee assumptions. An average interval is a deployment assumption, not a
  protocol guarantee.
- State-transition changes must retain cross-implementation proof vectors and
  define halt, exception, reset, and padding behavior before contracts rely on
  them.
- Production bytecode changes require regenerated deployment artifacts and
  CREATE2-derived addresses before release.

## Build and test

Run from the repository root unless a focused command says otherwise:

```bash
just prt-contracts::check-fmt
just prt-contracts::test-disputes
just prt-contracts::test-gas
just prt-contracts::coverage
just rollups-contracts::test
```

State-transition tests require the `machine/step` submodule and FFI:

```bash
just prt-contracts::test-stf
just prt-contracts::test-stf-fuzzy
```

Use `just prt-contracts::test-all` for the combined contract gate. Use
`just logged <file> <command...>` for long runs so a display pipeline cannot
hide the real exit code.

The ordinary fuzz count is pinned in `foundry.toml`. Record seeds and overrides
for deeper campaigns. Coverage excludes suites whose semantics or measured gas
would be changed by instrumentation; its optimized-IR branch map is
investigative, not a correctness claim.

## Explicit non-claims

Do not claim more than the maintained evidence establishes:

- there is no general recursive adversarial-arrival liveness proof;
- selected two-level geometry is not enabled by these contracts alone;
- non-Ethereum time and fee conformance is not established;
- state-transition halt and exception semantics are owned by separate work;
- the leaf-proof refund is not a universal proof-class gas ceiling; and
- archived review findings and test counts describe their recorded revision,
  not every future change.
