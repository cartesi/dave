# The computation hash

The computation hash (also called the commitment) is the object the whole
dispute protocol argues about. This document explains what its leaves are,
how they are generated, and why the micro-architecture gymnastics exist.
It is the single most arcane part of the codebase; read this before touching
`cartesi-rollups/node/src/engine/` or
`cartesi-rollups/node/src/storage/rollups_machine.rs`.

> Verify claims against the code. Primary sources:
> `machine/rust-bindings/cartesi-machine/src/constants.rs`,
> `machine/step/src/EmulatorConstants.sol`,
> `cartesi-rollups/node/src/engine/{structure,ruler,stf}.rs`, and the Solidity
> state-transition contracts under `prt/contracts/src/state-transition/`.

## Why micro-steps

The Cartesi Machine state-transition function has two layers: the big
machine (RV64GC, implemented in C++ in the emulator) and the
micro-architecture, or uarch (RV64I, small enough to implement in Solidity).
Each big-machine instruction is emulated by a bounded run of uarch
instructions ("machine swapping"). Disputes must bottom out in a single
transition that a contract can verify, so commitment leaves live at uarch
granularity: the on-chain referee only ever executes one uarch step (plus a
few auxiliary state mutations described below).

## The meta-cycle coordinate system

A position in an epoch's computation is a 92-bit integer called the
meta-cycle, carved into three fields. The primitive field widths come from the
emulator's rollup constants; `Structure::PRODUCTION` composes them into Dave's
coordinate system:

```
  bits 91..68            bits 67..20            bits 19..0
+---------------------+----------------------+---------------------+
| input index (24)    | big cycle (48)       | ucycle (20)         |
+---------------------+----------------------+---------------------+
  MAX_ADVANCE_STATES     MAX_MCYCLES_PER        MAX_UARCH_CYCLES
  PER_EPOCH = 24         ADVANCE_STATE = 48     PER_MCYCLE = 20
```

- An epoch processes at most 2^24 inputs.
- Each input is allotted at most 2^48 big-machine cycles.
- Each big cycle is emulated by at most 2^20 uarch cycles (including the
  reset; see below).

`Structure::decompose` (`engine/structure.rs`) is the one decoder and authority
for the field layout: input index =
`meta >> 68`, big cycle = `(meta >> 20) & (2^48 - 1)`, ucycle =
`meta & (2^20 - 1)`. (The prototype's shift/mask decoder survives as a
differential oracle in `cartesi-rollups/node/tests/common/`.)

Primitive widths are referenced directly through
`cartesi_machine::constants::rollup`, Lua's `cartesi.ROLLUP_LOG2_MAX_*`, or
the generated Solidity `EmulatorConstants`. Dave-owned constants are derived
quantities such as the input-window width, ruler width, and field masks. A
width is `k`, a span is `2^k`, and a mask is `2^k - 1`; keep those concepts
distinct when changing the coordinate code.

`CartesiStateTransition` accepts only counters inside this 92-bit epoch span.
It rejects a larger counter before parsing its proof or consulting the data
provider. The concrete adapter also exposes the `CM_MARCHID` qualified for the
pinned Cartesi Machine v0.21 release. Dave pins that value locally until a
released solidity-step exports it. Node startup compares the deployed value
with the linked Cartesi Machine library before opening or initializing local
storage.

## The leaf sequence

The commitment is a Merkle tree whose leaf at position `m` is the machine
root hash after applying transition `m`. The state before leaf 0 is not in
the tree; it rides along as the commitment's implicit hash
(`MachineCommitment.implicit_hash`) and is what parties implicitly agree on
at the start.

Transition `m` is one of three shapes, selected by where `m` falls
(`Ruler::prove_transition` mirrors this on the proof side, through the
same `Position` predicates the ruler steps by):

1. Input boundary (`ucycle == 0` and `big cycle == 0`): if the epoch has an
   input at this index, the transition atomically performs:
   - feed the input via a CMIO response, passing the current root as its
     revert root (the send primitive records it in the shadow slot),
   - execute one uarch step.
   If there is no input, it is just the uarch step (with a proof that the
   data availability is empty).
2. Big-step boundary (`(m + 1)` is a multiple of 2^20): one uarch step plus a
   uarch reset. The step is normally a halted no-op; an unhalted machine whose
   uarch counter is already maximal instead reports cycle overflow and is also
   unchanged. The reset itself substitutes the recorded revert root if the big
   machine yielded rejecting the input (see below).
3. Anywhere else: a single uarch step.

On-chain, `CartesiStateTransition` selects these three shapes explicitly. An
input boundary optionally calls `SendCmioResponse` and then `UArchStep`; a
big-step boundary calls `UArchStep` and then `UArchReset`; every other position
calls only `UArchStep`. Each branch requires the access-log proof buffer to be
consumed completely before returning its root.

The node's computation source owns transition-proof preparation: it replays
to the disputed position, checks the sealed agree-state hash, generates the
witness, and checks the claimed post-state hash before returning bytes. Hero
selects the position and its side's claimed state from the match. A mismatch
is a local preparation error; no proof action is submitted.

Inside one big cycle, the uarch typically halts long before spending its
2^20 budget. The remaining slots are padded by repeating the halted state
hash (a run's `repetitions`, held in memory only), so every big cycle
contributes exactly 2^20 leaves. After the machine yields for the last time
in an input
window (or halts), the remaining big cycles idle - but only their
boundaries repeat the final state. The yield and halt flags gate the
big machine, not the uarch: stepping the uarch of an idle machine
churns the emulated interpreter's own bookkeeping (it checks the flags
and declines to execute, a few dozen usteps) until the uarch halts,
and the closing ureset restores the base hash exactly. Every idle big
cycle therefore contributes one identical churn-and-reset leaf
pattern; at strides of a big cycle or coarser this collapses to a
repeated constant, while uarch-stride commitments carry the pattern
itself. Padding is what makes the tree geometry fixed while real
computation lengths vary.

All of this assumes the deployed step's pristine uarch at every big-cycle
boundary. The closing reset rewrites the uarch region to it, so only the
template can break the assumption, and the template is the trusted app
developer's (docs/dimensioning.md). Dave relies on it twice: the big
machine runs whole cycles without touching the uarch, and one captured idle
span stands for every later one. The v0.21 CLI and the Lua client rely on
it too. A template with custom uarch code is outside the model: on the
release corpus case `uarch-near-limit-tail`, Solidity, the CLI and Dave give
three different roots. The node refuses such a template at startup, before
it touches the state directory: a uarch reset must leave the template's root
unchanged. That compares with the linked emulator's pristine uarch; that it is
the deployed step's is the provenance gate's concern.

### Toy picture

Scaled-down epoch: 2 inputs per epoch, 2 big cycles per input, 4 uarch
slots per big cycle (production: 2^24, 2^48, 2^20).

```
meta-cycle  0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
          | u   u   u   uR| u   u   u   uR| u   u   u   uR| u   u   u   uR|
          +---- big 0 ----+---- big 1 ----+---- big 0 ----+---- big 1 ----+
          +------- input window 0 --------+------- input window 1 --------+
            ^                           ^   ^                           ^
            add-input 0 + revert root   |   add-input 1 + revert root   |
                         reset substitutes on reject   reset substitutes on reject
```

`u` = uarch step, `uR` = final uarch step + uarch reset. The final step is
normally halted; uarch-cycle overflow is also a valid identity step.

## Checkpoint and revert

Rollups semantics require rejected inputs to leave no trace: the machine
state must roll back to what it was before the input was fed. Off-chain
that is easy (reload a snapshot). On-chain it must be provable, which is
the trick:

- The emulator reserves a dedicated memory slot for the pre-input root hash
  (`CM_AR_SHADOW_REVERT_ROOT_HASH_START`, re-exported as
  `CHECKPOINT_ADDRESS` in `engine/constants.rs`).
- At each input boundary, `send_cmio_response` receives the current root as
  an argument and records it in that slot as part of the same logged
  operation that delivers the input. There is no separate checkpoint write
  or proof.
- When the machine yields with reason REJECTED - and only then - the
  uarch reset reads the recorded hash and replaces the entire machine root
  with it. State restored, provably, inside the reset log. An EXCEPTION or
  unexpected manual yield keeps its terminal state; halt and mcycle overflow
  with no manual yield pending are terminal as well. Sending a later advance
  response to any of those states is a provable no-op, so every
  window-opening transition remains defined. The step reads only the pending
  yield, never the halt flag or the input budget: an RX_ACCEPTED yield on the
  budget's last cycle (mcycle == imcyclemax), or on a template preset halted,
  is not terminal - the next advance response is delivered - and an
  RX_REJECTED one still reverts. Delivery renews the budget unless it is
  saturated at 2^64 - 1, where the fed machine is an overflow fixed point.

  The logged reset returns the canonical substituted root but leaves the
  physical emulator with only its uarch reset. Both off-chain clients reload
  the pre-input snapshot after logging or executing a rejected reset. Their
  equivalent big-machine run shortcuts perform the same reload when they
  observe `RX_REJECTED`, so subsequent execution begins at the canonical
  state. Solidity remains the semantics authority. The released corpus is
  immutable conformance evidence; the release CLI replays it through the
  emulator collect APIs and is therefore not an independent implementation or
  a replacement for contract tests.

The Solidity side reads the slot address from step's auto-generated
`EmulatorConstants.sol`. The unit test
`test_emulator_and_step_agree_on_revert_address` (`engine/constants.rs`)
guards the two against drifting apart across emulator/step bumps.

Off-chain, `MachineStf` mirrors this with a pre-feed snapshot per fed input;
its reset, logged-reset, big-run and bulk-collection paths all apply the
conditional physical reload. The bulk collector reports a rejection itself
from a revert tail, the idle period the node collects from the pre-feed
machine.

## Tournament levels and strides

Nobody can build (or store) 2^92 leaves. The dispute is split into levels;
`prt/contracts/src/arbitration-config/ArbitrationConstants.sol` holds the
deployed table. The two tables in use are three levels and two:

```
three levels
level  log2step  height   leaf =                       tree covers
0      44        48       one hash per 2^44 usteps     whole epoch (2^92)
1      27        17       one hash per 2^27 usteps     one level-0 stride
2      0         27       one hash per ustep           one level-1 stride

two levels
level  log2step  height   leaf =                       tree covers
0      37        55       one hash per 2^37 usteps     whole epoch (2^92)
1      0         37       one hash per ustep           one level-0 stride
```

Invariants: `log2step[i] == log2step[i+1] + height[i+1]`, and
`log2step[0] + height[0] == 92`. A level's tree refines exactly one leaf
stride of its parent. Only the leaf level (stride 0) reaches individual
uarch steps, where the on-chain state transition can verify one transition.

## Nested leaves are novel

A level-(i+1) tree refines one leaf stride of its parent: its leaves
sample the INTERIOR of that gap, at points the parent never touched.
The gap's initial state is shared but is not a leaf - it is the
implicit hash, the agreed state the match sealed on. The final leaf
is shared (the parent's next sample; joining proves consistency with
it). Every interior leaf is novel: never computed before, and not
precomputable, because the adversary picks which of the parent's
gaps gets disputed and the gap count makes precomputation
meaningless. Level 0 is the only level whose leaves pre-exist, and
only because the open regime computes them while the machine runs
anyway, priced by the root slowdown budget.

Consequently a nested join costs, irreducibly, one full replay of the
gap computing every leaf at the child stride - in any node
architecture. The sling engine changes only what happens after that
build: it keeps 8 levels of the tree and recomputes sub-slices of the
same leaves on deeper descents - a disk/recompute trade below the
root, never a cheaper root.

This is the most-confused fact in the system (four people and
counting, including its designers). The trap's mechanism: every path
anyone ever observes is cheap - level 0 answers from seeds, repeated
queries answer from the cache, test workloads are benign - so
intuition generalizes "roots come cheap" downward and "we have these
leaves already" sideways. Both generalizations are wrong: seeds exist
only at level 0, and the cache only ever holds leaves of divergences
already visited (a restart-resume aid, never a dimensioning input).
The path that sizes the system - a cold build over an
adversary-chosen gap - is the one path that never occurs unless
deliberately constructed. When pricing dispute costs, always price
the cold path; docs/dimensioning.md says which case (worst or
average) each dimension takes and why.

Two generation regimes exist off-chain (the sling ruler,
`cartesi-rollups/node/src/engine/ruler.rs`; the prototype builder in
`cartesi-rollups/node/tests/common/prototype.rs` implements the same split
and survives as a differential test oracle):

- Coarse sampling (`log2_stride >= 20`): run the big machine
  `stride / 2^20` big cycles at a time, one leaf per stop; when it reaches an
  input boundary or terminal state, pad the rest.
- Uarch sampling (`log2_stride == 0`): run uarch spans: one leaf
  per uarch step until uarch halt, pad to 2^20 - 1, append the post-reset
  state as the span's last leaf. Rejected-input substitution is already part
  of that reset state.

A stride-0 quartet tall enough that its 8 stored levels stay above big-cycle
granularity (a two-level leaf commitment is 2^37 transitions) is built from
one root per big cycle. The node takes the active cycles' roots from the
emulator's uarch collector (`cm_collect_uarch_cycle_root_hashes` bundled at
2^20, so each mcycle's entries end with its cycle's root), and an idle
stretch steps one captured span and repeats its root. The tree is the one
stepping every span would build. The stepped path stays, permanently, as the
test reference, and in production it covers one cycle the v0.21 collector gets
wrong: a rejection on the input budget's last cycle keeps the physical root
instead of the revert root, so that cycle is stepped. That fallback cannot
cover an input whose first cycle is its budget's last, which takes a delivery
at mcycle 2^64 - 2, where the budget saturates: a template preset there, or
centuries of machine time. It is out of model, and the node stops with an
assert where stepping would proceed. Memory is one
collection call's roots plus a tree over one root per active big cycle, and
an idle stretch costs one span however long it is.

The rollups node computes level-0 leaves eagerly while processing
inputs, at the root stride of the deployed tournament table (pinned at
initialization; 2^44 under three levels, one leaf per 2^24 big cycles, and
2^37 under two, one per 2^17) and
folds each closed window's runs into its window-root quartet row as
it commits - the unfolded runs are never persisted. At dispute time
the facade serves level 0 at or above window granularity from those
rows plus fixed-point padding math; everything below window
granularity - and every deeper level - is computed lazily by
re-running the machine, and cached as merkle nodes in the quartet
cache (`sling_nodes`, keyed by epoch, stride, height, and shift).

Before opening its database, the node reads the deployed tournament
factory's whole level table and refuses to start unless it passes the
geometry validator (the root spans this 92-bit ruler, levels tile, the leaf
stride is zero); it compiles in no stride. Initialization pins the table, and
level-0 sampling uses the pinned root stride. Each clone's immutable
descriptor is checked against its pinned row when the recursive dispute
reaches it (docs/node-architecture.md has the startup detail).

One subtlety (the ruler's fused feed transition): a machine snapshot taken at
an input boundary sits awaiting input. That boundary state is the implicit
hash for the next span, not its first leaf; the builder must feed the pending
input before executing the first ustep.

## Where implementations must agree

The same leaf sequence is computed independently by:

1. the Rust node (`cartesi-rollups/node`: level 0 eagerly in the machine
   runner, `Ruler::collect` folded per window in `storage/advance.rs`, and
   dispute levels lazily in `engine/`; its dense leaves come from the
   emulator's collector, the lineage the CLI shares, and its stepped path,
   kept as a test reference, is what stays independent of it),
2. the Lua client (`prt/client-lua/computation/`), and
3. implicitly, the on-chain state transition (one leaf transition at a
   time).

Roles: Solidity (`CartesiStateTransition` over `machine/step`) is the
authority for one transition. The release corpus is immutable conformance
evidence; the release CLI replays it through the emulator's collectors, so it
is not independent of the node's bulk path. The node's stepped path, the Lua
client and the test-only prototype builder are the independent lineages.
Agreement alone is not evidence (at seam 2 the node and the v0.21.0 CLI once
agreed and were both wrong): a divergence between any two is settled by
proving the transition through Solidity, and a golden is regenerated only
after its differential passes.

Where the v0.21.0 CLI disagrees with the step, the step wins and the case is
a named exclusion rather than a reference answer, until a tagged release
carries the fix (todo.md, Upstream):

- Seam 1: the rejecting period's uarch hash keeps the physical root at the
  closing reset (the node's bulk collector shares this; the seam-1 guard
  steps that cycle). After either seam with more inputs to come, the CLI
  ends the epoch and pads. The unreleased upstream c1280ed4 fixes both.
- A non-pristine uarch: `uarch-near-limit-tail` is out of model (above;
  the unreleased 22b4431 makes it error-no-hash), and a uarch cycle overflow
  or a uarch halting at `UARCH_CYCLE_MAX` throws where the step defines an
  identity step (no upstream fix yet).
- An oversized input throws where the step is a no-op (c1280ed4's host-send
  hunk); `InputBox` caps inputs at 2^16 bytes, so only synthetic vectors
  reach it.

Two v0.21 emulator traits shape Dave's tests and leaf builds without
changing any value: it flocks the files it creates without close-on-exec, so
tests that spawn anvil run serially (the justfile's `test-node-harness`), and
its hash tree goes parallel by core count rather than by work, so per-step
leaf hashing runs serially (`runtime_config`, `engine/machine_stf.rs`).

Any divergence between (1)/(2) and (3) means an honest node loses a
dispute it should have won. The e2e tests cross-check (1) against (2)
every epoch (`test/e2e/rollups/test_env.lua`, `epoch_settlement`), and
the stf test cases exercise (3) against both. Preserve these cross-checks
when refactoring; they are the executable specification of this document.

A change to leaf values or transition shapes (terminal rule, feed and revert,
sampling, strides) must bump `COMMITMENT_SEMANTICS` in
`cartesi-rollups/node/src/storage/sql/schema.rs`, so stores built under the
old rules are refused instead of reused.

The ruler's unit tests use a small scripted machine to enumerate complete
epochs. A literal window/cycle/slot oracle checks stepping and sampling;
cache and proof tests also use trees built from those checked runs. This
separates geometry errors from machine behavior, but does not establish that
the script models Cartesi correctly. The real-machine differentials and
on-chain state-transition tests provide that separate evidence. The scripted
machine and its proof markers are compiled only for unit tests.
