# PRT post-refactor gas calibration

Status: accepted 2026-07-26

This record captures the gas calibration required after the Clock, Match, and
MatchClocks readability refactor. It is historical evidence, not the maintained
procedure. Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The accepted candidate is
`2adcd3c2266563e073dc7febed08cad3cc41aab1`. Its clean, release-pinned run
passed every retained witness.

## Environment and provenance

The clean run used macOS 26.5.2 (Darwin 25.5.0) on arm64:

```text
Forge: 1.5.1-v1.5.1
Forge commit: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
release archive sha256: b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d
forge binary sha256: 051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c
effective config: {"solc":"0.8.30","via_ir":true,"optimizer":true,"optimizer_runs":200,"evm_version":"prague"}
PRT foundry.toml sha256: 52cbcb59a04926e546a2498ad27383b6f3670dcd6de4c1e051b118190d87acf6
PRT soldeer.lock sha256: fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53
PRT dependencies sha256: ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3
Rollups foundry.toml sha256: 72045392f8f79346c596dc946f3326e6c779c6941bf8c51ecace733645375658
Rollups soldeer.lock sha256: 28a76c49c9129aa07f257246a9a62a0b28fc996606f976dccc07ae748385daac
combined leaf dependencies sha256: bf5c94f033883d49e851fe57111f5031bfbbc1969c6027aedc6ac607815d4234
yield machine hash: d83e7921ab07b55e7e57217bd0f3427faea7474bf81b15866d8d4c1f873c51e0
Lua: 5.4.7
Cartesi Machine: 0.20.0
Cartesi Lua module sha256: f6ac06dce6325b7a14bd4f0aebcb09a1cdc3cc2495fb82fdeb4ee5a9d350c60b
```

The recursive submodules were:

```text
machine/emulator: 8bfca6912f4849e03b7b55677e17e385c0b2dfbe
machine/emulator/third-party/riscv-arch-test: 8f92acd11aa5d59005505ec7a48569c75e128167
machine/emulator/third-party/riscv-tests: a64ad67b8235c681cd244b087ced36c4d5df3cb9
machine/emulator/third-party/riscv-tests/env: d3931fa7c5d3fd9725351dc2fe26f578eb782335
machine/step: 3f5d163df0f7564fef3345fc919252a371e5fb9f
machine/step/lib/forge-std: 1714bee72e286e73f76e320d110e0eaf5c4e649d
```

The first clean attempt passed all 18 Tournament witnesses, then failed closed
before the leaf run because its dependency digest included Soldeer nested Git
metadata and generated build output. Those files are not compiler inputs and
differ across equivalent locked restores. The leaf runner now excludes nested
`.git`, `broadcast`, `cache`, `deployments`, and `out` paths and pins the
resulting reproducible dependency-content digest
`bf5c94f033883d49e851fe57111f5031bfbbc1969c6027aedc6ac607815d4234`.
The complete clean run prepended the verified release binary inside the
repository environment:

```bash
direnv exec . bash -lc \
  'export PATH=/absolute/path/to/foundry-v1.5.1/bin:$PATH; just measure-prt-gas'
```

## Supported envelope

The Tournament-only matrix uses the selected two-level geometry: root stride
37 and height 55, followed by leaf stride 0 and height 37. It retains both
bisection orientations, expensive storage writes, active and sealed-leaf
timeouts, maximum agree-state proofs, real child creation, both child winners,
single-claim and no-winner children, and dangling re-pairing.

The full-stack leaf matrix runs the production Tournament, provider, InputBox,
and Cartesi state transition. It retains ordinary, reset, revert, out-of-range,
small-input, representative-input, and maximum canonical-input paths, including
both expensive winner orientations where applicable. `WIN_LEAF_MATCH` remains
a provisional canonical-path subsidy, not a bound over every valid proof or
state-transition outcome.

## Tournament-only measurements

`Measured` is the allocation-unit request. `Margin` is
`max(10,000, ceil(delta / 10))`; `Reviewed` is measured plus margin. `Rounded`
rounds the reviewed value upward to 1,000 units. `Complete` is diagnostic.

| Witness | Measured | Margin | Reviewed | Rounded | Configured | Complete |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Active advanced timeout elimination | 123,920 | 10,000 | 133,920 | 134,000 | 135,000 | 117,370 |
| Active side one timeout win | 238,247 | 21,325 | 259,572 | 260,000 | 260,000 | 231,935 |
| Active side two timeout win | 238,369 | 21,337 | 259,706 | 260,000 | 260,000 | 232,057 |
| First charged right advance | 114,406 | 10,000 | 124,406 | 125,000 | 125,000 | 108,099 |
| First charged left advance | 92,191 | 10,000 | 102,191 | 103,000 | 125,000 | 85,884 |
| Expired resolved inner winner | 157,944 | 13,295 | 171,239 | 172,000 | 172,000 | 151,099 |
| No-winner inner child | 153,005 | 12,801 | 165,806 | 166,000 | 172,000 | 146,160 |
| Inner side one wins | 307,520 | 28,252 | 335,772 | 336,000 | 336,000 | 300,839 |
| Expired single inner claim | 157,929 | 13,293 | 171,222 | 172,000 | 172,000 | 151,084 |
| Single inner claim wins side two | 307,650 | 28,265 | 335,915 | 336,000 | 336,000 | 300,969 |
| Inner side two wins | 307,695 | 28,270 | 335,965 | 336,000 | 336,000 | 301,009 |
| Position-one inner seal | 331,271 | 30,628 | 361,899 | 362,000 | 363,000 | 325,113 |
| Position-two left inner seal | 316,891 | 29,190 | 346,081 | 347,000 | 363,000 | 310,733 |
| Position-one leaf seal | 94,687 | 10,000 | 104,687 | 105,000 | 105,000 | 88,504 |
| Position-two left leaf seal | 80,307 | 10,000 | 90,307 | 91,000 | 105,000 | 74,124 |
| Sealed-leaf long-deadline elimination | 123,487 | 10,000 | 133,487 | 134,000 | 135,000 | 116,951 |
| Sealed-leaf side one timeout win | 238,431 | 21,344 | 259,775 | 260,000 | 260,000 | 232,134 |
| Sealed-leaf side two timeout win | 238,553 | 21,356 | 259,909 | 260,000 | 260,000 | 232,256 |

## Full-stack leaf measurements

`Input` is the authenticated input segment within the proof. The Prague
transaction estimate includes the whole-call diagnostic and the calldata floor;
it is not the configured refund allocation.

| Witness | Proof bytes | Input | Measured | Margin | Reviewed | Rounded | Complete | Prague tx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Maximum input, side one wins | 88,204 | 65,508 | 3,907,303 | 388,231 | 4,295,534 | 4,296,000 | 3,932,250 | 5,359,690 |
| Maximum input, side two wins | 88,204 | 65,508 | 3,907,412 | 388,242 | 4,295,654 | 4,296,000 | 3,932,359 | 5,359,799 |
| Ordinary step, side one wins | 13,440 | 0 | 766,017 | 74,102 | 840,119 | 841,000 | 762,377 | 998,037 |
| Ordinary step, side two wins | 13,440 | 0 | 766,126 | 74,113 | 840,239 | 841,000 | 762,486 | 998,146 |
| Out-of-range input, side one wins | 13,448 | 0 | 774,155 | 74,916 | 849,071 | 850,000 | 770,522 | 1,006,190 |
| Representative input, side one wins | 27,180 | 4,388 | 1,516,227 | 149,123 | 1,665,350 | 1,666,000 | 1,516,245 | 1,967,289 |
| Reset, side one wins | 9,056 | 0 | 557,608 | 53,261 | 610,869 | 611,000 | 552,954 | 719,478 |
| Reset, side two wins | 9,056 | 0 | 557,717 | 53,272 | 610,989 | 611,000 | 553,063 | 719,587 |
| Revert, side one wins | 11,008 | 0 | 616,672 | 59,168 | 675,840 | 676,000 | 612,465 | 810,101 |
| Revert, side two wins | 11,008 | 0 | 616,781 | 59,179 | 675,960 | 676,000 | 612,569 | 810,205 |
| Small input, side one wins | 23,212 | 292 | 1,357,758 | 133,276 | 1,491,034 | 1,492,000 | 1,356,647 | 1,744,179 |
| Small input, side two wins | 23,212 | 292 | 1,357,867 | 133,287 | 1,491,154 | 1,492,000 | 1,356,756 | 1,744,288 |

The maximum proof hash is
`0x6210d2e816377a74375263123a4dc77fd3081b95cddff22720c65c758b8a1f0a`.
The 5,359,799-unit maximum Prague estimate leaves 11,417,417 units below
Ethereum's dated 16,777,216-unit transaction cap. It occupies 31.95% of that
cap and 8.93% of the dated 60,000,000-unit block limit.

## Allocation decision

| Allocation | Selected measured | Reviewed | Rounded | Configured | Retained extra |
| --- | ---: | ---: | ---: | ---: | ---: |
| `ADVANCE_MATCH` | 114,406 | 124,406 | 125,000 | 125,000 | 0 |
| `WIN_MATCH_BY_TIMEOUT` | 238,553 | 259,909 | 260,000 | 260,000 | 0 |
| `ELIMINATE_MATCH_BY_TIMEOUT` | 123,920 | 133,920 | 134,000 | 135,000 | 1,000 |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | 331,271 | 361,899 | 362,000 | 363,000 | 1,000 |
| `WIN_INNER_TOURNAMENT` | 307,695 | 335,965 | 336,000 | 336,000 | 0 |
| `ELIMINATE_INNER_TOURNAMENT` | 157,944 | 171,239 | 172,000 | 172,000 | 0 |
| `SEAL_LEAF_MATCH` | 94,687 | 104,687 | 105,000 | 105,000 | 0 |
| `WIN_LEAF_MATCH` | 3,907,412 | 4,295,654 | 4,296,000 | 4,296,000 | 0 |

The refactor moved the advance recommendation up one rounding bucket and the
inner-seal recommendation down one bucket. The existing 125,000-unit advance
allocation now equals its rounded recommendation. The existing 363,000-unit
inner-seal allocation retains 1,000 units rather than creating production and
deployment churn for a small downward shift. The selected witnesses assert
both relationships exactly.

`Gas.sol`, `Bond.sol`, `WORK_PRICE_CAP`, `REFUND_PRIORITY_FEE_CAP`, and the
payment callback limit remain unchanged. Raising `ADVANCE_MATCH` to preserve an
additional rounding bucket would increase every height-above-one work reserve
without a new supported path or security benefit. Lowering the inner-seal
allocation would be an unneeded gas optimization. The reviewed decision is to
leave the production gas table unchanged.

## Derived accounting

The legal terminal allocations remain:

| Terminal sequence | Allocation |
| --- | ---: |
| Direct timeout win | 260,000 |
| Direct timeout elimination | 135,000 |
| Sealed-leaf proof win | 4,401,000 |
| Sealed-leaf timeout win | 365,000 |
| Sealed-leaf timeout elimination | 240,000 |
| Inner-tournament win | 699,000 |
| Inner-tournament elimination | 535,000 |

The common terminal maximum, work reserves, and bonds remain:

| Height | Work reserve | Bond at 50 gwei |
| ---: | ---: | ---: |
| 1 | 4,401,000 | 0.22005 ETH |
| 17 | 6,401,000 | 0.32005 ETH |
| 27 | 7,651,000 | 0.38255 ETH |
| 37 | 8,901,000 | 0.44505 ETH |
| 48 | 10,276,000 | 0.5138 ETH |
| 55 | 11,151,000 | 0.55755 ETH |

## Validation and compatibility

The current evidence is:

```text
Tournament-only retained gas witnesses: 18/18
full-stack leaf retained gas witnesses: 12/12
total retained gas witnesses: 30/30
PRT dispute suites: 52 suites, 235 tests passed
Rollups contract suites: 1 suite, 4 tests passed
PRT scoped coverage: 98.43% lines, 98.47% statements, 49.31% branches, 100% functions
PRT and Rollups forge fmt checks: clean
git diff --check: clean
```

Tournament compatibility hashes are:

```text
ABI: 67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a
semantic storage: 952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
creation bytecode without metadata: a409ed085110bfc68ff7a3cd7f35a6a437d0a7787ae34e59db52113b8d542fc2
runtime bytecode without metadata: 1b662d92148081c106a358b789d991bd5909a3b3141160f6332a8057c6a30162
```

ABI and semantic storage remain unchanged. The earlier contract refactor
changed production bytecode, but the calibration assertion and dependency
provenance changes do not. Deployment artifacts and CREATE2-derived addresses
have not been regenerated in this calibration and remain a release task.
