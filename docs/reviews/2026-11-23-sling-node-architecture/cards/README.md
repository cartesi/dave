# Cards

Appendices of the [architecture review](../README.md). Each card was written
by an independent reader from one fixed template, for one component or one
body of evidence, against the reviewed tree
(`ec7afc62fd9d48ba39676c273ab09a74ab9cdeaf`). The cards are evidence: the
report's conclusions were drawn from them and then attacked separately, and
where a card and the report differ, the report is the later reading. Cards
keep the candidates their authors rejected; a candidate listed in a card is
not a proposal of the review unless the report takes it up.

Paths inside a card are relative to `cartesi-rollups/node/` or to the
repository root, as each card's scope line says. Emulator files are cited at
the pinned commit `54951d2ef027f26017c2f7df052ba5292e28e76f`. Records outside
the repository are cited by short name only.

## The template

Component cards use these headings, in this order: Possible correctness bug;
Owns; Takes; Gives; Invariants; Concurrency and crash consistency; What it
knows about its neighbours; Boundary verdict; Docs versus code; Defended
mechanisms; Candidate changes; Not verified. The rules given to every author:
read-only; cite `path:line` or do not claim; the code is the source of truth;
no line-level bug hunt, but anything that looks like a correctness bug goes
first; a recorded decision is not reopened without new evidence; every
conclusion is an argument with its premises, cost and reopening condition.

## The questions put to each card

Cards answer numbered questions beyond the template; "Q3" or "question 3" in
a card refers to these.

[Blockchain reader](blockchain-reader.md): 1 how inputs are numbered and
assigned to epochs, and what is carried across ticks; 2 the totals check at
the finalized head and the stall a retry never heals; 3 what it imports from
each neighbour; 4 which checks distrust a silent lie and which restate
contract rules; 5 where the stale-head pages belong; 6 why history below the
seed epoch is stored, and what pruning would take; 7 what an independent
replay would have to re-implement.

[Machine runner](machine-runner.md): 1 the emulator calls per accepted and per
rejected input; 2 what is durable after a crash at each step; 3 why a
dispute's boundary row is never the runner's cursor; 4 collection; 5 the
roll and its repeated checks; 6 whether the free-space floor and the
terminal-input page belong here; 7 what the benchmark measures.

[Storage](storage.md): the schema map, one entry per table; then 1 the
versioning fingerprints; 2 SQLite against the snapshot directories; 3 the
uses of `epoch_snapshot_info`; 4 the two populations of `sling_nodes`; 5 the
discipline tests; 6 connections and transactions; 7 outside readers.

[Engine](engine.md): 1 the claimed layering and every reach-around; 2 feeder
modes and collectors, and who uses each; 3 the level-0 special case; 4 the
surface the Hero uses; 5 chain-reachable asserts and the validator in front
of each; 6 emulator semantics re-implemented in the node; 7 what guards
`COMMITMENT_SEMANTICS`; 8 the merkle module; 9 test-only machinery.

[Tournament](tournament.md): 1 Solid and Foam; 2 every event and view
consumed; 3 the validation layers, by kind; 4 `sender.rs`; 5 what the module
knows of the Hero, the engine and storage; 6 which domain types are consumed;
7 the filter cap, the per-level harvest, the creation check and the hash
pins; 8 the phase and candidate checks; 9 what bounds memory.

[Hero](hero.md): 1 one tick, step by step; 2 the decision table; 3 the
self-healing doctrine, verified; 4 the panics and the exit-30 path; 5 losses
and missed obligations; 6 cleanup planning; 7 intent against prepared call;
8 what it knows of its neighbours; 9 tests; 10 where the timeout claim in
place of the proof would go.

[Epoch manager](epoch-manager.md): 1 one tick; 2 when a Hero is built and
dropped; 3 settlement planning and its asserts; 4 foreclosure and exit 30;
5 bond recovery; 6 the paging rule as used here; 7 what it knows of its
neighbours; 8 settled historical epochs; 9 machine work inside the tick;
10 what an outside observer can see of its obligations.

[Provider and lane](provider-lane.md): 1 what lives in which file; 2 the
lane, step by step; 3 what the lane has beyond nonce, classification and one
write per tick, and the recorded reason for each; 4 every chain read and its
block tag; 5 the run-time coupling to the contracts; 6 the bindings; 7 the
signer; 8 log fetching and who else implements it; 9 operations features.

[Process shell](process.md): 1 startup, step by step; 2 the workers; 3 the
exit-code contract; 4 the paging rule; 5 the flag surface; 6 the KMS client;
7 visibility in `lib.rs`; 8 dependencies; 9 `arithmetic.rs` and
`test_machine.rs`; 10 the README against the code; 11 what the shell knows
that it should not.

[Machine bindings](machine-bindings.md): 1 the wrapper calls the node uses;
2 the stored-directory types and the header rules behind them; 3 where the
node reaches past the wrapper; 4 errors; 5 the build seam and every pin;
6 other consumers; 7 what an independent replay would need; 8 whether the C
API has an in-process checkpoint; 9 the collectors; 10 the wrapper's tests.

Evidence cards have their own headings and no numbered questions:
[the per-input cycle](per-input-cycle.md),
[material for the detector](detector-material.md),
[seams with the repository](extraction-seams.md).
