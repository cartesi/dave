# Detection

What a detector outside the node must see, by when, and what it leaves to
the validators. This file describes no tool: it is what one is built and
reviewed against.

## Why

The tournament and the node rest on assumptions
([dispute-game.md](dispute-game.md#security-statement-and-assumptions)):
correct contracts, and one correct, live node within the censorship budget.
When one of them fails a wrong result can win, and nothing inside this system
objects. The answer outside it is detection plus the application's fallback,
the guardian's `foreclose()`, whose reaction window is the claim staging
period
([epoch-lifecycle.md](epoch-lifecycle.md#consensus-layer-staging-sentries-and-foreclosure)).

An alarm is for one of three things, and each takes its own kind of
knowledge:

- Attention: something happened that never happens among correct
  validators. The chain alone shows it.
- Repair: a validator or a sentry is not doing its part, and its operator
  brings it back. Only that node knows it exactly; the chain shows the case
  where nobody is attacking.
- Foreclosure: the state about to settle is wrong, or none can settle. That
  takes the true state, which only a validator computes.

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

Every sentry claiming one wrong state is the worst form of this: the window
is gone for exactly the result it was there to stop. A commitment ending in
that state, alone in its root, wins at the root's closure and can be staged
and accepted in that block. It means the sentries share a defect, or the
slots are no longer the operator's: the sentry manager's key moves a slot to
another address, which claims in the current epoch if the slot had not, and
in every later one.

## What the chain can say

Among correct validators an epoch looks one way. Its root holds exactly one
commitment: they all build the same one, and a second join of it reverts
(`ClockAlreadyInitialized`). Every sentry claims the same state, which is
the one staged. Each departure is a fact read from the chain, with no
computation behind it.

The chain does not say two things:

- Which side is right. Settlement reads one thing from a root, its winner's
  final state, and whether that is the true state is known to whoever
  computed the epoch.
- Whether a validator is taking part. A commitment is a whole computation,
  bound on chain to its final state alone. One that ends in the true state
  can be wrong before its end, anyone can join the correct one and leave it
  undefended, and a validator that was not the first to join leaves no
  trace until a move is due.

Judging a dispute in progress takes the correct commitment and the move
that is due, which is a validator. So a detector reads the root
tournament's joins and result and the consensus contract, and never a
match, a clock, a commitment or a proof. Once a second commitment joins it
says that a dispute exists, and stops: the validators say the rest.

## What to detect

Each condition is named by the assumption that broke, with what it is for,
its fallback and its deadline, and with what the chain alone shows of it.

A signal that something has not happened yet needs a time by which a
healthy deployment has done it. That time is no contract value and none of
the dispute game's budgets: `G`, `T` and `C` say where a delay is charged,
not when a healthy node acts. It is the operator's target, set from what
its own validators and sentries do. A node that reads only finalized blocks
learns of the seal at its finality, and still has the epoch's last inputs
to run and its commitment to build. Its root join lands after finality,
that remaining work, a polling interval and inclusion, and on Ethereum
finality alone is past `G` on every epoch
([dimensioning.md](dimensioning.md#tournament-clock-budgets)). The hard
thresholds are the chain's own deadlines: the root's closure, the root's
finish and the end of the staging period.

- A, a wrong result can settle, or the true one cannot. For foreclosure, by
  the guardian. Deadline: acceptance. Which state is wrong a validator says
  ([below](#who-knows-the-true-state)); the chain alone shows:
  - Two claimed states that differ, among those the chain shows
    ([below](#where-the-chain-shows-a-claimed-state)). One of them is
    wrong, and the chain does not say which. A sentry that differs from the
    staged state keeps the whole staging period open, and is the dissent
    the guardian reads.
  - A `SentryRotation`. The detector cannot know who made it, so every one
    raises attention and the operator confirms it. One the operator did not
    make is the guardian's alarm from its block (above): where every slot
    then claims one wrong state no window follows the staging, so the
    deadline moves back to the root finishing with that state.
  - A root that holds the application until the guardian acts, with no
    deadline: it closed to joins with no commitment, or finished without a
    winner. An epoch that ended with the application terminal is held the
    same way, defended and never stageable, and the chain shows it only as
    idle settlement (C).
- B, a validator or a sentry is not doing its part. For repair, by its
  operator. A node that is alive says so itself: an obligation its
  commitment missed is an error on every tick. A dead one is silent, and
  the chain alone shows:
  - No commitment has joined. The wait is charged to whoever joins: a
    commitment starts with the root's allowance less the time since the
    root's start (`joinTournament`, `Clock.initializePausedAt`). Two
    thresholds:
    - The page: none by the operator's join target (above). The dispute
      game's own target, `G` from the root's start
      ([dispute-game.md](dispute-game.md#security-statement-and-assumptions)),
      is where a join starts to draw on `C`, the one delay ledger
      ([dimensioning.md](dimensioning.md#one-delay-ledger-one-reference-price)).
      It is no threshold for a page: the finality wait alone passes it.
    - The hard cutoff, reported apart: the root's closure, the instant a
      joining clock would start at nothing, from which every join is
      refused (`TournamentIsClosed`). Then no join is a root without a
      winner, and one adversarial join is a wrong result winning. A join
      just before it still wins an uncontested root, and has almost
      nothing left for a contested one.

    Any join silences this, an adversary's included, and a commitment in
    the root is no sign of a validator: the signal is for the node that
    stopped with nobody attacking.
  - A second commitment has joined, so a dispute exists. For attention:
    someone is wrong or attacking. The detector follows it no further, and
    each validator's operator confirms that it is in the dispute.
  - A sentry has not claimed. Two thresholds:
    - Past the operator's target for that sentry (above), for attention:
      it may only be down.
    - Once the root has finished and that target has passed, for its
      operator to act. A silent sentry delays acceptance and does not stop
      it, so the result is accepted at the end of the staging period
      without that sentry's check, and with every sentry silent nobody has
      vouched for it on chain.
- C, settlement is idle. A finished root is unstaged, or acceptance is open
  and uncalled. For repair, with no deadline. Fallback: any node with a
  funded key, which stages and accepts a root its commitment won without
  having joined it (the node harness's
  `a_second_node_settles_the_epoch_the_first_won_and_left`). The chain does
  not say why a root stays unstaged, and a validator does:
  - Another commitment won that ends in the validator's state. It is
    settled only by direct calls, for both steps: a node that lost the root
    stages nothing and, even after somebody stages, does not accept. It
    only submits its sentry claim.
  - The epoch ended with the application terminal. No validity proof
    settles that state, so nobody stages it, whichever commitment won with
    it: one of A's held cases.
  - The winner ends in another state, which can be staged: A, with its
    deadline.
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

Among correct validators these all agree, and a detector compares them with
each other: it has no state of its own. A disagreement shows once two of
them exist. A lone fabricated commitment disagrees with nothing until a
sentry claims, and its lead is the adversary's choice: into a root that
holds no other commitment it can join in the last block before closure and
win at closure, one block later, which leaves the window alone.

## Who knows the true state

A detector must not share the failure it guards against, and one that
computed the state would be a validator. So it computes nothing, and the
true state comes from validators:

- A validator's own computed state. The node reports with it already. A
  lost root is an error on every tick that says whether the winner ends in
  the node's state or another (`DIVERGED`, with both states). A won root
  whose winner or staged values differ from the node's panics
  (`... mismatch, notify all users!`). A sentry claims the state it
  computed, whoever won. Once a divergent state settles, the node exits 30
  when its next epoch starts from it. Blind to a defect its implementation
  carries, and silent once the node is dead or no longer the operator's.
- A second, independent implementation of the validator. The only reference
  that sees a defect every node of the first shares, and it puts what it
  sees on chain. As a validator it joins its own commitment, and the
  tournament decides between the two with the on-chain step. As a sentry
  its differing claim keeps the staging period open. It shares the
  emulator, so on an emulator defect the two agree. One the on-chain step
  does not share shows only once a dispute is won against both, as a
  winner that differs from their state; one all of them share is outside
  every check here, which is the assumption the tournament states.

Where one implementation runs alone, the substitute is an independent
replay of each epoch's inputs to its final state and outputs root, compared
with every state the chain shows; it can start at the seal, since
`EpochSealed` fixes the epoch's inputs. It is a reader and a runner, half a
validator, and its mismatch has no tournament to settle it. A lead, not
planned work.

A fact read from the chain alone stands as an alert. A disagreement between
two implementations is settled, not judged, once both commitments are in
the root: the second one joins while the root takes joins, the on-chain
step decides, and each keeps defending for as long as their match runs,
which can be long after closure. It is the guardian's where the step does
not get to decide: the root closed before the second commitment was in, or
one side ran out of time, which decides a root and proves nothing about the
state. A wrong winner that can be staged is then condition A, with its
deadline. Foreclosure is irreversible, and both sides ran the
same emulator over the same inputs, so the fault is in one side's own code
or in what its provider served: whoever acts on it first finds the first
input boundary at which the two differ. That takes time and the deadline
does not wait, so the staging period has to be longer than it takes.

## Rules for a detector

- Compute no state. Compare the states the chain shows with each other:
  rebuilding the state, a commitment or a proof rebuilds a validator, with
  its defects.
- Read the root tournament's joins and result and the consensus contract.
  Never follow a match or a clock.
- Never transact. The fallbacks are an operator's or the guardian's acts.
- Never read the node's database or logs, and share no code with it.
- Latch a disagreement until an operator clears it: once a wrong result is
  accepted, the stage and accept views describe the next epoch and look
  healthy again.
- Have its own liveness watched from outside (D).

## Who watches what

A suggestion for whoever operates an application. Each watcher is exact
where the others are blind, so none replaces another:

- Each node, by its operator: every ERROR line, restart loops, and what
  [its README](../cartesi-rollups/node/README.md) lists beside them. Silent
  once the node is dead or no longer the operator's.
- The chain, by a detector on a host and a provider the nodes do not use:
  it is what still speaks then.
- The true state, by a second implementation run as a validator, or at
  least as a sentry, on its own host and provider.
- The guardian hears what can call for foreclosure: two claimed states that
  differ, a rotation nobody made, a root held without a winner, a node's
  divergence error. The staging period has to exceed its reaction time.

## Sentries

A sentry is the on-chain form of a validator's check, and the same
independence applies. Sentries that all run one implementation agree on a
defect they share, and their agreement removes the window. Keep at least
one sentry that runs another implementation, or none: without sentries the
staging period always applies.
