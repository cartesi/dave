# PRT timeout alignment

Status: OPEN (updated 2026-07-23). The contract semantics and gas calibration
are complete. Do not deploy or release this behavior until the Rust and Lua
clients and the end-to-end scenarios pass the remaining alignment gates below.

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

## Contract gas calibration

The three sealed-leaf witnesses now follow the phase-aware timeout policy. The
complete 18-witness matrix was remeasured under the release-pinned toolchain
after the Match readability refactor. No production allocation changed; the
accepted evidence is
[`2026-07-23-prt-timeout-gas-calibration`](../reviews/2026-07-23-prt-timeout-gas-calibration/).

## Completion gates

1. Mirror the full phase table in independent Rust and Lua tests, including
   both commitment orientations and exact shorter and longer leaf deadlines.
2. Prove at the strategy level that one observed match produces at most one of
   proof, timeout victory, or double elimination.
3. Run an end-to-end leaf dispute where the shorter clock expires first and the
   correct longer clock wins after the former midpoint boundary.
4. Run an end-to-end leaf dispute through the longer deadline and observe
   double elimination.
5. COMPLETE: align the three sealed-leaf semantic witnesses and re-measure the
   complete gas matrix under the pinned release toolchain.
6. Remove or close this plan only after the contract, Rust node, Lua client, and
   gas witnesses agree on the table.
