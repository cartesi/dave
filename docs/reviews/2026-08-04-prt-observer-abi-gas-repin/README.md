# PRT observer-ABI gas witness re-pin

Status: drafted 2026-08-04; the accepted clean-tree `just measure-prt-gas`
run is pending on the commit containing this record.

This record covers the gas effect of reconciling the six-view
`ITournamentObserver` ABI onto the merged contract review
([PR #273](https://github.com/cartesi/dave/pull/273)). It is historical
evidence, not the maintained procedure. Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

## Cause

Adding the six observer view functions to `Tournament` changes the deployed
bytecode. Function dispatch inside nested same-implementation clone calls and
optimizer layout shifts move two measured deltas across a 1,000-unit rounding
boundary. No production allocation, price cap, storage slot, event, or error
changed; the ABI delta over the merged review is exactly the six added views.

## Measured shifts and decisions

| Witness | Rounded recommendation | Allocation | Decision |
| --- | --- | --- | --- |
| `InnerTwoWinsGasTest` (Tournament matrix) | 334,000 -> 335,000 | `WIN_INNER_TOURNAMENT` = 336,000 | Retain allocation; recorded headroom 2,000 -> 1,000 |
| `MaximumInputLeafWinTwoFfiTest` (full stack) | 4,295,000 -> 4,296,000 | `WIN_LEAF_MATCH` = 4,296,000 | Retain allocation; now the exact selected maximum (headroom 1,000 -> 0) |
| `MaximumInputLeafWinOneFfiTest` (full stack) | 4,295,000 (unchanged) | `WIN_LEAF_MATCH` = 4,296,000 | Alternate orientation; recorded headroom 1,000 |

The `inner two wins` verbose measurement on the candidate tree: 306,019
allocation units, reviewed minimum 334,121, rounded recommendation 335,000.

Every other retained witness passed with its previously recorded relationship.
The allocation table in `Gas.sol`, the `Bond.sol` price caps, role terminal
maxima (4,401,000 leaf / 699,000 non-leaf), work reserves, and join bonds are
unchanged, so no deployment-parameter values move; deployment artifacts still
require regeneration because the bytecode changed.

## Validation on the candidate tree

- `just prt-contracts::test-disputes`: 266 passed, 0 failed (53 suites).
- `just prt-contracts::test-gas`: 18 passed, 0 failed.
- `just rollups-contracts::test-prt-leaf-gas`: 12 passed, 0 failed.
- `just rollups-contracts::test`: 4 passed, 0 failed.
- `just prt-contracts::compatibility-hashes`: semantic storage layout hash
  identical to the merged review; ABI and bytecode hashes changed as intended.
- `forge build --sizes`: Tournament runtime 16,724 bytes, 7,852 bytes of
  EIP-170 margin.

The environment was the repository nix devshell with the CI-pinned Forge
1.5.1. The authoritative `just measure-prt-gas` gate refuses a dirty worktree
by design; run it on the containing commit and update this status line.

## Second re-pin: legacy ABI retirement (same day)

The same branch then retired ten legacy external functions
(`arbitrationResult`, `canWinMatchByTimeout`, `getMatch`, `getMatchCycle`,
`getCommitment`, `tournamentLevelConstants`, `tournamentArguments`,
`isClosed`, `isFinished`, `timeFinished`) and indexed
`CommitmentJoined.commitment`. Storage layout is unchanged; runtime bytecode
shrank from 16,724 to 14,856 bytes (EIP-170 margin 9,720). The smaller
dispatcher cheapens every measured path, so rounded recommendations dropped
across the matrix and the witnesses now record interim retained headroom
against the UNCHANGED allocations: `ADVANCE_MATCH` 2,000; `SEAL_LEAF_MATCH`
1,000; `WIN_MATCH_BY_TIMEOUT` 1,000; inner sealing 11,000; `WIN_INNER_TOURNAMENT`
39,000 (the typed `innerResult` view replaced two cross-clone reads with one
on the propagation path); `ELIMINATE_INNER_TOURNAMENT` 7,000; both
maximum-input leaf-proof orientations 3,000.

These are deliberately NOT final selections. The branch defers the
calibration decision (likely lowering allocations toward the new
recommendations, which would propagate into bonds) to a single accepted
`just measure-prt-gas` run when the interface work settles. Until then the
witnesses pin the exact interim relationships so unintended gas drift stays
visible.

## Third re-pin: matchTimeoutStatus totality (2026-08-05)

The branch then removed the observer-side clock-shape asserts from
`matchTimeoutStatus` (the view now classifies stored clocks as they
are; shape invariants stay enforced on the transition paths), deleting
`_assertBisectionResponder` and the view-only `assertLeafRace`/
`assertInnerSeal` library helpers. ABI and storage layout are
unchanged; runtime bytecode shrank from 14,856 to 14,615 bytes, and
the optimizer ripple cheapened the seal path across a rounding
boundary: the seal-leaf rounded recommendation dropped from 104,000 to
103,000, so `SEAL_LEAF_MATCH`'s interim retained headroom moves from
1,000 to 2,000 against the unchanged allocation. All other witnesses
held their pinned relationships. The deferred `just measure-prt-gas`
acceptance run remains the single point where allocations get
re-selected.
