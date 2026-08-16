# PRT v0.21 state-transition gas calibration

Status: accepted 2026-08-11

This record captures the full refund-gas recalibration required by the Cartesi
Machine v0.21 and solidity-step v0.15 state-transition upgrade. It is historical
evidence for the named candidate, not the maintained procedure. Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The accepted candidate is
`eae1d340e2c5bebb93521fc907401cae7be72874`. Its clean, release-pinned run
passed all 30 retained gas witnesses. This record was written after that run
and is not part of the measured tree.

## Decision

The candidate upgrades the emulator proof encoding and replaces the two
state-transition proxy calls with direct composition of `SendCmioResponse` and
`MetaStep`. The maximum canonical-input proof grows from 88,204 bytes under
v0.20 to 93,964 bytes under v0.21, an increase of 5,760 bytes. The selected
side-two witness measures 4,019,879 allocation units, requires 4,419,367 after
the reviewed margin, and rounds to 4,420,000.

Relative to the named candidate's immediate parent, `Gas.WIN_LEAF_MATCH`
increases from 4,298,000 to 4,420,000 units. The other seven production
allocations retain their candidate-parent values and their exact recorded
headroom. This clean run supersedes the complete measurement table from prior
accepted records, including allocations changed by intervening commits.
`WORK_PRICE_CAP`, `REFUND_PRIORITY_FEE_CAP`, and
`PAYMENT_CALLBACK_GAS_LIMIT` do not change.

A same-proof diagnostic comparison measured direct v0.21 composition 86,403
allocation units below the prior proxy composition. That dirty diagnostic was
explanatory only and was not used to accept the allocation. The clean
calibration below establishes the selected production value.

The calibration runbook ordinarily keeps off-chain node work out of a gas-only
calibration commit. This candidate is instead one coordinated compatibility
slice: the Rust node, Lua proof producer, and Solidity verifier must agree on
the v0.21 proof encoding, counter convention, strict proof consumption, and
uarch-overflow closing transition. Splitting those semantic changes would
create intermediate revisions that do not stand alone. The accepted gas run
was performed only after that exact candidate was committed and clean. Its
evidence applies only to the named candidate, regardless of later history
rewrites.

## Environment and provenance

The clean run used macOS 26.5.2 (Darwin 25.5.0, build 25F84) on arm64:

```text
candidate: eae1d340e2c5bebb93521fc907401cae7be72874
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

The release archive and Forge binary match the hashes retained by the prior
accepted calibration. The release directory was prepended inside `direnv exec`
before running `just measure-prt-gas`; no diagnostic override was enabled. Both
measurement entry points reported the candidate revision without a dirty
suffix. Each also independently checked the Forge release, effective compiler
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
| Position-one inner seal | 319,143 | 29,415 | 348,558 | 349,000 | 363,000 | 312,295 |
| Position-two left inner seal | 304,763 | 27,977 | 332,740 | 333,000 | 363,000 | 297,915 |
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
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | 319,143 | 348,558 | 349,000 | 363,000 | 14,000 |
| `WIN_INNER_TOURNAMENT` | 267,134 | 291,348 | 292,000 | 338,000 | 46,000 |
| `ELIMINATE_INNER_TOURNAMENT` | 146,000 | 158,100 | 159,000 | 172,000 | 13,000 |
| `SEAL_LEAF_MATCH` | 117,593 | 127,593 | 128,000 | 130,000 | 2,000 |
| `WIN_LEAF_MATCH` | 4,019,879 | 4,419,367 | 4,420,000 | 4,420,000 | 0 |

Relative to the named candidate's immediate parent, only `WIN_LEAF_MATCH`
changes. The retained Tournament allocations already cover every selected
reviewed recommendation and remain unchanged in this candidate to avoid
unrelated deployment churn. This run supersedes the complete prior table
rather than implying that every configured value is unchanged from the
2026-08-01 record. Between that record and this candidate, the intervening
recursive-reader refactor had already changed `ADVANCE_MATCH` from 125,000 to
127,000, `WIN_MATCH_BY_TIMEOUT` from 260,000 to 262,000,
`WIN_INNER_TOURNAMENT` from 336,000 to 338,000, `SEAL_LEAF_MATCH` from
105,000 to 130,000, and `WIN_LEAF_MATCH` from 4,296,000 to 4,298,000. The
tests pin each current selected maximum and its exact retained headroom instead
of accepting a generic upper bound.

## Derived accounting

The legal terminal allocations become the following; `Old` is the named
candidate's immediate parent and `New` is the measured candidate:

| Terminal sequence | Role | Old | New |
| --- | --- | ---: | ---: |
| Direct timeout win | Both | 262,000 | 262,000 |
| Direct timeout elimination | Both | 135,000 | 135,000 |
| Sealed-leaf proof win | Leaf | 4,428,000 | 4,550,000 |
| Sealed-leaf timeout win | Leaf | 392,000 | 392,000 |
| Sealed-leaf timeout elimination | Leaf | 265,000 | 265,000 |
| Inner-tournament win | Non-leaf | 701,000 | 701,000 |
| Inner-tournament elimination | Non-leaf | 535,000 | 535,000 |

The leaf terminal maximum rises by 122,000 units, from 4,428,000 to
4,550,000. The non-leaf terminal maximum remains 701,000. The direct
`WIN_LEAF_MATCH` action cap rises from 0.2149 ETH to 0.221 ETH at the unchanged
50-gwei work-price cap.

| Geometry | Role | Old reserve | Old bond | New reserve | New bond |
| --- | --- | ---: | ---: | ---: | ---: |
| Height 1 | Leaf | 4,428,000 | 0.2214 ETH | 4,550,000 | 0.2275 ETH |
| Height 1 | Non-leaf | 701,000 | 0.03505 ETH | 701,000 | 0.03505 ETH |
| Canonical level 0, height 48 | Non-leaf | 6,670,000 | 0.3335 ETH | 6,670,000 | 0.3335 ETH |
| Canonical level 1, height 17 | Non-leaf | 2,733,000 | 0.13665 ETH | 2,733,000 | 0.13665 ETH |
| Canonical level 2, height 27 | Leaf | 7,730,000 | 0.3865 ETH | 7,852,000 | 0.3926 ETH |
| Retained root, height 55 | Non-leaf | 7,559,000 | 0.37795 ETH | 7,559,000 | 0.37795 ETH |
| Retained leaf, height 37 | Leaf | 9,000,000 | 0.45 ETH | 9,122,000 | 0.4561 ETH |

The accounting tests enumerate every terminal family legal for each role,
check the height formula against actual root and child clones, and retain the
population invariant `matchesCreated <= joins - 1`. No economic policy
constant changed.

## Network admission headroom

The largest retained Prague transaction diagnostic is 5,565,470 gas. Ethereum
[EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) caps one transaction at
16,777,216 gas. The witness occupies 33.17% of that cap and leaves 11,211,746
gas of per-transaction headroom.

Ethereum Mainnet block 25,732,194 at `2026-08-11T13:56:23Z` reported a
60,000,000-gas block limit. Its hash was
`0x74f3dbbe7d7b434795dcc792a3fede466ef68f7ee49d41862773464b8cf1bd12`.
Independent `eth_getBlockByNumber` queries through
[PublicNode](https://ethereum-rpc.publicnode.com) and
[Flashbots](https://rpc.flashbots.net) returned the same latest-block
observation. The witness occupies 9.28% of that limit and leaves 54,434,530
gas. These are dated admission observations, not permanent protocol constants.

## Compatibility and deployment impact

`IStateTransition` keeps its external selector and ABI. Tournament ABI and
semantic storage are unchanged across the candidate; the `WIN_LEAF_MATCH`
constant changes Tournament bytecode and therefore deployment identity:

```text
Tournament ABI: d1dda187022f25ff1fdf43afa98b0350d131d85e009380a320ff6cd5becb55d7
Tournament semantic storage: c01aeacb5aa4307359b99806977b3ed356fb699bc27b7130a7879dd4b53e6988
before creation bytecode: 660dc00ff8854fad03c9adc928587fd4dc913499b98e88da835e6ba9c2d910b4
after creation bytecode: bd24687dc3adb38c56127bf80853afeda8194f49d5f50c543a4dc6dad0fc66ad
before runtime bytecode: 4bf6e57a63919450987a21945c41993b87ced155807474cc99eecef438799f95
after runtime bytecode: 54b07ef0b459cd73b6a39ee3ebd7b467fbef7a950e4625e537c23bcf75aba7e7
IStateTransition ABI: afe69e90871224512ae94a5e555a8eb53160121c9889893d080762634e6c2440
MultiLevelTournamentFactory ABI: 89d8da13a49de135d3155bb2f7d174a2cc420d092d5e1c0b5d31e52a3d508040
CartesiStateTransition ABI: cf1ba256a1fab23b1270f5973df726e0a1619492864e23d440261ff359a15e39
CartesiStateTransition creation bytecode: f36c37a4e303126ab3c91107c912dc85b7cf7b719c8f77efface61b93e4ef961
CartesiStateTransition runtime bytecode: ba14e625c330a49936f2ddb577697c42b64bbfc67feccd6adefb83b4426ee62e
```

The directly composed `CartesiStateTransition` is 13,713 runtime bytes and
13,739 initcode bytes. It retains 10,863 bytes below EIP-170 and 35,413 bytes
below EIP-3860. The removed RISC-V and CMIO proxies are no longer deployment
dependencies.

The devnet bundle was regenerated and its v3 fingerprint verified:

```text
CartesiStateTransition: 0x8f80E7e1cFf91D70B4BdA53a77046915103a443c
MultiLevelTournamentFactory: 0xFd8C1CeeAeAe58Df2C19eB61FA3d1D44BDE6C58A
DaveAppFactory: 0x24D80311279A6ea110E08F23300C2A822fBE54DA
Tournament: 0x641D976A46Ce0DE5De58C9ea6ce3FCA711919859
CanonicalTournamentParametersProvider: 0x765Fd35C2B99117A3f8ecec5964a1BE2Ac013863
state fingerprint: v3 a033cc3544502648b042d0cf13d998ce516441360841285df3b54dff6b2a1cdf 96456a4654e9e5ffad799e18eb1aa1ce85e970e51542a419d6f4b63ac9fa910b 791d699210e421c5639dcd6b875594ed8bd3cd840d4c5cc40d9041384cf1cf5f
```

No RISC-V or CMIO proxy deployment record remains. Forced bindings generation
completed for both contract projects and produced no tracked binding diff.

## Validation

The accepted evidence is:

```text
just check: passed
clean release-pinned gas calibration: 30/30 witnesses
Tournament-only retained gas witnesses: 18/18
full-stack leaf retained gas witnesses: 12/12
PRT non-FFI suites: 53 suites, 275 tests passed
PRT deterministic state-transition FFI: 5/5 tests passed
PRT fuzzy state-transition FFI: 2/2 tests passed, 256 runs each
Rollups contract suite: 5/5 tests passed
exact refund formula: 3/3 tests passed
refund callback behavior: 11/11 tests passed
refund reserve accounting: 10/10 tests passed
Lua client: 70/70 tests passed
Rust node library: 178/178 tests passed
Rust workspace clippy: all targets, warnings denied
v0.21 computation-hash corpus: 17/17 cases matched CLI and Rust
echo full-dispute e2e: correct claim won
yield stf_all e2e: correct claim won for four disputed epochs
yield stf_revert e2e: exact rejected-input revert dispute won
contract bindings regeneration: clean
devnet bundle regeneration and fingerprint verification: clean
formatting and git diff --check: clean
```

`just doctor` found the toolchain, submodules, generated bindings, echo and
yield machine images, and devnet bundle healthy. It reported only the absent
optional honeypot machine image and fingerprint, which was pre-existing and is
outside this calibration's exercised fixtures.
