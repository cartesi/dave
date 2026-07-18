# Match API design and implementation record

Status: implemented and validated

Last reviewed: 2026-07-18

This document records the compatibility fence, implemented internal shape, and
validation evidence for the dispute-game `Match` library. The goal was to make
alternating bisection and sealed divergence state reviewable without changing
protocol behavior, the external ABI, the raw stored representation, or event
semantics.

The implementation was split into small reviewable commits: representation
characterization, phase views, mutation centralization, call-site migration,
legacy cleanup, branch-complete gas witnesses, and gas recalibration.

## Scope and exclusions

The redesign:

- derive one explicit phase from the existing stored fields;
- expose phase-specific internal views instead of asking callers to interpret
  overloaded slots;
- name the revealing and waiting roles in alternating bisection;
- centralize branch selection, sealing-side parity, agree-proof ownership, and
  final-state ordering;
- reject or assert on illegal source phases rather than reinterpret them; and
- retain the independent sparse-Merkle model as the semantic oracle.

It did not:

- change any `ITournament` function, event, or error;
- add, remove, reorder, rename, or normalize stored `Match.State` fields;
- change `Match.Id`, its order-sensitive hash, or commitment-one/two identity;
- change clocks, geometry, refunds, state-transition semantics, or tournament
  population policy;
- decompose unrelated `Tournament` lifecycle code; or
- require any node or client change.

All supported tournament geometries have `height >= 1`. A zero-height match is
currently constructible through a misconfigured parameters provider and is born
with `isInit == true, currentHeight == 0`; its creation encoding is therefore
indistinguishable from the sealed sentinel. Zero height remains explicitly
unsupported trusted configuration. The canonical table test and every injected
fixture must enforce positive height. Runtime parameter validation, if desired,
is a separate policy change rather than an accidental consequence of this
refactor.

## Pre-refactor abstraction failures

### One tuple contains two representations

`Match.State` is externally observable but changes meaning at seal:

| Field | Bisection or ready to seal | Sealed |
| --- | --- | --- |
| `otherParent` | Parent that the current responder must reveal | Agree-state hash reinterpreted as a tree node |
| `leftNode` | Waiting side's revealed left child | One of the two divergent leaves |
| `rightNode` | Waiting side's revealed right child | The other divergent leaf |
| `runningLeafPosition` | Start of the unresolved segment | Exact divergent leaf position |
| `currentHeight` | Unresolved subtree height | Zero phase sentinel |
| `isInit` | Existence sentinel | Still true |

The sealed `leftNode` and `rightNode` values are not normalized to commitment
one and two. Their ownership depends on both the divergent branch and the
original commitment height. A reader cannot safely interpret the three node
slots without first establishing the phase.

### Phase is implicit and order-dependent

The default mapping value has `currentHeight == 0`, so the current
`isSealed()` predicate returns true even though the match does not exist.
Production callers correctly check `requireExist()` first, but correctness
depends on remembering that ordering. `currentHeight > 1`, `== 1`, and `== 0`
otherwise encode bisection, ready-to-seal, and sealed phases.

`runningLeafPosition` is similarly overloaded. Before seal it is aligned to the
current subtree and names that segment's first leaf. Seal turns it into the
exact divergent position by adding one only for a right-leaf divergence.

### Alternation and parity are scattered

Commitment one reveals first. Every advance swaps the revealing and waiting
sides, but no pre-refactor type or accessor named that role. Reviewers had to
reconstruct the alternation from assignments to `otherParent`, `leftNode`, and
`rightNode`.

Before the refactor, three coupled decisions were spread across several seal
branches:

1. `agreesOnLeftNode` selects the left or right divergent leaf.
2. Original-height parity selects which commitment owns the agree-state proof.
3. Original-height parity plus branch selection maps the two encoded leaves
   back to commitment one and two.

The four `_setDivergenceOn*` / `_getDivergenceOn*` paths encode one rule through
a parity table. The rule is simpler: the final revealing side is commitment one
for odd total height and commitment two for even total height. That same side
owns the agree proof and the newly supplied divergent leaf.

### Mutation names hide roles

Names such as `otherParent`, `agreesOnLeftNode`, `_goDown*Tree`, and
`requireParentHasChildren` described storage history rather than protocol roles.
`sealMatch` selected a branch, mutated the overloaded encoding, chose the agree
proof owner, verified the proof, and returned fixed-side final states in one
operation. Transaction rollback made the mutation-before-proof order atomic,
but the operation remained difficult to audit.

The focused legacy `Match.t.sol` suite compounded this problem by directly
calling internal encoding helpers over ad hoc zero-heavy trees. The newer
sparse-Merkle property suite is a substantially stronger semantic oracle and
now owns parity and leftmost-divergence behavior.

## Representation and compatibility fence

`Match.Id` remains exactly:

```solidity
struct Id {
    Tree.Node commitmentOne;
    Tree.Node commitmentTwo;
}
```

Its order is semantic. Pairing assigns the waiting dangling commitment to one
and the newcomer or re-entering winner to two. The mapping key remains
`keccak256(abi.encode(id))`; swapping the two commitments identifies a different
match and reverses fixed-side winner attribution.

`Match.State` remains exactly:

```solidity
struct State {
    Tree.Node otherParent;
    Tree.Node leftNode;
    Tree.Node rightNode;
    uint256 runningLeafPosition;
    uint64 currentHeight;
    bool isInit;
}
```

This is a five-slot storage value and a six-word ABI tuple. The library name,
type name, field names, order, user-defined value types, and Solidity types are
all part of the compatibility fence. `getMatch` exposes the tuple directly, so
preserving only function selectors is insufficient.

The refactor must also preserve exact raw values:

- active and sealed `getMatch` snapshots;
- the legacy sealed leaf encoding described below;
- `MatchAdvanced` topics and emitted `otherParent` / `leftNode` values;
- `getMatchCycle` in every existing phase;
- qualified `ITournament` error selectors and their current public boundaries;
- match deletion and parent-child link behavior; and
- the order in which Tournament coordinates Match and clock phase checks.

That last item includes public revert precedence. Advance validates the Match
before switching clocks. Leaf and inner sealing establish the tournament role,
match existence, and seal readiness, then transition clocks before validating
the leaf pair and agree proof. Leaf proof resolution checks its clock phase
before its Match existence/sealed checks. Transaction rollback makes every
failed path atomic, but reordering those checks would still change the public
error contract.

Timeout entry points remain Match-phase-neutral for every existing match; the
clock configuration alone determines whether either entry point can resolve it.
The new phase API describes bisection and divergence operations and must not add
a Match phase restriction to timeout classification.

Normalizing a sealed state to `leftNode = finalStateOne` and
`rightNode = finalStateTwo` would be locally attractive but externally visible.
That belongs only in a future versioned API.

The fence has concrete consumers. Generated Rust bindings expose the tuple
components by name, while the Lua client decodes the six values positionally.
The current validator reads active `otherParent`, `currentHeight`, and
`runningLeafPosition`, uses sealed `otherParent` as the agreed state forwarded
to a child tournament, and follows the exact `MatchAdvanced` payload. No change
in this campaign requires a client update.

Before the implementation, the local Forge 1.5.1-dev artifact snapshot is:

```text
canonical Tournament ABI sha256:
67e34ced79c75e19935e3cfc67305ac22f634a0a90f9477e10062ac0bc8feb8a

semantic Tournament storage-layout JSON sha256:
952af2f68c5d04f9bf27a720e04c12492453d2edd76b7516bcdb1cf2e873a329

Tournament creation bytecode without metadata sha256:
bb08bf058f8a7e084ba39db5b852ff854863e83d821129c60b868e1c3e50a90f

Tournament runtime bytecode without metadata sha256:
506874f96a32e92c0bd5dda9303f88cff06332e6e57fe160916ba14160deaee9
```

The ABI canonical form is produced with
`forge inspect --json Tournament abi | jq -S .`. The storage witness uses:

```sh
forge inspect --json Tournament storageLayout \
    | jq -S -f audit/storage-layout-semantic.jq \
    | sha256sum
```

The projection retains every storage variable and reachable type, including
struct member order, slot, offset, and semantic type, while removing
source-dependent AST identifiers. The bytecode witnesses use:

```sh
forge inspect --no-metadata Tournament bytecode | sha256sum
forge inspect --no-metadata Tournament deployedBytecode | sha256sum
```

These commands hash Forge's newline-terminated output. Metadata-free output
prevents a source hash from masquerading as executable change. The hashes are
local compatibility witnesses, not substitutes for inspecting the semantic
test vectors below.

The derived phase and read-only views landed without a production call-site
change. Against the pre-slice worktree, the ABI, semantic storage layout, and
both no-metadata bytecode hashes above remain exact. Full bytecode differs only
in source metadata.

The subsequent mutation refactor deliberately changed executable bytecode while
preserving the ABI and semantic storage-layout hashes above. The final
metadata-free witnesses are:

```text
Tournament creation bytecode without metadata sha256:
94798529a349a513d59fbb4b3ff697dc41a1062fca3fcc8dc3f50574dc6d3dbe

Tournament runtime bytecode without metadata sha256:
cdcb81a8c101935b5700b491cf4046d4a2ed0583d0c26f5f49f06eacfb0185b7
```

## Derived phase and invariants

### Phase

The implemented phase is internal and derived; it is never stored:

```solidity
enum Phase {
    UNINITIALIZED,
    BISECTING,
    READY_TO_SEAL,
    SEALED
}
```

Derivation checks `isInit` first, then classifies `currentHeight` as greater
than one, equal to one, or zero. The four values are disjoint and exhaustive for
a valid representation produced by positive-height geometry. Any parity helper
that also receives total height must assert `currentHeight <= totalHeight` or
compare parity directly; it must not use an unchecked
`totalHeight - currentHeight` subtraction.

Existing public errors remain authoritative:

- absent state -> `MatchDoesNotExist`;
- a non-bisecting state passed to advance -> `MatchCannotBeAdvanced`;
- a state not ready to seal passed to seal -> `MatchCannotBeSealed`; and
- a non-sealed state passed to a sealed-only operation -> `MatchIsNotSealed`.

### Active bisection

For total commitment height `H`, current height `h`, and segment start `p`:

1. Creation starts at `(h, p) = (H, 0)` with commitment one revealing and the
   stored children belonging to commitment two.
2. `p` is aligned to `2**h` and identifies the unresolved interval
   `[p, p + 2**h)`.
3. Commitment one reveals exactly when `(H - h)` is even. Every advance flips
   the revealing side.
4. The caller proves that the revealing parent joins from the supplied left and
   right children.
5. If the supplied left child differs from the waiting left child, the first
   disagreement is in the left half. Otherwise it is in the right half because
   the two parent roots differ under the hash assumptions.
6. Left descent keeps `p`; right descent adds `2**(h - 1)`. Both decrement `h`
   exactly once and store the revealing side's chosen-child children for the
   next, role-swapped response.
7. Every interior addition is even because advance is legal only for `h > 1`.
   Position therefore remains even until the final right-leaf seal adds one.

### Seal and legacy encoding

At `h == 1`, the final revealing side is commitment one iff `H` is odd. Call it
`R`; the other fixed side is `W`.

- The supplied leaves belong to `R`.
- The stored leaves belong to `W`.
- A left mismatch selects the supplied left leaf from `R` and the stored left
  leaf from `W`.
- Otherwise the right leaves are the divergent pair.
- If `p == 0`, the agree state must equal the tournament initial state.
- Otherwise `R` proves the agree state at position `p - 1`.
- The returned final states are ordered by fixed commitment identity, never by
  revealing/waiting role.

The exact sealed storage encoding remains:

| Divergence | `runningLeafPosition` | `leftNode` | `rightNode` |
| --- | --- | --- | --- |
| Left | even `p` | Waiting leaf | Revealing leaf |
| Right | odd `p + 1` | Revealing leaf | Waiting leaf |

`otherParent` then stores the agree-state hash as a `Tree.Node`, and
`currentHeight` becomes zero. Decoding first derives left/right from position
parity, reconstructs revealing/waiting leaves from the table, then orders them
using the one sealing-side decision above.

The divergence cycle remains:

```text
startCycle + (runningLeafPosition << log2step)
```

## Implemented internal API

Keep one `Match` library. Identity, the compressed bisection witness, and sealed
decoding are one coherent representation; splitting files would add navigation
without separating policy as cleanly as `Clock` / `MatchClocks` did.

Phase-specific internal views make the overloading explicit:

```solidity
struct BisectionView {
    Tree.Node revealingParent;
    Tree.Node waitingLeft;
    Tree.Node waitingRight;
    uint256 segmentStart;
    uint64 height;
}

struct SealedView {
    Machine.Hash agreeState;
    uint256 divergencePosition;
    Machine.Hash finalStateOne;
    Machine.Hash finalStateTwo;
}

function phase(State memory state) internal pure returns (Phase);

function bisectionView(State memory state)
    internal pure returns (BisectionView memory);

function sealedView(State memory state, uint64 totalHeight)
    internal pure returns (SealedView memory);
```

`BisectionView` covers both `BISECTING` and `READY_TO_SEAL`; both phases use the
same revealing/waiting representation, including a match created directly at
height one. `sealedView` establishes existence before the sealed phase and
decodes fixed commitment identity using the original total height.

The existing `toCycle` remains the deliberately phase-neutral compatibility
helper behind `getMatchCycle`: before sealing it returns the unresolved
segment's first cycle, and after sealing it returns the disputed transition
cycle. The compatibility `getDivergence` helper still uses that behavior;
future phase-specific call sites can compute the latter explicitly from the
sealed divergence position instead of introducing another overloaded accessor.

Mutation verbs name the state machine rather than repeat the library name:

```solidity
function create(...)
    internal pure returns (IdHash, State memory);

function advanceBisection(State storage state, ...)
    internal;

function sealDivergence(State storage state, ...)
    internal returns (Machine.Hash finalStateOne, Machine.Hash finalStateTwo);
```

Named private decisions replace the parity table:

- select `LEFT` or `RIGHT` from the supplied and waiting left nodes;
- perform one common descent mutation;
- derive the sealing side once from total-height parity;
- select the agree-proof commitment from that sealing side;
- encode the exact legacy sealed slots once; and
- decode them once before ordering final states by commitment one and two.

Tournament call sites retain explicit existence and public phase guards before
coordinating clock transitions. Match mutations assert their expected internal
source representation and never repair it. This preserves current public error
ordering while making misuse by a future internal caller fail locally.

`sealedView` establishes both existence and the sealed phase. The compatibility
`getDivergence` helper still asserts only `currentHeight == 0`, which the default
absent mapping value also satisfies. Existing public callers retain their
explicit existence guards and public revert ordering; new internal readers can
use the safe view directly.

Memory views are available to internal readers and make phase interpretation
directly testable. The hot leaf-winner path retains the guarded compatibility
tuple returned by `getDivergence`; both paths still share the single divergence
decoder and fixed-side ordering implementation.

## Test treatment

The Match campaign has four clearly separated owners:

1. **Compatibility characterization** pins raw state and event values. It covers
   creation, left/right advance, odd/even total height, left/right seal,
   position zero/nonzero, the exact legacy sealed encoding, and
   `MatchAdvanced` data.
2. **Independent sparse-Merkle properties** own semantic correctness. They
   exhaust every position and both commitment orders through height eight,
   cover representative paths through height 55, fuzz the reviewed geometry,
   verify agree-proof ownership, and pin leftmost-divergence precedence.
3. **Focused validation tests** own proof and child-validation failures without
   rebuilding a complete Tournament lifecycle around each library guard.
4. **Lifecycle integration** owns public phase errors, clocks, deletion,
   re-pairing, recursion, and terminal results. Match unit tests should not
   recreate those tournament fixtures.

The pre-refactor fence pins these observable cases:

- raw sealed `leftNode`, `rightNode`, `otherParent`, position, height, and
  `isInit` values across odd and even heights and both divergence branches;
- leftmost precedence in the terminal height-one case when both leaf pairs
  differ;
- the exact `MatchAdvanced` event payload for left and right descent;
- `InvalidChildrenNodes` for an invalid revealing parent, an invalid selected
  subtree on advance, and an invalid leaf pair on seal;
- `IncorrectAgreeState` at divergence position zero; and
- `CommitmentProofWrongSize` on the nonzero-position seal path.

Compatibility expectations should remain visibly separate from the
sparse-Merkle model's semantic expectations, even if they share its compact
tree-building harness. This keeps the independent oracle useful for a future
versioned representation.

The 379-line legacy helper suite was removed after the compatibility, semantic,
and validation suites covered its observable behavior. `MatchIdentity.t.sol`
retains a concrete zero-pair ID vector and proves that commitment ordering
changes identity; it does not pretend a Keccak-derived ID can be the zero
existence sentinel.

## Completed implementation sequence

1. The design checkpoint established the compatibility fence.
2. Sparse-tree properties and raw active/sealed snapshots pinned semantic and
   representation behavior before mutation changed.
3. Event and validation tests pinned exact payloads, revert data, validation
   stages, and rollback.
4. Derived phase and phase-specific views landed without changing executable
   behavior.
5. One branch selector, one sealing-side derivation, one divergence encoder,
   and one decoder replaced the scattered parity paths.
6. `Tournament` and independent tests adopted `create`, `advanceBisection`, and
   `sealDivergence` before the compatibility wrappers were removed.
7. The obsolete helper suite was replaced by the identity vectors above.
8. Left and right advance, leaf-seal, and inner-seal gas witnesses were retained
   before the three shared allocations were recalibrated.
9. The audit ledger and protocol documentation were synchronized with the
   implemented result.

No commit in this sequence touches node source or changes the external ABI.

## Validation result

The completed campaign checked all of the following:

- The canonical `Tournament` ABI and semantic storage-layout hashes remain
  `67e34c...feb8a` and `952af2...a329`; selectors, tuple field order, raw active
  and sealed values, event data, and public revert precedence remain pinned.
- The independent sparse-Merkle campaign exhausts every position and both
  commitment orders through height eight, covers representative height-55
  paths, and fuzzes the reviewed geometry.
- The positive lifecycle invariant completed 256 runs of depth 128, or 32,768
  calls, with no handler reverts or discards. The independent rejection model
  completed 128 runs of depth 128, or 16,384 calls, with the same result.
- Recursive two-level timing, winner propagation, double elimination, and two
  sequential children remain covered.
- The release-style coverage recipe passed 135 included tests. `Match.sol` maps
  107/107 lines, 102/102 statements, 10/20 branches, and 24/24 functions; as
  documented in the recipe, IR-minimum branch mappings are investigative rather
  than semantic evidence.
- All 159 dispute-game tests passed under both Forge 1.5.1-dev and release Forge
  1.4.3.
- All 18 retained refund-gas witnesses reproduced exactly under both versions.
  The shared advance, inner-seal, and leaf-seal allocations are respectively
  126,000, 364,000, and 107,000 gas.
- `rollups-contracts` retained all three integration tests, including both fuzz
  properties at 256 runs and the bounded-callback settlement trace.
- `forge fmt --check`, focused lint, and `git diff --check` passed throughout.

Production bytecode changed intentionally. The final metadata-free creation and
runtime hashes are recorded above, so deployment and CREATE2 artifacts must be
regenerated and reviewed before release. The external ABI, storage layout, raw
state encoding, events, selectors, and protocol outcomes did not change. No
node source changed.

Future production changes to an advance, seal, or winner path must rerun the
focused gas cases immediately and then the complete calibration. The manual
procedure and propagation checklist live in `GAS-CALIBRATION.md`.
