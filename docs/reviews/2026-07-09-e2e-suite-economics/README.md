# E2e suite economics - first measurements and incident record

Status: frozen historical record (measurements 2026-07-09/10, case
studies through 2026-07-24), moved verbatim out of docs/test-harness.md
on 2026-07-25. The living summary - baseline, wall-time classes, open
levers, tiering recommendation, and diagnosis disciplines - lives in
docs/test-harness.md's Suite economics section. Numbers and open items
below describe their recorded dates, not the present.

## Suite economics (first measurements, 2026-07-09)

Measured on one dev machine (debug node, local anvil) during the
workstream 6 verification run; the first hard numbers behind the
assessment above. Wall times include harness setup but not the
workspace build.

Superseded 2026-07-10 by the full parallel battery (battery.sh: all
21 scenarios at the time - the SCENARIOS array in battery.sh is the
current list and has since grown - TEST_INSTANCE lanes, ff=128):
green scenarios sum to
~41 min of machine time, wall clock ~15 min at 5 lanes. Slowest:
stf_all ~7 min per program, simple_no_input ~3.5 min; the whole kill
family runs 33-129 s; gc_match 46 s. The racy-era "half a day,
serial" figure is retired. That run also caught the second reader
bug (the pruned-pin case study below): the only failures were both
gc_tournament flavors hanging on a dead node until the scenario
deadline failed them - the deadline and the battery each doing
exactly their job.

The clean baseline, same day, after the retry fix and caffeinate:
21/21 green, ~42 min of scenario time, ~11 min wall at 5 lanes, no
leaked processes. gc_tournament runs 80 s on the retried node;
slowest scenario is yield stf_all at ~7 min; the cheapest ten all
finish under two minutes. This is the number to beat, and the run
to repeat before any handoff: LANES=5 prt/tests/rollups/battery.sh.

Sweep the instance dirs once results are read (`just
rollups-tests::sweep`): each lane leaves ~5 GB of forensic state,
two batteries filled a disk to 7 GB free on 2026-07-11, and a
nearly-full disk quietly slowed every 128 MB machine store - the
unit suite crawled from 2 s to 15 s with no code change. `just
doctor` warns when the litter passes 10 GB.

Addendum, same day: the verification battery on the retry-fixed
binary looked catastrophic - four new deadline failures, uniform
~14x dispute slowdowns - and every symptom was the LAPTOP, not the
code: the machine was on battery and cycling into Deep Idle, and
pmset's log matched the lanes' freeze windows to the second (a
608 s sleep = a 607 s simultaneous node+sybil+anvil silence). Zero
retries had fired; the binary was innocent. Three lessons now
encoded: battery.sh holds the machine awake (caffeinate) for the
run; the scenario deadline counts wall clock through sleep, which
is fine once the runner holds the box but must be remembered when
reading unattended failures; and the diagnosis discipline - when
independent processes freeze and resume in lockstep, check
pmset -g log before blaming software. A side probe worth its
numbers: anvil with --preserve-historical-states holds every state
in memory - 8.5 GB at 30k blocks with a superlinear jump past
~12k, vs 4 GB default - so the dump flag pair became opt-in
(ANVIL_DUMP_PATH, unset by default; nothing consumed the dumps).
Real scenarios mine under 1k blocks, where neither config strains.

Second environment incident (2026-07-14): a fresh worktree carried a
STALE devnet - a state.json and deployments deployed from older
contract sources - and the echo e2e died on the node's scariest
assert ("Winner commitment mismatch, notify all users!"), left and
right both plausible hashes. The node, harness, and image were all
innocent; observed on-chain, the stale deployment settled the empty
epoch 0 with the initial machine hash as winner where the current
contracts settle with the joined claim (the padded tree over it).
Diagnosis needed a full bisect run at the
pre-session commit (same failure = environment). Two lessons
encoded: build-devnet now writes state.fingerprint (tree hashes of
both contract packages plus dirty status - script/
devnet-fingerprint.sh), and `just doctor` compares it, naming the
rebuild command; and the diagnosis discipline - when an e2e fails
on a consensus assert in a NEW environment, suspect the deployed
state before the code, and check the sibling worktree's artifacts
byte-for-byte. Copying a green worktree's state.json + deployments
is as valid as copying its machine images (both are deterministic
functions of the sources), and the fingerprint travels with them.

- `echo simple` (full 3-level dispute): ~7 min. Bisection itself is
  fast - advances land 1-2 s apart in bursts; the sybil-active
  window is ~70 s.
- `gc_match` (two lazy sybils, timeout eliminations): ~25 min, of
  which sybil activity is ~1 min. The rest is protocol-time
  fast-forwarding: `wait_until_epoch` advances 16 blocks per 4 s
  poll (FAST_FORWARD_TIME), so every sequential ~300-block clock
  expiry costs ~75 s of wall clock, and timeout-heavy scenarios
  stack several.
- `gc_tournament`: ~5 min (same mechanism, fewer expiries).
- `kill_mid_match`: ~4 min of node-side dispute time with the
  pinned reader (see the case study - the first run took >2 h and
  crashed, and the hours turned out to be the bug, not the test).

Where the wall time goes, by class, largest first: (1) protocol-
timeout fast-forwarding throttled by the harness poll loop
(dominates gc_*, bad_commitment); (2) per-scenario setup and
inter-phase waits (anvil spawn, epoch-0 roll, oracle commitment
builds, settlement polling); (3) serial scenario execution on fixed
ports. Node-side machine work and tick cadence are NOT drivers at
current constants (tests run --sleep-duration-seconds 1; bisection
advances land 1-2 s apart; a full 3-level dispute with a mid-match
kill and catch-up is ~4 min).

Levers, in leverage order:

1. (done 2026-07-10, ff=128 in test_env.lua) Crank the fast-forward
   loop: 16 blocks per 4 s was arbitrary caution; anvil can advance
   hundreds of blocks in one call and the node at 1 s ticks keeps up.
2. Test-shape constants profile (workstream 8): smaller clock
   allowances shrink class 1 at the source, shallower trees shrink
   dispute depth. Contracts-side gap; sling's Structure is ready.
   Note its urgency dropped with the pinned reader: stf_all measured
   ~9 min on 2026-07-09 (all five epochs, four disputes, while
   sharing the machine with a parallel scenario) against the 60 min
   CI budget set in the racy-reader era.
3. (done 2026-07-09) TEST_INSTANCE parallel isolation - wall clock
   for a batch becomes the max of the set, not the sum. Battery
   runners must pick distinct free ports per scenario; since
   2026-07-10 (run-local snapshot scratch) even the same scenario
   twice concurrently is safe, anvil dump paths aside.
4. (done 2026-07-09) Scenario deadline: every wait in the harness and
   Lua client sleeps through utils/time.lua, which now errors loudly
   past SCENARIO_DEADLINE_SECS (default 3600, 0 disables) - a hung
   run fails instead of burning hours. dave.log is archived one
   generation (.prev) so the forensics survive the next run.

Case study, 2026-07-09: the first kill_mid_match run under
workstream 6 ran >2 h with 8-16 minute stalls between node moves,
then crashed - an unpinned overlay read raced the advancing chain
and a clock display underflowed. The stalls and the crash were the
same bug: the tick sampled its block once but point-read at Latest,
so under heavy block traffic the Hero kept seeing inconsistent
fold-vs-position state and concluding "not my turn". Pinning every
read at the tick's block (plus saturating clock arithmetic) fixed
the crash AND cut the scenario to ~4 min. Lessons the numbers
teach: the slow scenario earned its keep (it is the only net that
holds a dispute open long enough, with enough block traffic, to
hit tick-consistency races); when the slowest test is mysteriously
slow, suspect the product before the test (the 2026-07-08
"battery is about half a day" figure was measured on the racy
reader - remeasure before optimizing anything); a dead node
manifests as an infinite hang, not a failure (lever 4); and
per-run log truncation destroyed the first run's evidence (worth
teeing dave.log per run into a scratch dir before rm).

Case study, 2026-07-24: the semantic Hero cutover initially made
`kill_mid_match` finish the dispute without killing the node. The action still
landed, but the new single-dispatch seam had dropped the stable `advance match`
marker, so the harness never observed its protocol kill point. Restoring
concise markers at that seam made the scenario kill, respawn, and win again
without changing a timeout or assertion. The marker contract above is
behavioral test infrastructure, not incidental log prose.

Case study, 2026-07-10 (the pin's other edge): the first full
parallel battery failed exactly two scenarios - both gc_tournament
flavors - each hanging until the new scenario deadline killed it.
The node logs held the cause: a pinned overlay read asked anvil for
state at the tick's sampled block, anvil under aggressive
fast-forward would not serve it (BlockOutOfRangeError), and the
epoch manager's ?-operator turned that transient into node
shutdown - a dead validator with its clocks still running, found
only because the deadline converts hangs to failures. The fix is
architectural, not harness-side: every tick is re-derived from
storage and chain by design, so the epoch manager now logs and
retries failed iterations instead of dying; real gateways prune
historical state too, so this was a production bug wearing a
harness costume. Consensus asserts stay fatal. Lesson: the pinned
read trades tail freshness for consistency, and its price is that
the provider must serve a seconds-old block - degrade to retry,
never to death.

What is NOT earning its keep, on current evidence: the yield-all
tier duplicates honeypot-all's scenario list 1:1 minus
deposit_withdrawal (simple_no_input, stf_all, big_input, gc_match,
gc_tournament, bad_commitment) - the program differs but the
protocol paths exercised are the same. Yield's unique value is the
revert shape, and that lives in stf_revert - which, as discovered
while writing this, was wired into NO suite target and no CI step
(now in test-yield-all): the full-revert-restore net had been dark
since it was written, the exact big_input rot pattern. A reasonable
nightly tier keeps yield stf_revert and drops the duplicated yield
scenarios to manual; verify the overlap claim per scenario before
acting.

The unit-layer counterpart landed the same day (see the blind-spot
list): the Hero is generic over the ruler factory, the toy grew
proving verbs, and thirteen decision-table tests run the react loop
chain-free in a fraction of a second. Still open from that recipe:
the reader's overlay assembly against a mock provider.
