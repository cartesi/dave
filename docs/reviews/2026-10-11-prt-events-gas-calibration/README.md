# 2026-10-11 PRT events gas calibration

The event extension in cartesi/dave#297 ("feat(prt)!: publish match schedules
and tournament standing in events", after "refactor(prt): decode the clone
arguments once per call" and "refactor(prt): give each derived clock and
result value one authority") moved the gas of every refundable action.
`StandingChanged`, emitted by every match deletion, pushed both elimination
families past their reviewed margins. The refactors and the 2026-10-05
narrowing of the calldata meter to the leaf proof had left other families with
stale headroom. This single recalibration sets every allocation to its
family's maximum rounded recommendation: two go up, six come down.

The emission added branches the retained matrix did not run, since every
retained win re-paired its winner and no elimination left a claim behind.
With no match left live, it publishes the finish instant, and a non-root
tournament with a dangling survivor also reads that survivor's final state
and clock to publish its parent commitment and expiry. "test(prt): retain
the standing branches the events added" adds five witnesses that leave a
survivor dangling with no live match. Two of them, eliminations that leave a
third claim dangling in the leaf tournament, are the new
`ELIMINATE_MATCH_BY_TIMEOUT` maximum.

## Environment

- Candidate: the commit "fix(prt)!: recalibrate every allocation for the
  published events" (cartesi/dave#297), with a clean worktree (no tracked or
  untracked change). Its tree (`git rev-parse <commit>^{tree}`) is
  `94cb0c5e2c89c0a078a13c71713fdae3275f5f76`. The accepted run is at that
  commit; the commit adding this record changes only documentation.
- Forge: the official `1.5.1-v1.5.1` release (commit b0a9dd9c, maxperf) from
  the development flake: archive sha256
  `b3bf1752be066e0877911721e0624058171c88fc5616e228937fe4620b41c40d`, forge
  binary sha256
  `051dc63dd492b3eb85a8d4fecafd4b0701ad9b2b2ece92237e9ceee3f589ad5c`, both
  equal to the 2026-10-02 record's.
- Effective config: solc 0.8.30, via-ir, optimizer 200 runs, Prague EVM
  (both projects). Configuration and lockfile sha256: rollups contracts
  `foundry.toml` `e093fa1bf79273998e318fe8a3d4b5b308fbebb375e995cfc1741d305de13de7`,
  `soldeer.lock` `dd59cb3997b8acb0310c9157de3b61d8e65ebe2c3c727ac29661ffd2fae889b2`;
  PRT contracts `foundry.toml`
  `41e2524df1b198ff8cdf3df07bda2437759887da50c3ee34fc560cd0570a3aa7`,
  `soldeer.lock` `fdd646e1cc6cd5d2308d22c0f97fabc1f6df4c72ec14703e918a78fe8b1a2f53`.
- Dependencies sha256 (both projects' trees)
  `5908c611e27574eacfc14cf431a0c77ab096f3b60d9b874ff2306bff08943d90`, the
  pin, unchanged since the 2026-10-02 record. As then, the stale untracked
  alpha-6 and alpha-9 rollups-contracts directories that soldeer had left in
  `cartesi-rollups/contracts/dependencies` were moved out of the tree before
  the run; nothing needed them back.
- `machine/step` at 23765c88 (v0.15.0); `machine/emulator` and
  `machine/step/lib/forge-std` not checked out (the development shell
  provides the emulator). Yield machine hash
  `9b358eac8ebd2aa2c7ab4c00d098da7fd90906dc571ec83ec16e889fd220e0fb`;
  cartesi-machine 0.21.0; Lua 5.4.7; native `cartesi` Lua module sha256
  `33950bea57e6a1b22b012ea75369eb9a5d8cb0dbf061cd793c2529c8918ecf19`.
- macOS (Darwin 25.6.0), arm64.

## Envelope

- Tournament witnesses: two levels, root `log2step` 39 at height 55 and leaf
  `log2step` 0 at height 39, response budget 300, maximum allowance
  1,000,000, no commitment budget. Each height is at least its canonical
  (`[38, 0]` / `[54, 38]`) one. Merkle proofs are full length for those
  heights.
- Leaf proofs: the full `Tournament.winLeafMatch -> CartesiStateTransition
  -> DaveConsensus -> InputBox` path on the yield machine. The largest input
  is the maximum canonical InputBox payload (65,216 bytes, 65,508 encoded;
  65,540 encoded bytes are rejected), whose proof is 93,964 bytes in 94,180
  calldata bytes. Classes as in the runbook: ordinary step, reset, revert,
  small, representative and maximum inputs, the out-of-range fixpoint.
- Tournament states: both winner orientations, nonzero positions, dangling
  re-pairing, and now a survivor left dangling with no live match, in the
  non-root leaf tournament and, for inner wins, in the root.
- Outside it: the three-level test table that CI and the local devnet use
  (`[44, 27, 0]` / `[48, 17, 27]`). Its middle tournament is non-root and
  non-leaf, so an inner-tournament action there can take the non-root
  standing branch, which no witness runs. A lead, not measured: with the
  4,872 units that leaving a claim dangling adds to the sealed-leaf
  elimination, an inner elimination there that leaves a claim dangling
  would measure about 153,000 units, inside the 161,000 allocation but
  beyond its reviewed margin.

## Measurements and selection

Units are read from the production `PartialBondRefund` event at gas price
one; the margin is `max(10,000, ceil((units - Gas.TX) / 10))`, and the
recommendation rounds `units + margin` up to a thousand. Each allocation
adopts its family's maximum recommendation exactly:

| Allocation | Selecting witness | Reviewed | Old | New | Rounding |
| --- | --- | --- | --- | --- | --- |
| `ADVANCE_MATCH` | advance match | 123,219 | 128,000 | 124,000 | 781 |
| `WIN_MATCH_BY_TIMEOUT` | sealed leaf two wins timeout | 260,298 | 263,000 | 261,000 | 702 |
| `ELIMINATE_MATCH_BY_TIMEOUT` | active leaf timeout elimination leaves dangling | 143,699 | 135,000 | 144,000 | 301 |
| `SEAL_LEAF_MATCH` | seal leaf match | 128,340 | 152,000 | 129,000 | 660 |
| `SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT` | seal inner match | 357,139 | 392,000 | 358,000 | 861 |
| `WIN_INNER_TOURNAMENT` | inner two wins | 292,867 | 298,000 | 293,000 | 133 |
| `ELIMINATE_INNER_TOURNAMENT` | inner elimination | 160,622 | 160,000 | 161,000 | 378 |
| `WIN_LEAF_MATCH` | maximum input two wins | 5,535,019 | 5,543,000 | 5,536,000 | 981 |

No headroom is retained beyond rounding. The six families that come down
carried headroom that later changes left behind; keeping it would only avoid
bytecode churn, and the bytecode changes anyway. The seals drop most (23,000
and 34,000), nearly all of it calldata: their 2026-10-02 allocations counted
every calldata byte, and the 2026-10-05 amendment stopped metering any but
the leaf proof's.

`ELIMINATE_MATCH_BY_TIMEOUT` rises by 9,000. The eliminations that leave
nothing behind gained about 4,800 units from the event extension and need
139,000 and 138,000. Leaving a claim dangling in the non-root leaf
tournament adds 4,805 and 4,872 units, mostly two cold reads (the active
pair also moves from the root to the leaf tournament), and that shape
selects. Neither raised family enters a bond: the timeout terminal stays
`WIN_MATCH_BY_TIMEOUT` and the inner terminal `WIN_INNER_TOURNAMENT`.

Every retained witness, with the new allocation's headroom over its reviewed
minimum (new witnesses marked):

| Witness | Units | Margin | Reviewed | Recommendation | Headroom |
| --- | --- | --- | --- | --- | --- |
| **`ADVANCE_MATCH`** (128,000 -> 124,000) | | | | | |
| advance match | 113,219 | 10,000 | 123,219 | 124,000 | 781 |
| advance match left | 93,055 | 10,000 | 103,055 | 104,000 | 20,945 |
| **`WIN_MATCH_BY_TIMEOUT`** (263,000 -> 261,000) | | | | | |
| sealed leaf two wins timeout | 238,907 | 21,391 | 260,298 | 261,000 | 702 |
| sealed leaf one wins timeout | 238,774 | 21,378 | 260,152 | 261,000 | 848 |
| active two wins timeout | 235,751 | 21,076 | 256,827 | 257,000 | 4,173 |
| active one wins timeout | 235,618 | 21,062 | 256,680 | 257,000 | 4,320 |
| sealed leaf two wins timeout unpaired (new) | 151,120 | 12,612 | 163,732 | 164,000 | 97,268 |
| **`ELIMINATE_MATCH_BY_TIMEOUT`** (135,000 -> 144,000) | | | | | |
| active leaf timeout elimination leaves dangling (new) | 132,908 | 10,791 | 143,699 | 144,000 | 301 |
| sealed leaf long deadline elimination leaves dangling (new) | 132,547 | 10,755 | 143,302 | 144,000 | 698 |
| active advanced timeout elimination | 128,103 | 10,311 | 138,414 | 139,000 | 5,586 |
| sealed leaf long deadline elimination | 127,675 | 10,268 | 137,943 | 138,000 | 6,057 |
| **`SEAL_LEAF_MATCH`** (152,000 -> 129,000) | | | | | |
| seal leaf match | 118,340 | 10,000 | 128,340 | 129,000 | 660 |
| seal leaf match left | 103,954 | 10,000 | 113,954 | 114,000 | 15,046 |
| **`SEAL_INNER_MATCH_AND_CREATE_INNER_TOURNAMENT`** (392,000 -> 358,000) | | | | | |
| seal inner match | 326,944 | 30,195 | 357,139 | 358,000 | 861 |
| seal inner match left | 312,558 | 28,756 | 341,314 | 342,000 | 16,686 |
| **`WIN_INNER_TOURNAMENT`** (298,000 -> 293,000) | | | | | |
| inner two wins | 268,515 | 24,352 | 292,867 | 293,000 | 133 |
| inner one wins | 268,286 | 24,329 | 292,615 | 293,000 | 385 |
| inner single-claim two wins | 265,707 | 24,071 | 289,778 | 290,000 | 3,222 |
| inner two wins unpaired (new) | 177,978 | 15,298 | 193,276 | 194,000 | 99,724 |
| **`ELIMINATE_INNER_TOURNAMENT`** (160,000 -> 161,000) | | | | | |
| inner elimination | 148,292 | 12,330 | 160,622 | 161,000 | 378 |
| inner single-claim elimination | 148,288 | 12,329 | 160,617 | 161,000 | 383 |
| inner no-winner elimination | 145,536 | 12,054 | 157,590 | 158,000 | 3,410 |
| **`WIN_LEAF_MATCH`** (5,543,000 -> 5,536,000) | | | | | |
| maximum input two wins | 5,034,108 | 500,911 | 5,535,019 | 5,536,000 | 981 |
| maximum input one wins | 5,034,017 | 500,902 | 5,534,919 | 5,535,000 | 1,081 |
| representative input one wins | 2,116,186 | 209,119 | 2,325,305 | 2,326,000 | 3,210,695 |
| small input two wins | 1,925,587 | 190,059 | 2,115,646 | 2,116,000 | 3,420,354 |
| small input one wins | 1,925,496 | 190,050 | 2,115,546 | 2,116,000 | 3,420,454 |
| out of range input one wins | 958,245 | 93,325 | 1,051,570 | 1,052,000 | 4,484,430 |
| ordinary step two wins | 949,644 | 92,465 | 1,042,109 | 1,043,000 | 4,493,891 |
| ordinary step one wins | 949,553 | 92,456 | 1,042,009 | 1,043,000 | 4,493,991 |
| ordinary step two wins unpaired (new) | 862,005 | 83,701 | 945,706 | 946,000 | 4,590,294 |
| revert two wins | 732,700 | 70,770 | 803,470 | 804,000 | 4,732,530 |
| revert one wins | 732,609 | 70,761 | 803,370 | 804,000 | 4,732,630 |
| reset two wins | 651,567 | 62,657 | 714,224 | 715,000 | 4,821,776 |
| reset one wins | 651,476 | 62,648 | 714,124 | 715,000 | 4,821,876 |

The active dangling elimination leaves a claim committed to the first
contested final state, the shorter parent-commitment lookup; the sealed one
takes the longer lookup and still measures less. The lookup differs by a
comparison, well inside the 301 units of rounding.

The maximum-input leaf witness measures 6,640 units below the 2026-10-02
record's 5,040,748: the 2026-10-05 amendment stopped metering its non-proof
calldata, and the decode-once refactor saved more than the new emissions
cost. Its whole-transaction estimate is 3,188 units lower.

## Propagation

- Terminal maxima (`Bond.terminalAllocation`): leaf 5,695,000 -> 5,665,000;
  non-leaf 690,000 -> 651,000.
- Leaf action refund cap: 0.27715 -> 0.2768 ether at the unchanged 50 gwei
  work-price cap.
- Work reserves and join bonds (`RefundReserve.t.sol` policy checkpoint):

  | Height, role | Table | Old reserve | New reserve | Old bond | New bond |
  | --- | --- | --- | --- | --- | --- |
  | 54, non-leaf | canonical root | 7,474,000 | 7,223,000 | 0.3737 ether | 0.36115 ether |
  | 38, leaf | canonical leaf | 10,431,000 | 10,253,000 | 0.52155 ether | 0.51265 ether |
  | 48, non-leaf | test-table root | 6,706,000 | 6,479,000 | 0.3353 ether | 0.32395 ether |
  | 17, non-leaf | test-table middle | 2,738,000 | 2,635,000 | 0.1369 ether | 0.13175 ether |
  | 27, leaf | test-table leaf | 9,023,000 | 8,889,000 | 0.45115 ether | 0.44445 ether |

- The node README's funding floor, root bond plus two leaf bonds plus the
  padded leaf proof and 1M at 200 gwei, is `0.36115 + 2 x 0.51265 +
  (7.61M + 1M) x 200 gwei`, still about 3.1 ETH.
- The CHANGELOG, the accounting doc's terminal maxima, the audit-readiness
  notes and the dated admission evidence in the runbook and the dispute-game
  doc follow.
- No economic policy constant changed: `WORK_PRICE_CAP` 50 gwei,
  `REFUND_PRIORITY_FEE_CAP` 10 gwei, `PAYMENT_CALLBACK_GAS_LIMIT` 50,000,
  `Gas.TX` 25,000 and `Gas.CALLDATA_BYTE` 16.
- Compatibility (`just prt-contracts::compatibility-hashes`, first 8 hex
  digits, before -> after the constants): the wire ABI and semantic storage
  layout of `Tournament` (`b7eb730a`, `c01aeacb`) and of
  `MultiLevelTournamentFactory` (`74ac8c3d`, `1a715ed0`) are unchanged.
  Every bytecode fingerprint moves: `Tournament` metadata-free creation
  `ac6ddaaa -> 3547c749` and runtime `68d5521c -> 3c4e7c81`; the factory,
  which projects the child's bond, metadata-free creation
  `a9f174df -> 495436e2` and runtime `6bced69f -> 2d7ad73f`; and all four
  metadata-included fingerprints.
- Deployment artifacts were not regenerated here. Every CREATE2 address
  built from these contracts moves; the release regenerates the deployment
  artifacts and the published addresses.

## Network admission

The largest whole-transaction diagnostic is the maximum-input two-wins
Prague estimate, 5,076,415 units (complete call 3,558,135 plus intrinsic and
calldata). The standard calldata price binds over the EIP-7623 floor
(3,764,200).

- Against Ethereum Mainnet's EIP-7825 cap of 16,777,216 units (the protocol
  constant; the cap itself was not probed): 30.26%, leaving 11,700,801.
- Against the block gas limit: Ethereum block 26,171,128 at
  `2026-10-11T18:53:11Z`, hash
  `0x2cfc63a2172e251e060be2a65be20a1b4b52eb45d0aab3873f27daab3ffb2f16`, had a
  60,000,000 gas limit and used 59,396,371. PublicNode and Flashbots
  returned the same block. The witness uses 8.46% of that limit and leaves
  54,923,585.
- The node pads that estimate to 7,614,622, below the cap; a retained
  maximum loses headroom under the cap only above about 11.18M.

These are dated observations, not permanent limits.

## Validation

- `just test-prt-gas`: 22 Tournament and 13 leaf witnesses pass (18 and 12
  before the five new ones).
- `just prt-contracts::test-disputes`: 360 passed, including the reserve
  checkpoint (`RefundReserve.t.sol`, 11), the exact refund formula
  (`RefundFormula.t.sol`, 4) and the callbacks and per-clone lock
  (`RefundCallbacks.t.sol`, 12).
- `just rollups-contracts::test`: 14 passed. `just prt-contracts::test-stf`:
  29 passed.
- Both projects' `check-fmt`.
- Logs are kept outside the repository
  (zMisc/prt-events-2026-10-10/gas/logs).

## Acceptance

Accepted: `just measure-prt-gas` on the clean candidate (Environment) under
the release Forge, with no diagnostic override, exits 0 with no warning; all
35 witnesses pass. Every one of its 244 reported values, the complete-call
and transaction diagnostics included, equals the diagnostic run's on the
uncommitted candidate.
