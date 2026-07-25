# Trust model and dimensioning rules

Who is allowed to be adversarial, and which case - worst or average -
each protocol dimension must be sized for. Settled 2026-07 during the
node-refactor campaign. The reasoning is the load-bearing part: new
dimensioning questions will appear, and the rule must be re-derivable
from it, not just remembered.

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

## The rule

Coordinates are dimensioned to the worst case. Clocks are dimensioned
to the average case.

- Coordinates (the structure spans: 2^20 usteps per big cycle, 2^48
  big cycles per input, 2^24 inputs per epoch): a single legitimate
  event that does not fit its span is fatal - the coordinate system
  cannot represent the honest computation, so the honest validator
  cannot even state the truth. Even an honest program occasionally
  executes the worst instruction (the sqrt / TLB-flush class, near
  the 2^20 bound - which is why the span is 2^20). One occurrence,
  ever, breaks soundness, so rarity does not discount anything.
- Clocks (the inner tournament timeout, responseBudget, the root
  slowdown budget, and the strides derived from them): these price
  aggregates - sums of per-step costs over whole gaps. Rare heavy
  instructions vanish into a sum of millions of terms. The honest
  program lives at the average (typical code runs ~50 executed usteps
  per big cycle against the 2^20 span, a factor of ~20,000; even the
  deliberately instruction-heavy stress workload measures ~616 - see
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
| input span per epoch (2^24) | single event | chain | worst case |
| leaf-level dense build within the inner timeout | aggregate | trusted app | average density |
| root slowdown (level-0 sampling overhead) | aggregate | trusted app | average |
| positioning through an input's prefix | aggregate | trusted app (per-input compute is an app design contract) | app profile |
| which gap / which leaf gets disputed | - | dispute adversary | worst location |

Open protocol gap, found 2026-07-15 while verifying halted/exception
semantics against the contracts (for the audit): a HALTED machine at
a window start whose input exists has no provable transition
on-chain - SendCmioResponse.sol requires iflags.Y and throws, so
neither party can produce a valid witness for any post-state at that
leaf, and the match degenerates to clock order. A halting app is not
adversary-authored (guest crash), but once it happens the node
cannot claim the epoch at all (the runner refuses to advance past a
halt), which forfeits settlement to any claimant. Either the
contracts define the halted-feed transition (e.g. the feed branch
checks the halt flag and degenerates to a plain step) or halting
apps are declared out of scope explicitly. The missing halt and
exception semantics are being addressed on the contracts side (in
progress as of 2026-07-15); node-side scheduling of halted windows
stays blocked on that work landing (the lead in one-engine.md step
4), and the off-chain revert sites must be re-verified against it.

## Base-layer censorship model

The contracts adopt the base-layer adversary model from Section 3 of the
[`Dave paper`](../dave/docs/dave.pdf), without adopting Dave's dispute
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
  tournament.
- `G`: the small per-response inclusion and execution budget for a tournament
  transaction.

The contract expires a clock when `elapsed >= allowance`. These duration
components are therefore strict provisioning bounds in the on-chain block
coordinate: modeled consumption before a required progress action must remain
below the configured duration. Timeout resolution becomes eligible at equality.
If a wall-clock policy states an inclusive maximum, its conversion must add
boundary slack rather than map equality to equality.

For `L` tournament levels, the intended root allowance and structural clock
bound are

```text
maxAllowance = C + (L - 1) * T
```

The root claim starts with the censorship budget and may later have to construct
one new commitment at each inner level. A child tournament does not necessarily
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

The checked-in mainnet value, one week plus one hour, is consistent with the
historical three-level model at `T = 30 minutes` - consistent in total
allowance only, not per-level shape: a fresh `T = 30` derivation produces a
different geometry (docs/measurements/constants.md), and the checked-in table
predates the current measurement tooling. The selected two-level
replacement uses `T = 60 minutes`, `log2step = [37, 0]`, and
`height = [55, 37]`, reaching the same numerical allowance. It remains planned
and must land with the separate node branch rather than changing the contract
constants in isolation.

Before adopting any generated table, run the test-only whole-table validator
under `prt/contracts/test/config/`. It checks the declared level count, positive
heights and root allowance, heights and row extents strictly below 256,
256-bit shift limits, root span, inter-level tiling, and zero leaf stride. A
height or row extent of 256 would require representing the span `2^256`, which
does not fit the clients' 256-bit coordinate type. Then run a production-path
recursive trace for the intended level count; the four-level miniature proves
that the generic contract path can cross three child seams. These checks catch
malformed Solidity geometry, but cannot prove cross-implementation agreement.
The node's commitment strides and the complete contract table must still be
compared as a release gate.

`G` is not commitment-construction time. The contracts store the per-response
value, currently five minutes, in the `responseBudget` field. A
height-`H` match earns at most `H` discounts: one for each of its `H - 1`
successful advances and one for its final leaf or inner seal. If a response
starts with balance `b` and arrives after elapsed time `e`, it requires `e < b`
and leaves

```text
b' = b - max(e - G, 0)
```

The response never increases its starting balance, pairing earns no time, and
an expired clock cannot be revived. Joining, proof resolution, timeout cleanup,
child propagation, elimination, and bond recovery are not eligible responses.
Across `q` responses, the total elapsed time plus the remaining clock mass is
bounded by the starting mass plus `q * G`. One root-to-leaf descent with one
match at each level spans 92 heights and may therefore earn at most 7 hours
40 minutes, but only action by action. Re-pairing creates a new match with new
response discounts. The configured scalar remains five minutes, or 25 blocks
on Ethereum.

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
    + (ceil(N / 2) - 1) * (A + (H - 1)g)
```

Height one has a different two-running-clock leaf-race table. These are finite
results, not an induction step. The model independently permits either side to
be objectively provable and does not impose an honest strategy, so it is a
clock-only upper envelope. A general attacker-versus-honest upper bound still
needs an unbounded proof or counterexample.

For the two-level target heights `[55, 37]`, a root match can earn at most 275
minutes of discounts and a leaf match at most 185 minutes. One descent through
one match at each level totals 460 minutes. These are per-match cumulative
ceilings, not values deposited into a clock or a whole-tournament maximum.

The historical `prt/measure_constants/measure.lua` script exposes the two inputs
that shape the level layout: maximum acceptable root slowdown and the time
budget for constructing an inner commitment. It derives strides and heights
bottom-up. The current generator is `just measure-constants`
(`measure.rs --constants`), with results and caveats recorded in
`docs/measurements/constants.md`. Generator output is evidence for a parameter set, not
a permanent constant: measurements, hardware assumptions, rounding, and the
intended level count must travel with the generated table. These tools take `T`
and root slowdown as inputs and derive strides and heights; they do not derive
`G`. The node-owned generator and its generated planning prose still use the
historical grant wording. That documentation correction is intentionally
coordinated with the separate node branch and tracked in
[`constants.md`](measurements/constants.md).

This timing and geometry process is separate from EVM refund calibration.
[`prt-refund-gas-calibration.md`](runbooks/prt-refund-gas-calibration.md) owns
the manual procedure for measuring refundable contract actions, changing
`Gas.sol`, and tracing the resulting bond and deployment effects.

## Measurement discipline

Because clocks price the average, the average must be measured, and
measured validly:

- Measure on real workloads and label the density. An idle machine
  churns ~34 usteps per big cycle; typical executing code runs ~50;
  the instruction-heavy stress workload measures ~616 (the density
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
  (`just measure-constants`; `just measure` / `just measure-stress`;
  docs/measurements/constants.md; docs/measurements/measurements*.md).

Known instances (measure.lua audited 2026-07-08): the script guards
big-machine HALT correctly everywhere (its timing loops measure real
work, no identity steps, padding never stepped), but it never checks
YIELD - a manually-yielding machine (any rollups image) would be
re-hashed frozen with the halt assert passing, inflating throughput
or hanging; historical results are trustworthy only because the
shipped compute targets halt rather than yield. Two further defects:
uarch halt detection compares `run_uarch()`'s return against the
BIG-machine break-reason enum and works only because both enums
number HALTED = 1 (a reorder silently breaks it, measure.lua:91,118);
and heights round upward (`floor(log2)+1`, measure.lua:144,222), so
derived constants can demand up to ~2x the measured throughput -
optimism to subtract from any observed slack. Any port must guard
halt AND yield, use the correct enum, and round conservatively.

## Pointers

- The "nested leaves are novel" invariant - why no cache or seed can
  ever cheapen a nested join - lives in computation-hash.md with its
  trap diagnosis. Read it before reasoning about dispute costs.
- The level constants chain from two free knobs. The leaf-level dense build
  fitting the inner timeout at average density determines
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
