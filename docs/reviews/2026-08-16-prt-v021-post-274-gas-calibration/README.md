# PRT v0.21 post-#274 gas calibration

Status: accepted 2026-08-16

This record captures the full refund-gas recalibration after the contract and
client changes merged in PR #274 and the v0.21 campaign's history cleanup. It
is historical evidence for the named candidate, not the maintained procedure.
Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The accepted candidate is
`d658bfcbc3b67afc770b5625e4802a03e05dd8c4`. Its clean, release-pinned run
passed all 30 retained gas witnesses. This record was written after that run
and is not part of the measured tree. The candidate and measurements captured
by the accepted
[`2026-08-11 v0.21 calibration`](../2026-08-11-prt-v021-stf-gas-calibration/)
remain unchanged historical evidence.

## Decision

All 12 full-stack leaf measurements and 16 of the 18 Tournament-only
measurements exactly match the 2026-08-11 record. The two witnesses that seal
an inner match and instantiate its child each increase by 76 allocation units:

| Witness | 2026-08-11 | Candidate | Delta | Reviewed | Rounded | Configured |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Position-one inner seal | 319,143 | 319,219 | +76 | 348,641 | 349,000 | 363,000 |
| Position-two left inner seal | 304,763 | 304,839 | +76 | 332,823 | 333,000 | 363,000 |

These are the two retained witnesses that create an inner child through the
factory path changed by the post-#274 contract interface. The increase does not
cross a rounded recommendation or require a production allocation change. The
selected maximum for
`SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` remains 349,000 after margin,
with 363,000 configured.

All eight production allocations and their derived terminal sequences, work
reserves, and bonds remain unchanged. `WORK_PRICE_CAP`,
`REFUND_PRIORITY_FEE_CAP`, and `PAYMENT_CALLBACK_GAS_LIMIT` also remain
unchanged. The accepted measurement therefore characterizes the measured
candidate without creating deployment churn for gas policy.

The accepted run was performed only after the exact candidate was committed
and clean. Its evidence applies only to the named candidate, regardless of
later history rewrites.

## Environment and provenance

The clean run used macOS 26.5.2 (Darwin 25.5.0, build 25F84) on arm64:

```text
candidate: d658bfcbc3b67afc770b5625e4802a03e05dd8c4
Forge: 1.5.1-v1.5.1
Forge commit: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
release archive sha256: b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d
forge binary sha256: 051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c
effective config: {"solc":"0.8.30","via_ir":true,"optimizer":true,"optimizer_runs":200,"evm_version":"prague"}
PRT foundry.toml sha256: 52cbcb59a04926e546a2498ad27383b6f3670dcd6de4c1e051b118190d87acf6
PRT soldeer.lock sha256: fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53
PRT dependencies sha256: ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3
Rollups foundry.toml sha256: 6403f888f3378eb6b7150628ef5a50682308ee0b67dd0e1e9eef2d85b22bd0de
Rollups soldeer.lock sha256: 28a76c49c9129aa07f257246a9a62a0b28fc996606f976dccc07ae748385daac
combined leaf dependencies sha256: bf5c94f033883d49e851fe57111f5031bfbbc1969c6027aedc6ac607815d4234
yield machine hash: 9b358eac8ebd2aa2c7ab4c00d098da7fd90906dc571ec83ec16e889fd220e0fb
Lua: 5.4.7
Cartesi Machine: 0.21.0
Cartesi Lua module sha256: 6e49710b6deceb4b6af6061ad1d958914e861b9dbda65a3f269de6356807fcd7
```

The release archive and Forge binary match the retained hashes from the prior
accepted calibration. The release directory was prepended inside `direnv exec`
before running `just measure-prt-gas`; no diagnostic override was enabled. Both
measurement entry points reported the candidate revision without a dirty
suffix. Each independently checked the Forge release, effective compiler
configuration, locked dependency digest, and recursive submodule state.

The recursive submodule status recorded by the run was:

```text
 bd09538131e589319e371d7d65e81c2c82dd3411 machine/emulator (v0.21.0)
-8f92acd11aa5d59005505ec7a48569c75e128167 machine/emulator/third-party/riscv-arch-test
-a64ad67b8235c681cd244b087ced36c4d5df3cb9 machine/emulator/third-party/riscv-tests
 23765c8841103912755bb3d80952c2a8e1adf4d3 machine/step (v0.15.0)
-1714bee72e286e73f76e320d110e0eaf5c4e649d machine/step/lib/forge-std
```

The leading `-` entries are the verbatim Git status for nested submodules that
were not initialized in this checkout; they are not compiler inputs to the
release-provided emulator library or the vendored Solidity source used here.

The local retained logs have these hashes:

```text
gas calibration sha256: 69d539fedbb91c5ba94095ad4a13c4710a96992c5f5e0207a0e1ada68d9d5fd5
gas witness validation sha256: cf4f9b8ef58c4f7dc30e1f86a64f72ec316b382e490a78454967f850f485a2bd
contract validation sha256: 22e5721eeaf181a128f78091ff8c413089765411af094ecba050d4dc9ded54e4
full check sha256: c81ab6c0f61df6ed429f4553b1db47d270bc66d795b1306e91ae559e3b3b5282
```

The logs are regenerable local evidence and are not tracked artifacts. Their
hashes bind this review to the exact evidence used for the decision.

## Supported envelope

The Tournament-only matrix retains its deliberately large two-level stress
geometry: root stride 37 and height 55, followed by leaf stride 0 and height
37. It covers both bisection orientations, first writes, active and sealed-leaf
timeouts, maximum agree-state proofs, real child creation, both child winners,
resolved, single-claim, and no-winner children, and dangling re-pairing.

The full-stack leaf matrix runs the production `Tournament`, Dave provider,
`InputBox`, and directly composed Cartesi state transition. It retains ordinary
uarch steps, resets, rejected-input reverts, small, representative, and maximum
canonical inputs, the out-of-range fixpoint, both expensive winner orientations
where applicable, nonzero Match deletion, and dangling re-pairing. The maximum
authenticated input segment is 65,508 bytes. For tractability, this fixture uses
a two-level height-one tournament and places the divergence at position one;
the separate Tournament-only matrix owns the large-geometry and storage-path
stress coverage.

The v0.15 `MetaStep` verifier requires complete consumption of the canonical
access-log buffer. The coordinated semantic tests retain trailing-proof
rejection and the closing transition at uarch-cycle overflow. These properties
are compatibility requirements, not reasons to claim that the gas matrix
enumerates every honest instruction or access-log shape. It also does not
retain a gas witness for every terminal halt or exception outcome.
`WIN_LEAF_MATCH` therefore remains a provisional canonical-input reference
subsidy, not a universal finite proof-class ceiling.

## Tournament-only measurements

`Measured` is the allocation-unit request. `Margin` is
`max(10,000, ceil((Measured - Gas.TX) / 10))`; `Reviewed` includes that margin,
and `Rounded` rounds it upward to 1,000 units. `Complete` is diagnostic.

| Witness | Measured | Margin | Reviewed | Rounded | Configured | Complete |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Active advanced timeout elimination | 123,154 | 10,000 | 133,154 | 134,000 | 135,000 | 115,824 |
| Active side one timeout win | 238,078 | 21,308 | 259,386 | 260,000 | 262,000 | 230,952 |
| Active side two timeout win | 238,214 | 21,322 | 259,536 | 260,000 | 262,000 | 231,088 |
| First charged right advance | 114,085 | 10,000 | 124,085 | 125,000 | 127,000 | 106,957 |
| First charged left advance | 91,921 | 10,000 | 101,921 | 102,000 | 127,000 | 84,793 |
| Expired resolved inner winner | 146,000 | 12,100 | 158,100 | 159,000 | 172,000 | 138,458 |
| No-winner inner child | 143,233 | 11,824 | 155,057 | 156,000 | 172,000 | 135,691 |
| Inner side one wins | 266,905 | 24,191 | 291,096 | 292,000 | 338,000 | 259,525 |
| Expired single inner claim | 145,985 | 12,099 | 158,084 | 159,000 | 172,000 | 138,443 |
| Single inner claim wins side two | 267,119 | 24,212 | 291,331 | 292,000 | 338,000 | 259,739 |
| Inner side two wins | 267,134 | 24,214 | 291,348 | 292,000 | 338,000 | 259,749 |
| Position-one inner seal | 319,219 | 29,422 | 348,641 | 349,000 | 363,000 | 312,371 |
| Position-two left inner seal | 304,839 | 27,984 | 332,823 | 333,000 | 363,000 | 297,991 |
| Position-one leaf seal | 117,593 | 10,000 | 127,593 | 128,000 | 130,000 | 110,689 |
| Position-two left leaf seal | 103,213 | 10,000 | 113,213 | 114,000 | 130,000 | 96,309 |
| Sealed-leaf long-deadline elimination | 122,726 | 10,000 | 132,726 | 133,000 | 135,000 | 115,411 |
| Sealed-leaf side one timeout win | 238,253 | 21,326 | 259,579 | 260,000 | 262,000 | 231,130 |
| Sealed-leaf side two timeout win | 238,389 | 21,339 | 259,728 | 260,000 | 262,000 | 231,266 |

## Full-stack leaf measurements

`Input` is the authenticated input segment within the proof. The Prague
transaction estimate is a whole-transaction admission diagnostic; it is not
the configured refund allocation.

| Witness | Proof bytes | Input | Measured | Margin | Reviewed | Rounded | Complete | Prague tx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Maximum input, side one wins | 93,964 | 65,508 | 4,019,790 | 399,479 | 4,419,269 | 4,420,000 | 4,047,101 | 5,565,381 |
| Maximum input, side two wins | 93,964 | 65,508 | 4,019,879 | 399,488 | 4,419,367 | 4,420,000 | 4,047,190 | 5,565,470 |
| Ordinary step, side one wins | 13,440 | 0 | 737,147 | 71,215 | 808,362 | 809,000 | 732,784 | 968,288 |
| Ordinary step, side two wins | 13,440 | 0 | 737,236 | 71,224 | 808,460 | 809,000 | 732,873 | 968,377 |
| Out-of-range input, side one wins | 13,448 | 0 | 745,818 | 72,082 | 817,900 | 818,000 | 741,462 | 976,998 |
| Representative input, side one wins | 32,940 | 4,388 | 1,627,819 | 160,282 | 1,788,101 | 1,789,000 | 1,628,860 | 2,170,612 |
| Reset, side one wins | 9,056 | 0 | 509,119 | 48,412 | 557,531 | 558,000 | 503,742 | 670,206 |
| Reset, side two wins | 9,056 | 0 | 509,208 | 48,421 | 557,629 | 558,000 | 503,831 | 670,295 |
| Revert, side one wins | 11,008 | 0 | 559,050 | 53,405 | 612,455 | 613,000 | 554,120 | 751,816 |
| Revert, side two wins | 11,008 | 0 | 559,139 | 53,414 | 612,553 | 613,000 | 554,204 | 751,900 |
| Small input, side one wins | 28,972 | 292 | 1,468,908 | 144,391 | 1,613,299 | 1,614,000 | 1,468,733 | 1,947,081 |
| Small input, side two wins | 28,972 | 292 | 1,468,997 | 144,400 | 1,613,397 | 1,614,000 | 1,468,822 | 1,947,170 |

The two maximum-input witnesses use proof hash
`0x0970191240c628673a2c1005cb51c507a8a578ecb6e085d241f0495c91d741b0`.
Their calldata is 94,180 bytes: 800 zero bytes and 93,380 nonzero bytes. The
measurement report records a 3,764,200-unit Prague calldata floor for each.

## Allocation decision

| Allocation | Selected measured | Reviewed | Rounded | Configured | Retained extra |
| --- | ---: | ---: | ---: | ---: | ---: |
| `ADVANCE_MATCH` | 114,085 | 124,085 | 125,000 | 127,000 | 2,000 |
| `WIN_MATCH_BY_TIMEOUT` | 238,389 | 259,728 | 260,000 | 262,000 | 2,000 |
| `ELIMINATE_MATCH_BY_TIMEOUT` | 123,154 | 133,154 | 134,000 | 135,000 | 1,000 |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | 319,219 | 348,641 | 349,000 | 363,000 | 14,000 |
| `WIN_INNER_TOURNAMENT` | 267,134 | 291,348 | 292,000 | 338,000 | 46,000 |
| `ELIMINATE_INNER_TOURNAMENT` | 146,000 | 158,100 | 159,000 | 172,000 | 13,000 |
| `SEAL_LEAF_MATCH` | 117,593 | 127,593 | 128,000 | 130,000 | 2,000 |
| `WIN_LEAF_MATCH` | 4,019,879 | 4,419,367 | 4,420,000 | 4,420,000 | 0 |

The tests pin each selected maximum and its exact retained headroom instead of
accepting a generic upper bound. No configured allocation changes relative to
the 2026-08-11 accepted record.

## Derived accounting

Because the configured allocations do not change, the legal terminal
allocations remain:

| Terminal sequence | Role | Current |
| --- | --- | ---: |
| Direct timeout win | Both | 262,000 |
| Direct timeout elimination | Both | 135,000 |
| Sealed-leaf proof win | Leaf | 4,550,000 |
| Sealed-leaf timeout win | Leaf | 392,000 |
| Sealed-leaf timeout elimination | Leaf | 265,000 |
| Inner-tournament win | Non-leaf | 701,000 |
| Inner-tournament elimination | Non-leaf | 535,000 |

The leaf terminal maximum remains 4,550,000 units. The non-leaf terminal
maximum remains 701,000. The direct `WIN_LEAF_MATCH` action cap remains 0.221
ETH at the unchanged 50-gwei work-price cap.

| Geometry | Role | Work reserve | Bond |
| --- | --- | ---: | ---: |
| Height 1 | Leaf | 4,550,000 | 0.2275 ETH |
| Height 1 | Non-leaf | 701,000 | 0.03505 ETH |
| Canonical level 0, height 48 | Non-leaf | 6,670,000 | 0.3335 ETH |
| Canonical level 1, height 17 | Non-leaf | 2,733,000 | 0.13665 ETH |
| Canonical level 2, height 27 | Leaf | 7,852,000 | 0.3926 ETH |
| Retained root, height 55 | Non-leaf | 7,559,000 | 0.37795 ETH |
| Retained leaf, height 37 | Leaf | 9,122,000 | 0.4561 ETH |

The accounting tests enumerate every terminal family legal for each role,
check the height formula against actual root and child clones, and retain the
population invariant `matchesCreated <= joins - 1`. No economic policy
constant changed.

## Network admission headroom

The largest retained Prague transaction diagnostic is 5,565,470 gas. Ethereum
[`EIP-7825`](https://eips.ethereum.org/EIPS/eip-7825) caps one transaction at
16,777,216 gas. The witness occupies 33.172786% of that cap and leaves
11,211,746 gas of per-transaction headroom.

Ethereum Mainnet block 25,768,287 at `2026-08-16T14:41:47Z` reported a gas
limit of 59,941,408 and gas used of 48,345,449. Its hash was
`0xd02c771fd254960b3b41684c363ac80df453bcb371a443f37f5cee68eb47c963`.
Independent `eth_getBlockByNumber` queries through
[PublicNode](https://ethereum-rpc.publicnode.com) and
[Flashbots](https://rpc.flashbots.net) returned the same latest-block
observation. The witness occupies 9.284850% of that limit and leaves 54,375,938
gas of block-limit headroom. These are dated admission observations, not
permanent protocol constants.

## Compatibility and deployment impact

The current compatibility fingerprints are:

```text
Tournament wire ABI sha256: d1dda187022f25ff1fdf43afa98b0350d131d85e009380a320ff6cd5becb55d7
Tournament semantic storage sha256: c01aeacb5aa4307359b99806977b3ed356fb699bc27b7130a7879dd4b53e6988
Tournament metadata-free creation bytecode sha256: bd24687dc3adb38c56127bf80853afeda8194f49d5f50c543a4dc6dad0fc66ad
Tournament metadata-free runtime bytecode sha256: 54b07ef0b459cd73b6a39ee3ebd7b467fbef7a950e4625e537c23bcf75aba7e7
Tournament metadata-included creation bytecode sha256: 432c3eaa5b20d5b6e25c675d7b4559f813d7ee206a6d648a167e1542ad99027f
Tournament metadata-included runtime bytecode sha256: 013f9b973a7ce671c5d289d6d0086a4385da474245c051444099437cc2030ab2
MultiLevelTournamentFactory wire ABI sha256: 6c11978a4a826c5a752cf9170602592ec7a4f44a7702b7f659d365e10e19fbca
MultiLevelTournamentFactory semantic storage sha256: 1a715ed0e372f6e0759f9c377294e26d11c3ca7873193f8603f5074f8177468b
MultiLevelTournamentFactory metadata-free creation bytecode sha256: d5e771c63286f1f97289b7367e008d1104cd34aef790437dc0037810cbd98c53
MultiLevelTournamentFactory metadata-free runtime bytecode sha256: dc695bc0aa105223ae612b4b29aaae6171193ee305551cb0b9787c8b4b9c84ec
MultiLevelTournamentFactory metadata-included creation bytecode sha256: 0393c06c64a8d5cb5bea95042812b6f309e81d3c409b7a127572e6e63caaa830
MultiLevelTournamentFactory metadata-included runtime bytecode sha256: 34b60b580d4b5ae58b1ea7c51ff39810385d268a1e1c7ff4ed4cbf3dfc5b5f0c
IStateTransition ABI sha256: afe69e90871224512ae94a5e555a8eb53160121c9889893d080762634e6c2440
CartesiStateTransition ABI sha256: cf1ba256a1fab23b1270f5973df726e0a1619492864e23d440261ff359a15e39
CartesiStateTransition metadata-free creation bytecode sha256: f36c37a4e303126ab3c91107c912dc85b7cf7b719c8f77efface61b93e4ef961
CartesiStateTransition metadata-free runtime bytecode sha256: ba14e625c330a49936f2ddb577697c42b64bbfc67feccd6adefb83b4426ee62e
```

Tournament wire ABI, semantic storage, and metadata-free bytecode remain equal
to the 2026-08-11 accepted record. The factory now exposes its trusted
parameter table, so its ABI and deployment fingerprints are recorded as part
of the current compatibility boundary.

The directly composed `CartesiStateTransition` remains 13,713 runtime bytes and
13,739 initcode bytes. It retains 10,863 bytes below EIP-170 and 35,413 bytes
below EIP-3860.

Bindings generation completed for both contract projects and the generated
bindings were healthy, with no tracked binding diff. After calibration, the
devnet bundle and Honeypot machine were regenerated in that dependency order.
Their current ignored receipts are:

```text
devnet v4 input digest: e2e6ce24acf433ee1dca493717621cc54b55a6f94a34dceeeba8ce882a2c2ba8
devnet state digest: 87082a0be1dd1fdf5d0c9aa7d91a588318d2eff3cc478ad771715671c9b5b90f
devnet deployments digest: d872cb605ea976073782dd9d5192548be0fa4a188eff4e0c7015e31dda64f00d
Honeypot v2 input digest: 9b6bc832052b61d30cf9f37120f67b26d371f48689bb033bdd1c3aa159523003
Honeypot semantic root: 91f72ab1622bea59af7d54e48c5154ce9b255ff5e98bfe1294b5e9d542bab45a
```

The regenerated local deployment bundle records:

```text
CartesiStateTransition: 0x8f80E7e1cFf91D70B4BdA53a77046915103a443c
MultiLevelTournamentFactory: 0x7746748CfF092D7dD95aA7bBD07C82114b13A183
DaveAppFactory: 0x6b7b3a5F5141ED60bf96EF7A4cCD5eF0703Bd1AA
Tournament: 0xdD3FA71FccaBBfe653F2F00397ffd2b01090F9dC
CanonicalTournamentParametersProvider: 0x765Fd35C2B99117A3f8ecec5964a1BE2Ac013863
```

No RISC-V or CMIO proxy deployment is present.

`just doctor-all` accepted the machine provider, both binding sets, all three
machine images, and the devnet bundle. These ignored artifacts are local
follow-up evidence; they are not inputs to the gas-allocation decision.

## Validation

The accepted evidence is:

```text
clean release-pinned gas calibration: 30/30 witnesses
Tournament-only retained gas witnesses: 18/18
full-stack leaf retained gas witnesses: 12/12
release Forge version and effective-config gates: passed
forge fmt --check: passed
PRT non-FFI suites: 53 suites, 278 tests passed
Rollups contract suite: 5/5 tests passed
exact refund formula: 3/3 tests passed
refund callback behavior: 11/11 tests passed
refund reserve accounting: 10/10 tests passed
Rust node library: 190/190 tests passed
Rust workspace clippy: all targets, warnings denied
Lua static analysis: 76 files, zero warnings and zero errors
Lua client: 70/70 tests passed
contract size gates: passed
contract bindings regeneration: clean and healthy
just check: passed
formatting and git diff --check: clean
post-calibration devnet and Honeypot regeneration: passed
just doctor-all: passed
```

The retained post-candidate logs carry the hashes listed in the provenance
section. The artifact refresh happened after the clean gas run and was not
counted as accepted gas evidence.
