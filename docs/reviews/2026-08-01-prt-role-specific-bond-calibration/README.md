# PRT role-specific bond calibration

Status: accepted 2026-08-01

This record adopts separate terminal work maxima for leaf and non-leaf
tournaments. It is historical evidence, not the maintained procedure. Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The accepted candidate is the commit containing this record. Its clean,
release-pinned run passed all 30 retained gas witnesses. The production action
allocations and price caps did not change.

## Decision

The old formula used the largest terminal sequence from either tournament role
for every clone. The maximum leaf-proof sequence was therefore charged to
non-leaf tournaments even though their role guards make that sequence
unreachable.

`Bond.terminalAllocation(isLeafTournament)` now selects only terminal families
legal for that role. Direct timeout paths remain available to both roles. Leaf
seal and proof paths contribute only to a leaf reserve; inner seal and child
propagation paths contribute only to a non-leaf reserve. The accounting model
enumerates these role boundaries independently, and actual root and child
clones are checked against the pure formula.

This remains a work reserve, not an independent Sybil principal. The change
reduces only capital that could not fund a legal non-leaf action.

## Environment and provenance

The accepted run used macOS 26.5.2 (Darwin 25.5.0) on arm64:

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

The release archive and Forge binary matched the hashes retained by the prior
accepted calibration. The report was run with the release directory prepended
inside `direnv exec`.

## Supported envelope

The supported Tournament-only and full-stack leaf envelopes are unchanged from
the 2026-07-26 calibration. The selected two-level geometry has a height-55
non-leaf root and height-37 leaf child. The full-stack leaf matrix retains the
production provider, InputBox, Cartesi state transition, and maximum canonical
input proof.

`WIN_LEAF_MATCH` remains a provisional reference-path subsidy, not a bound over
every valid proof or state-transition outcome. This decision changes only which
already-calibrated terminal families contribute to each role's join reserve.

## Tournament-only measurements

`Measured` is the allocation-unit request. `Reviewed` includes the retained
margin, `Rounded` is the recommendation, and `Complete` is diagnostic.

| Witness | Measured | Reviewed | Rounded | Configured | Complete |
| --- | ---: | ---: | ---: | ---: | ---: |
| Active advanced timeout elimination | 123,893 | 133,893 | 134,000 | 135,000 | 116,585 |
| Active side one timeout win | 237,996 | 259,296 | 260,000 | 260,000 | 230,924 |
| Active side two timeout win | 238,132 | 259,446 | 260,000 | 260,000 | 231,060 |
| First charged right advance | 114,135 | 124,135 | 125,000 | 125,000 | 107,073 |
| First charged left advance | 91,920 | 101,920 | 102,000 | 125,000 | 84,858 |
| Expired resolved inner winner | 157,239 | 170,463 | 171,000 | 172,000 | 149,631 |
| No-winner inner child | 152,299 | 165,029 | 166,000 | 172,000 | 144,691 |
| Inner side one wins | 305,636 | 333,700 | 334,000 | 336,000 | 298,190 |
| Expired single inner claim | 157,224 | 170,447 | 171,000 | 172,000 | 149,616 |
| Single inner claim wins side two | 305,820 | 333,902 | 334,000 | 336,000 | 298,374 |
| Inner side two wins | 305,865 | 333,952 | 334,000 | 336,000 | 298,414 |
| Position-one inner seal | 324,209 | 354,130 | 355,000 | 363,000 | 317,295 |
| Position-two left inner seal | 309,829 | 338,312 | 339,000 | 363,000 | 302,915 |
| Position-one leaf seal | 94,404 | 104,404 | 105,000 | 105,000 | 87,454 |
| Position-two left leaf seal | 80,024 | 90,024 | 91,000 | 105,000 | 73,074 |
| Sealed-leaf long-deadline elimination | 123,465 | 133,465 | 134,000 | 135,000 | 116,172 |
| Sealed-leaf side one timeout win | 238,171 | 259,489 | 260,000 | 260,000 | 231,114 |
| Sealed-leaf side two timeout win | 238,307 | 259,638 | 260,000 | 260,000 | 231,250 |

## Full-stack leaf measurements

| Witness | Proof bytes | Input | Measured | Reviewed | Rounded | Complete | Prague tx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Maximum input, side one wins | 88,204 | 65,508 | 3,906,715 | 4,294,887 | 4,295,000 | 3,930,917 | 5,358,357 |
| Maximum input, side two wins | 88,204 | 65,508 | 3,906,804 | 4,294,985 | 4,295,000 | 3,931,006 | 5,358,446 |
| Ordinary step, side one wins | 13,440 | 0 | 765,530 | 839,583 | 840,000 | 761,145 | 996,805 |
| Ordinary step, side two wins | 13,440 | 0 | 765,619 | 839,681 | 840,000 | 761,234 | 996,894 |
| Out-of-range input, side one wins | 13,448 | 0 | 773,668 | 848,535 | 849,000 | 769,290 | 1,004,958 |
| Representative input, side one wins | 27,180 | 4,388 | 1,515,721 | 1,664,794 | 1,665,000 | 1,514,994 | 1,966,038 |
| Reset, side one wins | 9,056 | 0 | 557,127 | 610,340 | 611,000 | 551,728 | 718,252 |
| Reset, side two wins | 9,056 | 0 | 557,216 | 610,438 | 611,000 | 551,817 | 718,341 |
| Revert, side one wins | 11,008 | 0 | 616,188 | 675,307 | 676,000 | 611,236 | 808,872 |
| Revert, side two wins | 11,008 | 0 | 616,277 | 675,405 | 676,000 | 611,320 | 808,956 |
| Small input, side one wins | 23,212 | 292 | 1,357,257 | 1,490,483 | 1,491,000 | 1,355,401 | 1,742,933 |
| Small input, side two wins | 23,212 | 292 | 1,357,346 | 1,490,581 | 1,491,000 | 1,355,490 | 1,743,022 |

The maximum proof hash remains
`0x6210d2e816377a74375263123a4dc77fd3081b95cddff22720c65c758b8a1f0a`.
The smaller complete-call diagnostics reflect the intentional removal of the
unused `PartialBondRefund.ret` event field in the preceding API commit. The
measured allocations are sampled before that event. They also decreased after
that commit shortened the clone's immutable-argument payload and replaced
impossible-state custom errors with internal assertions.

The configured action allocations remain unchanged. Relative to the selected
rounded recommendations, they retain 8,000 units for inner sealing, 2,000 for
an inner winner, 1,000 for inner elimination, and 1,000 for
`WIN_LEAF_MATCH`.

## Role-specific accounting

The legal terminal sequences remain:

| Terminal sequence | Role | Allocation |
| --- | --- | ---: |
| Direct timeout win | Both | 260,000 |
| Direct timeout elimination | Both | 135,000 |
| Sealed-leaf proof win | Leaf | 4,401,000 |
| Sealed-leaf timeout win | Leaf | 365,000 |
| Sealed-leaf timeout elimination | Leaf | 240,000 |
| Inner-tournament win | Non-leaf | 699,000 |
| Inner-tournament elimination | Non-leaf | 535,000 |

The old common maximum was 4,401,000 units. The leaf maximum remains 4,401,000
units; the non-leaf maximum becomes 699,000 units. Every positive-height
non-leaf reserve therefore falls by 3,702,000 units, exactly 0.1851 ETH at the
unchanged 50-gwei work-price cap.

| Geometry | Role | Old reserve | Old bond | New reserve | New bond |
| --- | --- | ---: | ---: | ---: | ---: |
| Height 1 | Leaf | 4,401,000 | 0.22005 ETH | 4,401,000 | 0.22005 ETH |
| Height 1 | Non-leaf | 4,401,000 | 0.22005 ETH | 699,000 | 0.03495 ETH |
| Canonical level 0, height 48 | Non-leaf | 10,276,000 | 0.5138 ETH | 6,574,000 | 0.3287 ETH |
| Canonical level 1, height 17 | Non-leaf | 6,401,000 | 0.32005 ETH | 2,699,000 | 0.13495 ETH |
| Canonical level 2, height 27 | Leaf | 7,651,000 | 0.38255 ETH | 7,651,000 | 0.38255 ETH |
| Retained root, height 55 | Non-leaf | 11,151,000 | 0.55755 ETH | 7,449,000 | 0.37245 ETH |
| Retained leaf, height 37 | Leaf | 8,901,000 | 0.44505 ETH | 8,901,000 | 0.44505 ETH |

`Gas.sol`, `WORK_PRICE_CAP`, `REFUND_PRIORITY_FEE_CAP`, and the payment callback
limit are unchanged. The focused tests prove every terminal path included in a
role is legal for that role, every such path fits its reserve, and the largest
legal path equals the selected reserve. The population model retains
`matchesCreated <= joins - 1` and one winner bond after worst-case refundable
liability for both roles.

## Network admission headroom

The largest retained Prague transaction diagnostic is 5,358,446 gas. Ethereum
[EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) caps one transaction at
16,777,216 gas, leaving 11,418,770 gas of headroom; the witness occupies 31.94%
of the cap.

Ethereum Mainnet block 25,659,666 at `2026-08-01T11:16:35Z` reported a
60,000,000-gas block limit through `eth_getBlockByNumber`. The block hash was
`0x30a2fc44db1f85c2d901f280a0e20ca20cc05ac6de63d1d2ced8f58d0150135f`.
The witness occupies 8.93% of that limit and leaves 54,641,554 gas. These are
dated admission observations, not permanent protocol constants.

## Validation and compatibility

The accepted evidence is:

```text
focused role-specific reserve suite: 7/7 tests passed
Tournament-only retained gas witnesses: 18/18
full-stack leaf retained gas witnesses: 12/12
total retained gas witnesses: 30/30
PRT dispute suites: 52 suites, 239 tests passed
Rollups contract suites: 1 suite, 4 tests passed
exact refund formula: 3/3 tests passed
refund callback behavior: 11/11 tests passed
PRT scoped coverage: 98.71% lines, 98.74% statements, 52.24% branches, 100% functions
PRT and Rollups forge fmt checks: clean
git diff --check: clean
```

The preceding API commit and this bond commit have separate compatibility
boundaries. Across this bond commit, Tournament ABI and semantic storage remain
unchanged while production bytecode changes:

```text
before ABI: 52cc4c9fd0231698579497959e818b65b66759a7df69fff9c3e493145617f50b
after ABI: 52cc4c9fd0231698579497959e818b65b66759a7df69fff9c3e493145617f50b
before semantic storage: 952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
after semantic storage: 952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
before creation bytecode: 5c23427c48f2edece0adaffbd542083b8132798c0823de4b2d458fd86d820140
after creation bytecode: 5f75292296aea74a141943c010feb8305a3280b3ec50ad61ef313996d461d6a5
before runtime bytecode: 24fb186f82e129efe4405dcf65eeb1cf33a302fedc63a5faeea3779173233d41
after runtime bytecode: 317110710a663c3937e11d6b6fa703dc04d84479f4c1bd99dcb63c041a857351
```

Deployment artifacts and CREATE2-derived addresses were not regenerated in
this calibration. They must be regenerated and reviewed before release. No
off-chain node or Lua change is part of this commit; both consume each clone's
external `bondValue()` dynamically.
