# PRT timeout gas calibration

Status: accepted 2026-07-23

This record captures the gas recalibration required by the cumulative-censorship
timeout fix and the subsequent Match readability refactor. It is historical
evidence, not the maintained calibration procedure. Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The accepted candidate is
`1aea024dd10372001a637d39a05f4bbd55aa5436`. The worktree was clean. The
retained matrix passed without changing any production gas, fee, refund, or bond
constant.

## Environment

The run used macOS 26.5.2 on Darwin 25.5.0 arm64.

```text
Forge: 1.5.1-v1.5.1
Forge commit: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
release archive sha256: b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d
forge binary sha256: 051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c
effective config: {"solc":"0.8.30","via_ir":true,"optimizer":true,"optimizer_runs":200,"evm_version":"prague"}
foundry.toml sha256: 52cbcb59a04926e546a2498ad27383b6f3670dcd6de4c1e051b118190d87acf6
soldeer.lock sha256: fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53
dependency digest: ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3
machine/emulator: 8bfca6912f4849e03b7b55677e17e385c0b2dfbe
machine/emulator/third-party/riscv-arch-test: 8f92acd11aa5d59005505ec7a48569c75e128167
machine/emulator/third-party/riscv-tests: a64ad67b8235c681cd244b087ced36c4d5df3cb9
machine/emulator/third-party/riscv-tests/env: d3931fa7c5d3fd9725351dc2fe26f578eb782335
machine/step: 3f5d163df0f7564fef3345fc919252a371e5fb9f
machine/step/lib/forge-std: 1714bee72e286e73f76e320d110e0eaf5c4e649d
```

The repository development shell exposed Forge `1.5.1-dev`, which the
authoritative recipe rejected. The accepted run used a fresh detached worktree
at the candidate revision. Every recursive submodule was initialized, and
`just prt-contracts::install-deps` restored Solidity dependencies from
`soldeer.lock`. The worktree was clean after setup.

The official Darwin arm64 v1.5.1 release archive was downloaded to a temporary
directory, both hashes above were verified, and its `bin` directory was placed
first on `PATH` after entering the `direnv` environment. No `FOUNDRY_*`
override was present. The fresh-worktree measurements reproduced the earlier
clean development-worktree measurements exactly.

## Supported witness envelope

The retained suite injects the selected two-level geometry: root stride 37 and
height 55, followed by leaf stride 0 and height 37. This keeps the gas evidence
independent from the checked-in historical three-level defaults while covering
the larger selected root height.

The matrix retains:

- both bisection orientations and first counter and position writes;
- active and sealed-leaf timeout phases, both winners, both elimination
  boundaries, and dangling re-pairing;
- maximum-height agree-state proofs for leaf and inner seals;
- a real child clone, resolved and single-claim children, both parent winners,
  and all inner-elimination shapes; and
- production refund accounting and counter writes inside the measured seam.

The gas state transition is intentionally a stub. `Gas.WIN_LEAF_MATCH` remains a
provisional subsidy for the previously selected ordinary proof, not a
comprehensive ceiling over state-transition outcomes, proof encodings, or input
sizes. This run neither remeasures nor strengthens that claim.

## Measurements

`Measured` is the emitted allocation-unit request. `Margin` is the explicit
review allowance, and `Reviewed` is their sum. `Rounded` is the reviewed value
rounded up to the next 1,000 units. `Complete call` is diagnostic and is not
used to select an allocation.

| Witness | Allocation | Measured | Margin | Reviewed | Rounded | Configured | Complete call |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Active advanced timeout elimination | `ELIMINATE_MATCH_BY_TIMEOUT` | 123,678 | 10,000 | 133,678 | 134,000 | 135,000 | 117,097 |
| Active side one timeout win | `WIN_MATCH_BY_TIMEOUT` | 237,482 | 21,249 | 258,731 | 259,000 | 260,000 | 231,140 |
| Active side two timeout win | `WIN_MATCH_BY_TIMEOUT` | 237,607 | 21,261 | 258,868 | 259,000 | 260,000 | 231,265 |
| First charged right advance | `ADVANCE_MATCH` | 113,939 | 10,000 | 123,939 | 124,000 | 125,000 | 107,602 |
| First charged left advance | `ADVANCE_MATCH` | 91,735 | 10,000 | 101,735 | 102,000 | 125,000 | 85,398 |
| Expired resolved inner winner | `ELIMINATE_INNER_TOURNAMENT` | 157,947 | 13,295 | 171,242 | 172,000 | 172,000 | 151,072 |
| No-winner inner child | `ELIMINATE_INNER_TOURNAMENT` | 153,008 | 12,801 | 165,809 | 166,000 | 172,000 | 146,133 |
| Inner side one wins | `WIN_INNER_TOURNAMENT` | 306,796 | 28,180 | 334,976 | 335,000 | 336,000 | 300,084 |
| Expired single inner claim | `ELIMINATE_INNER_TOURNAMENT` | 157,932 | 13,294 | 171,226 | 172,000 | 172,000 | 151,057 |
| Single inner claim wins side two | `WIN_INNER_TOURNAMENT` | 306,926 | 28,193 | 335,119 | 336,000 | 336,000 | 300,214 |
| Inner side two wins | `WIN_INNER_TOURNAMENT` | 306,971 | 28,198 | 335,169 | 336,000 | 336,000 | 300,254 |
| Position-one inner seal | `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | 331,417 | 30,642 | 362,059 | 363,000 | 363,000 | 325,229 |
| Position-two left inner seal | `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | 311,349 | 28,635 | 339,984 | 340,000 | 363,000 | 305,161 |
| Position-one leaf seal | `SEAL_LEAF_MATCH` | 94,797 | 10,000 | 104,797 | 105,000 | 105,000 | 88,583 |
| Position-two left leaf seal | `SEAL_LEAF_MATCH` | 74,729 | 10,000 | 84,729 | 85,000 | 105,000 | 68,515 |
| Sealed-leaf long-deadline elimination | `ELIMINATE_MATCH_BY_TIMEOUT` | 123,409 | 10,000 | 133,409 | 134,000 | 135,000 | 116,843 |
| Sealed-leaf side one timeout win | `WIN_MATCH_BY_TIMEOUT` | 237,668 | 21,267 | 258,935 | 259,000 | 260,000 | 231,341 |
| Sealed-leaf side two timeout win | `WIN_MATCH_BY_TIMEOUT` | 237,793 | 21,280 | 259,073 | 260,000 | 260,000 | 231,466 |

## Allocation decision

Five measured families still select their configured allocation exactly. The
fresh rounded recommendations for `ADVANCE_MATCH` and
`ELIMINATE_MATCH_BY_TIMEOUT` are each 1,000 units below the existing
allocation:

| Allocation | Rounded maximum | Configured | Retained headroom |
| --- | ---: | ---: | ---: |
| `ADVANCE_MATCH` | 124,000 | 125,000 | 1,000 |
| `ELIMINATE_MATCH_BY_TIMEOUT` | 134,000 | 135,000 | 1,000 |

Both existing values were retained. A one-bucket downward adjustment would
change Tournament bytecode, deployment addresses, every work reserve and bond
above height one through `ADVANCE_MATCH`, and the corresponding terminal payment
amounts, without improving a security property. The selected witnesses now
assert exactly the rounded maximum plus the recorded 1,000-unit headroom, so
a change in the rounded recommendation fails visibly.

No `Gas.sol`, `Bond.sol`, `WORK_PRICE_CAP`, `PRIORITY_FEE_CAP`, or payment
callback value changed.

## Derived accounting

The legal terminal allocations remain:

| Terminal sequence | Allocation |
| --- | ---: |
| Direct timeout win | 260,000 |
| Direct timeout elimination | 135,000 |
| Sealed-leaf proof win | 948,000 |
| Sealed-leaf timeout win | 365,000 |
| Sealed-leaf timeout elimination | 240,000 |
| Inner-tournament win | 699,000 |
| Inner-tournament elimination | 535,000 |

The common terminal maximum remains 948,000 units. The current work reserves
and bonds therefore remain:

| Height | Work reserve | Bond at 50 gwei |
| ---: | ---: | ---: |
| 1 | 948,000 | 0.0474 ETH |
| 17 | 2,948,000 | 0.1474 ETH |
| 27 | 4,198,000 | 0.2099 ETH |
| 37 | 5,448,000 | 0.2724 ETH |
| 48 | 6,823,000 | 0.34115 ETH |
| 55 | 7,698,000 | 0.3849 ETH |

Heights 17, 27, and 48 characterize the checked-in historical table. Heights
37 and 55 characterize the selected two-level table. Height 1 records the
terminal-only boundary.

## Validation and compatibility

The release-pinned candidate passed:

- retained gas witnesses: 18/18;
- PRT dispute tests: 229/229 across 52 suites, including the 3 refund-formula
  and 11 refund-callback tests;
- downstream Rollups contract tests: 4/4;
- `just prt-contracts::check-fmt`; and
- `git diff --check`.

Current Tournament compatibility hashes are:

```text
ABI: 67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a
semantic storage: 952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
creation bytecode without metadata: 4d03edb91eab5f546c3419594bb8f5657886d2502df96bcf1af6737e067d386d
runtime bytecode without metadata: d6aada33d49b29ce88a970d262e5eeb816580a769950a5ad85df0a0b1d0f7ddd
```

ABI and semantic storage remain unchanged from the pre-fix contract. Production
bytecode changed in the earlier timeout and Match commits, not in the witness
or calibration-selection commits. Deployment artifacts and derived CREATE2
addresses were not regenerated in this pass; they must be regenerated from the
final rebased production tree before release.

The Rust and Lua timeout strategies and end-to-end timeout scenarios remain
owned by [`prt-timeout-alignment.md`](../../plans/prt-timeout-alignment.md).
