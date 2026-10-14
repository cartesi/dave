# PRT contracts: Cyber Verification threat model

Status: the brief that seeded the campaign of 2026-10-13 to 2026-10-14,
kept as written apart from the marked corrections in "What the first read
checked". It is not a review conclusion; the record of the campaign's
findings is FINDINGS.md beside it and the method is in REVIEW.md.

The code is the source of truth. Everything below was derived from one full
read of `prt/contracts/src` at the campaign's start and may already be wrong.
A finder that refutes a claim here has found something worth reporting.

## Scope and trust

In scope: every file under `prt/contracts/src`, including the adapter
`state-transition/CartesiStateTransition.sol` and its composition with
`Tournament`, the factory, the canonical provider, `ClockBudgets`, and the
deployment script's conversion of wall-clock budgets into blocks.

Assumed correct, out of scope: the `machine/step` library (uarch step, reset,
CMIO delivery semantics, access-log verification), the emulator, the data
provider (`DaveConsensus`, a later campaign), the off-chain clients, and the
rollups contracts. The system is not live, so exploits may be written in the
tree.

The adversary is permissionless and fully malicious: any number of Sybil
commitments at any level, one bond each, into either contested final-state
class of a child, acting in any order, controlling both sides of its own
matches, ordering transactions within a block, and censoring the honest
party for a cumulative `C` across one root dispute and all its descendants.
It cannot prove a wrong leaf transition and cannot make the honest commitment
wrong. The application developer, the deployer's parameter table, and the
factory wiring are trusted (docs/dimensioning.md, docs/plans/audit-readiness.md).

## The properties, as the attacker sees them

1. Result-selection safety. A root tournament finishes with a dangling
   commitment whose final state is not the correct one, while an honest
   participant joined the correct commitment at the root and every child on
   its path and acted within every latency bound with total censorship at
   most `C`. Equivalent: a path exists that eliminates the honest commitment
   without charging more than `C` of honest delay, or a path lets a wrong
   commitment survive a match against the honest one.
2. Liveness. A tournament that should finish cannot: a required honest action
   is unavailable or reverts on every schedule, a state is reachable from
   which no permissionless action progresses, or an `assert` is reachable on
   an honest path.
3. Resource resistance. The honest winner cannot recover its bond, the pool
   pays more than the configured reserve, an action's refund exceeds its cap,
   refunds or payments can be extracted twice, a callback can block progress,
   or the adversary buys delay or work below the priced bound.

A finding must say which property it breaks and must price its trigger in
bonds, gas, blockspace, and censorship. "Anyone can" is not a price.

## The mechanism in one page

Every tournament is an ERC-1167 clone with immutable arguments: geometry
(`initialHash`, `startCycle`, `log2step`, `height`), `level`, `kind`
(LEAF or NON_LEAF), `startInstant`, `allowance`, `responseBudget` (G),
`commitmentBudget` (T), provider, the parent's two contested
commitments and final states (zero at the root), the state transition, and
the factory. A root is `level == 0`. The clone decodes its arguments on every
call; nothing about its role is stored.

Join: pay at least `Bond.bondValue(height, isLeaf)`, supply the root's two
children and a last-leaf proof of the final state. Inner tournaments accept
only the two contested final states; the commitment root itself is free, so
a child commitment is classified by final state, not lineage. The clock is
initialized paused at `allowance - (now - startInstant)`, which must be
positive (a zero allowance is the uninitialized sentinel). Joins stop at
`startInstant + allowance` inclusive. A root can be joined only once per
commitment root: the first claimer owns the terminal payment slot.

Pairing: one dangling slot. A newcomer pairs with the dangling commitment
(the elder is commitment one, the newcomer two) and only the elder's clock
starts. Pairing never grants time. Every winner re-enters pairing inside the
call that won.

Bisection: `Match.State` holds the revealer's parent, the waiting side's
cached children, the running leaf position, and the current height. One
reveals first; each `advanceMatch` opens the revealer's parent, picks the
left child when the lefts differ and the right otherwise, opens the selected
child, and swaps roles; the responder's clock pauses with
`b' = b - max(e - G, 0)` (reject at `e >= b`), and the other starts. At height
one the seal opens the last pair, proves the agree state (the leaf before the
divergence, against the revealer's root, or `initialHash` at position zero),
and stores the two final states in canonical commitment order. Height parity
decides which side seals.

Leaf seal: both clocks run from the seal. `winLeafMatch` is valid only while
the timeout classification is NONE; it calls
`stateTransition.transitionState(agreeState, toCycle(position), proofs,
provider)` and compares the result with one side's claimed state. The winner
is paused charged its elapsed race time less G. Inner seal: both clocks pause
after the responder's discount, and the child is created with allowance
`max(r1, r2)`, start cycle `toCycle(position)`, initial hash the agree state,
and the pair as contested states. `winInnerTournament` consumes the recorded
child's `innerResult()` (WINNER only), maps the winner back to a parent side
by final state, replaces that side's clock with
`min(carried + T + 2G, max(r1, r2))`, re-pairs it, and deletes the match and
link. `eliminateInnerTournament` needs ELIMINABLE and deletes both sides.

Timeouts: one pure classifier over the two clocks. In bisection the paused
side wins if its remainder strictly exceeds the responder's overdue, and that
overdue is its deferred charge; equality eliminates both. In a sealed leaf
the running survivor wins with no deferred charge once the other expires;
both expired eliminates both. Sealed-inner pairs are both paused and have no
local timeout. A win pauses the winner charged `cost - G`, never above its
stored balance.

Finish: closed (`now >= startInstant + allowance`) and no live matches. The
dangling commitment, if any, is the winner. `resultAt` is the later of
closure and the last deletion. An inner winner is usable until
`resultAt + pausedAllowance` exclusive, and its carried allowance is deducted
by the time since `resultAt`. Nothing re-opens a finished tournament.

Money: each refundable action pays its caller
`min(balance, allocation * 50 gwei, units * min(gasprice, basefee + 10 gwei))`
through a 50,000-gas value call that copies no return data; `units` is
`25,000 + 16 * proofBytes + gasleft delta`. The bond is the configured
refundable work of one match for the role, `(h - 1) * ADVANCE + E_role`,
times 50 gwei. `J` joins make at most `J - 1` matches, so one bond survives
for the winner's claimer, who is paid `bond + (balance - bond) / 10` on
`tryRecoveringBond`; the rest burns after a successful payment. A no-winner
tournament keeps its balance forever.

Locks: one transient lock per clone around every mutator and both payment
paths. Other clones are independent. Child reads and the state transition are
static calls; the factory call during an inner seal is the one non-static
external call on a progress path.

## Known-closed baseline

Do not resurface these; cite them if a candidate reduces to one.

- PRT-001 through PRT-013 and CFG-001/002 in
  `docs/reviews/2026-07-21-prt-dispute-game/REVIEW.md`: Arbitrum time source
  (deferred, experimental chains), sealed-leaf time restoration (fixed),
  refund estimates versus real cost (accepted heuristic subsidy), capability
  view (fixed), match-id-zero sentinel (fixed), recovery idempotence (fixed),
  residual sweep recycling (fixed by the one-bond-plus-tenth cap), bankable
  pairing grants (fixed), proof/timeout overlap (fixed, strict verb
  partition), parent-triggered child recovery (removed), extra Sybil
  principal (rejected), unbounded callbacks (bounded).
- CF-01 in `docs/reviews/2026-09-29-prt-clock-refill/REVIEW.md`: a leaf proof
  in flight when the opponent's shorter clock expires reverts and needs a
  separate timeout claim, costing up to one G of C per occurrence. Accepted.
- CF-02 there: an e2e assertion weakness, not a contract issue.
- Accepted by design: timeout victory does not prove correctness; the same
  root's first claimer owns the payment slot while defense stays
  permissionless; `Gas.TX` per action in a batch, priority fee for a
  proposer, and the calldata metering gap are known refund slack; a child
  nobody joins eliminates both parents; a no-winner child locks its balance;
  the shared pair envelope may return more than a side's own snapshot;
  repeated vandalism across epochs is linear in forfeited bonds; the
  per-input compute contract and the 2^24 input bound are out of model.
- Explicit non-claims (`prt/contracts/AGENTS.md`): no general recursive
  liveness or delay proof; the `floor(K / 2)` invariant is single-level; a
  well-formed table does not prove client agreement; non-Ethereum time and
  fee conformance; the leaf refund is not a proof-class ceiling. A finding
  that only restates a non-claim is not a finding; one that gives a concrete
  schedule the docs' budgets do not cover is.

## What the first read checked

These are the reader's conclusions, each a target for refutation. The
phase 2 swarm corrected several of them; the corrections are folded in and
marked.

- Frontier parents always differ: at creation the roots differ, a left
  descent keeps differing children, a right descent follows equal lefts
  under differing parents. So the sealed final states always differ.
  Corrected: `_parentCommitment` is total because the join gate admits only
  the two contested final states, not because the finals differ; differing
  finals buy unambiguous attribution of the child winner to a parent side.
- All leaves before the first divergence agree, so the agree-state proof
  against the revealer's root is sound at any position.
- Corrected: `toCycle(position) = startCycle + position << log2step` is the
  first transition of leaf `position`'s stride. It is the index of the output
  leaf only at stride zero, which is where the adapter is reached, and the
  child's base cycle otherwise. The child's last leaf is the parent's
  divergent leaf under the tiling rule
  `log2step[i] = log2step[i+1] + height[i+1]`. That rule and the maximum
  counter `2^92 - 1` are properties of the trusted table, checked by the
  test-only validator, not on chain; the adapter rejects only counters at or
  above `2^92`.
- The dangling commitment's clock is always paused, so the standing and
  `innerResult` asserts are unreachable on production paths.
- Corrected: every `assert` in `Clock`, `MatchClocks`, `Match`, and
  `Tournament` is guarded on every external path of a factory-made clone with
  in-table parameters. A clone built by hand with height zero, or an orphan
  from the permissionless `instantiateInner` with an allowance near `2^64`,
  reaches an assert, harmlessly, since no parent or consensus trusts it.
- Corrected: the permissionless surface lets anyone act on behalf of the
  responder if they know its tree, and such actions only help the acted-for
  side's protocol state: clocks, phases, and match outcomes. Two costs fall
  outside that state. The acted-for party's own in-flight copy reverts at its
  gas expense, and an early third-party seal removes an overlap a strategy
  could have used to build its child commitment before its own seal, up to
  one G of child clock. Both are recorded as leads in FINDINGS.md.
- The refund population argument holds for every deletion reason, since
  each deletion removes at least one live commitment.
- Finished is absorbing: no mutator can raise `matchCount` from zero after
  closure.
- Corrected, locks: the factory call during an inner seal is the one
  non-static external call made before a mutator's effects complete. Every
  refundable verb then ends in a value CALL to the caller under the lock,
  and terminal recovery makes two, after all effects.

## Attack surface for the swarm

Each dimension names the files to read, what to try, and the reader's open
questions. A finder owns one dimension but may report anything.

1. Match encoding and bisection (`libs/Match.sol`, `libs/Commitment.sol`,
   `types/Tree.sol`). Divergence attribution, parity at even and odd heights,
   height one, position arithmetic near `2^height`, the overloaded sealed
   tuple, `getRoot` versus `getRootForLastLeaf`, proofs of the wrong length
   or against the wrong root, both commitment orders.
2. One-clock arithmetic (`libs/Clock.sol`, `libs/Time.sol`). Inclusive
   expiry, saturating versus checked subtraction, the zero sentinel for
   paused and uninitialized, same-block actions, `uint64` casts, a running
   clock that outlives its match.
3. Timeout classification (`libs/MatchClocks.sol`, `Tournament`
   `winMatchByTimeout`, `eliminateMatchByTimeout`, `classifyMatchTimeout`).
   Deferred charge in each phase, equality, double charging of one interval,
   unequal leaf allowances, both orientations, the view versus the mutators.
4. Leaf race and proof (`Tournament.winLeafMatch`, `sealLeafMatch`). The
   strict verb partition, CF-01 compositions that cost more than one G,
   proving for the wrong side, sealing or proving on the honest side's
   behalf at a chosen block, the proof's calldata and refund metering.
5. Recursion (`sealInnerMatchAndCreateInnerTournament`,
   `winInnerTournament`, `eliminateInnerTournament`, `innerResult`,
   `childReturnAllowance`). Envelope and refill arithmetic, the carried
   deduction, the expiry boundary, orphan and replayed children, the
   deleted link, a child whose contested states or commitments are unusual,
   deep recursion with the four-level table.
6. Standing and finish (`_timeFinished`, `_resultAt`, `_winnerExpired`,
   `tournamentStanding`, `innerResult`, `StandingChanged`). `lastMatchDeleted`
   before and after closure, same-block deletion and propagation, a result
   the parent and an observer could read differently.
7. Join and pairing (`joinTournament`, `pairCommitment`, `deleteMatch`).
   Late joins, joins at the boundary, the same root twice, zero final states,
   the dangling invariant across every deletion, claimer bookkeeping, the
   order of effects before `StandingChanged`.
8. Refund accounting (`refundable`, `_refundableAfter`, `libs/Gas.sol`,
   `libs/Bond.sol`, docs/prt-refund-accounting.md). Per-action caps, the
   per-match reserve for each terminal sequence, batching, forced ETH,
   failed callbacks, a schedule that leaves the honest winner below one
   bond, a Sybil extracting more than its own bonds.
9. Terminal recovery (`tryRecoveringBond`, `_bondRecovery`). Every arm,
   rejecting and gas-burning recipients, claimer deletion, the burn, the
   no-winner lock, recovery racing propagation, EIP-7702 recipients.
10. Reentrancy and cross-clone sequences (`withLock`, `_tryPayment`, the
    factory call in the inner seal, the static calls). A callback that
    mutates a parent or child clone to change what the outer call's
    completed effects mean; lock state across a reverting body.
11. Factory and parameters (`factories/`, `arbitration-config/`). Orphan
    clones with crafted arguments, level overflow past the table, kind
    derivation, one-level and four-level tables, clone argument encoding,
    the provider's table changing, `tournamentLevelCount`.
12. Adapter composition (`state-transition/CartesiStateTransition.sol`,
    `Commitment.toCycle`, docs/computation-hash.md). The three transition
    shapes at every boundary, input index derivation, the zero-root rule,
    proof consumption, provider return handling, the epoch's last counter,
    a start cycle at the last stride, the `counter` passed for position zero
    of a child.
13. Honest survival (R19 lens, docs/plans/r19-honest-survival.md). Build
    schedules at exactly `C + G + (L - 1)(T + 2G)` with Sybil-contested
    children, both orientations, repeated delegations, dangling waits, and
    censorship split across levels; find any that eliminates the honest
    commitment with less than `C` of honest delay.
14. Delay and work per bond (docs/prt-delay-bound.md). Schedules that
    maximize settlement delay or honest transaction work per Sybil bond;
    report the price, since the general bound is a non-claim.
15. Permissionless interference. Enumerate every mutator called by a party
    other than the one it serves: front-running the honest join, advancing or
    sealing for the honest side, claiming its timeouts, propagating its
    child, recovering its bond, eliminating its child. Find one that hurts.
16. Safety paths. Enumerate every path that deletes a commitment's claimer
    and every path that makes a commitment dangling at finish; for each,
    state the honest delay it requires.
17. Events and observers (`ITournament` events, the views, the counters).
    A published schedule or standing that disagrees with what the mutators
    accept, which would make an honest client miss a deadline.
18. Geometry generality. The canonical `[38, 0] / [54, 38]`, the devnet
    `[44, 27, 0] / [48, 17, 27]`, one level, four levels, heights near the
    256-bit limits, bonds per height, `assert(height > 0)`.
19. Solidity and EVM. Transient storage across reverts, `via_ir`,
    `abi.decode` of clone arguments, calldata slicing in the adapter, the
    assembly `call`, OpenZeppelin 5.5.0 `Clones` with immutable arguments,
    `block.number` as `uint64`, selector and enum assumptions.
20. Deployment conversion (`script/Deployment.s.sol`, `ClockBudgets`).
    Rounding of each term, the refill equality with `winInnerTournament`,
    chain registrations, a block time that changes after deployment.

## Finding format and gate

A candidate names the property, the preconditions, a block-by-block trace
naming every call and its caller, the expected and actual outcome, the
smallest injected geometry that shows it, and its price. A candidate becomes
a finding only when a Foundry test on the current tree reproduces it: a test
named `testExploit...` (renamed `testTrace...` or `testRegression...` when
placed in its owning suite at the campaign's close) that passes while
the defect is present and states the violated invariant in a comment. Without
that test it is a lead and is recorded as one.

Severity follows the property: safety above liveness above resource. Within a
property, the price decides: cheaper triggers rank higher. A finding inside an
accepted limitation or a non-claim is reported as such, ranked by whether it
changes the documented price.
