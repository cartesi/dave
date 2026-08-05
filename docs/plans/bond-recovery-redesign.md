# Bond recovery redesign

Status: CONTRACTS IMPLEMENTED 2026-08-04 on the interface branch; the
node-side recovery action is deferred to the
[self-healing batch submission](self-healing-batch-submission.md)
campaign. Decisions recorded below.

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

## Node-side work (deferred to the batch-submission campaign)

- Recovery becomes a planned cleanup intent through the ordinary lane,
  emitted after settlement (and after child propagation for inner
  tournaments), gated on the node being the winning claimer. No config
  flag: recovering for a stranger pays their bounty with our gas, and
  recovery stays permissionless for anyone who disagrees.
- No gas-kickback subsidy for recovery, and no bond-math entry for it:
  the refund subsidy exists to motivate permissionless progress work,
  while recovery is self-interested by construction (the recovered bond
  dwarfs its gas). Keeping it outside the `refundable` seam also avoids
  circular accounting - the subsidy would be paid from the very balance
  recovery is settling.
- Until the node lane lands, e2e scenarios that assert terminal
  balances trigger recovery explicitly from the harness.

## Deliberately not done

A no-winner child's balance stays locked in the dead clone. Locked and
burned are economically identical (both permanently remove the funds);
an explicit burn path would buy only bookkeeping legibility at the cost
of new code on a security-critical terminal path. Recorded as a
non-claim in docs/dispute-game.md.
