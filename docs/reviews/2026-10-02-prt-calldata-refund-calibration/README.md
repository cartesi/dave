# 2026-10-02 PRT calldata refund calibration

Refunded units now count the action's calldata:
`units = Gas.TX + Gas.CALLDATA_BYTE * msg.data.length + delta`, with
`CALLDATA_BYTE = 16` (the EIP-2028 nonzero-byte rate). Before this change the
maximum-input leaf proof (94,180 calldata bytes) left about 1.5M units of its
own cost unrefunded, the largest cost an honest prover cannot avoid. Every
allocation was remeasured, and the witnesses became one-sided: each asserts
its reviewed minimum fits the allocation, and the exact-recommendation pins
and their retained-headroom constants are gone. This calibration also
discharges the one owed since 2c502f63 and 935dc133.

## Environment

- Candidate: the commit that adds this record, on top of 4b72c0ea. The
  accepted run is at 6d5caebb, whose contracts, `machine/step` and
  dependencies are unchanged since that commit.
- Forge: the measurements were first taken with a nixpkgs `1.5.1-dev`
  source build, which the guard treats as diagnostic. The accepted run used
  the official `1.5.1-v1.5.1` release (commit b0a9dd9c, maxperf), now what
  the development flake provides: archive sha256
  `b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d`, forge
  binary sha256
  `051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c`, both
  equal to the 2026-08-16 record's.
- Effective config: solc 0.8.30, via-ir, optimizer 200 runs, Prague EVM
  (both projects).
- PRT dependencies sha256
  `ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3`
  (matches the pin). Leaf-gate dependencies sha256 (both projects' trees)
  `5908c611e27574eacfc14cf431a0c77ab096f3b60d9b874ff2306bff08943d90`, with
  rollups-contracts alpha 10; the pin had not moved since alpha 9 and is
  re-pinned here. The digest covers everything under `dependencies/`, and
  soldeer leaves earlier versions behind on a bump, so the stale alpha-6 and
  alpha-9 directories were moved aside first.
- `machine/step` at 23765c88 (v0.15.0); yield machine hash
  `9b358eac8ebd2aa2c7ab4c00d098da7fd90906dc571ec83ec16e889fd220e0fb`;
  cartesi-machine 0.21.0.
- macOS (Darwin 25.6.0), aarch64.

## Measurements and selection

Per family, the largest witness (units read from the production event at gas
price one) and the selection, which adopts the maximum rounded
recommendation exactly:

| Allocation | Largest witness | Units | Recommendation | Old | New |
| --- | --- | --- | --- | --- | --- |
| `ADVANCE_MATCH` | right advance | 117,846 | 128,000 | 127,000 | 128,000 |
| `WIN_MATCH_BY_TIMEOUT` | sealed-leaf two wins | 241,058 | 263,000 | 262,000 | 263,000 |
| `ELIMINATE_MATCH_BY_TIMEOUT` | active equality | 124,364 | 135,000 | 135,000 | 135,000 |
| `SEAL_LEAF_MATCH` | position one | 140,430 | 152,000 | 130,000 | 152,000 |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | position one | 358,120 | 392,000 | 363,000 | 392,000 |
| `WIN_INNER_TOURNAMENT` | resolved two wins | 273,056 | 298,000 | 338,000 | 298,000 |
| `ELIMINATE_INNER_TOURNAMENT` | expired winner | 146,976 | 160,000 | 172,000 | 160,000 |
| `WIN_LEAF_MATCH` | maximum input two wins | 5,040,748 | 5,543,000 | 3,885,000 | 5,543,000 |

The seals and the leaf proof grow the most because they carry proofs in
calldata. `WIN_INNER_TOURNAMENT` and `ELIMINATE_INNER_TOURNAMENT` drop: they
had carried 41,000 and 13,000 units of retained headroom, which only avoided
bytecode churn, and the bytecode changes anyway. Without its calldata charge
(`16 * 94,180 = 1,506,880`) the maximum-input leaf witness is 3,533,868
units, 626 above the 2026-08-27 record's 3,533,242.

Other leaf witnesses (rounded recommendations): representative input
2,333,000; small input 2,123,000; out-of-range 1,059,000; ordinary step
1,049,000; revert 811,000; reset 721,000.

## Propagation

- Terminal maxima: leaf 4,015,000 -> 5,695,000; non-leaf 701,000 ->
  690,000.
- Leaf action refund cap: 0.19425 -> 0.27715 ether at the unchanged 50 gwei
  work-price cap.
- Work reserves and join bonds (`RefundReserve.t.sol` policy checkpoint):

  | Height, role | Old reserve | New reserve | New bond |
  | --- | --- | --- | --- |
  | 17, non-leaf | 2,733,000 | 2,738,000 | 0.1369 ether |
  | 48, non-leaf | 6,670,000 | 6,706,000 | 0.3353 ether |
  | 55, non-leaf | 7,559,000 | 7,602,000 | 0.3801 ether |
  | 27, leaf | 7,317,000 | 9,023,000 | 0.45115 ether |
  | 37, leaf | 8,587,000 | 10,303,000 | 0.51515 ether |

- Compatibility: Tournament wire ABI and storage layout unchanged; Tournament
  creation and runtime bytecode changed; the factory's metadata-free
  bytecode is unchanged and only its metadata hash moved. Deployment
  artifacts and CREATE2-derived addresses must be regenerated before release.
  No economic policy constant changed.

## Padding

Padding calldata with cheap bytes (4 units each, or 10 under the EIP-7623
floor) now earns 16 each, so a caller can lift an action's refund up to its
allocation. The reserve argument in `prt-refund-accounting.md` already
charges every action at its allocation, so the winner's reserve holds. What
moves is who receives the losing reserves: refunds instead of bounty and
burn, which the accounting already permits.

## Network admission

The largest whole-transaction diagnostic is the maximum-input two-wins Prague
estimate, 5,079,603 units (complete call 3,561,323 plus intrinsic and
calldata). Against Ethereum Mainnet's EIP-7825 cap of 16,777,216 units that
is 30.28%. The standard calldata price binds over the EIP-7623 floor
(3,764,200) for that witness, so the 16-unit rate covers its calldata. The
block gas limit was not re-queried.

## Validation

- `just test-prt-gas`: 18 Tournament and 12 leaf witnesses pass.
- `just prt-contracts::test-disputes`: 319 passed, including the new
  `testCalldataIsRefundedPerByte`, which pads 1,000 bytes and expects exactly
  16,000 more units.
- `just rollups-contracts::test`: 14 passed.
- Both projects' `check-fmt`.
- Logs are kept outside the repository (zMisc/gas-calldata).

## Acceptance

Accepted: `just measure-prt-gas` on the clean tree at 6d5caebb under the
release Forge, with no diagnostic override, exits 0 with no warning; all 30
witnesses pass. Every one of its 186 reported values, including the
complete-call diagnostics, equals the source build's.
