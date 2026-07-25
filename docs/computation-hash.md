# The computation hash

The computation hash (also called the commitment) is the object the whole
dispute protocol argues about. This document explains what its leaves are,
how they are generated, and why the micro-architecture gymnastics exist.
It is the single most arcane part of the codebase; read this before touching
`cartesi-rollups/node/src/engine/` or
`cartesi-rollups/node/src/storage/rollups_machine.rs`.

> Verify claims against the code. Primary sources:
> `cartesi-rollups/node/src/engine/constants.rs`,
> `cartesi-rollups/node/src/engine/{structure,ruler,stf}.rs`, and the
> Solidity state-transition contracts under
> `prt/contracts/src/state-transition/`.

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
meta-cycle, carved into three fields (`engine/constants.rs`):

```
  bits 91..68            bits 67..20            bits 19..0
+---------------------+----------------------+---------------------+
| input index (24)    | big cycle (48)       | ucycle (20)         |
+---------------------+----------------------+---------------------+
  LOG2_INPUT_SPAN_      LOG2_BARCH_SPAN_       LOG2_UARCH_SPAN_
  TO_EPOCH = 24         TO_INPUT = 48          TO_BARCH = 20
```

- An epoch processes at most 2^24 inputs.
- Each input is allotted at most 2^48 big-machine cycles.
- Each big cycle is emulated by at most 2^20 uarch cycles (including the
  reset; see below).

`Structure::decompose` (`engine/structure.rs`) is the decoder - the one
authority for the field layout since workstream 4: input index =
`meta >> 68`, big cycle = `(meta >> 20) & (2^48 - 1)`, ucycle =
`meta & (2^20 - 1)`. (The prototype's shift/mask decoder survives as a
differential oracle in `cartesi-rollups/node/tests/common/`.)

Naming trap: the `*_SPAN_*` constants are defined with `max_uint`, so they
are masks (2^k - 1), not spans (2^k). Code uses them both ways; do not
"fix" one usage without auditing the others.

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
   - write the current root hash into the checkpoint slot (see below),
   - feed the input via a CMIO response,
   - execute one uarch step.
   If there is no input, it is just the uarch step (with a proof that the
   data availability is empty).
2. Big-step boundary (`(m + 1)` is a multiple of 2^20): the uarch must have
   halted by now; the transition is a (no-op, halted) uarch step plus a
   uarch reset, and, if the big machine yielded rejecting the input, a
   revert (see below).
3. Anywhere else: a single uarch step.

Inside one big cycle, the uarch typically halts long before spending its
2^20 budget. The remaining slots are padded by repeating the halted state
hash (`repetitions` in leaf storage), so every big cycle contributes exactly
2^20 leaves. After the machine yields for the last time in an input
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

### Toy picture

Scaled-down epoch: 2 inputs per epoch, 2 big cycles per input, 4 uarch
slots per big cycle (production: 2^24, 2^48, 2^20).

```
meta-cycle  0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
          | u   u   u   uR| u   u   u   uR| u   u   u   uR| u   u   u   uR|
          +---- big 0 ----+---- big 1 ----+---- big 0 ----+---- big 1 ----+
          +------- input window 0 --------+------- input window 1 --------+
            ^                           ^   ^                           ^
            checkpoint + add-input 0    |   checkpoint + add-input 1    |
                              revert if rejected              revert if rejected
```

`u` = uarch step, `uR` = (halted) uarch step + uarch reset.

## Checkpoint and revert

Rollups semantics require rejected inputs to leave no trace: the machine
state must roll back to what it was before the input was fed. Off-chain
that is easy (reload a snapshot). On-chain it must be provable, which is
the trick:

- The emulator reserves a dedicated memory slot for the pre-input root hash
  (`CM_AR_SHADOW_REVERT_ROOT_HASH_START`, re-exported as
  `CHECKPOINT_ADDRESS` in `engine/constants.rs`).
- At each input boundary, the transition writes the current root hash into
  that slot before feeding the input (the "checkpoint").
- When the machine yields with reason REJECTED - and only then - the
  big-step boundary transition reads the checkpoint hash out of the
  rejected state and replaces the entire machine root with it. State
  restored, provably. An EXCEPTION yield keeps the exception state (no
  restore), and any other manual reason has no defined transition
  on-chain (AdvanceStatus reverts with InvalidReason). Solidity is the
  source of truth here: both off-chain clients treated every
  non-accept as a revert until 2026-07-15, a consensus mismatch that
  survived because the node and the Lua oracle were wrong the same
  way and no test image emits exceptions. The halt/exception on-chain
  semantics are being reworked (contracts side, in progress as of
  2026-07-15); when that lands, re-verify all four off-chain sites
  against it (revert_if_needed and log_revert_check in
  engine/machine_stf.rs; revert_if_needed and prove_revert_if_needed
  in prt/client-lua/computation/machine.lua) and only then pin the
  exception shape end to end (an exception-emitting image plus an
  stf scenario, like stf_revert pins rejection).

The Solidity side reads the slot address from step's auto-generated
`EmulatorConstants.sol`. The unit test
`test_emulator_and_step_agree_on_revert_address` (`engine/constants.rs`)
guards the two against drifting apart across emulator/step bumps.

Off-chain, `MachineStf` mirrors this with a pre-feed snapshot per fed
input (`feed`, `revert_if_needed` in `engine/machine_stf.rs`).

## Tournament levels and strides

Nobody can build (or store) 2^92 leaves. The dispute is split into levels
(`prt/contracts/src/arbitration-config/ArbitrationConstants.sol`, currently
L = 3):

```
level  log2step  height   leaf =                       tree covers
0      44        48       one hash per 2^44 usteps     whole epoch (2^92)
1      27        17       one hash per 2^27 usteps     one level-0 stride
2      0         27       one hash per ustep           one level-1 stride
```

Invariants: `log2step[i] == log2step[i+1] + height[i+1]`, and
`log2step[0] + height[0] == 92`. A level's tree refines exactly one leaf
stride of its parent. Only level 2 (the leaf level) reaches individual
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
  `stride / 2^20` big cycles at a time, one leaf per stop; on halt or yield,
  pad the rest.
- Uarch sampling (`log2_stride == 0`): run uarch spans: one leaf
  per uarch step until uarch halt, pad to 2^20 - 1, append the post-reset
  state as the span's last leaf, then check for revert.

The rollups node computes level-0 leaves eagerly while processing
inputs (`LOG2_STRIDE = 44`, so one leaf per 2^24 big cycles) and
folds each closed window's runs into its window-root quartet row as
it commits - the unfolded runs are never persisted. At dispute time
the facade serves level 0 at or above window granularity from those
rows plus fixed-point padding math; everything below window
granularity - and every deeper level - is computed lazily by
re-running the machine, and cached as merkle nodes in the quartet
cache (`sling_nodes`, keyed by epoch, stride, height, shift;
one-engine.md section 6, amended).

One subtlety (the ruler's fused feed transition): a machine snapshot
taken at an input boundary sits yielded, mid-transition. Its state hash
at that point is not a leaf; the builder must feed the pending input
first ("unyield") before stepping.

## Where implementations must agree

The same leaf sequence is computed independently by:

1. the Rust node (`rollups_machine.rs` for level 0, `cartesi-rollups/node` for
   dispute levels),
2. the Lua client (`prt/client-lua/computation/`), and
3. implicitly, the on-chain state transition (one leaf transition at a
   time).

Any divergence between (1)/(2) and (3) means an honest node loses a
dispute it should have won. The e2e tests cross-check (1) against (2)
every epoch (`prt/tests/rollups/test_env.lua`, `epoch_settlement`), and
the stf test cases exercise (3) against both. Preserve these cross-checks
when refactoring; they are the executable specification of this document.
