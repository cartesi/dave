# Trust model and dimensioning rules

Who is allowed to be adversarial, and which case - worst or average -
each protocol dimension must be sized for. Settled 2026-07 during the
node rewrite. The reasoning is the load-bearing part: new dimensioning
questions will appear, and the rule must be re-derivable from it, not
just remembered.

## The trust boundary

Two different actors shape a dispute's cost, with different trust:

- The dispute adversary (a sybil claimant) is permissionless and
  fully malicious. It chooses what to claim, where to disagree, and
  when to move. Nothing about its behavior may be assumed.
- The application developer is currently inside the validator's trust
  base. A validator chooses which applications to defend; defending
  one is a bet that its machine is disputable: that no computation
  the app can reach - under ANY permissionless input, since inputs
  are not chosen by the developer - produces behavior the dispute
  protocol cannot serve within its clocks.

An un-disputable machine is one that loses that bet on purpose. The
naive version loops forever. The subtle versions concentrate
pathological instruction mixes: code built from instructions whose
uarch emulation is maximally long (the sqrt / TLB-flush class), dense
enough that building a nested commitment over any gap of it exceeds
any realistic timeout. Nothing currently detects these; detection
mechanisms (requiring emulator support) are future research, far off.
Until then the assumption is explicit: the app developer is trusted,
and trusted specifically to keep input-reachable behavior disputable.
The developer also authors the template machine, which must carry the
deployed step's pristine uarch (docs/computation-hash.md). The node reads a
yield as the step does, from the HTIF header alone, so a guest's malformed
yield length cannot stop it.

## One delay ledger, one reference price

Three rules keep the model's precision even, so that no guard hardens a door
while a cheaper wall stays open.

One delay ledger. Every delay of the honest node's observation or inclusion
past an action's `G` draws on the same non-rechargeable `C`, whatever its
cause, because the contracts cannot tell causes apart: censorship, a finality
stall, a halted or lagging chain, a provider or relay outage, a restart, and
the time an operator takes to answer a page. `C` is a week on Ethereum and
hours on the testnet deployments. The node reports the delays it can see (a
stale latest or finalized head, a call still overdue after `G`) and works
around none of them. Nor does it compare its own latency with `G`: a slow poll
or preparation draws on `C` like any other delay, and each action logs how
long its preparation took. The operator duties that keep delays short (a
supervisor that never gives up, redundant providers outside the node, someone
answering pages) are in the node README. Finality is the clearest case: if it
stops for a week, the dispute is lost whatever the node does. On the OP Stack
a sequencer outage is charged when the chain resumes, since block numbers
advance with time there (a lead).

One reference price. The cheapest loss the model accepts is the
aggregate-throughput attack (below): inputs that outrun the honest runner.
The runner pays a fixed overhead per input, accepted or rejected, whatever the
application does (node-architecture.md, Storage). At the 0.14-0.2 s measured
on macOS, a root window of about a week (`C + T + 2G`, less a finality) holds
3-4.4 million inputs, so an epoch with more outruns the runner: about
0.9-1.3e11 gas at 30k gas per input batched through a contract, 90-1,300 ETH
on Ethereum at 1-10 gwei but only 0.09-1.3 ETH on an L2 at 0.001-0.01 gwei,
where input-priced attacks cost about a thousand times less and bonds do
not. An attack that fills a resource (disk, links, memory,
provider quota) for less than that is a wall to close; a guard against one
that costs more, or that is out of model, is a door not worth its code. The
figures rest on one machine's overhead and are re-measured on Linux
(todo.md). A faster runner raises the price by about four times at most:
below about 36 ms per input (a week over 2^24) the input span binds first,
at about 5e11 gas, provided the snapshot disk keeps up.

Evenly distributed effort. The trusted application's work arrives spread over
the epoch enough for the runner to keep up: one input that runs for days at
the end of a quiet week breaks the root build, and the per-input contract
(below) excludes it. Inside a leaf the average-density clause of the rule
plays the same role. The adversary also chooses when, so it can concentrate
contract-respecting load into a leaf build or a response: hardware is sized
for the runner and the Hero together, not for an idle host.

## The rule

Coordinates are dimensioned to the worst case. Clocks are dimensioned
to the average case.

- Coordinates (the structure spans: 2^20 usteps per big cycle, 2^48
  big cycles per input, 2^24 inputs per epoch): a single legitimate
  event that does not fit its span is fatal - the coordinate system
  cannot represent the honest computation, so the honest validator
  cannot even state the truth. Even an honest program occasionally
  executes the worst instruction (the sqrt / TLB-flush class), and one
  occurrence, ever, past the span would break soundness, so rarity
  does not discount anything. The span is the emulator's uarch cycle
  budget, `2^20 - 1` executed usteps per big cycle plus the closing
  slot; the heaviest instruction measured on v0.21, `sfence.vma`, takes
  17,595 usteps, about 60 times below it (one workload on one machine;
  re-measure with the validator-grade run, todo.md).
  The input span differs in kind: no single legitimate event exceeds
  it, only a flood of roughly 5e11 gas of inputs in one epoch. Past
  it the contracts never feed the tail, and the Rust node panics
  instead. It is an economic bound only on Ethereum (500-5,000 ETH at
  1-10 gwei; 0.5-5 ETH on a cheap L2), and the reference price binds
  first: the runner falls behind long before the span.
- Clocks (the commitment budget `T`, responseBudget, the root
  slowdown budget, and the strides derived from them): these price
  aggregates - sums of per-step costs over whole gaps. Rare heavy
  instructions vanish into a sum of millions of terms. The honest
  program lives at the average (typical code runs ~50 executed usteps
  per big cycle against the 2^20 span, a factor of ~20,000; even the
  deliberately instruction-heavy stress workload measures ~566 - see
  the density labels in docs/measurements/constants.md), and the trusted
  party authors that distribution. So clocks are sized to average density
  plus a hardware slack factor - not to the worst instruction
  repeated wall to wall, which is precisely the un-disputable machine
  the trust assumption excludes.

## Why the rule has this shape (re-derive from here)

Two questions decide every dimensioning case:

1. Failure mode: does a SINGLE occurrence break it (representation,
   soundness), or only an AGGREGATE (a deadline, a budget)?
   Single-occurrence failures take the worst case no matter who
   authors the behavior - rarity does not help when one event is
   fatal.
2. Authorship: who authors the behavior distribution being priced -
   an untrusted actor (the dispute adversary; the input author,
   wherever the app lets inputs amplify into behavior), or a trusted
   one (the app developer)? Untrusted authorship means the
   adversarial distribution; trusted authorship means the actual
   profile.

Averaging is safe only when both answers align: aggregate failure
mode AND trusted authorship. Every other combination takes the worst
case.

One residual adversarial power survives the trusted-app assumption:
the dispute adversary chooses WHERE. It cannot make the honest
computation denser, but it picks the gap, so clocks must cover the
heaviest gap the honest computation contains, not the
computation-wide mean. The trusted-app assumption does real work
exactly here: it promises density stays near average everywhere. An
app that violates that locally - one pathological region in an
otherwise normal program - is un-disputable in that region, and the
adversary will find it.

## Worked examples

| dimension | failure mode | author | verdict |
|---|---|---|---|
| uarch span (2^20 usteps)  | single event | any - honest code hits it | worst case |
| barch span per input (2^48) | single event | app + input | worst case |
| input span per epoch (2^24) | input flood | anyone, at roughly 5e11 gas per epoch | beyond the reference price: the throughput loss comes first |
| leaf-level dense build within the commitment budget | aggregate | trusted app | average density |
| root slowdown (level-0 sampling overhead) | aggregate | trusted app | average |
| positioning through an input's prefix | aggregate | trusted app (the per-input compute contract, below) | app profile |
| which gap / which leaf gets disputed | - | dispute adversary | worst location |

The halt/exception protocol gap found on 2026-07-15 is closed at the
emulator and solidity-step boundary since v0.21 and v0.15. SendCmioResponse is total:
an advance response to a machine that is not waiting on an RX_ACCEPTED manual
yield is a provable no-op. The step reads only the pending yield, never the
halt flag or the input budget, so exception and unexpected manual yields are
terminal fixed points at big cycle boundaries, and so are halt and mcycle
overflow when no manual yield is pending; later input windows remain
claimable. An RX_ACCEPTED yield takes the next input even on the budget's last
cycle (mcycle == imcyclemax), which renews the budget unless it is already
saturated at 2^64 - 1, where the fed machine is an overflow fixed point at
once. Rejection is the one nonterminal manual outcome: the closing uarch reset
substitutes the recorded pre-input root, even on the budget's last cycle,
after which the next input can be fed normally.

At uarch granularity, terminal fixed points still have the usual idle-churn
span followed by reset; they are constant only at big-cycle boundaries and
coarser samples. Keep contract transition tests for every terminal reason and
the emulator computation-hash corpus in the release gate. In particular, do
not infer leaf semantics only from the big-machine run break reason.

## Per-input compute contract

How much computation one input may take is an application design contract,
like average density: the trusted developer promises it, and nothing below
the 2^48 coordinate span enforces it. Clocks depend on it because work inside
one input is replayed, never cached, by three honest actions:

- A root-level response inside an input runs that input from its boundary,
  sampling at the root stride. The first such response also replays the
  inputs between the last kept snapshot and the disputed one, up to
  `--snapshot-gap-inputs - 1` of them (64 by default, chosen by the
  operator). That work must fit `G`.
- A join's positioning and a leaf proof replay the disputed input's prefix
  from its boundary.

Under the canonical table (`[38, 0]` / `[54, 38]`, `G` of five minutes,
hardware slack 2), the hash-cost curve in docs/measurements/constants.md
(stress workload, measured on v0.21) gives about 3.5 ns per big cycle sampled
at stride 2^38 (its 2^18 row: 557 us of run plus 370 us of root hash per 2^18
big cycles). Replaying whole inputs is one unbroken run, which its long rows
put at about 1.1 ns per big cycle, close to the positioning in
docs/measurements/node-vs-emulator.md. With `G` halved by the slack to 150 s,
the contract is near 2^35.3 big cycles per input at a gap of 1
(150 s / 3.5 ns), and near 2^30.9 at the default gap of 64 (63 replayed
inputs and one sampled: 150 s / (63 x 1.1 + 3.5) ns), where the prefix
replay dominates. Each replayed input also pays the node's fixed overhead
(about 0.14-0.2 s on macOS), about 9-13 s of the 150 s at the default gap,
and that overhead alone caps any gap near `G / (2 x overhead)`. The gap also
bounds the open tail a seal leaves unexecuted, which the root join waits for.
These are estimates on one workload; a re-measurement on validator-grade
hardware confirms or replaces them. Heavy applications lower the gap, which
trades disk for the contract: at gap 1 a flood of cheap inputs makes one
snapshot each, so it fills disk at about a hundredth of the reference price,
and a heavy application needs boundaries spaced by work as well as count
(todo.md) before it runs at a low gap in production.

An overrun is charged to the honest clock beyond `G` and draws on `C`: it
spends censorship tolerance before it loses a dispute. Past the contract, as
past the other out-of-model bounds, the protocol promises nothing.

### Aggregate throughput, the second per-app contract

The per-input contract bounds one input. The root join window bounds their
sum. The root allowance `C + 2G + (L - 1)(T + 2G)` holds no term for building
the level-0 commitment, because the node computes it while the inputs
arrive, so the honest root join assumes the node has kept up with the
epoch's inputs when the epoch seals. The input author is untrusted, and
sealing takes every input posted before the acceptance block, so an epoch's
total compute is adversarial even when every input respects the per-input
contract. A backlog larger than the root window at the seal makes the honest
root join miss closure, and a Sybil's claim then wins the root unopposed; the
cost is the inputs' gas and one bond, far below the 2^24 flood
(reviews/2026-10-13-prt-cyber-verification, L-01). The assumption is
therefore the app's second contract: the app digests, within the root
window, any input stream the chain can deliver in one epoch, with margin for
the node's catch-up after a burst. An app meets it the way it meets the
per-input contract, by design: it meters effort per input and prices it,
with prices that rise as the epoch's effort is consumed, so that underpriced
inputs are dismissed cheaply. Inputs that execute nearly instantly do not make
it slack: the node pays its fixed per-input overhead on every input, accepted
or rejected, so the runner tops out near a handful of inputs per second
whatever the application does, and an app's pricing can dismiss an input but
not that overhead. The contract therefore binds for every application, at the
reference price above. The trigger, sealing with no input cap or minimum
notice, belongs to DaveConsensus and is priced in that campaign; a smaller
per-input overhead is the node's lever, worth at most a factor of about
four (One reference price, above).

## Base-layer censorship model

The contracts adopt the base-layer adversary model from Section 3 of the
[`Dave paper`](papers/dave.pdf), without adopting Dave's dispute
algorithm or its delay bound. The adversary may delay any set of the correct
participant's transactions, split that delay into intervals of arbitrary
length, and reorder transactions. Across the chain timeline, the total duration
for which correct-participant transactions are censored is bounded by one
global budget `C` for one root dispute and all of its linked descendants.

`C` is cumulative and non-rechargeable. It is not a fresh budget for each
transaction, match, tournament level, or timeout. A clock design is therefore
unsafe if the same censorship interval can reduce the correct commitment's
allowance twice.

Timeout accounting depends on which clocks were consuming that interval:

- During active bisection exactly one clock runs. If that responder expires,
  its opponent was paused. Charging the paused survivor for the responder's
  overdue interval accounts for the time in which timeout cleanup itself could
  have been censored.
- During a sealed leaf both clocks run. A surviving clock's live remainder has
  already paid for every elapsed block since sealing. Transferring the expired
  opponent's overdue interval would charge the same time twice.
- Delay chosen by a Sybil for its own transaction is not censorship of the
  correct participant. The contract cannot observe that distinction, so this
  statement relies on a responsive correct actor and sufficient transaction
  capacity for immediate permissionless cleanup. The model charges any further
  inclusion delay against `C`; the contract cannot distinguish censorship from
  ordinary congestion.

The contract-level timeout-accounting invariant is that one elapsed interval
reduces a correct commitment's clock at most once. This is narrower than a
complete PRT liveness proof: asynchronous arrivals, finite blockspace,
transaction work, and multi-level population reduction remain separate
concerns.

When comparing adversarial schedules, hold fixed both the adversary's resource
budget and the damage metric. For clock dimensioning, the metric is
clock-induced settlement delay. Dimensioning targets a schedule that maximizes
that delay: making a dominated schedule more precise does not improve the
worst-case bound while the maximizing schedule remains available. This is a
design heuristic, not a proof that an optimal recursive schedule has been
characterized. It does not compare transaction work, fees, refunds, or other
damage metrics, and it does not relax correctness requirements for any
schedule.

## Tournament clock budgets

Keep three wall-clock quantities separate:

- `C`: the global cumulative censorship budget across one root dispute and its
  linked descendants.
- `T`: the supported time to construct the commitment needed for one inner
  tournament, the same at every inner level. It belongs with the geometry
  (`ArbitrationConstants.COMMITMENT_BUDGET`): a generated geometry is only
  valid for a `T` at least the one it was generated against.
- `G`: the small per-response inclusion and execution budget for a tournament
  transaction.

The contract expires a clock when `elapsed >= allowance`. These duration
components are therefore strict provisioning bounds in the on-chain block
coordinate: modeled consumption before a required progress action must remain
below the configured duration. Timeout resolution becomes eligible at equality.
If a wall-clock policy states an inclusive maximum, its conversion must add
boundary slack rather than map equality to equality.

For `L` tournament levels, the root allowance and structural clock bound are

```text
maxAllowance = C + 2G + (L - 1) * (T + 2G)
```

The rule behind it: every honest action gets one inclusion `G`, joining a
child also gets the build `T`, and one inclusion is held in reserve for the
action in flight. Responses are discounted by `G` as they land, but only
after they land: a response is accepted only while its latency fits the
balance, and the root join's lateness is deducted with no discount, so the
balance must hold the join's lateness and the next action's latency at once.
At inner levels a pending delegation's unspent propagation inclusion covers
that reserve; at the root nothing else does, which is why a single-level
table at `C + G` lost the honest commitment at zero censorship (F-01,
reviews/2026-10-13-prt-cyber-verification). A
delegation costs the build and the join, charged at the join as lateness, and
the propagation back, deducted from the carried remainder; when the child
returns its winner, the parent refills it by up to `T + 2G`, within the sealed
pair's envelope, so each delegation is paid back. The root allowance holds the
censorship budget, one inclusion for the root join, one in reserve, and one
refill per inner level: the delegations a correct commitment may have pending
on its path.
`ClockBudgets` derives it, `responseBudget = G` and `commitmentBudget = T` from
the wall-clock inputs and the deployment's block time. The number of children
a correct commitment passes through is chosen by the adversary, one Sybil bond
each; without the refill, `C + (L - 1) * T` covered only one build per level
and a few Sybils could exhaust it once `C` was spent. A child tournament does not necessarily
receive this maximum: sealing delegates the greater live remainder of the two
parent clocks as a shared pair envelope, and that value becomes the child's
tournament allowance. On return, the selected parent side may therefore receive
more than its own snapshotted remainder, but
`returned <= max(r1, r2) <= r1 + r2`, where `r1` and `r2` are the post-discount
remainders snapshotted by the final seal. The parent has not yet established
which side is correct, so the maximum prevents either side's lower remainder
from truncating the other side's child dispute. The global `maxAllowance`
remains a structural upper bound for legitimate child clocks; no response
operation dynamically raises a clock toward that bound.

The shared maximum is a deliberate worst-case simplification. In a
Sybil-versus-Sybil parent match, the adversary controls both sides and can
already choose which one survives, preserving the more useful remainder at the
other's expense. In a correct-versus-Sybil match, child lineage is not
authenticated by parent root or claimer: a distinct child commitment may bind
to either contested final state, and the child result maps back to a parent
side by final state. The adversary can therefore enter the correct side's
final-state class instead of being forced to inherit one particular Sybil
clock. Exact per-lineage accounting would change some schedule-specific
balances, but would not remove the preserved-clock strategy that
`max(r1, r2)` exposes. This is not a claim of schedule-by-schedule equivalence
or a formal recursive delay theorem. Any corresponding leniency toward a
correct participant is incidental, not the security rationale.

The canonical table is two levels, `log2step = [38, 0]` and
`height = [54, 38]`: the `T = 60` derivation in
docs/measurements/constants.md, which prices the leaf on the node's bulk
collection path with hardware slack 2, deployed with `T = 120 minutes` for
double slack. On Ethereum it gives one week plus 140 minutes. The three-level
table (`[44, 27, 0]` / `[48, 17, 27]`) predates the current measurement
tooling and is not a `T = 30` derivation; it remains the devnet test table
that CI and local tests run, at `T = 30 minutes`.
`ArbitrationConstants` holds the deployed table together with its `T`.

Before adopting any generated table, run the test-only whole-table validator
under `prt/contracts/test/config/`. It checks the declared level count, positive
heights and root allowance, heights and row extents strictly below 256,
256-bit shift limits, root span, inter-level tiling, and zero leaf stride. A
height or row extent of 256 would require representing the span `2^256`, which
does not fit the clients' 256-bit coordinate type. Then run a production-path
recursive trace for the intended level count; the four-level miniature proves
that the generic contract path can cross three child seams. These checks catch
malformed Solidity geometry, but cannot prove cross-implementation agreement.
The node compiles in no tournament geometry: startup reads the whole deployed
table, validates it (the root spans the 92-bit ruler, rows tile, the leaf
stride is zero, and the root stride lies between one big cycle and one input
window), and pins it; the Hero checks each tournament descriptor on its path
against the pinned row for its level. Cross-implementation commitment
agreement at the deployed strides is a separate gate; dispute-game.md
(tournament roles and configuration) names the evidence that carries it for
the canonical table.

`G` is not commitment-construction time. The contracts store the per-response
value, currently five minutes, in the `responseBudget` field. A
height-`H` match earns at most `H + 1` discounts: one for each of its `H - 1`
successful advances, one for its final leaf or inner seal, and one for a
winning leaf proof or timeout claim. If a response
starts with balance `b` and arrives after elapsed time `e`, it requires `e < b`
and leaves

```text
b' = b - max(e - G, 0)
```

The response never increases its starting balance, pairing earns no time, and
an expired clock cannot be revived. A win is charged the same way on its live
cost (time run plus any deferred charge). Joining, eliminating both sides,
child propagation, and bond recovery earn no discount. Across `q` responses,
`w` wins, and `j` child returns, the total elapsed time plus the remaining
clock mass is bounded by the starting mass plus `(q + w) * G + j * (T + 2G)`;
each child return stays within its pair's envelope. One root-to-leaf descent with one
match at each level spans 92 heights and ends in one leaf win, so it may earn at
most 7 hours 45 minutes, but only action by action. Re-pairing creates a new match with new
response discounts. The configured scalar remains five minutes, or 25 blocks
on Ethereum.

The honest node builds a child commitment from the latest view but joins
only from finalized state, so a join lands about `max(build, finality) +
inclusion` after the seal. `T + G` covers that while finality stays within
`T` (13 to 19 minutes on Ethereum today). A finality stall behaves like
censorship and draws on `C`, as does the root join's one finality delay. A
chain with slower finality must not reuse Ethereum's `T` without checking it.

`G` must also cover the honest node's own latency: one polling interval (30
s by default), the action's preparation (a leaf proof replays the disputed
input's prefix, bounded by the per-input compute contract), and inclusion.
A leaf proof, and the fallback timeout claim when the opponent's expiry
overtakes it, should land together within one `G` of the seal: the two
landings share one inclusion budget (dispute-game.md, CF-01). The strategy
below plans the claim instead of the proof when the opponent's clock cannot
outlive the proof; the node does not do that yet (todo.md, Node).

## Honest survival under the budgets

The safety claim the budgets serve, with the argument that composes the
clock rules into it. The claim: fix the correct computation and the correct
commitment at every level; if the correct participant follows the eager
strategy below and the adversary's cumulative censorship of its transactions
across the root and every linked descendant is at most `C`, then its clock
never expires in any tournament it enters, it is never eliminated, and a
finished root carries its final state. Termination and the delay bound stay
separate non-claims.

The strategy, as latency bounds: the root join lands within `G` of the
root's start; each child join within `T + G` of the seal that created the
child; every advance, seal, timeout claim and propagation within `G` of
becoming due; a leaf proof and its fallback timeout claim together within
`G` of the seal, the claim planned instead of the proof whenever the
opponent's clock cannot outlive the proof's latency, a choice the node does
not make yet: it claims only a timeout that has already occurred
(todo.md, Node). Every bound is strict,
since a clock expires at equality. Lateness beyond a bound is censorship,
drawn from one ledger that nothing refills.

The adversary enters Sybils at any level and time, in either contested
final-state class, the correct one's included; times its own actions freely;
controls both sides of its own matches; orders transactions within a block;
acts on the correct side's behalf wherever the surface is permissionless;
and censors within `C`. It cannot prove a wrong leaf.

The argument is a balance. Write `F = T + 2G` for one refill and
`D = L - 1` for the inner levels. After the root join at lateness `j0 < G`
and `d` child joins each at lateness `j_i < T + G`, with `c` of censorship
spent so far, the correct clock holds at least

```text
C - c + (G - j0) + G + (D - d) * F + sum_i (F - j_i)
```

because every landed response or win is forgiven up to `G`, every child
return refills its delegation by `F` within the pair envelope, and the
envelope is at least the correct side's own remainder at the seal. The
reserve `G` stays unspent until an action is in flight; each pending
delegation's unspent propagation inclusion adds another. A response or claim
in flight needs the balance to exceed its latency, which the reserve
supplies at every level. The leaf race is the tight step: after the worst
in-bound child join the correct child clock is `G + 2` blocks before the
reserve, and a Sybil that joins one block before closure and seals in its
pairing block forces the proof-to-timeout handover at any proof latency, so
the proof and the claim must share one `G`. The reserve added for F-01 lifts
that margin by `G` without changing the argument.

Evidence: `prt/contracts/test/properties/HonestSurvivalInvariant.t.sol`, a
stateful search over the small two-level geometry with budgets one inclusion
below the formula, the strategy above derived from production state, the
adversary powers above, and one ledger, in both orientations at `C` of 0, 2
and 5, 256 runs of depth 250 each; no schedule eliminated the correct
commitment or finished the root with another final state, and removing the
child-return refill makes every configuration fail. The deterministic worst
schedule is `HonestSurvivalSchedule.t.sol`. The argument has not yet been
reviewed by someone other than its author, and the search covers two levels
in a small box; neither is a theorem for any level count.

For one leaf match with current live balances `b1`, `b2` and `h` responses left,
the safe local wall-time bound is `b1 + b2 + h * G`. It cannot be replaced by one
allowance: a reachable equal-allowance schedule takes `2A - 1`, and a third
same-time claim waiting dangling extends completion to `3A - 1`. Population
halving after a common bounded window, aggregate transaction work, and finite
blockspace serialization are separate quantities. The current traces establish
these lower bounds and structural accounting. The bound does not require both
leaf clocks to keep consuming after the first expires: from that deadline
through the longer clock's deadline, only the live survivor continues to lose
time.

A proof-inclusive finite-state search now exhausts `N = 1..6`, `A = 1..4`,
`G = 0..2`, and `H = 1..3`, assuming every timeout is cleaned up in its first
eligible block while all join, response, proof, and same-block orderings remain
scheduler-controlled. For heights two and three, every cell in that domain has
completion time `A` for `N = 1`; for `N >= 2`, with
`g = min(G, A - 1)`, the observed maximum is

```text
2A - 1 + (H - 1)g
    + (ceil(N / 2) - 1) * (A + (H - 1)g + max(g - 1, 0))
```

The last term is the winner's discount: an earlier pair can reach its leaf and
end with a proof inside one `G`, so its survivor re-pairs with a full clock.

Height one has a different two-running-clock leaf-race table. These are finite
results, not an induction step. The model independently permits either side to
be objectively provable and does not impose an honest strategy, so it is a
clock-only upper envelope. A general attacker-versus-honest upper bound still
needs an unbounded proof or counterexample.

For the canonical heights `[54, 38]`, a root match can earn at most 270
minutes of discounts (a timeout win replaces its seal, since a sealed inner
match resolves through its child) and a leaf match at most 195 minutes,
including its win. One descent through one match at each level totals 465
minutes. These are per-match cumulative
ceilings, not values deposited into a clock or a whole-tournament maximum.

The independent `prt/measure_constants` emulator harness and the Rust
`just measure-level-constants` generator expose the two inputs that shape the
level layout: maximum acceptable root slowdown and the time budget for
constructing an inner commitment. Both derive strides and heights bottom-up;
the Rust generator, which prices the leaf on the node's own bulk collection
path, owns the current checked-in result and caveats in
`docs/measurements/constants.md`. The emulator harness supplies a second
measurement method across explicitly selected stress-ng workloads. Generator
output is evidence for a parameter set, not a permanent constant: workloads,
hardware assumptions, rounding, and the intended level count must travel with
the generated table. These tools take `T` and root slowdown as inputs and
derive strides and heights; they do not derive `G`.

This timing and geometry process is separate from EVM refund calibration.
[`prt-refund-gas-calibration.md`](runbooks/prt-refund-gas-calibration.md) owns
the manual procedure for measuring refundable contract actions, changing
`Gas.sol`, and tracing the resulting bond and deployment effects.

## Measurement discipline

Because clocks price the average, the average must be measured, and
measured validly:

- Measure on real workloads and label the density. An idle machine
  churns ~43 usteps per big cycle; typical executing code runs ~50;
  the instruction-heavy stress workload measures ~566 (the density
  label in docs/measurements/constants.md, and the basis for the candidate
  tables derived there); the span allows 2^20. A throughput number
  without its density label is meaningless for dimensioning.
- The classic measurement bug: timing a loop while the machine is in
  the wrong state - uarch halted (ustep is identity), machine yielded
  or halted (big steps no-op into idle churn), or a span the program
  already finished (pure padding). All inflate throughput and produce
  overly aggressive constants. Timing loops must assert the machine
  state they claim to measure, and report it.
- Everything here is hardware-relative. A derived constant carries
  the machine it was measured on; use a reference machine or an
  explicit slack factor, and keep every derivation re-runnable
  (`just measure-level-constants`; `just measure` / `just measure-stress`;
  docs/measurements/constants.md; docs/measurements/measurements*.md).

The emulator reference harness starts each selected stress-ng worker, reaches a
post-boot RX-accepted readiness marker, releases it through the CMIO API,
and runs a fixed untimed warmup before storing the active machine used by every
timed phase. Linux boot, process startup, input injection, and warmup are
excluded. Every timed span rejects halt, yield, early breaks, and non-pristine
uarch state. Capacity is rounded down to a complete power-of-two commitment.
Its cheap `check-fixtures` mode validates the warmed workload without running
the multi-minute measurements. The
curated nop, crypt, sorting, search, allocation, matrix, tree, TLB, and memory
churn workloads reduce single-workload bias; they do not make the sample a
protocol worst case or a representative application distribution.

## Pointers

- The "nested leaves are novel" invariant - why no cache or seed can
  ever cheapen a nested join - lives in computation-hash.md with its
  trap diagnosis. Read it before reasoning about dispute costs.
- The level constants chain from two free knobs. The leaf-level dense build
  fitting the commitment budget at average density determines
  `height[L - 1]`, with `log2step[L - 1] = 0`. Parent strides follow
  recursively from
  `log2step[i] = log2step[i + 1] + height[i + 1]`; the root slowdown budget
  selects the top stride, and `log2step[0] + height[0] = 92` closes the
  meta-cycle span. `ArbitrationConstants.sol` holds the live result;
  `measure.rs --constants` derives candidate tables,
  [measurements/constants.md](measurements/constants.md) owns the integration
  work, and the
  [completed review](reviews/2026-07-21-prt-dispute-game/REVIEW.md) preserves
  the decision provenance.
