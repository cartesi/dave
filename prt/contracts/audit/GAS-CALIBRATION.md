# Refund gas calibration runbook

Status: seven dispute-game actions calibrated against retained witnesses and
reproduced with the release Foundry version; `winLeafMatch` blocked on its
supported state-transition proof and input envelope

Last reviewed: 2026-07-18

This is the reproducible procedure for measuring and changing the gas-unit
allocations in `tournament/libs/Gas.sol`. The procedure is deliberately manual:
the reviewer chooses the supported witnesses and checks the derived reserve.
The retained tests make the measurements and arithmetic executable.

This runbook covers successful dispute-game action refunds on Ethereum. It does
not select the Sybil principal, gas-price caps, validator incentives, or L2 fee
policy. Those are economic decisions in `REFUND-DESIGN.md`, not gas measurement
outputs.

## Sources of truth

| Concern | Source |
| --- | --- |
| Production action allocations | `src/tournament/libs/Gas.sol` |
| Principal, price policy, terminal maximum, and bond formula | `src/tournament/libs/Bond.sol` |
| Retained execution witnesses and measurement helper | `test/gas/TournamentGas.t.sol` |
| Reserve algebra and population properties | `test/accounting/RefundReserve.t.sol` |
| Compiler, optimizer, and EVM settings | `foundry.toml` |
| Solidity dependency revisions | `soldeer.lock` |
| Current derivation and accepted measurements | `audit/REFUND-DESIGN.md` |
| Finding and validation ledger | `audit/REVIEW.md` |

The gas tests observe the production `PartialBondRefund` event; they do not add
instrumentation to `Tournament`. At zero base fee and a transaction gas price of
one Wei, the event value in Wei is numerically equal to the allocation units
consumed by the successful call.

## What the number means

The `refundable` modifier snapshots `gasleft()` after dispatch, ABI decoding,
and lock acquisition. It emits the refund after the action body and remaining
modifier work. For one retained witness:

```text
delta = gas at the production snapshot - gas at the production postlude
measured allocation = Gas.TX + delta
margin = max(10,000, ceil(delta / 10))
reviewed minimum = measured allocation + margin
recommended allocation = roundUpTo1000(reviewed minimum)
```

`Gas.TX` is a fixed policy allowance for unmetered work. It is not measured
transaction-intrinsic gas. The refund excludes dynamic calldata cost, dispatch
and decoding before the snapshot, exact storage-refund reconciliation, and
chain-specific data fees. `complete call` in the report is diagnostic only; it
is not used to select an allocation.

Do not use `forge snapshot` as a substitute for this report. It measures the
test entry point, not the production refund seam. Do not measure under `forge
coverage`: coverage instrumentation changes execution gas. Every coverage
command must therefore exclude these gas tests.

## 1. Freeze and record the environment

Run from the repository root inside the repository development environment:

```bash
direnv exec . just prt-contracts::measure-gas
```

The report starts with:

- the Git revision and whether the worktree is dirty;
- the exact Forge version;
- the effective gas-relevant Foundry configuration;
- SHA-256 hashes of `foundry.toml`, `soldeer.lock`, and the installed dependency
  tree; and
- every recursive Git submodule revision.

The recipe forces a clean Solidity rebuild, runs witnesses on one thread for a
stable report order, and disables terminal color so the output can be retained
verbatim.

The contract configuration currently pins Solidity 0.8.30, optimized IR, and
200 optimizer runs for the Prague EVM. The gas recipe requires Foundry v1.4.3,
matching repository CI and the release container. Forge itself is supplied by
the environment rather than installed by the recipe.

This campaign also compared Forge 1.5.1-dev from an external parent development
environment. An intentional dirty, overridden, or unpinned comparison may
bypass the fail-fast checks with:

```bash
ALLOW_DIAGNOSTIC_GAS_MEASUREMENT=1 \
  direnv exec . just prt-contracts::measure-gas
```

Never use a diagnostic report to approve constants. Either reproduce with the
required clean release environment or deliberately align the recipe, CI,
release container, and development toolchain pins in a separate change.

For an accepted run, use a fresh checkout or CI job, reinstall Solidity
dependencies from `soldeer.lock`, and initialize the recorded submodules. The
recipe rejects a dirty worktree, `FOUNDRY_*` overrides, an unexpected effective
compiler configuration, and dependency drift. A diagnostic dirty measurement
is useful while developing a change, but the accepted table must be reproduced
on the exact candidate commit. Also record the operating system/architecture;
the report header captures the remaining inputs.

## 2. Define the supported envelope before measuring

An allocation is meaningful only relative to a finite set of supported
successful executions. Write that envelope in the calibration record before
choosing a ceiling:

1. Tournament roles and geometry used by each witness.
2. Every successful branch of the entry point that remains supported.
3. Storage conditions that can raise gas, including first writes, nonzero
   clears, winner orientation, dangling re-pairing, and nested calls.
4. Maximum Merkle proof lengths accepted by the deployment geometry.
5. For `winLeafMatch`, the state-transition proof classes, input representation,
   and maximum input/proof sizes being promised.
6. Production counters and callback behavior included in the deployed code.

The gas witnesses inject their required geometry. They must not import the
canonical deployment table merely for convenience. A canonical geometry change
does not invalidate a witness whose documented height remains the supported
maximum, but a larger supported height or proof does.

`prt/measure_constants/measure.lua` derives tournament timing and geometry from
slowdown and commitment-production assumptions. It does not measure EVM gas or
select refund allocations. Its output can change the supported proof lengths
and thereby trigger this runbook, but the two measurement processes must remain
separate.

Do not label an allocation a worst-case bound while a successful proof encoding
can grow outside the documented envelope. The current `winLeafMatch` literal is
intentionally not calibrated for this reason.

## 3. Retain the worst successful paths

The retained suite must cover at least the following shapes. More expensive
reachable shapes replace the selected maximum; cheaper alternate branches stay
as regression witnesses.

| Allocation | Required witness shapes |
| --- | --- |
| `ADVANCE_MATCH` | Charged right advance with the first counter and position writes; both bisection orientations when their storage behavior differs. |
| `WIN_MATCH_BY_TIMEOUT` | Active and sealed-leaf phases; side one and side two; nonzero old position; a dangling survivor that forces a new match. |
| `ELIMINATE_MATCH_BY_TIMEOUT` | Active and sealed-leaf phases; inclusive equality boundary; nonzero position; both timeout-classifier orderings. |
| `SEAL_LEAF_MATCH` | Charged seal at nonzero position with the maximum supported agree-state proof. |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | Charged seal at nonzero position with the maximum supported proof and a real factory clone. |
| `WIN_INNER_TOURNAMENT` | Both parent winner orientations; resolved and single-claim children; final legal carryover block; dangling parent re-pairing. |
| `ELIMINATE_INNER_TOURNAMENT` | Expired resolved winner, expired single-claim winner, and no-winner child; nonzero parent position. |
| `WIN_LEAF_MATCH` | Full production `Tournament.winLeafMatch`, not an isolated transition or stub; every supported state-transition and input proof class described below. |

The present two-level target witnesses use height 55 for the root and height 37
for the leaf. Historical top/middle/bottom suites do not define this envelope.

The current advance maximum is the first right descent: it performs the common
node and height writes plus a zero-to-nonzero `runningLeafPosition` write that a
first left descent omits. The retained left comparator confirms that the right
descent dominates under the current `Match.State` layout. The seal witnesses
retain nonzero positions and maximum-length agree proofs for both divergence
orientations. At both levels, the right divergence at position one dominates
the retained left divergence at position two.

## 4. Run and read the report

For the verbose report:

```bash
direnv exec . just prt-contracts::measure-gas
```

For a quiet pass/fail check of only the retained gas suite:

```bash
direnv exec . just prt-contracts::test-gas
```

Every witness prints four values:

```text
<label>: measured allocation
<label> reviewed minimum: measured allocation plus reviewed margin
<label> rounded recommendation: reviewed minimum rounded to 1,000 gas
<label> complete call: diagnostic outer-call gas
```

The tests also enforce the following:

- every successful action emits exactly one refund event;
- the event is not balance-capped or allocation-capped by the fixture;
- every retained branch preserves the full reviewed margin under its shared
  action allocation; and
- the selected maximum for each calibrated action equals the rounded
  recommendation exactly.

If a change makes a formerly cheaper branch the maximum, move the exact
calibration assertion to that witness. Do not delete the old branch merely
because it is no longer largest.

## 5. Change the allocations

For each action family, apply this checklist in one reviewable commit:

1. Collect the rounded recommendation for every retained witness.
2. Select their maximum as the shared entry-point allocation.
3. Update only the corresponding constant in `Gas.sol`.
4. Make the selected witness assert exact equality and all alternates assert
   that the full reviewed margin still fits.
5. Run the report again on the candidate commit.
6. Recompute `Bond.terminalAllocation()` over every legal terminal sequence.
7. Recompute the work reserve and join deposit for every supported height.
8. Update the measurement and derived-value tables in `REFUND-DESIGN.md` and
   the validation ledger in `REVIEW.md`.

Never change these values merely because a gas witness changed:

- `Bond.SYBIL_PRINCIPAL`;
- `Bond.WORK_PRICE_CAP`;
- `Bond.PRIORITY_FEE_CAP`; or
- `Bond.PAYMENT_CALLBACK_GAS_LIMIT`.

They are policy parameters and require their own rationale and commit.

## 6. Trace every propagated effect

A local allocation edit can change substantially more than one refund cap:

```text
Gas action allocation
    -> action refund cap
    -> legal terminal-path totals
    -> Bond.terminalAllocation maximum
    -> per-height match work reserve
    -> per-height join deposit
    -> clone runtime/creation bytecode and deployment addresses
```

`ADVANCE_MATCH` changes every height-dependent reserve directly. A terminal
action changes every reserve only if its legal sequence becomes the new common
terminal maximum. Because the current design uses one common maximum, an
expensive leaf path can raise non-leaf deposits as well.

The explicit Sybil principal must remain unchanged during this propagation.
External selectors, events, tuple shapes, and storage should also remain
unchanged for a constants-only calibration, but runtime and creation bytecode
will change. Regenerate deployment artifacts and CREATE2 addresses before a
deployment. Do not quietly reuse artifacts produced from an older allocation.

## 7. Validate the candidate

Run at least:

```bash
direnv exec . just prt-contracts::check-fmt
direnv exec . just prt-contracts::test-gas
direnv exec . just prt-contracts::test-disputes
direnv exec . just rollups-contracts::test
git diff --check
```

Before and after a contract change, record:

```bash
direnv exec . sh -c \
  'cd prt/contracts && forge inspect --json Tournament abi | jq -S . | sha256sum'
direnv exec . sh -c \
  'cd prt/contracts && forge inspect --json Tournament storageLayout \
    | jq -S -f audit/storage-layout-semantic.jq | sha256sum'
direnv exec . sh -c \
  'cd prt/contracts && forge inspect --no-metadata Tournament bytecode | sha256sum'
direnv exec . sh -c \
  'cd prt/contracts && forge inspect --no-metadata Tournament deployedBytecode | sha256sum'
```

The hashes are comparison aids, not substitutes for inspecting an unexpected
diff. A test-only or documentation-only calibration change should not alter
production bytecode. A constants change should alter bytecode even when ABI and
storage remain identical.

Do not touch the off-chain node as part of a gas-calibration commit. If a proof
format or geometry change requires coordinated off-chain work, record that gate
and land it in its own branch and review sequence.

## 8. Record the accepted calibration

The committed record must include:

- candidate revision and clean/dirty state;
- Forge version and configuration/lockfile hashes;
- Solidity, optimizer, EVM, and dependency versions;
- supported geometry and proof/input envelope;
- every retained measurement, margin, and selected allocation;
- the old and new terminal maximum;
- work reserves and join deposits at every supported height;
- confirmation that economic policy constants did or did not change;
- focused, full, and downstream test results;
- ABI and storage comparison; and
- deployment-artifact regeneration status.

Use the current table in `REFUND-DESIGN.md` for accepted measurements and the
chronological validation section in `REVIEW.md` for the command results. Do not
replace an old result without leaving enough history to explain why the value
changed.

## Recalibration triggers

Repeat the complete procedure after any change to:

- `Tournament`, `Match`, `MatchClocks`, `Clock`, `Gas`, `Bond`, or a nested
  contract called by a refundable action;
- compiler, optimizer, EVM revision, Forge, or a Solidity dependency;
- production event counters, payment callback, refund modifier, or lock;
- supported tournament geometry or Merkle proof length;
- state-transition implementation or accepted proof encoding;
- data-provider or InputBox input representation and maximum size; or
- the set of successful branches considered supported.

A small source diff is not an exemption. Re-run the report and retain unchanged
numbers as evidence when the trigger does not affect the selected maximum.

## `winLeafMatch` and the InputBox decision

`winLeafMatch` is the remaining uncalibrated action. Its witness must call the
complete tournament entry point with the deployed `CartesiStateTransition` and
data provider. Measuring `transitionState` alone establishes useful component
costs but omits Tournament resolution, clock settlement, re-pairing, deletion,
refund postlude, and nested-call coldness.

The resulting envelope applies only to the canonical deployment using the
reviewed `CartesiStateTransition` and `DaveConsensus`/InputBox provider. The
generic tournament factory accepts arbitrary transition and provider contracts;
those deployments receive only the configured bounded subsidy and must define
and calibrate their own envelope. No common gas constant can promise exact
coverage for arbitrary external implementations.

The current input-boundary path is:

1. `InputBox.addInput` stores `keccak256(encodedInput)` and emits the input.
2. A dispute proof carries that encoded input again.
3. `CartesiStateTransition` extracts it and calls the epoch data provider.
4. `DaveConsensus.provideMerkleRootOfInput` hashes it, compares the stored hash,
   and builds its Merkle root.
5. The state transition sends that root and length into the machine proof.

The current InputBox caps the complete encoded input at `1 << 16` bytes. The
dynamic calldata needed to resubmit it is outside the refund snapshot, while
the provider call, hashing, Merkleization, and state-transition work are inside.
The calibration record must distinguish those two costs.

Before selecting `WIN_LEAF_MATCH`, retain full-entry-point witnesses for at
least:

- an ordinary uarch step;
- the reset/revert boundary;
- an in-range input boundary with small, representative, and maximum supported
  encoded inputs;
- the out-of-range input fixpoint path; and
- every halt/exception outcome that the state-transition workstream defines as
  supported.

For every applicable proof class, retain both winner orientations and the
material Tournament states: no timeout, a compatible single-winner timeout
charge, nonzero match state deletion, and dangling re-pairing. An isolated
state-transition maximum is not necessarily the Tournament maximum.

The state-transition workstream must also define whether trailing or otherwise
noncanonical proof bytes are rejected. Until the accepted proof/input envelope
is finite and documented, `WIN_LEAF_MATCH` must remain explicitly uncalibrated.

There is a concrete unbounded successful encoding today. At an input boundary
whose index lies outside the sealed epoch, `DaveConsensus` returns zero before
hashing or validating the supplied input. A proof can therefore declare an
arbitrarily large input segment, place valid access logs after it, and still
reach the successful fixpoint path, subject only to transaction/block limits.
Canonical encoding or an on-chain input-length/proof-consumption bound is needed
before an allocation can be described as a finite worst-case success bound.

A future pre-Merkleized InputBox would move input hashing and Merkleization to
input submission and let the dispute consume the commitment without
resubmitting the input. That commitment must authenticate both the Merkle root
and the logical input length: CMIO consumes the length, and zero padding can
otherwise make equal roots represent inputs with different logical lengths. If
that design is brought into scope:

1. measure its InputBox submission cost separately;
2. replace, rather than mix, the current input-boundary witnesses;
3. rerun every full `winLeafMatch` witness;
4. recompute the configured common terminal allocation and every join deposit;
5. record exact calldata length, zero/nonzero byte composition, and intrinsic
   calldata gas even though calldata is not subsidized by the current refund
   formula.

Pre-Merkleization also shifts cost in time and frequency: the new hashing and
tree work is paid for every submitted input, while the current on-chain
Merkleization is paid only when a dispute reaches that input boundary. Compare
aggregate application input cost as well as the worst dispute transaction.

The decision should compare the maximum successful leaf-proof gas, Ethereum
blockspace and calldata burden, the resulting common work reserve and honest
capital requirement, and the already-measured InputBox submission increase.
That makes bringing the InputBox change into scope an explicit protocol tradeoff
rather than an undocumented reaction to one gas number.

The current configured common terminal allocation is 701,000 gas and
`SEAL_LEAF_MATCH` is 107,000 gas. Therefore any `WIN_LEAF_MATCH` allocation above
594,000 gas makes leaf seal plus proof the new configured maximum and raises
every level's work reserve. Existing input-boundary state-transition measurements
already exceed that threshold before Tournament overhead and reviewed margin.
Under the current InputBox path, a production calibration will therefore raise
all join deposits; the remaining questions are by how much and whether the
pre-Merkleized design is worth that avoided cost.
