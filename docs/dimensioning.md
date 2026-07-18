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
- Clocks (the inner tournament timeout, matchEffort, the root
  slowdown budget, and the strides derived from them): these price
  aggregates - sums of per-step costs over whole gaps. Rare heavy
  instructions vanish into a sum of millions of terms. The honest
  program lives at the average (~50 executed usteps per big cycle
  against the 2^20 span: a factor of ~20,000), and the trusted party
  authors that distribution. So clocks are sized to average density
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

## Tournament clock budgets

Keep three wall-clock quantities separate:

- `C`: the censorship budget within which a correct validator is assumed able
  to land a transaction.
- `T`: the maximum supported time to construct the commitment needed for one
  inner tournament.
- `G`: the small per-response inclusion and execution budget for a tournament
  transaction.

For `L` tournament levels, the intended root allowance and structural clock
bound are

```text
maxAllowance = C + (L - 1) * T
```

The root claim starts with the censorship budget and may later have to construct
one new commitment at each inner level. A child tournament does not necessarily
receive this maximum: sealing delegates the greater live remainder of the two
parent clocks, and that value becomes the child's tournament allowance. The
global `maxAllowance` remains a structural upper bound for legitimate child
clocks; no response operation dynamically raises a clock toward that bound.

The checked-in mainnet value, one week plus one hour, is consistent with the
historical three-level model at `T = 30 minutes`. The selected two-level
replacement uses `T = 60 minutes`, `log2step = [37, 0]`, and
`height = [55, 37]`, reaching the same numerical allowance. It remains planned
and must land with the separate node branch rather than changing the contract
constants in isolation.

`G` is not commitment-construction time. The contracts store the per-response
value, currently five minutes, in the legacy-named `matchEffort` field. A
height-`H` match earns at most `H` discounts: one for each of its `H - 1`
successful advances and one for its final leaf or inner seal. If a response
starts with balance `b` and arrives after elapsed time `e`, it requires `e < b`
and leaves

```text
b' = b - max(e - G, 0)
```

The balance never increases, pairing earns no time, and an expired clock cannot
be revived. Joining, proof resolution, timeout cleanup, child propagation,
elimination, and bond recovery are not eligible responses. Across `q`
responses, the total elapsed time plus the remaining clock mass is bounded by
the starting mass plus `q * G`. One root-to-leaf descent with one match at each
level spans 92 heights and may therefore earn at most 7 hours 40 minutes, but
only action by action. Re-pairing creates a new match with new response
discounts. The configured scalar remains five minutes, or 25 blocks on
Ethereum.

For the two-level target heights `[55, 37]`, a root match can earn at most 275
minutes of discounts and a leaf match at most 185 minutes. One descent through
one match at each level totals 460 minutes. These are per-match cumulative
ceilings, not values deposited into a clock or a whole-tournament maximum.

The historical `prt/measure_constants/measure.lua` script exposes the two inputs
that shape the level layout: maximum acceptable root slowdown and the time
budget for constructing an inner commitment. It derives strides and heights
bottom-up. The current generator is `just measure-constants`
(`measure.rs --constants`), with results and caveats recorded in
`docs/plans/constants.md`. Generator output is evidence for a parameter set, not
a permanent constant: measurements, hardware assumptions, rounding, and the
intended level count must travel with the generated table. These tools take `T`
and root slowdown as inputs and derive strides and heights; they do not derive
`G`. The node-owned generator and its generated planning prose still use the
historical grant wording. That documentation correction is intentionally
coordinated with the separate node branch and tracked in the review ledger.

This timing and geometry process is separate from EVM refund calibration.
`prt/contracts/audit/GAS-CALIBRATION.md` owns the manual procedure for measuring
refundable contract actions, changing `Gas.sol`, and tracing the resulting bond
and deployment effects.

## Measurement discipline

Because clocks price the average, the average must be measured, and
measured validly:

- Measure on real workloads and label the density. An idle machine
  churns ~34 usteps per big cycle; typical executing code runs ~50;
  the span allows 2^20. A throughput number without its density label
  is meaningless for dimensioning.
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
  docs/plans/constants.md; docs/plans/measurements*.md).

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
  `measure.rs --constants` derives candidate tables, and
  `prt/contracts/audit/REVIEW.md` records the selected migration.
