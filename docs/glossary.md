# Glossary

Project vocabulary, roughly ordered from machine level up to protocol
level. Terms marked (code) appear verbatim in identifiers.

## Machine

- big machine / barch (code): the full RV64GC Cartesi Machine implemented
  by the emulator. One big-machine instruction = one big cycle / mcycle.
- uarch, micro-architecture: the small RV64I machine that emulates one big
  instruction in Solidity-implementable steps.
- ustep (code): one uarch instruction; the atomic transition the on-chain
  referee verifies.
- ureset (code): resetting the uarch to its pristine state after it halts,
  committing the emulated big instruction. Counts as the last uarch slot
  of a big cycle.
- uarch span: the 2^20 leaf slots of one big cycle: usteps until uarch
  halt, padding, then the ureset.
- machine swapping: the technique of implementing only the uarch state
  transition on-chain while the big machine provides the real ISA.
- manual yield: the raw `iflags_Y` state. `RX_ACCEPTED` means the machine is
  awaiting the next input; `RX_REJECTED` is restored to its pre-input root at
  reset; exception and unexpected manual reasons are terminal.
- awaiting input: an `RX_ACCEPTED` manual yield. At an input boundary, the
  fused transition feeds the pending input and executes the first ustep.
- CMIO: the Cartesi Machine I/O mechanism used to feed inputs (advance)
  and read outputs.
- revert-root slot (code alias: CHECKPOINT_ADDRESS): dedicated machine memory slot
  holding the pre-input root hash. The send-CMIO primitive records it when
  delivering an input, and the uarch-reset primitive consumes it when a
  rejected input must be provably restored. Aliases the emulator's
  shadow-revert-root-hash slot.
- rejected-input substitution: the conditional root replacement performed
  inside uarch reset when the machine yielded RX_REJECTED.
- snapshot: an on-disk serialized machine, in this repo always stored in a
  directory named by the machine root hash.
- template machine: the genesis snapshot of an application, from which all
  epochs derive.

## Commitment

- meta-cycle (code: meta_cycle): 92-bit position in an epoch's
  computation: (input index: 24 bits, big cycle: 48, ucycle: 20). See
  docs/computation-hash.md.
- computation hash / commitment: Merkle root over the epoch's leaf
  sequence; what a validator stakes a bond on.
- leaf: machine root hash after one meta-cycle transition; builders carry
  runs of equal leaves as (hash, repetitions) in memory.
- repetitions (code): how many consecutive identical leaves one run stands
  for (padding after an input boundary or terminal state).
- implicit hash (code: implicit_hash): the state before leaf 0; carried
  alongside the tree, not inside it.
- stride / log2step (configuration code): leaf granularity of a tournament
  level; a level-k leaf covers 2^log2step[k] usteps. The semantic tournament
  descriptor exposes the same quantity as `log2Stride`.
- height (code): tree height at a level; 2^height leaves per tree.
- input window (code: `log2_window_span`): the 2^68 meta-cycles one input
  owns; window k starts where input k is fed. A boundary is the machine at
  a window start; the runner keeps one every `--snapshot-gap-inputs` inputs
  (the snapshot gap) and dispute positioning adds the disputed input's.
- quartet (code): (epoch, stride, height, shift), the identifier of one
  Merkle node of a commitment tree; the node's quartet cache (`sling_nodes`)
  is keyed by it. A level root is the quartet of shift 0 at full height.
- dense (leaf, span): a leaf-level span over executing big cycles, where
  every uarch step is a distinct leaf, so its build cost scales with
  executed usteps (the density label in docs/measurements). An idle stretch
  at a fixed point costs one captured span however long it is, one per
  stratum span in a tall leaf build.
- seam 1, seam 2: the input budget's last cycle (mcycle == imcyclemax). At
  seam 1 an `RX_REJECTED` yield still reverts at the closing reset; at seam
  2 an `RX_ACCEPTED` yield still takes the next input, because the step
  reads only the pending yield. Dave follows the step at both; the v0.21.0
  collector diverges at seam 1 and the v0.21.0 CLI at both
  (computation-hash.md, the CLI exclusions).
- collect API, bulk collector (code: `Collector::Bulk`): the emulator's
  `cm_collect_uarch_cycle_root_hashes` and `cm_collect_mcycle_root_hashes`,
  which run a span and return its sampled roots in one call (wrapped in
  machine/rust-bindings `types/collect.rs`). The node builds tall leaves
  (stride 0, height 28 or more: the two-level table's height-38 leaf) with
  the uarch collector, bundled per big cycle; every other quartet, every
  three-level leaf included, is stepped. `Collector::Stepped` steps tall
  leaves too, as the collector's test reference. The release CLI is
  built on the same collectors, so it is not an independent oracle.
- seam-1 guard: bulk collection stops before the budget's last cycle and the
  ruler steps it (`MachineStf::big_cycle_roots`), because the v0.21.0
  collector keeps the physical root there. A control test
  (`bulk_collection_leaves_the_budgets_last_cycle_to_stepping`) fails once
  an emulator fixes it; the guard goes then.
- per-input compute contract: how many big cycles one input may run, a
  trusted-developer promise the clocks are priced against
  (docs/dimensioning.md).
- span vs mask naming: the primitive field widths come directly from the
  emulator's rollup constants. Dave derives its input-window and ruler widths
  plus the field masks (2^k - 1) from them. The historical trap - masks named
  `*_SPAN_*`, colliding with true-span constants - is retired. Engine code is
  additionally protected by construction: it speaks `Structure` log2 fields
  and `Position` coordinates, never the masks.

## Tournament (PRT)

- PRT: Permissionless Refereed Tournaments, the dispute algorithm the
  current contracts implement (asynchronous, multi-level variant; neither
  paper matches the code exactly).
- Dave: (a) this repo/system's name; (b) the successor algorithm (see the
  [Dave paper](papers/dave.pdf)) improving PRT liveness - not yet what the
  contracts implement.
- level: dispute granularity tier. Level 0 disputes the whole epoch at
  coarse stride; the final configured level disputes single usteps and its
  clones carry `kind == LEAF`.
- commitment (in a tournament): a joined claim, i.e. a Merkle root plus
  bond, paired into matches.
- dangling commitment: the commitment currently waiting for an opponent in
  a tournament's pairing pool.
- match: a two-commitment bisection duel over their first divergent leaf.
- bisection / advanceMatch: alternately splitting the disputed range in
  half until one leaf transition remains.
- seal: freezing a match at its divergent leaf: leaf matches start the
  proof race; inner matches spawn a child tournament one level deeper.
- nested novelty: every interior leaf of a child tournament's
  commitment is computed for the first time when the dispute reaches
  its gap; no cache or seed can pre-exist it (computation-hash.md,
  "Nested leaves are novel" - the system's most-confused fact).
- un-disputable machine: an application whose reachable computation
  (under some input) the dispute protocol cannot serve within its
  clocks - the naive form loops forever, the subtle form concentrates
  maximally-long uarch instructions. Excluded by assumption: the app
  developer is trusted (docs/dimensioning.md).
- chess clock: per-commitment time budget. Exactly one side runs during
  bisection; both run after leaf sealing; both pause while a sealed inner match
  delegates to its child; and a dangling commitment remains paused.
- clock deadline: the inclusive expiry boundary
  `current >= startInstant + allowance`. Progress that requires a live clock is
  too late at equality; timeout resolution becomes eligible there.
- censorship budget (`C`): one cumulative, non-rechargeable bound on delaying
  the correct participant across a root dispute and all linked descendants.
- responseBudget (G): the inclusion budget of one honest action. As a response
  discount it is non-bankable: applied after each successful bisection
  response, including sealing, it never increases the balance. A winning leaf
  proof or timeout claim earns the same discount on its live cost. A child return
  separately refills its winner by up to `T + 2G`, within the pair envelope.
- maxAllowance: root allowance and structural upper bound for clocks in
  parent-linked tournaments, derived as `C + G + (levels - 1) * (T + 2G)`.
  Inner sealing delegates the pair's greater remainder as a shared child
  envelope; no response operation raises a clock toward this bound, and a
  child return refills its winner only within that envelope.
- commitmentBudget (T): time granted to build one inner tournament's
  commitment, the same at every inner level. It belongs with the tournament
  geometry, which is only valid for the `T` it was generated against; a parent
  refills the winner its child returns by up to `T + 2G` (build, join,
  propagation).
- win by timeout / eliminate by timeout: resolving a match when one (or
  both) clocks run out.
- garbage collection (gc): permissionlessly eliminating finished or
  timed-out matches/tournaments so protocol progress does not depend on their
  claimers. It does not guarantee recovery of every bond; a no-winner child has
  no winning-claimer payment or residual-burn path.
- arbitration result: the root tournament's final answer (winner
  commitment and final machine state hash).

## Rollups / node

- epoch: a sealed range of inputs that settles as one unit via one root
  tournament.
- input index boundary (code: input_index_boundary): exclusive global
  input index where an epoch ends.
- sealed epoch: epoch whose input set is frozen and whose tournament
  exists; the thing validators defend.
- settlement: staging the root winner's final state on DaveConsensus with a
  machine validity proof, then accepting it once every sentry agrees or the
  claim staging period ends; acceptance records the outputs root and seals
  the next epoch.
- sentry: one of the addresses (zero or more, fixed at deployment and
  rotatable by the sentry manager) that may claim the post-epoch state it
  computed; unanimous agreement accepts a staged result early, and a sentry
  can neither veto nor corrupt it.
- claim staging period: the wait after staging before anyone may accept
  without unanimous sentries; the guardian's reaction window.
- guardian, foreclosure: the application's guardian may call
  `Application.foreclose()`, which irreversibly freezes epoch progress; the
  last line for anything the tournament cannot settle or got wrong
  (epoch-lifecycle.md).
- settles (code: `MachineValidityProof::settles`): whether a final state can
  be staged, the contracts' validity predicate: a manual `RX_ACCEPTED` yield.
- defend, never stage: the node records and defends every epoch's true
  final state, settling or not; only staging asks `settles`, and an epoch
  that cannot settle is held with an error (epoch-lifecycle.md).
- hero / sybil (tests): the honest player under test / a dishonest player
  defending a corrupted commitment. Hero is also the node's name for its
  dispute module (`cartesi-rollups/node/src/hero`, formerly `strategy`
  with its `Player` struct): the paper's term for the honest validator.
- P1, P2: the node's failure policy (docs/node-architecture.md). P1: an
  adversary that can halt or stall the honest node deterministically makes N
  honest nodes protect like zero, so no check may reject what the contracts
  can produce or the trusted application can process. P2: spend distrust
  where a lie would be silent, not where it would fail loudly.
- Solid, Foam (code: `Solid` in `tournament/reader.rs`, `foam` in
  `hero/actor.rs`): the tournament reader's two views. Solid is the event
  fold through the finalized block, kept in memory between ticks; Foam is a
  disposable clone extended to the latest block for one tick's
  deadline-sensitive actions. Joins take their payload from Solid.
- CoW crossing (code: `Positioner::cross`): dispute positioning across whole
  inputs on copy-on-write clones of the runner's chain; a rejection resumes
  from the pre-input clone, and only the disputed input's boundary is stored
  and registered, since every later action of that dispute stays inside
  that input.
- tail adversary (code: `Tail`, test-only): the anvil harness's adversary,
  the production Hero over a source whose every leaf from one meta-cycle on
  is a fixed wrong value, never stored and unprovable, so it loses by STEP
  or timeout.
- commitment semantics (code: `COMMITMENT_SEMANTICS`): the version of the
  leaf rules a store was built under; bumped on any change to leaf values or
  transition shapes, so an older store is refused, not reused.
- Storage (code): the SQLite-backed storage layer all node workers
  share. The older name "state manager" survives only in the
  `StateManagerError` error variants.
- ShutdownSignal (code): the shutdown broadcast between node threads
  (`src/sync.rs`). Deliberately carries no errors - worker errors return
  through join handles; its retired predecessor (Watch) conflated the
  two.
- sling node: the PRT validator node, the productized rewrite of the
  prototype node. The name covers the `cartesi-sling-node` crate, binary and
  release asset, the `CARTESI_SLING_` prefix of its environment variables,
  and the schema's tables (`sling_config`, `sling_nodes`). The geometry
  module itself is named `engine`.
