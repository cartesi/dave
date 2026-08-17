# PRT STF composition gas calibration

Status: accepted 2026-08-17

This record captures the refund-gas recalibration after the Cartesi state
transition was made explicit, its counter and witness boundaries were checked,
and the tournament factory exposed its configured state transition. Follow the
maintained
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The accepted candidate is
`48736252e0cf2ed3c64f1a00f3e3e496966a3e0c`. The release-pinned run was clean;
this record was written afterward and is not part of the measured tree.

## Decision

All 30 retained witnesses passed. Relative to the
[`2026-08-16 calibration`](../2026-08-16-prt-v021-post-274-gas-calibration/),
the only Tournament-only changes are the two factory child-creation paths. The
full-stack leaf paths became cheaper.

| Witness | Previous | Candidate | Delta | Reviewed | Rounded | Configured |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Position-one inner seal | 319,219 | 319,241 | +22 | 348,666 | 349,000 | 363,000 |
| Position-two left inner seal | 304,839 | 304,861 | +22 | 332,848 | 333,000 | 363,000 |
| Maximum input, side one | 4,019,790 | 4,019,073 | -717 | 4,418,481 | 4,419,000 | 4,420,000 |
| Maximum input, side two | 4,019,879 | 4,019,162 | -717 | 4,418,579 | 4,419,000 | 4,420,000 |

The selected `WIN_LEAF_MATCH` recommendation is now 4,419,000. The configured
4,420,000 deliberately retains 1,000 units of headroom. No `Gas.sol` allocation,
economic policy constant, terminal sequence, work reserve, or bond changes.

The exact retained Tournament measurements are:

| Witness | Measured | Margin | Reviewed | Rounded | Configured |
| --- | ---: | ---: | ---: | ---: | ---: |
| Active advanced timeout elimination | 123,154 | 10,000 | 133,154 | 134,000 | 135,000 |
| Active side one timeout win | 238,078 | 21,308 | 259,386 | 260,000 | 262,000 |
| Active side two timeout win | 238,214 | 21,322 | 259,536 | 260,000 | 262,000 |
| First charged right advance | 114,085 | 10,000 | 124,085 | 125,000 | 127,000 |
| First charged left advance | 91,921 | 10,000 | 101,921 | 102,000 | 127,000 |
| Expired resolved inner winner | 146,000 | 12,100 | 158,100 | 159,000 | 172,000 |
| No-winner inner child | 143,233 | 11,824 | 155,057 | 156,000 | 172,000 |
| Inner side one wins | 266,905 | 24,191 | 291,096 | 292,000 | 338,000 |
| Expired single inner claim | 145,985 | 12,099 | 158,084 | 159,000 | 172,000 |
| Single inner claim wins side two | 267,119 | 24,212 | 291,331 | 292,000 | 338,000 |
| Inner side two wins | 267,134 | 24,214 | 291,348 | 292,000 | 338,000 |
| Position-one inner seal | 319,241 | 29,425 | 348,666 | 349,000 | 363,000 |
| Position-two left inner seal | 304,861 | 27,987 | 332,848 | 333,000 | 363,000 |
| Position-one leaf seal | 117,593 | 10,000 | 127,593 | 128,000 | 130,000 |
| Position-two left leaf seal | 103,213 | 10,000 | 113,213 | 114,000 | 130,000 |
| Sealed-leaf long-deadline elimination | 122,726 | 10,000 | 132,726 | 133,000 | 135,000 |
| Sealed-leaf side one timeout win | 238,253 | 21,326 | 259,579 | 260,000 | 262,000 |
| Sealed-leaf side two timeout win | 238,389 | 21,339 | 259,728 | 260,000 | 262,000 |

The exact retained full-stack measurements are:

| Witness | Proof bytes | Input | Measured | Margin | Reviewed | Rounded | Configured |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Maximum input, side one wins | 93,964 | 65,508 | 4,019,073 | 399,408 | 4,418,481 | 4,419,000 | 4,420,000 |
| Maximum input, side two wins | 93,964 | 65,508 | 4,019,162 | 399,417 | 4,418,579 | 4,419,000 | 4,420,000 |
| Ordinary step, side one wins | 13,440 | 0 | 736,823 | 71,183 | 808,006 | 809,000 | 4,420,000 |
| Ordinary step, side two wins | 13,440 | 0 | 736,912 | 71,192 | 808,104 | 809,000 | 4,420,000 |
| Out-of-range input, side one wins | 13,448 | 0 | 745,147 | 72,015 | 817,162 | 818,000 | 4,420,000 |
| Representative input, side one wins | 32,940 | 4,388 | 1,627,091 | 160,210 | 1,787,301 | 1,788,000 | 4,420,000 |
| Reset, side one wins | 9,056 | 0 | 508,863 | 48,387 | 557,250 | 558,000 | 4,420,000 |
| Reset, side two wins | 9,056 | 0 | 508,952 | 48,396 | 557,348 | 558,000 | 4,420,000 |
| Revert, side one wins | 11,008 | 0 | 558,776 | 53,378 | 612,154 | 613,000 | 4,420,000 |
| Revert, side two wins | 11,008 | 0 | 558,865 | 53,387 | 612,252 | 613,000 | 4,420,000 |
| Small input, side one wins | 28,972 | 292 | 1,468,180 | 144,318 | 1,612,498 | 1,613,000 | 4,420,000 |
| Small input, side two wins | 28,972 | 292 | 1,468,269 | 144,327 | 1,612,596 | 1,613,000 | 4,420,000 |

## Supported envelope and accounting

The Tournament matrix retains a root stride of 37 and height 55, followed by
a leaf stride of zero and height 37. It covers both orientations, first writes,
active and sealed-leaf timeouts, maximum agree-state proofs, real child
creation, resolved, single-claim, and no-winner children, both child winners,
and dangling re-pairing.

The full-stack matrix uses the production Tournament, Dave provider, InputBox,
Cartesi state transition, and a two-level height-one fixture with the divergence
at position one. It retains ordinary step, reset, rejection rollback, small,
representative, and maximum canonical inputs, the out-of-range fixpoint, both
winner orientations where applicable, nonzero Match deletion, and dangling
re-pairing. The maximum proof is 93,964 bytes, including 65,508 authenticated
input bytes. This remains a reference subsidy over the declared envelope, not
a universal proof-class ceiling.

The unchanged configured action allocations are 127,000 for advance, 262,000
for timeout win, 135,000 for timeout elimination, 363,000 for inner seal,
338,000 for inner win, 172,000 for inner elimination, 130,000 for leaf seal,
and 4,420,000 for leaf proof win. Their unchanged terminal maxima are:

| Terminal sequence | Role | Allocation |
| --- | --- | ---: |
| Direct timeout win | Both | 262,000 |
| Direct timeout elimination | Both | 135,000 |
| Sealed-leaf proof win | Leaf | 4,550,000 |
| Sealed-leaf timeout win | Leaf | 392,000 |
| Sealed-leaf timeout elimination | Leaf | 265,000 |
| Inner-tournament win | Non-leaf | 701,000 |
| Inner-tournament elimination | Non-leaf | 535,000 |

The corresponding reserves and bonds remain:

| Geometry | Role | Work reserve | Bond |
| --- | --- | ---: | ---: |
| Height 1 | Leaf | 4,550,000 | 0.2275 ETH |
| Height 1 | Non-leaf | 701,000 | 0.03505 ETH |
| Canonical level 0, height 48 | Non-leaf | 6,670,000 | 0.3335 ETH |
| Canonical level 1, height 17 | Non-leaf | 2,733,000 | 0.13665 ETH |
| Canonical level 2, height 27 | Leaf | 7,852,000 | 0.3926 ETH |
| Retained root, height 55 | Non-leaf | 7,559,000 | 0.37795 ETH |
| Retained leaf, height 37 | Leaf | 9,122,000 | 0.4561 ETH |

The independent accounting gates passed 3/3 refund-formula tests, including
the 256-run production-formula fuzz property; 11/11 callback and retry tests;
and 10/10 reserve, terminal-sequence, population, and bond tests, including the
256-run bond-formula property.

## Environment and evidence

The clean run used macOS 26.5.2 (build 25F84) on arm64. It used Forge
`1.5.1-v1.5.1` at commit
`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`; the release archive and Forge
binary SHA-256 hashes were respectively
`b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d` and
`051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c`.
The compiler was Solidity 0.8.30, with IR and the optimizer enabled for 200
runs and the Prague EVM revision. The PRT and combined leaf dependency hashes
were respectively
`ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3` and
`bf5c94f033883d49e851fe57111f5031bfbbc1969c6027aedc6ac607815d4234`.
The run used Cartesi Machine 0.21.0, emulator commit
`bd09538131e589319e371d7d65e81c2c82dd3411`, solidity-step commit
`23765c8841103912755bb3d80952c2a8e1adf4d3`, and yield-machine hash
`9b358eac8ebd2aa2c7ab4c00d098da7fd90906dc571ec83ec16e889fd220e0fb`.

The retained local logs are bound by:

```text
gas calibration: 4284900634b211de6050fbb97adb8744c64136aef72eccc7bfb927a1fa0f5430
gas validation: 9f1944d06f4e7912a8f00f6c470359469879e53420d364040258152a62ee42f9
compatibility: 6acd00842636f38a1bf3d5156fdcd7f3a3911abd2d68a9c065a316b92c41ecae
state-transition compatibility: 72e54a342abbdaafe0a77e920a62bf854ee519682360a228b40998469b26cfd2
full check: 1d6609223e88079ef93ecbf3bd747f31bcadc3c6b6541f286461cacb6e139028
```

## Compatibility and admission

Tournament wire ABI, semantic storage, and metadata-free bytecode remain equal
to the prior accepted record. Factory storage also remains equal; its new
`stateTransition()` getter changes its ABI and bytecode. The current factory
ABI, metadata-free creation, and runtime hashes are respectively
`8cdb8212f80ab2d25c62522976aea5469771ca9e420e0f9522b534f8c1723338`,
`bcaba81341e9d6020eb9720b7e5b5ef1658df4d31f7da510e83f750e6e8b62bb`, and
`36ddfb3b50bb11eeb856f27fdda1a081ff9305249915e363e68ab16710c6f55f`.

The concrete state transition's ABI, metadata-free creation, and runtime
hashes are respectively
`48914028c968778c6126511479ae7f940e94038e34b9892aa0ae25a31c018ef1`,
`1c65b555eef9b6dfc72f72b139c0805aade75f68deba1fc2c6200ca03c320faf`, and
`1d614bccf4fa78d553730ec9b4367915361d6e079738c964d53118a3b583e27c`.
It is 13,708 runtime bytes and 13,734 initcode bytes. These expected ABI and
bytecode changes require the coordinated deployment generation; they do not
change the gas allocation decision.

Both generated Rust binding sets were refreshed and verified. The devnet was
regenerated after the ABI changes and passed its v4 fingerprint verification:

```text
inputs: f8a4ec5d6db2f8654429a7041104b991ed0a5e5c5e3c0143976546d0b8c3c4ed
state: b8bc90928ade98c7057441711a2602132371c4984e54559f0e00c470a45d6dd3
deployments: 909e4310748003665a69bb1d76dbca463e1dd5dd9d1d15944d97747107cb970e
```

These generated bindings and deployment outputs are ignored build artifacts;
the tracked compatibility surface is the source and this evidence record.

The largest retained Prague transaction diagnostic is 5,564,753 gas. It uses
33.168513% of Ethereum's
[`EIP-7825`](https://eips.ethereum.org/EIPS/eip-7825) 16,777,216-unit cap and
leaves 11,212,463 gas. Ethereum block 25,771,873 at
`2026-08-17T02:40:35Z`, hash
`0x63788b43622bdc9f1820d7399c115434d69db4a4e14882c43f037e71b4b729a3`,
had a 60,000,000 gas limit and used 36,346,940 gas. The witness uses 9.274588%
of that limit and leaves 54,435,247 gas. PublicNode and Flashbots returned the
same block. These are dated admission observations, not permanent limits.

## Validation

- release-pinned gas calibration: 30/30 witnesses;
- retained gas validation: 18/18 Tournament and 12/12 full-stack leaf tests;
- compatibility fingerprints and contract size gates: passed; and
- full `just check`, formatting, lint, bindings, Solidity, Rust, and Lua gates:
  passed.
