# PRT timeout alignment

Status: COMPLETE (updated 2026-07-25). The contract semantics, semantic
observer, Rust and Lua strategy migration, gas calibration, and exact
sealed-leaf end-to-end boundaries agree.

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

## Client resolution

The client-interface campaign removed timeout classification from both acting
clients instead of teaching each one a corrected clock algorithm:

- `ITournament.classifyMatchTimeout` calls
  `MatchClocks.classifyTimeoutAt` for the pinned observation block;
- the Rust and Lua adapters convert its tagged outcome into a semantic
  `TimeoutDisposition`;
- the pure Hero planners select one proof, timeout, wait, or cleanup intent
  from that disposition; and
- the old Rust classifier remains only in focused legacy differential tests.

This is stronger than mirroring the table in two clients: there is one
contract-local authority and two independently implemented strict consumers.

## Contract gas calibration

The three sealed-leaf witnesses now follow the phase-aware timeout policy. The
complete 18-witness matrix was remeasured under the release-pinned toolchain
after the Match readability refactor. No production allocation changed; the
accepted evidence is
[`2026-07-23-prt-timeout-gas-calibration`](../reviews/2026-07-23-prt-timeout-gas-calibration/).

## End-to-end boundary evidence

The `test-prt-timeout-boundaries` recipe creates unequal leaf clocks from one
measured sealing response. It reads `matchEffort` and both pre-seal clocks from
the deployed contracts, stops the Rust node, drains commitment one's clock by a
computed amount, and seals the leaf at one common start block. The harness
therefore controls the deadline gap without depending on host scheduling or
hard-coded clock parameters.

The 2026-07-25 acceptance runs observed:

- `sealed_leaf_timeout_winner`: seal 674, shorter deadline 888, former
  classifier boundary 928, timeout victory for commitment two at 930, and
  longer deadline 968; and
- `sealed_leaf_timeout_both`: seal 674, shorter deadline 888, longer deadline
  968, `TWO_WINS` at 967, `ELIMINATE_BOTH` at exactly 968, and
  `TIMEOUT/NONE` deletion at 969.

Both scenarios use the real Rust node after respawn and assert the durable
`MatchDeleted` reason, winner, participants, and cleared match storage. Run
them together with:

```sh
just test-prt-timeout-boundaries
```

## Completion gates

1. COMPLETE: exercise the full phase table at the observer boundary, including
   both commitment orientations and exact shorter and longer leaf deadlines,
   and reject inconsistent Rust and Lua adapter shapes.
2. COMPLETE: prove in both pure planners that one observed match produces at
   most one of proof, timeout victory, or double elimination.
3. COMPLETE: run an end-to-end leaf dispute where the shorter clock expires
   first and the correct longer clock wins after the former midpoint boundary.
4. COMPLETE: run an end-to-end leaf dispute through the longer deadline and
   observe double elimination.
5. COMPLETE: align the three sealed-leaf semantic witnesses and re-measure the
   complete gas matrix under the pinned release toolchain.
6. COMPLETE: close this plan after the contract, Rust node, Lua client, and gas
   witnesses agree on the table.
