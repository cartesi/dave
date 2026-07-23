# PRT leaf-proof gas calibration

Status: accepted for candidate `4a980a8f0a656c224c5c22c3bc3cf8dd6cde375c`
on 2026-07-23.

This record closes the missing full-entry-point evidence behind
`Gas.WIN_LEAF_MATCH`. It is historical evidence for the named candidate, not
the maintained procedure. Follow
[`prt-refund-gas-calibration.md`](../../runbooks/prt-refund-gas-calibration.md)
for later changes.

The branch has a known pending rebase that changes Foundry. That toolchain
change is a mandatory full recalibration trigger. This record supports the
current allocation decision, but it is not the final pre-merge release record.

## Decision

`WIN_LEAF_MATCH` increased from 843,000 to 4,296,000 allocation units. The
selected witness is the more expensive winner orientation for the largest
canonical input accepted by the production InputBox:

```text
measured allocation = 3,907,553
review margin        =   388,256
reviewed minimum     = 4,295,809
rounded allocation   = 4,296,000
```

The 65,216-byte payload produces a 65,508-byte canonical `EvmAdvance`
encoding. A payload one byte larger produces a 65,540-byte encoding and is
rejected by the 65,536-byte InputBox limit; the fixture pins both boundaries.

This is a deliberately generous reference-path subsidy, not a universal proof
ceiling. It does not bound arbitrary accepted trailing proof bytes, every
possible instruction/access-log shape, unresolved halt or exception behavior,
or a whole transaction receipt.

## Environment

The clean run used:

```text
candidate: 4a980a8f0a656c224c5c22c3bc3cf8dd6cde375c
host: macOS 26.5.2, Darwin 25.5.0, arm64
Forge: 1.5.1-v1.5.1
Forge commit: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
release archive sha256: b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d
forge binary sha256: 051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c
effective config: Solidity 0.8.30, optimized IR, 200 runs, Prague
PRT dependency digest: ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3
full-stack dependency digest: e90c4e0e6b7b4000a7f75b8af2d8562cfce0bef655033e1f2dfa36115d61e4c9
yield machine hash: d83e7921ab07b55e7e57217bd0f3427faea7474bf81b15866d8d4c1f873c51e0
Lua: 5.4.7
Cartesi Machine: 0.20.0
Cartesi Lua module sha256: f6ac06dce6325b7a14bd4f0aebcb09a1cdc3cc2495fb82fdeb4ee5a9d350c60b
```

Configuration hashes:

| File | SHA-256 |
| --- | --- |
| `prt/contracts/foundry.toml` | `52cbcb59a04926e546a2498ad27383b6f3670dcd6de4c1e051b118190d87acf6` |
| `prt/contracts/soldeer.lock` | `fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53` |
| `cartesi-rollups/contracts/foundry.toml` | `72045392f8f79346c596dc946f3326e6c779c6941bf8c51ecace733645375658` |
| `cartesi-rollups/contracts/soldeer.lock` | `28a76c49c9129aa07f257246a9a62a0b28fc996606f976dccc07ae748385daac` |

The release binary directory was prepended inside `direnv exec`; prepending it
outside the development environment selects the repository's development Forge
instead. The accepted command was:

```bash
direnv exec . bash -lc \
  'export PATH=/tmp/foundry-v1.5.1-darwin-arm64:$PATH; just measure-prt-gas'
```

## Witness construction

The retained leaf suite executes the complete production composition:

```text
Tournament.winLeafMatch
    -> CartesiStateTransition
    -> DaveConsensus.provideMerkleRootOfInput
    -> InputBox.getInputHash
```

The InputBox event bytes are passed unchanged to the machine proof generator.
Inputs are added before DaveConsensus snapshots the epoch bounds. The fixture
separates the epoch's pristine initial state from the leaf tournament's state
before `startCycle`, then builds a height-one commitment whose two leaves are
the agree and next states. The divergence is at position one. A third
commitment is left dangling so resolution also deletes the old match and
creates a new pairing.

The matrix runs serially because the machine snapshot helper is not safe for
concurrent writers. Exact inputs are split across FFI arguments to avoid the
platform's per-argument size boundary. The recipe isolates and removes its
snapshot scratch directory.

For the rejected-input witness, the shared Lua log helper supplies the closing
proof but does not expose the checkpoint root restored by rejection. The
fixture derives the expected post-state from a separate run of the same
emulator, then verifies the proof through the on-chain transition. Aligning
that helper's returned next-state API is separate state-transition/client work.

## Leaf-proof measurements

`Measured` is the production refund request at one Wei gas price. `Reviewed`
adds `max(10,000, ceil((Measured - Gas.TX) / 10))`. `Prague tx` is a diagnostic
estimate that includes the calldata floor; it is not used to select the
allocation and is not a receipt-exact promise.

| Witness | Proof input | Proof | Measured | Reviewed | Rounded | Complete call | Prague tx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Ordinary step, one wins | 0 | 13,440 | 766,104 | 840,215 | 841,000 | 762,464 | 998,124 |
| Ordinary step, two wins | 0 | 13,440 | 766,213 | 840,335 | 841,000 | 762,573 | 998,233 |
| Reset, one wins | 0 | 9,056 | 557,692 | 610,962 | 611,000 | 553,038 | 719,562 |
| Reset, two wins | 0 | 9,056 | 557,801 | 611,082 | 612,000 | 553,147 | 719,671 |
| Rejected-input revert, one wins | 0 | 11,008 | 616,757 | 675,933 | 676,000 | 612,550 | 810,186 |
| Rejected-input revert, two wins | 0 | 11,008 | 616,866 | 676,053 | 677,000 | 612,654 | 810,290 |
| Out-of-range input fixpoint | 0 | 13,448 | 774,242 | 849,167 | 850,000 | 770,609 | 1,006,277 |
| 292-byte input, one wins | 292 | 23,212 | 1,357,851 | 1,491,137 | 1,492,000 | 1,356,740 | 1,744,272 |
| 292-byte input, two wins | 292 | 23,212 | 1,357,960 | 1,491,256 | 1,492,000 | 1,356,849 | 1,744,381 |
| 4,388-byte input | 4,388 | 27,180 | 1,516,324 | 1,665,457 | 1,666,000 | 1,516,342 | 1,967,386 |
| 65,508-byte input, one wins | 65,508 | 88,204 | 3,907,444 | 4,295,689 | 4,296,000 | 3,932,391 | 5,359,831 |
| 65,508-byte input, two wins | 65,508 | 88,204 | 3,907,553 | 4,295,809 | 4,296,000 | 3,932,500 | 5,359,940 |

The two maximum-input witnesses use proof hash
`0x6210d2e816377a74375263123a4dc77fd3081b95cddff22720c65c758b8a1f0a`.
Every retained witness logs its proof hash, byte composition, and diagnostic
calldata estimates so a native proof-generation change is visible.

The maximum reference transaction is large but executable. Moving input
hashing and Merkleization to the InputBox would reduce the rare dispute cost
while charging additional work for every input and changing the authenticated
representation. This measurement does not by itself justify that protocol
change.

## Ethereum gas-limit headroom

At the time of this calibration, Ethereum Mainnet enforced the
[EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) per-transaction gas-limit
cap of 16,777,216 units and had a
[60,000,000-unit block gas limit](https://ethereum.org/developers/docs/blocks/).
The maximum retained canonical-input diagnostic compares as follows:

```text
Prague transaction estimate:       5,359,940
per-transaction gas-limit cap:     16,777,216
remaining per-transaction space:  11,417,276
share of per-transaction cap:          31.95%
share of block gas limit:                8.93%
```

The retained witness is therefore materially below both limits. The
per-transaction cap is the tighter admission boundary: the estimate is about
3.13 times smaller than that cap.

The diagnostic is neither the configured refund allocation nor a
receipt-exact guarantee. A submitted transaction still needs an appropriate
gas-limit buffer, and the retained matrix does not bound arbitrary proof
encodings or future state-transition behavior. Network limits and gas
repricing are fork-dependent, so the mandatory post-rebase calibration must
recheck this comparison rather than copy it forward.

## Other action allocations

The release-pinned run reproduced the seven Tournament-only families. Each
measured value is three units below the preceding accepted record after the
production bytecode change; no rounded recommendation or configured allocation
changed:

| Allocation | Maximum measured | Reviewed minimum | Rounded | Configured |
| --- | ---: | ---: | ---: | ---: |
| `ADVANCE_MATCH` | 113,936 | 123,936 | 124,000 | 125,000 |
| `WIN_MATCH_BY_TIMEOUT` | 237,790 | 259,069 | 260,000 | 260,000 |
| `ELIMINATE_MATCH_BY_TIMEOUT` | 123,675 | 133,675 | 134,000 | 135,000 |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | 331,414 | 362,056 | 363,000 | 363,000 |
| `WIN_INNER_TOURNAMENT` | 306,968 | 335,165 | 336,000 | 336,000 |
| `ELIMINATE_INNER_TOURNAMENT` | 157,944 | 171,239 | 172,000 | 172,000 |
| `SEAL_LEAF_MATCH` | 94,794 | 104,794 | 105,000 | 105,000 |

The existing 1,000-unit headroom remains deliberate for `ADVANCE_MATCH` and
`ELIMINATE_MATCH_BY_TIMEOUT`. No other action allocation changed.

## Derived accounting

The new legal terminal allocations are:

| Terminal sequence | Allocation |
| --- | ---: |
| Direct timeout win | 260,000 |
| Direct timeout elimination | 135,000 |
| Sealed-leaf proof win | 4,401,000 |
| Sealed-leaf timeout win | 365,000 |
| Sealed-leaf timeout elimination | 240,000 |
| Inner-tournament win | 699,000 |
| Inner-tournament elimination | 535,000 |

The common terminal maximum increases from 948,000 to 4,401,000 units. Every
positive-height match reserve therefore increases by 3,453,000 units and every
minimum join bond increases by 0.17265 ETH at the unchanged 50-gwei work-price
cap:

| Height | Work reserve | Bond |
| ---: | ---: | ---: |
| 1 | 4,401,000 | 0.22005 ETH |
| 17 | 6,401,000 | 0.32005 ETH |
| 27 | 7,651,000 | 0.38255 ETH |
| 37 | 8,901,000 | 0.44505 ETH |
| 48 | 10,276,000 | 0.5138 ETH |
| 55 | 11,151,000 | 0.55755 ETH |

`WORK_PRICE_CAP`, `PRIORITY_FEE_CAP`, and the payment callback limit did not
change. The refund remains a bounded aid to altruistic validation, not a safety
assumption or an endogenous validator incentive.

## Validation

The accepted release-pinned calibration passed:

```text
Tournament-only gas witnesses: 18/18
full-stack leaf-proof witnesses: 12/12
total retained gas witnesses: 30/30
```

The surrounding candidate gates passed:

```text
dispute suites: 52 suites, 233 tests
refund-reserve suite: 6/6
ordinary Rollups contract suite: 4/4
PRT Forge formatting: clean
Rollups Forge formatting: clean
Lua lint: 44 files, 0 warnings, 0 errors
git diff --check: clean
```

The root `just check` gate includes the Rust node and remains deferred to the
separate node compatibility session. No Rust node source was changed while
constructing or validating this record.

## Compatibility and remaining release work

The allocation change preserves the Tournament ABI and semantic storage layout:

```text
ABI: 67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a
semantic storage: 952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329
creation bytecode without metadata: fd036e4eddd632c7862b2338da881cb482ba3316492fc31e77c5acd25ddc5e05
runtime bytecode without metadata: 0215b94127847f29f68da5795ca8b20184273552e47a6d27d06050e7e85fc5a0
```

Production bytecode and CREATE2-derived deployment addresses change.
Deployment artifacts were intentionally not regenerated on this pre-rebase
candidate. Before merge:

1. rebase after the Sling node branch lands on `next/3.0`;
2. rerun the complete calibration under the new Foundry version and record the
   new release, dependency, machine, and native-module provenance;
3. recheck the active per-transaction and block gas limits and record the
   maximum retained transaction's headroom;
4. adjust the allocation if the selected rounded recommendation changes;
5. regenerate and review deployment artifacts and derived addresses; and
6. keep the separate node compatibility repair as the branch's final commit.

No Rust node source was changed in this calibration.
