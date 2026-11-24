# Detection

What a detector outside the node must see, and by when. This file describes
no tool: it is what one is built and reviewed against.

## Why

The tournament and the node rest on assumptions
([dispute-game.md](dispute-game.md#security-statement-and-assumptions)):
correct contracts, and one correct, live node within the censorship budget.
When one of them fails a wrong result can win, and nothing inside this system
objects. The answer outside it is detection plus the application's fallback,
the guardian's `foreclose()`, whose reaction window is the claim staging
period
([epoch-lifecycle.md](epoch-lifecycle.md#consensus-layer-staging-sentries-and-foreclosure)).

## The deadline

Foreclosure stops a result only before `acceptStagedTournamentResult`. An
accepted result stays: its outputs remain executable (`executeOutput` has no
foreclosure gate), and a later foreclosure pays withdrawals from the accepted
state (rollups-contracts 3.0.0-alpha.10, `Application.sol`; read it again on
a dependency bump).

Acceptance needs a staged result and either every sentry's claim of the
staged state or the staging period, counted from the staging block. The
agreement is checked when acceptance is called, and `submitSentryClaim`
checks its caller and the epoch number, not staging, so a claim can land
before the staging or in any block after it. With sentries the window
therefore has no fixed length: the period bounds it, and it ends in the
block the last sentry's agreeing claim lands. When every sentry has claimed
the state that is then staged, acceptance can share the staging block, and
there is no window at all. Without sentries only the period opens
acceptance.

## What to detect

Each condition is named by the assumption that broke, with its fallback and
its deadline.

- A, a wrong result can settle, or the true one cannot. A claimed state that
  differs from the reference is not yet this. A false commitment joining the
  root is the ordinary dispute, which a validator wins: it is first that
  validator's alarm (B) and, where the reference is the replay, the moment
  corroboration starts. It becomes the guardian's when a wrong result can
  settle or the true one can no longer win. Fallback: foreclosure. Deadline:
  acceptance, for a root whose winner ends in a wrong state, for a wrong
  staged result, and for a root that closes to joins holding no commitment
  with the true state and one with a wrong state a validity proof accepts,
  which then wins. The other cases hold the application until the guardian
  acts: no commitment joined at all, the root finishes without a winner, or
  the epoch ends terminal (defended, never stageable).
- B, the honest side is losing time. No commitment has joined while the join
  window runs; a second commitment has joined, so a dispute exists; a clock
  runs unanswered. Fallback: a validator online. Deadline: that clock, after
  which B is A.
- C, settlement is idle. A finished root is unstaged, or acceptance is open
  and uncalled. Fallback: any node with a funded key, which stages and
  accepts a root its commitment won without having joined it (the node
  harness's `a_second_node_settles_the_epoch_the_first_won_and_left`). A root
  won by another commitment that ends in the true state is settled only by
  direct calls, for both steps: a node that lost the root stages nothing
  and, even after somebody stages, does not accept. It only submits its
  sentry claim. No deadline.
- D, the detector is blind. It has no fresh reading, or its provider lags.
  Every quiet reading is then ambiguous, so D alerts on its own.

## Where the chain shows a claimed state

Earliest first, with the lead each leaves before acceptance:

1. `CommitmentJoined` in the root tournament, which carries the final state
   the commitment ends in: what remains of the dispute, then the window.
2. The winner fields of `canStageTournamentResult`, once the root finishes:
   the wait for staging, then the window.
3. `SentryClaim`, a sentry's own state, at any point of the epoch.
4. `EpochStaged`: the window alone. Without sentries that is the staging
   period. With sentries it is not a fixed number of blocks: the period at
   most, ended by the last sentry's agreeing claim in whatever block it
   lands, and nothing when every sentry already agrees.
5. The next `EpochSealed`, which starts from the accepted state: too late.

So a disagreement is detected at the join. Its lead is the adversary's choice,
though: into a root that holds no other commitment, a fabricated claim can
join in the last block before closure and win at closure, one block later,
which leaves the window alone.

## What the chain is compared with

A detector must not share the failure it guards against, so its reference
decides what it can see.

- The chain and the clock. No computation. Covers B, C and D, and a sentry
  claim that differs from another claim or from the staged state.
- The node's own computed state. Catches a contract defect or a lost dispute,
  and the node reports both already. A lost root is an error on every tick
  that says whether the winner ends in the node's state or another (`DIVERGED`,
  with both states). A won root whose winner or staged values differ from the
  node's panics (`... mismatch, notify all users!`). A sentry claims the state
  it computed, whoever won. Once a divergent state settles, the node exits 30
  when its next epoch starts from it. Blind to a defect every node shares.
- An independent replay of the epoch's inputs to its final state and outputs
  root. The only reference that sees a defect the nodes share. It needs the
  template, each sealed epoch's input range and the emulator, and no
  commitments, proofs or tournament geometry. It shares the emulator with the
  node, so on an emulator defect it agrees with the nodes. One the on-chain
  step does not share shows only once a dispute is won against the nodes, as
  a winner that differs from the replay; one both share is outside every
  check here, which is the assumption the tournament states.

## Rules for a detector

- Compare final states and outputs roots only. Rebuilding commitments or
  proofs rebuilds the node's defects.
- Never transact. The fallbacks are an operator's or the guardian's acts.
- Never read the node's database or logs, and share no code with it.
- Latch a divergence until an operator clears it: once a wrong result is
  accepted, the stage and accept views describe the next epoch and look
  healthy again.
- Have its own liveness watched from outside (D).

Whoever acts on an alarm corroborates one that rests on the replay.
Foreclosure is irreversible, and a replay that differs from the nodes ran the
same emulator over the same inputs, so the fault is in one side's own code or
in what its provider served, and the detector's is the newer and less
exercised. A fact read from the chain alone (no commitment joined, a sentry
rotated, settlement idle) stands as an alert; a mismatch waits until a second
replay with other code agrees with the first, or the first input boundary at
which the replay and a node differ is found.

## Sentries

A sentry is the on-chain form of this check, and the same independence
applies. Sentries that all run the node agree on a defect they share, and
their agreement removes the window. Keep at least one sentry that does not
run the node, or none: without sentries the staging period always applies.
