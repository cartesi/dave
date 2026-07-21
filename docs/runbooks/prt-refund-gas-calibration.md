# PRT refund gas calibration

This runbook defines the maintained procedure for measuring and changing the
gas-unit allocations in `prt/contracts/src/tournament/libs/Gas.sol`. The
procedure is deliberately manual: a reviewer defines the supported execution
envelope, retains the expensive reachable witnesses, and checks every
propagated accounting and deployment effect.

It covers successful dispute-game action subsidies on Ethereum. It does not
choose gas-price caps, validator incentives, or L2 fee policy. Those are
economic decisions described in
[`prt-refund-accounting.md`](../prt-refund-accounting.md). Join bonds derive
automatically from the reviewed gas table and the separately selected
work-price cap.

Historical measurements and accepted release evidence from the 2026-07 review
remain in the
[`GAS-CALIBRATION.md`](../reviews/2026-07-21-prt-dispute-game/GAS-CALIBRATION.md)
archive.

## Sources of truth

Paths in this table are relative to `prt/contracts`.

| Concern | Source |
| --- | --- |
| Production action allocations | `src/tournament/libs/Gas.sol` |
| Price policy, terminal maximum, and bond formula | `src/tournament/libs/Bond.sol` |
| Retained execution witnesses | `test/gas/TournamentGas.t.sol` |
| Reserve algebra and population properties | `test/accounting/RefundReserve.t.sol` |
| Exact refund formula and cap boundaries | `test/accounting/RefundFormula.t.sol` |
| Callback and per-clone lock behavior | `test/accounting/RefundCallbacks.t.sol` |
| Compiler, optimizer, and EVM settings | `foundry.toml` |
| Solidity dependency revisions | `soldeer.lock` |

The gas tests observe the production `PartialBondRefund` event; they do not add
instrumentation to `Tournament`. Formula and callback tests establish payment
semantics separately and are not substitutes for production gas witnesses.

## What is measured

The `refundable` modifier snapshots `gasleft()` after dispatch, ABI decoding,
and lock acquisition, then samples it again before refund calculation and the
recipient callback. For one witness:

```text
delta = gasBefore - gasAfter
measuredAllocation = Gas.TX + delta
margin = max(10,000, ceil(delta / 10))
reviewedMinimum = measuredAllocation + margin
recommendation = roundUpTo1000(reviewedMinimum)
```

The production refund request is:

```text
units = Gas.TX + delta
effectivePrice = min(tx.gasprice, block.basefee + PRIORITY_FEE_CAP)
requestedRefund = min(
    tournament balance before the callback,
    allocation * WORK_PRICE_CAP,
    units * effectivePrice
)
```

`Gas.TX` is a fixed policy allowance for work outside the snapshots. It is not
measured transaction-intrinsic gas. The measurement excludes dispatch and
decoding before the snapshot, dynamic calldata cost, exact storage-refund
reconciliation, and chain-specific fees. Proof forwarding, copying, memory
expansion, nested proof work, events, and production counter writes after the
snapshot remain in the measured delta.

Recipient behavior occurs after `gasAfter` and cannot change the request.
Complete-call gas printed by a witness is diagnostic only.

Do not replace this report with `forge snapshot`: that measures the test entry
point rather than the production refund seam. Do not measure under `forge
coverage`: instrumentation changes the quantity being calibrated and can make
the production cap bind before the event exposes the uncapped units.

## 1. Freeze the environment

Run from a clean repository root inside the repository development environment:

```bash
direnv exec . just prt-contracts::measure-gas
```

The recipe owns the required Forge release and gas-relevant Foundry settings.
It records:

- the Git revision and clean state;
- the exact Forge version;
- effective Solidity, optimizer, IR, and EVM settings;
- hashes of `foundry.toml`, `soldeer.lock`, and installed dependencies; and
- recursive submodule revisions.

Also record the operating system and architecture. Use a fresh checkout or CI
job for an accepted run and restore dependencies from the lockfile.

For exploratory work only:

```bash
ALLOW_DIAGNOSTIC_GAS_MEASUREMENT=1 \
  direnv exec . just prt-contracts::measure-gas
```

Never approve constants from a diagnostic report. Reproduce the result on the
exact clean candidate with the required release environment, or align the
repository, CI, and release toolchain pins in a separate reviewed change.

## 2. Define the supported envelope

Before choosing a ceiling, record:

1. tournament roles and maximum supported geometry for each witness;
2. every successful branch of the entry point that remains supported;
3. expensive storage states, including first writes, nonzero clears, winner
   orientation, dangling re-pairing, and nested calls;
4. maximum Merkle proof lengths;
5. state-transition and input proof classes, representations, and size bounds;
   and
6. production counters and callback behavior included in deployed code.

Gas witnesses inject the geometry they require. They must not import canonical
deployment constants merely for convenience. A geometry change matters when it
increases a supported proof or path, not merely because a default table changed.

Tournament timing and commitment-production measurement are separate from EVM
gas calibration. The former can change the supported proof envelope and trigger
this runbook, but it does not select a gas allocation.

Do not describe an allocation as a worst-case bound while accepted successful
inputs or proofs can grow outside the declared envelope. A bounded heuristic
subsidy is allowed, but its reference path and limitations must be explicit.

## 3. Retain expensive successful paths

The retained suite must cover at least:

| Allocation | Required witness shapes |
| --- | --- |
| `ADVANCE_MATCH` | Charged right advance with first counter and position writes; alternate orientation retained |
| `WIN_MATCH_BY_TIMEOUT` | Active and sealed-leaf phases; both winners; nonzero position; dangling re-pairing |
| `ELIMINATE_MATCH_BY_TIMEOUT` | Active and sealed-leaf phases; equality boundary; nonzero position; both classifier orderings |
| `SEAL_LEAF_MATCH` | Charged nonzero-position seal with the maximum supported agree-state proof |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | Charged nonzero-position seal with maximum proof and real child clone |
| `WIN_INNER_TOURNAMENT` | Both parent winners; resolved and single-claim children; final legal carryover block; dangling re-pairing |
| `ELIMINATE_INNER_TOURNAMENT` | Expired resolved winner, expired single claimant, and no-winner child |
| `WIN_LEAF_MATCH`, if claiming a proof-class ceiling | Full Tournament entry point for every supported transition and input class |

When a more expensive reachable shape appears, it becomes the selected maximum.
Keep cheaper alternate branches as regressions when their storage or control
flow differs.

## 4. Run and interpret

```bash
direnv exec . just prt-contracts::measure-gas
direnv exec . just prt-contracts::test-gas
```

The verbose report prints the measured allocation, reviewed minimum, rounded
recommendation, and diagnostic complete-call gas. The retained tests must prove:

- one refund event per successful action;
- fixtures whose balance and action caps do not hide measured work;
- the complete reviewed margin for every retained branch; and
- exact equality between the selected maximum and its rounded recommendation.

## 5. Change an allocation

For one action family:

1. take the maximum rounded recommendation over retained witnesses;
2. update only the corresponding `Gas.sol` constant;
3. make the selected witness assert exact equality and alternates retain their
   full margin;
4. rerun the report on the candidate;
5. recompute every legal terminal sequence;
6. recompute work reserves and join bonds for supported heights; and
7. record the accepted environment, measurements, derived values, tests, and
   deployment-artifact status.

Do not change `WORK_PRICE_CAP`, `PRIORITY_FEE_CAP`, or
`PAYMENT_CALLBACK_GAS_LIMIT` merely because a witness changed. They are policy
parameters and require independent rationale.

## 6. Trace propagation

```text
action allocation
    -> action refund cap
    -> legal terminal sequence totals
    -> common terminal maximum
    -> height-dependent match reserve
    -> join bond
    -> creation/runtime bytecode and deployment addresses
```

`ADVANCE_MATCH` changes every positive-height reserve directly. A terminal
allocation changes every reserve only when its sequence changes the maximum.
Adding a new action or legal sequence is structural: enumerate it in production
and in the independent accounting tests.

There is no separately maintained bond value. A constants-only change should
preserve ABI and storage but changes bytecode. Regenerate and review deployment
artifacts and every CREATE2-derived address before release.

## 7. Validate compatibility and behavior

Run at least:

```bash
direnv exec . just prt-contracts::check-fmt
direnv exec . just prt-contracts::test-gas
direnv exec . just prt-contracts::test-disputes
direnv exec . just rollups-contracts::test
direnv exec . just prt-contracts::compatibility-hashes
git diff --check
```

The compatibility report covers ABI, semantic storage layout, and metadata-free
creation and runtime bytecode. Hashes are comparison aids, not substitutes for
inspecting an unexpected diff.

Do not modify the off-chain node in a gas-calibration commit. A proof-format or
geometry change that requires client coordination belongs in its own review
sequence.

## 8. Record an accepted calibration

Record:

- candidate revision and clean state;
- toolchain, compiler settings, lockfile, dependencies, submodules, OS, and
  architecture;
- supported geometry and proof/input envelope;
- every retained measurement, margin, and selected allocation;
- old and new terminal maximum;
- work reserves and join bonds at supported heights;
- whether economic policy constants changed;
- focused, dispute, and downstream test results;
- exact refund-formula and callback results;
- ABI and storage comparison; and
- deployment-artifact regeneration status.

Create a new dated review or calibration record. Do not rewrite an older
accepted result to make history appear continuous.

## Recalibration triggers

Repeat the complete procedure after changes to:

- `Tournament`, `Match`, `MatchClocks`, `Clock`, `Gas`, `Bond`, or nested calls
  made by a refundable action;
- compiler, optimizer, EVM revision, Forge, or Solidity dependencies;
- production counters, callbacks, locks, or the refund modifier;
- supported geometry or Merkle proof lengths;
- state-transition implementation or accepted proof encoding;
- data-provider or InputBox representation and maximum size; or
- the set of supported successful branches.

A small diff is not an exemption. An unchanged recommendation is still a result
that must be reproduced and recorded.

## Leaf proofs and InputBox changes

`WIN_LEAF_MATCH` may be configured as a provisional ordinary-proof subsidy
rather than a finite proof-class ceiling. This is compatible with the refund's
role as a bounded aid to altruistic validation; it must be documented honestly.

Before claiming a comprehensive ceiling, retain full-entry-point witnesses for:

- an ordinary uarch step;
- reset and revert boundaries;
- in-range input boundaries at small, representative, and maximum supported
  sizes;
- the out-of-range input fixpoint; and
- every supported halt and exception outcome.

Cover both winner orientations and material Tournament states: no timeout,
compatible timeout charging, nonzero Match deletion, and dangling re-pairing.
An isolated transition maximum is not necessarily the Tournament maximum.

The reviewed implementation permits successful proof encodings with trailing
bytes because buffer consumption is not required to end exactly at the proof
boundary. The out-of-range input path can also return zero before validating
the supplied input segment. Verify these properties against current code before
making a finite bound claim; canonical proof consumption or explicit size
bounds may be prerequisites.

The current InputBox path stores a hash, then resubmits the encoded input during
a dispute so the provider can authenticate and Merkleize it before the state
transition consumes its root and logical length. A pre-Merkleized InputBox would
move that work to input submission and remove it from the dispute path. Its
commitment must authenticate both the Merkle root and logical input length;
zero padding can otherwise give different logical inputs the same root.

If pre-Merkleization enters scope:

1. measure submission cost separately;
2. replace the old input-boundary witnesses rather than mixing representations;
3. rerun every full `winLeafMatch` witness;
4. recompute terminal allocations, reserves, and bonds;
5. record calldata length, byte composition, and intrinsic calldata cost even
   though the current refund formula excludes it; and
6. compare aggregate cost paid for every input with the rare-dispute saving.

That makes the InputBox change an explicit protocol tradeoff rather than an
undocumented response to one gas measurement.
