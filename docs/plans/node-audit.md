# Node deep dive: oracle-anchored audit (2026-07-15)

Status: ROUND 1 COMPLETE. Findings verified and dispositioned below;
fixes landed the same session (battery-gated). Re-run the method
after the contracts-side halt/exception rework lands and after any
campaign that reshapes a module.

## Method

Motivated by the exception-revert mismatch (fixed at 9ab579d): the
bugs that survive our verification net are the ones where the
implementations are CORRELATED (node and Lua oracle wrong the same
way) and the pin is missing. So the dive is oracle-anchored, not
free-form code reading: six parallel readers, each comparing one
slice of the node against its ground truth, forbidden from reporting
anything without a concrete failure scenario and evidence. Findings
were then re-verified in the main session before being believed -
finding and verifying stay separate roles.

The six dimensions and their oracles:

1. Hero react loop and GC vs Tournament.sol/Match.sol/Clock.sol/
   Commitment.sol.
2. Epoch lifecycle vs DaveConsensus.sol and InputBox semantics.
3. Byte-level witness and calldata encodings vs the state-transition
   contracts' buffer consumption.
4. Recorded invariants (docs) vs enforced reality (code).
5. The un-campaigned modules plus error-vs-panic discipline at every
   seam.
6. Protocol shapes with no pin at any level of the verification net.

Ten findings (2 high, 5 medium, 3 low), zero critical. 56 explicit
clean comparisons recorded alongside (the coverage section below) -
notably the entire react-loop turn logic, every sender encoding, and
every witness byte layout traced clean against the contracts.

## Findings and dispositions

| # | sev | finding | verdict | disposition |
|---|-----|---------|---------|-------------|
| 1 | high | corruption tripwires erased into retry-forever errors | CONFIRMED, deeper than reported | FIXED this session |
| 2 | high | no test anywhere runs two simultaneous live matches | CONFIRMED (gap) | CLOSED: multi_sybil scenario + recording |
| 3 | med | settle() reverts swallowed uniformly; stuck epoch never escalates | CONFIRMED by evidence | LEAD: revert taxonomy |
| 4 | med | LOG2_STRIDE mirrors log2step(0) with no drift guard | CONFIRMED | FIXED this session |
| 5 | med | two docs describe the deleted runs-table serving as current | CONFIRMED | FIXED this session |
| 6 | med | MatchDeletionReason::Timeout never decoded from a real chain log | CONFIRMED (gap) | CLOSED: multi_sybil recording + fold test |
| 7 | med | no kill scenario at join or leaf-resolution lifecycle points | CONFIRMED (gap) | CLOSED: kill_join scenario |
| 8 | low | gc.rs elimination gate uses static allowance, not live timeLeft | CONFIRMED (conservative-only) | LEAD: minor, delay not misfire |
| 9 | low | span-width constants also lacked a cross-repo guard | CONFIRMED | FIXED with 4 |
| 10 | low | frontier's full-capacity (no-padding) branch untested | CONFIRMED | FIXED this session |

### 1. The tripwire livelock (high, fixed)

Every corruption/nondeterminism tripwire - the quartet collision
check, the window-root count/hole checks, the boundary and
settlement write-once disagreements - returned Err, and both
workers' tick loops (machine_runner::start, epoch_manager::
execution_loop) retry every Err with a warn, forever. The recorded
doctrine was already "invariant violations are asserts and stay
fatal through the panic path", and lib.rs's worker_failure turns any
worker panic into a loud process exit - the tripwires simply
violated the doctrine by being errors. A corrupt store would have
silently livelocked the dispute loop while its clocks ran out: the
same loss shape as the (already fixed) bricked-reconstruction bug,
which had demonstrated the masking in practice.

Verification went one level deeper than the finding: converting only
the Rust-side checks to panics is NOT enough, because the schema
triggers (defense in depth beneath the Rust checks) fire FIRST on
the same connection and surface as ordinary rusqlite errors. The fix
therefore has two layers: the Rust-side checks panic at their sites,
and escalate_tripwires at the write() transaction boundary promotes
trigger aborts by their pinned message fragments ("nondeterminism or
corruption", "node cache collision", "corruption or version drift",
"disagrees with its stored row"). API-contract refusals (append-only,
validate_next) stay ordinary errors - ingest legitimately observes
those. The loudness tests flipped from is_err to should_panic.

### 2. Multi-match coverage (high, CLOSED 2026-07-16)

Dave is permissionless - N sybils produce N/2 simultaneous live
matches - yet every layer of the net (fold unit tests, both chain
recordings, all 13 hero decision-table tests, every e2e scenario)
exercised exactly one live match per tournament. Closed by the
multi_sybil scenario (honest + three sybils: two active, one silent;
two matches live at once; sybil-vs-sybil pairing possible; the
silent match dies by a real on-chain timeout; the honest node wins)
plus the chain recording captured from it and the
fold_reproduces_the_multi_sybil_dispute test, which asserts the
concurrency and the Timeout decode from the raw log stream. In the
battery and test-kill-all/test-multi-sybil.

Three harness lessons the scenario build itself surfaced, recorded
in the scenario's comments: (a) a joined-wait loop that advances no
blocks freezes the node's FINALIZED view and deadlocks the join;
(b) fast-forwarding while the honest node is on turn burns its
chess clock between its one-second ticks - sleep first, advance
gently (observed: 128 blocks per idle poll timed the honest node
out of its own dispute); (c) concurrent sybils must sign with
distinct accounts - every prior scenario got away with the shared
default because its sybils never send simultaneously.

### 3. settlement revert taxonomy (medium, lead)

allow_revert_rethrow_others treats every decodable revert as a
benign race. For join/advance/seal that is right (another actor got
there first). UPDATED for the staged protocol (ported 2026-07-20):
the surface split across three sends. stageTournamentResult carries
the self-authored, permanently-failing class - InvalidOutputsMerkle
RootProof (the node's own outputs proof is wrong) - that retries
identically forever and stalls the app's whole rollup, unpaged (the
winner-mismatch asserts never see it). acceptStagedTournamentResult
's ClaimStagingPeriodNotOverYet and submitSentryClaim's
SentryAlreadyClaimed are genuine wait/race classes, correctly
swallowed. Fix direction unchanged: decode the revert selector at
the sender and escalate non-race classes through the same loudness
path as finding 1; sequence with Diego's halt/exception contracts
rework, which may reshape the surface again.

### 4 + 9. Cross-repo constant drift guards (fixed)

LOG2_STRIDE (44) and the meta-cycle span widths were hand-maintained
mirrors of ArbitrationConstants.log2step(0) and CartesiState
Transition.sol, with only a comment; the CHECKPOINT_ADDRESS
parse-the-Solidity-source test was the established precedent and now
has a sibling: node_constants_match_arbitration_contracts pins
log2step(0), the ruler span vs the root tournament span, and both
span widths. Drift here would make the frontier fold serve level-0
nodes at a stride the deployed tournament does not use - wrongness
with no loud error, since the fold bypasses the machine-replay
collision checks.

### 5. Stale docs (fixed)

node-architecture.md and computation-hash.md still described the
deleted per-window leaf-run serving ("reads ... the per-window leaf
runs from storage on demand") - the session-C sweep grepped for the
table name, and these passages describe the mechanism without naming
it. Both now state the amended architecture (window roots plus
padding math at or above window granularity; machine replay below).
Sweep lesson recorded: grep for the CONCEPT'S VOCABULARY, not just
its identifiers.

### 6, 7. Harness gaps (CLOSED 2026-07-16)

Both closed alongside finding 2: the multi_sybil recording carries a
real Timeout-reasoned MatchDeleted, decoded and asserted by the fold
test (the enum-order pin the synthetic tests bypassed); and
kill_join SIGKILLs the node at its join decision - the join tx
in-flight or landed - with the respawn required to end up joined
exactly once and win (green on its first run). The stable-marker
contract in test-harness.md gained the `join tournament` line.

### 8. gc.rs allowance vs timeLeft (low, lead)

The elimination gate compares against the opponent clock's static
allowance where Tournament.sol uses live timeLeft; reachable only in
the leaf-race window where both clocks run. Strictly conservative
(the node waits longer than necessary to sweep a dead match, never
fires early), inherited verbatim from the pre-rewrite reference.
Align when the tournament module is next open.

### 10. Full-capacity frontier branch (fixed)

Every facade-level test recorded 3 of S_MEDIUM's 4 windows, so the
no-padding branch of top_tree was never taken; the new
full_capacity_frontier_serves_without_padding spec test records all
four and forbids the machine at window granularity.

## Coverage: what was traced clean

The full clean-check list lives with the findings (56 entries); the
load-bearing ones:

- React loop vs Match.sol: the contested-node map, the turn check,
  bisection direction parity including both leaf-sealing edges, and
  the agree-state proof's height-parity trick - all exact. The
  win_inner_match argument construction was suspected wrong and
  proven right (innerTournamentWinner's second tuple field is the
  PARENT-level commitment, matching the node's usage).
- Every sender method's argument order vs ITournament.sol, and every
  witness encoding (DA framing, checkpoint write proof, access-log
  flattening, sibling order, the three transition shapes' concat
  order) vs the state-transition contracts' consumption order.
- Epoch lifecycle: the roll decision vs settle()'s atomic
  seal-and-settle, InputId::validate_next vs InputBox numbering,
  finalized-only ingestion (reorg exposure is a documented design
  exclusion, not an oversight), and gc_old_epochs' "settled before
  sealed" dependency verified against DaveConsensus.
- The storage mutation-class taxonomy vs the actual trigger DDL, and
  the boundary store's stage/rename/write-once/assert-on-load
  invariants vs snapshots.rs.
- lib.rs worker lifecycle: any worker exit or panic ends the node
  loudly; sync.rs shutdown has no missed-wakeup window.
- Level-2 (uarch) leaf matches, timeout wins, and dangling-commitment
  finalization ARE covered e2e (gc_match, gc_tournament, the
  recordings) - the gaps are the specific shapes in findings 2/6/7.

## Standing conclusions

- The consensus-critical seams reshaped by the recent campaigns
  (engine, storage, facade) came out clean; the residual risk
  concentrated in OPERATIONAL loudness (findings 1, 3) and in
  UNPINNED protocol shapes (2, 6, 7) - the net's edges, not its
  center.
- The loudness doctrine is now enforced end to end for storage
  tripwires. The settle() path (finding 3) is the remaining seam
  where a permanent failure can impersonate a transient one.
- When re-running this audit: keep finders oracle-anchored and
  separate from verification; require failure scenarios; ship the
  clean-check list, not just findings - it is what makes the next
  audit incremental.
