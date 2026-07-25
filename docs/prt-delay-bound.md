# PRT delay and work bounds

The derivation record behind the delay-bound invariants stated in
[`dispute-game.md`](dispute-game.md#delay-work-and-bracket-shape): the
population and clock accounting, the potential-function bound, worked
adversarial lower-bound traces, the finite-state exhaustive model, and
the multi-level asymptotic attack shapes. The code and its property
tests remain the source of truth. The claim-status table in
dispute-game.md governs how far any expression here may be relied on;
this document exists so that the derivations can be checked, not so
that they can be cited as stronger claims than that table records.

Let `K` be the number of live commitments in one tournament. There are
`M = floor(K / 2)` live matches and `D` dangling commitments, with

```text
K = 2M + D
D in {0, 1}
```

During bisection, one of each match's two clocks runs; after leaf sealing both
run. A leaf tournament therefore has at least `M` running clocks. Stale clock
storage for commitments already eliminated is not part of `K`.

A sealed non-leaf match is the recursive exception: after the final response
discount, both parent clocks pause with snapshotted remainders `r1` and `r2`,
and the child tournament receives `max(r1, r2)` as its initial allowance. A
child deadline closes joining; child finish still depends on resolving its
matches and any deeper children. The recursive structural invariant is
therefore that every parent pair either has a clock running or has delegated
population reduction to a child tournament. At most one commitment per
tournament escapes pairing by waiting dangling. If `S` of the `M` parent
matches are sealed-inner, the parent-local count is
`runningClocks >= M - S`; each of those `S` exceptions has one linked child
carrying the bounded resolution obligation.

The executable
[`ConcurrentRecursivePopulation.t.sol`](../prt/contracts/test/properties/ConcurrentRecursivePopulation.t.sol)
trace pins one production instance of this accounting: four parent commitments
form two sealed matches, the two linked children coexist with the same deadline,
and each child reduces four live commitments to one over two timeout waves before
propagation re-pairs the parent winners. The trace covers local timed matches
versus linked-child obligations at both even and odd parent populations. It is a
fixed balanced-arrival witness, not an asynchronous upper-bound model: parent
seals are immediate, allowances are equal, and cleanup occurs promptly at exact
deadlines.

On successful propagation, the returned child-winner clock replaces the
corresponding parent clock after post-finish deduction; it is not added to the
parent balance. The maximum is a shared pair envelope, not side-specific
carryover. If the child winner maps to the side with the smaller post-discount
snapshot, that side may return with more than its own `r_i`. The other parent is
eliminated, and the returned survivor still satisfies

```text
0 < returned <= max(r1, r2) <= r1 + r2
returned <= maxAllowance
```

The shared maximum is a worst-case envelope, not side-specific conservation. An
adversary controlling both sides can choose which Sybil survives. Against a
correct side, a child commitment is classified by its contested final state
rather than by claimer or root lineage, so a distinct child root may enter
either parent's final-state class. More exact lineage accounting would alter
individual schedules without excluding the preserved-clock delay strategy.
The fixed-budget, fixed-metric qualification and its non-claims are documented
in [`dimensioning.md`](dimensioning.md).
Thus recursive propagation may transfer live clock mass within the sealed pair,
but does not create live pair-level clock mass. The eliminated side's historical
clock storage may remain. Ordinary same-tournament settlement and pairing never
grant time.

That active-pair invariant, rather than the visual shape of the asynchronous
bracket, gives a structural population reduction. It does not say that one
clock allowance resolves a pair: the two clocks in one match can consume time
serially.

For one height-`H` match, let `B` be the sum of its two clock balances and `h`
the number of eligible responses still required. The potential

```text
potential = B + h * G
```

drops by `max(e, G)` on a successful response of elapsed duration `e`. Across
`q` responses,

```text
responseElapsed + B_after
    = B_before + sum(min(e_i, G))
    <= B_before + q * G
```

From any observation instant, a leaf match with current live balances `b1` and
`b2` and `h` eligible responses left has the safe local bound

```text
W_match <= b1 + b2 + h * G
```

to resolution with at most one survivor. For a non-leaf match, the same
expression bounds reaching local seal or timeout deletion, but excludes
resolution of any child created by sealing. Consequently, in a single-level
leaf tournament with per-clock bound `A`, every match present at instant `t`
resolves within the common bound `W = 2A + H * G`. If joining has closed and
permissionless cleanup is prompt, the structural population statement is

```text
K(t + W) <= ceil(K(t) / 2)
```

This treats transactions as available when needed; finite blockspace is a
separate source of wall-clock serialization. Iterating the structural statement
gives an all-at-once reservoir the coarse clock-delay upper bound

```text
(2A + H * G) * max(1, ceil(log2(P)))
```

for `P` commitments of one common height. This is deliberately conservative;
many timeout paths consume only one clock. It is also an upper-bound argument,
not a claim that half the population disappears after one allowance.

Production-path lower-bound traces show why that distinction matters. In the
height-three fixture, let two equal clocks start with allowance `A >= 2` and let
`0 <= G < A`. The active side can respond at `A - 1`, retaining `G + 1`, then
make the other side consume its full allowance. The first match is deleted at
elapsed time `2A - 1`. If a third claim has waited dangling since the initial
block, re-pairing starts its untouched clock and its timeout becomes available
at `3A - 1`. These schedules are reachable for both `G = 0` and `G > 0`; the
discount is the only extra term in the exact clock-mass identity. They show
that both clocks of a pair and then a dangling claim can serialize in wall
time. They neither show that a responsive correct participant must follow the
schedule, disprove the coarser population-window upper bound, nor prove that
this is the globally optimal adversarial strategy.

A separate proof-inclusive finite-state model exhausts every schedule in its
clock abstraction for `N = 1..6`, `A = 1..4`, `G = 0..2`, and `H = 1..3`
under prompt first-eligible-block timeout cleanup. It explores late joins,
responses, pre-timeout proofs, timeout and proof settlement, re-pairing, and
same-block ordering. For heights two and three, its finite maxima match

```text
N = 1: A
N >= 2: 2A - 1 + (H - 1)g
          + (ceil(N / 2) - 1) * (A + (H - 1)g)
where g = min(G, A - 1)
```

Height one has a distinct leaf-race table. The model deliberately lets either
side be provable independently at each leaf, forgetting cross-match correctness
correlation, and it does not impose an honest-validator strategy. Its values are
therefore a conservative clock-only envelope for that finite box, not the
general adversarial theorem. The executable maximum witness for
`N = 3, A = 4, G = 2, H = 3` completes at relative block 19 and is replayed
against `Tournament`.

Progressively late joins have their initial clocks reduced by their lateness,
and ordinary re-pairing never refills a survivor. Still, the asynchronous
bracket can look like a list and a same-time dangling claim can retain a full
paused clock.
Only one unmatched commitment per tournament can wait without an opposing
running clock or delegated child. Full population-halving rounds require a
corresponding live claim reservoir, but that structural fact must not be
substituted for a finite wall-time proof. The timeout argument also depends on
charging each elapsed interval at most once: a paused bisection winner inherits
the responder's overdue interval, while a running leaf winner has already paid
for it through its live remainder.

For the intended two-level deployment, let `A_i` denote the allowance-scale
term available at level `i`. An attack with `R` root claims and `S` claims in
each slow child has the approximate allowance-only delay shape

```text
log2(R) * (A0 + log2(S) * A1)
```

For `L` per-level reservoirs `n_i`, with total claim instances approximately
`N = product(n_i)`, the deepest nested allowance term has the shape

```text
A_(L - 1) * product(log2(n_i))
```

Under comparable per-level allowance and claim costs, the balanced construction
uses `n_i ~= N^(1/L)` and has the familiar leading shape

```text
A * (log2(N) / L)^L
```

These asymptotic expressions suppress finite response terms. For a conservative
one-level leaf window, substitute `W_i = 2A_i + H_i * G` for an
allowance-only term. The construction requires a full adversarial reservoir of
order `product(n_i)`. Here `N` counts claim instances across distinct
tournament contracts, not unique actors. Different per-level bond values change
the budget-balancing point.

The construction is not a recursive upper bound over every asynchronous
ordering. The retained on-chain trace validates concurrent-child population
mechanics for its fixed four-root, four-child-claim shape, not the expression's
worst-case timing.
