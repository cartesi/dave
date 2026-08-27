# 2026-08-27 PRT leaf gas recalibration

Recalibration of `Gas.WIN_LEAF_MATCH` after the exact-relationship
maximum-input witnesses began failing: the retained `4_420_000` selection
predated the machine-yield check (53c4c424) and the alpha-9
rollups-contracts bump (98f355f7), which together made the maximum-input
leaf-proof path cheaper. The reproducible leaf gate's dependency-digest pin
had also not been updated for alpha 9 and rejected every correctly restored
checkout; it was re-pinned first (f3f49968) from a pristine `soldeer.lock`
restore reproduced by wipe-and-reinstall.

## Environment

- Accepted candidate: `021b5ae929f9bb7a23ede383d02afe53bd827c0e`, clean
  worktree, `just measure-prt-gas` exit 0.
- Forge: official release `1.5.1-v1.5.1` (commit b0a9dd9c, maxperf), now
  provided by the development flake as the official release binaries; the
  previous nixpkgs source build reported `1.5.1-dev` and is rejected by the
  measurement guard.
- Effective config: solc 0.8.30, via-ir, optimizer 200 runs, Prague EVM
  (both projects).
- PRT dependencies sha256
  `ef44ca028e8ae45ab0d7a6b183c9db0fded37461db8355456f2b2b876ce57ac3`;
  rollups dependencies sha256
  `0390394d7559329a94913a96b298a798c16fb03446600ca746760d5942ae6f4d`
  (alpha-9 tree).
- `machine/step` at 23765c88 (v0.15.0); yield machine hash
  `9b358eac8ebd2aa2c7ab4c00d098da7fd90906dc571ec83ec16e889fd220e0fb`.
- macOS (Darwin 25.5.0), aarch64.

## Measurements and selection

Maximum-input full-stack leaf-win witnesses (the reference path):

| Witness | Reviewed minimum | Rounded recommendation |
| --- | --- | --- |
| maximum input two wins (selected) | 3,884,067 | 3,885,000 |
| maximum input one wins (alternate) | 3,883,969 | 3,884,000 |

Selection: `WIN_LEAF_MATCH = 3_885_000`, adopting the maximum rounded
recommendation exactly with zero retained headroom. The two winner
orientations now straddle a 1,000-unit rounding boundary; the selected
two-winning witness asserts the exact recommendation and the one-winning
alternate records its 1,000-unit slack explicitly
(`WIN_LEAF_MATCH_ALTERNATE_HEADROOM`).

Other retained leaf witnesses (rounded recommendations): representative
input 1,748,000; small input well below; revert 613,000; reset 558,000;
out-of-range 818,000; ordinary step 809,000. Every Tournament-only action
family's recommendation stayed at or below its configured allocation
(largest deltas: advance match 125,000 vs 127,000 configured; timeout win
260,000 vs 262,000), so no other constant moved.

## Propagation

- Leaf terminal allocation: 4,550,000 -> 4,015,000; non-leaf terminal
  unchanged at 701,000.
- Leaf action refund cap: 0.221 -> 0.19425 ether at the 50 gwei work-price
  cap (policy constants unchanged).
- Leaf work reserves and join bonds shrink accordingly, for example
  `matchWorkAllocation(27, true)` 7,852,000 -> 7,317,000 (bond 0.3926 ->
  0.36585 ether) and `matchWorkAllocation(37, true)` 9,122,000 ->
  8,587,000 (bond 0.4561 -> 0.42935 ether). Non-leaf rows unchanged.
- Constants-only change: wire ABI and storage layout unchanged; Tournament
  bytecode and deployment identity change, so deployment artifacts and
  CREATE2-derived addresses must be regenerated before release.

## Network admission headroom

Largest retained whole-transaction diagnostic: 3,560,586 units (maximum
input two wins), down from the 2026-07-23 record's 5,359,940. Against
Ethereum Mainnet's EIP-7825 transaction cap of 16,777,216 units this is
21.2%; against the observed 60,000,000 block gas limit, 5.9%. Dated
evidence, not a permanent constant.

## Validation

`just measure-prt-gas` (acceptance, exit 0), `just test-prt-gas` (18 + 12
witnesses), formatting gates, and the disputes, rollups, and workspace
suites run in the same session on the candidate line. Witness assertions
pin the exact selection and the recorded alternate slack; reserve algebra
pins in `RefundReserve.t.sol` were recomputed for the leaf role.
