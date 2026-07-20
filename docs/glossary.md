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
- yield: the big machine pausing to await rollups I/O (next input). A
  yielded machine is mid-transition; its hash is not a commitment leaf
  until unyielded (fed).
- CMIO: the Cartesi Machine I/O mechanism used to feed inputs (advance)
  and read outputs.
- checkpoint (code: CHECKPOINT_ADDRESS): dedicated machine memory slot
  holding the pre-input root hash, written at each input boundary so a
  rejected input can be provably reverted. Aliases the emulator's
  shadow-revert-root-hash slot.
- revert-if-needed (code): the conditional state restore at a big-step
  boundary when the machine yielded rejecting the input.
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
  stands for (padding after halt/yield).
- implicit hash (code: implicit_hash): the state before leaf 0; carried
  alongside the tree, not inside it.
- stride / log2step (code): leaf granularity of a tournament level; a
  level-k leaf covers 2^log2step[k] usteps.
- height (code): tree height at a level; 2^height leaves per tree.
- span vs mask trap: constants named `*_SPAN_*` (engine/constants.rs)
  are defined as 2^k - 1 (masks), not 2^k. Verify usage before changing
  anything around them. Sling code is immune by construction: it speaks
  `Structure` log2 fields and `Position` coordinates, never the masks.

## Tournament (PRT)

- PRT: Permissionless Refereed Tournaments, the dispute algorithm the
  current contracts implement (asynchronous, multi-level variant; neither
  paper matches the code exactly).
- Dave: (a) this repo/system's name; (b) the successor algorithm (see
  dave/docs/dave.pdf) improving PRT liveness - not yet what the contracts
  implement.
- level: dispute granularity tier. Level 0 disputes the whole epoch at
  coarse stride; the leaf level (currently 2) disputes single usteps.
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
- chess clock: per-commitment time budget within a match; exactly one
  side's clock runs at a time (except sealed leaf matches, where both
  run).
- matchEffort / maxAllowance: clock time granted per pairing / cap on
  total clock time (deployment parameters).
- win by timeout / eliminate by timeout: resolving a match when one (or
  both) clocks run out.
- garbage collection (gc): permissionlessly eliminating finished or
  timed-out matches/tournaments to unlock bonds.
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
- state manager (code): the SQLite-backed storage layer all node workers
  share.
- Watch (code): the condvar-based shutdown/error broadcast between node
  threads.
- sling node: working name for the productized rewrite of the prototype
  node. The geometry module itself is named `engine` (renamed from
  `sling` at one-engine step 5); "sling" survives as the codename in
  the schema's table names (`sling_config`, `sling_nodes`) and the
  historical plan documents - the tables were deliberately not renamed.
