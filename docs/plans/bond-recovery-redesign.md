# Bond recovery redesign

Status: CONTRACTS IMPLEMENTED 2026-08-04 on the interface branch, and
COMPLETED 2026-08-05 with the `bondRecovery` capability view and
`BondRecovered` event; the node-side recovery action is owned by the
[self-healing transaction lane](self-healing-batch-submission.md). Its
finalized-snapshot and low-priority cadence were tightened on 2026-08-08.

## Motivation

The most critical findings of the 2026-07 hardening pass (the
tournament-bricking exploits fixed and merged in
[PR #273](https://github.com/cartesi/dave/pull/273)) all arose from the
system attempting to move bond value automatically inside other flows:
recipient callbacks on the action path and best-effort terminal recovery
invoked from result staging. The fixes bound and isolate those calls, but
the class of bug survives as long as value transfer rides on unrelated
progress paths.

## Direction (implemented contract-side)

1. Bonds are never recovered automatically. `DaveConsensus` result
   staging stores the result and nothing else; `tryRecoveringBond` is an
   explicit, permissionless call. No value-moving call remains on any
   progress or settlement path.
2. Terminal economics: the winner payment is
   `min(balance, bond + (balance - bond) / 10)` - one bond back plus a
   one-tenth bounty on the forfeited residual, rounded toward the burn;
   the other nine tenths burn. In undisputed operation the balance is
   exactly one bond and the bounty is zero. The anti-recycling argument
   survives with a 0.9 factor: an attacker in the claimer slot recovers
   at most a tenth of the reserves it forfeited
   (docs/prt-refund-accounting.md restates conservation;
   docs/dispute-game.md restates the recycling bound).

## The recovery interface (added 2026-08-05)

`tryRecoveringBond` was the one mutator left without a capability-view
twin, so its consumer would have re-derived the gate from three
sources (standing arm, joined-commitment inference, balance) with the
claimer unobservable. The `bondRecovery()` view closes that asymmetry
under the established doctrine (one shared classification drives the
view and the mutation, as with timeouts): it returns
`(BondDisposition, claimer, payment)` where `TOURNAMENT_RUNNING` and
`NO_WINNER` are the mutator's revert arms, `RECOVERED` its no-op arm,
and `RECOVERABLE` its payment arm. The `BondRecovered` event completes
the economics surface next to `PartialBondRefund`, giving terminal
recovery a first-class observability signal.

## Node-side work (implemented; lowest-priority lane work)

- Recovery uses the same exclusive signer lane, but never rides a dispute or
  settlement wave's tail. A pending low-priority nonce cannot then become the
  next tick's head and obstruct a newly urgent dispute action. The planner is
  stateless over chain reads:
  - Candidates by provenance, never by search. The node can only hold
    bonds in tournaments it participated in, and those all live inside
    dispute trees rooted at epochs recorded in its own database (from
    the trusted DaveConsensus stream). The planner walks each
    unretired epoch's tree root-down through each trusted tournament's
    own `NewInnerTournament` events through one sampled finalized head, so
    every candidate address descends from trust by construction.
  - Capability and completion use that same finalized hash. One
    `bondRecovery()` read per tree node identifies the first
    `RECOVERABLE && claimer == us` candidate and whether the complete tree is
    terminal. A single latest-pinned read of that candidate may suppress a
    recovery already mined, but latest state never retires a tournament or
    epoch. The claimer answers "did
    we join and win" from the contract's own records, so the planner
    needs no join history.
  - Completion: `RECOVERED` retires a tournament, whoever triggered
    the recovery; an epoch retires when its whole tree is terminal.
    The retired-epoch set is the planner's only state, in memory,
    rebuilt by a boot re-walk. Self-healing throughout.
  - Cadence: scan only when higher-priority work is absent and the finalized
    head has advanced; plan at most one recovery. If urgent work postpones a
    due scan, the cadence remains due. A Latest epoch newer than finalized
    storage is also a fence, reserving the lane for the next join. Every sealed
    epoch remains discoverable after rotation, so no persistent recovery queue
    is required.
  - REJECTED alternative, recorded for its lesson: a chain-wide
    `CommitmentJoined` log scan filtered by the indexed submitter,
    with candidates verified as genuine clones by ERC-1167 prelude
    comparison before any send. The verification argument held under
    audit, but the posture is wrong: it admits an attacker-writable
    candidate set (anyone can emit a matching event naming our
    signer, and paying a spoofed candidate would burn the gas limit
    every tick) and then makes a filter's correctness load-bearing
    forever. A candidate set derived from the node's own knowledge
    needs no filter, and the whole verification machinery deletes.
- No config flag: recovering for a stranger pays their bounty with our
  gas, and recovery stays permissionless for anyone who disagrees.
- No gas-kickback subsidy for recovery, and no bond-math entry for it:
  the refund subsidy exists to motivate permissionless progress work,
  while recovery is self-interested by construction (the recovered bond
  dwarfs its gas). Keeping it outside the `refundable` seam also avoids
  circular accounting - the subsidy would be paid from the very balance
  recovery is settling.
- The multi-sybil e2e waits for the node's own planner to drain the terminal
  tournament, and asserts both the resulting zero balance and the planner's
  trace. The harness does not recover the node's bond on its behalf.

## Deliberately not done

A no-winner child's balance stays locked in the dead clone. Locked and
burned are economically identical (both permanently remove the funds);
an explicit burn path would buy only bookkeeping legibility at the cost
of new code on a security-critical terminal path. Recorded as a
non-claim in docs/dispute-game.md.
