# PRT timeout alignment

Status: OPEN (2026-07-23). The contract change is being reviewed independently
from the off-chain clients and gas calibration. Do not deploy or release this
contract behavior until the Rust and Lua clients and the gas witnesses pass the
alignment gates below.

## Contract rule to mirror

`MatchClocks.classifyTimeoutAt` is the source of truth for one observed block:

| legal phase | clock state | outcome |
| --- | --- | --- |
| active bisection | neither expired | `NONE` |
| active bisection | responder expired | paused opponent wins only if its remainder is greater than the responder's overdue duration; otherwise `ELIMINATE_BOTH` |
| sealed leaf | neither expired | `NONE` |
| sealed leaf | exactly one expired | the other commitment wins with zero deferred charge |
| sealed leaf | both expired | `ELIMINATE_BOTH` |
| sealed inner | both paused | `NONE` |

A leaf proof is valid only under `NONE`. Once either leaf clock expires, the
client must choose `winMatchByTimeout` for a single winner or
`eliminateMatchByTimeout` for `ELIMINATE_BOTH`. It must not submit a proof and a
timeout verb for the same observation.

The phase distinction prevents one censorship interval from being charged
twice. A running leaf survivor has already lost the elapsed interval from its
live remainder. A paused bisection survivor has not, so it receives the
responder's overdue interval as a deferred charge to subtract.

## Known stale consumers

- `cartesi-rollups/node/src/tournament/types.rs::classify_timeout` applies the
  paused-winner overdue comparison to every phase. It must classify from both
  remaining time and running/paused state.
- `cartesi-rollups/node/src/hero/mod.rs` currently attempts timeout handling and
  then continues into sealed-leaf proof handling from the same folded snapshot.
  It must select exactly one resolution verb.
- `cartesi-rollups/node/src/hero/gc.rs` must share the corrected classifier so
  it does not eliminate a sealed leaf before the longer deadline.
- `prt/client-lua/player/strategy.lua` contains the same unconditional
  `remaining > time_since_timeout` comparison and then falls through to proof
  resolution. It needs the same phase-aware, single-verb policy.

No off-chain source is changed by the contract commit. This file is the handoff
for the node and Lua workstreams.

## Deferred gas calibration

The contract change deliberately does not edit
`prt/contracts/test/gas/TournamentGas.t.sol`. Three witnesses there retain the
superseded sealed-leaf policy:

- the two timeout-winner witnesses expect the running survivor to pay elapsed
  time twice; and
- the elimination witness resolves at the former midpoint instead of the
  longer clock's deadline.

Update those scenarios in a separate gas-calibration pass following
[`prt-refund-gas-calibration.md`](../runbooks/prt-refund-gas-calibration.md).
Re-measure the supported paths before deciding whether any `Gas` allocation
changes. Do not treat a semantic witness rewrite as calibration evidence.

## Completion gates

1. Mirror the full phase table in independent Rust and Lua tests, including
   both commitment orientations and exact shorter and longer leaf deadlines.
2. Prove at the strategy level that one observed match produces at most one of
   proof, timeout victory, or double elimination.
3. Run an end-to-end leaf dispute where the shorter clock expires first and the
   correct longer clock wins after the former midpoint boundary.
4. Run an end-to-end leaf dispute through the longer deadline and observe
   double elimination.
5. Align and re-measure the three sealed-leaf gas witnesses under the pinned
   release toolchain.
6. Remove or close this plan only after the contract, Rust node, Lua client, and
   gas witnesses agree on the table.
