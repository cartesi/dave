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
- leaf: machine root hash after one meta-cycle transition. Stored
  run-length compressed as (hash, repetitions).
- repetitions (code): how many consecutive identical leaves a stored row
  stands for (padding after an input boundary or terminal state).
- implicit hash (code: implicit_hash): the state before leaf 0; carried
  alongside the tree, not inside it.
- stride / log2step (configuration code): leaf granularity of a tournament
  level; a level-k leaf covers 2^log2step[k] usteps. The semantic tournament
  descriptor exposes the same quantity as `log2Stride`.
- height (code): tree height at a level; 2^height leaves per tree.
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
- responseBudget: non-bankable elapsed-time discount applied after each
  successful bisection response, including sealing. It is never deposited into
  a clock.
- maxAllowance: configured root allowance and structural upper bound for clocks
  in parent-linked tournaments. Inner sealing delegates the pair's greater
  remainder as a shared child envelope; no response operation raises a clock
  toward this bound.
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
- settlement: posting the winning result to DaveConsensus, which also
  seals the next epoch.
- hero / sybil (tests): the honest player under test / a dishonest player
  defending a corrupted commitment. Hero is also the node's name for its
  dispute module (`cartesi-rollups/node/src/hero`, formerly `strategy`
  with its `Player` struct): the paper's term for the honest validator.
- Storage (code): the SQLite-backed storage layer all node workers
  share. The older name "state manager" survives only in the
  `StateManagerError` error variants.
- ShutdownSignal (code): the shutdown broadcast between node threads
  (`src/sync.rs`). Deliberately carries no errors - worker errors return
  through join handles; its retired predecessor (Watch) conflated the
  two.
- sling node: working name for the productized rewrite of the prototype
  node. The geometry module itself is named `engine`; "sling" survives as the
  codename in the schema's table names (`sling_config`, `sling_nodes`). The
  tables were deliberately not renamed.
