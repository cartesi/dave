# Card: evidence on the runner's per-input cycle

Scope: the runner's batch loop and clone rotation as of the reviewed tree
(`cartesi-rollups/node/src/machine_runner/mod.rs`, `storage/advance.rs`,
`storage/snapshots.rs`, `storage/rollups_machine.rs`, `engine/machine_stf.rs`,
`engine/ruler.rs`, `machine/rust-bindings/cartesi-machine/src/{stored,machine}.rs`),
the docs that price it, the benchmark, and the out-of-tree measurement records.
The pinned emulator is `v0.23.0-test3` (`git describe` of the submodule pin).
Emulator files are cited as `emulator:src/<file>:<line>` at that pin.
Out-of-tree records (working notes, not part of the repository) are cited by
short name:
- REPORT: the report of the emulator v0.23 bump.
- STRIDE: that bump's runner measurements at both root strides.
- REPLY: the upstream reply of 2026-11 on stored directories and cold reads.
- ASKS, ASKS-RESP: an earlier list of asks sent upstream, and its response.
- R3, OVH: round 3 of the October 2026 robustness study, and its overhead
  measurements (macOS, and Linux in a container).

Possible correctness bug: none met.

## The cycle, call by call

Batch start (once per batch of up to 64 inputs, `DEFAULT_SNAPSHOT_GAP_INPUTS`,
`machine_runner/mod.rs:17`):
1. `advance_plan` reads SQLite and runs `gc_completed_epochs`, which may
   `remove_dir_all` released snapshots (`storage/advance.rs:244`, `:250-256`,
   `storage/snapshots.rs:450-455`).
2. `ensure_free_space` for open or settled epochs (`machine_runner/mod.rs:159-161`).
3. `begin_advances_at`: `checkout` = `cm_clone_stored` of the durable boundary
   into `.work-<pid>-<seq>` (`storage/advance.rs:286`, `storage/snapshots.rs:141-148`,
   `stored.rs:46-49`, `machine.rs:257-261`); `load_shared` = `cm_load_new`
   with `CM_SHARING_ALL` (`storage/advance.rs:305`, `rollups_machine.rs:269-274`,
   `machine.rs:200-204`, `:219`); one root hash to verify the row
   (`storage/advance.rs:312`, `storage/snapshots.rs:86`).

Per input, common prefix (`machine_runner/mod.rs:220-249`): the stf wraps the
shared machine; `Ruler::collect` at the root stride (2^38 on the canonical
table) runs `coarse_step_until` (`engine/ruler.rs:160-168`, `:396-451`). The
feed takes one root hash for the revert root (`engine/machine_stf.rs:360`),
then `send_cmio_response` (`:435-436`); `run_big` runs chunks up to the next
sample or window end (`engine/ruler.rs:441-447`, `engine/machine_stf.rs:456-477`).
The sampler pulls one root hash per emitted run that contains a sample
(`engine/ruler.rs:505-513`); the idle remainder after the yield is one run
(`engine/ruler.rs:424-432`). So the in-window root hashes are: one at the
feed, one per active stride chunk, one for the idle tail. I did not count the
active chunks for echo.

Accepted input (`record_accepted`, `storage/advance.rs:321-346`):
1. root hash (`storage/advance.rs:333`; with nothing dirty since the last
   sample it should be cheap, not measured separately).
2. `close` = checked `cm_destroy` (`storage/advance.rs:366-369`,
   `rollups_machine.rs:289-292`, `machine.rs:240-243`), then `cm_delete` on drop
   (`machine.rs:49-56`). Returns the working clone as `Volatile`.
3. `checkout` = `cm_clone_stored` of that just-closed, unsynced directory
   (`storage/advance.rs:370`).
4. `reopen_shared` = `cm_load_new(SHARING_ALL)` on the new clone
   (`storage/advance.rs:371-373`, `rollups_machine.rs:297-300`).
5. `batch.checkpoint = Checkpoint::Transient(checkpoint)` drops the previous
   checkpoint; if it was transient, `Volatile::drop` runs `remove_dir_all`, not
   `cm_remove_stored` (`storage/advance.rs:377`, `stored.rs:105-117`). For the
   batch's first input the previous checkpoint is `Durable` and nothing is
   removed (`storage/advance.rs:299`).

Rejected input (detected inside the ruler, finished by `record_reverted`):
1. `restore_rejected` (called from `ureset` or `run_big`,
   `engine/machine_stf.rs:452`, `:476`) does a private `Machine::load` of the
   checkpoint (`cm_load_new(SHARING_NONE)`, `engine/machine_stf.rs:314`,
   `machine.rs:189-190`). The assignment drops the poisoned shared machine:
   unchecked `cm_delete`, then `remove_dir_all` of its working clone
   (`machine.rs:43-56`, `stored.rs:105-117`).
2. root hash of the reloaded checkpoint against the revert root
   (`engine/machine_stf.rs:319-324`); further sample hashes, if any, are on
   this private machine.
3. `rotate_reverted`: `close` = checked `cm_destroy` of the private machine,
   which owns no directory (`storage/advance.rs:429`, `rollups_machine.rs:285-288`);
   `checkout` = `cm_clone_stored` of `batch.checkpoint` (`storage/advance.rs:430`);
   `reopen_shared` = `cm_load_new(SHARING_ALL)` (`:431-433`). No root hash in
   `record_reverted` (`storage/advance.rs:387-410`).

Counts per input (my count from the code above; S = in-window sample hashes):

| | loads | clones | root hashes | destroys (checked / unchecked) | removals |
|---|---:|---:|---:|---|---:|
| accepted | 1 shared | 1 | 1 (feed) + S + 1 | 1 / 0 | 1 (0 for a batch's first) |
| rejected | 1 private + 1 shared | 1 | 1 (feed) + S + 1 (restore check) | 1 / 1 | 1 (the poisoned clone) |

Batch end (`machine_runner/mod.rs:260-262`):
1. `drop(machine)`: the working clone the last rotation opened is never used;
   unchecked `cm_delete` and `remove_dir_all`. So each batch pays one extra
   clone + shared load + removal beyond one per input (my reading).
2. `commit_advances` -> `publish_checkpoint`: if the checkpoint is transient,
   `publish_staged` does a private `cm_load_new` and a root hash
   (`storage/snapshots.rs:109`), then `Volatile::persist` =
   `cm_sync_stored` + `cm_rename_stored` (`stored.rs:82-84`). A durable
   checkpoint (every input of the batch rejected) publishes nothing
   (`storage/advance.rs:476-480`).
3. One SQLite write transaction for the boundary row and the window roots
   (`storage/advance.rs:468-471`), WAL with `synchronous = FULL`
   (`storage/open.rs:38`, `:464-465`).
4. The node logs the batch's ms per input (`machine_runner/mod.rs:273-280`);
   this is the only production-side timing.

Dispute crossing uses the same rotations without collection or window roots
(`engine/machine_stf.rs:715-756`, `storage/advance.rs:487-503`).

## Measured figures, by source

All node-side figures are macOS on one Apple M5 Max laptop, APFS (REPORT:10;
STRIDE:7; OVH:3). Image is Dave's `test/programs/echo/machine-image` unless
said. No figure in the repository names its platform or emulator version:
the `just measure` preamble prints neither (`examples/measure.rs:175-200`).

Whole time per input, production runner (`bench_runner`):

| figure | source | emulator | stride | what it timed |
|---|---|---|---|---|
| 24.2 ms acc / 21.1 ms rej (41.4 / 47.5 per s) | `docs/measurements/measurements.md:60-63` | v0.23.0-test3 (inferred: regenerated by the latest change) | 2^38 | one run, 256 inputs each kind |
| medians 25.1 acc / 21.6 rej; ranges 24.1-26.9 (one 30.3) / 20.4-22.4 (one 24.7) | STRIDE:13-14, and the commit message of the change that moved the benchmark to the canonical table | v0.23.0-test3 | 2^38 | 10 runs each, quiet round |
| same at 2^44: 24.8 / 22.2 | STRIDE:13 | v0.23.0-test3 | 2^44 | 10 runs |
| busy round medians 26.2 / 24.1, worst 31.1 / 32.0 at 2^38 | STRIDE:15-20 | v0.23.0-test3 | both | 7 runs, load average up to 8.6 |
| 25.2 and 24.4 acc / 21.8 and 21.3 rej | REPORT:151-152 | v0.23.0-test3 | 2^44 | two runs |
| 24.4-26.4 acc / 21.2-22.6 rej | REPORT:542-543 | v0.23.0-test3 | 2^44 | nine runs |
| 149.6 acc / 149.5 rej | REPORT:151-152; `measure/v022-measurements-runner.md:61-62` | v0.22.0 | 2^44 | one run |

macOS phase breakdown (REPORT:154-163, a 25-sample probe mirroring the
rotations, medians; v0.22.0 -> v0.23.0-test3): shared load of a fresh clone
126.4 ms (3,089 page-ins) -> 2.6 ms (22); clone of the just-closed directory
2.8 -> 2.7; close 1.8 -> 4.6; discard old transient checkpoint 1.9 -> 3.2;
rotation total accepted 134.2 -> 14.9, rejected 135.0 -> 14.6; first input
after the rotation 9.2 -> 10.2; same input warm 2.2 -> 2.3. REPORT:174-175
attributes "about 8 ms" to first touch (10.2 - 2.3 = 7.9 is my arithmetic).
Earlier v0.22 rotation (ASKS:45-51): close 2.3, clone 2.8, load 132.3,
discard 2.2, first input 10.1, state_hash 0.7, total about 151 ms.

Repository clone loop (`docs/measurements/measurements.md:43-46`, one sample,
2 inputs, raw machine, no ruler): clone 3.8 / 2.3 ms, shared load 3.4 / 2.3,
advance 13.0 / 10.1, root hash 1.7 / 1.1, destroy 4.1 / 4.6.

The upstream reply (REPLY), versions "0.22" and "0.23" (the 0.23 build
is not named; the reply ships its changes in v0.23.0-test4, REPLY:3, while
the node pins test3). Their image is "the echo application from our root file
system" (REPLY:41), not stated to be Dave's echo image. Hardware not stated.
- macOS, fresh shared clone per input (REPLY:41): load 69 -> 3.3 ms; first
  root hash 1.8 -> 2.6; root hash after the first input 1.8 -> 2.6; on a
  warm machine after a third input 0.53 -> 0.27; their sum of load and both
  root hashes about 72.5 -> 8.5 ms.
- Linux, medians of 10 inputs on fresh reflinked clones of the template
  (REPLY:43-49), XFS 0.22 / XFS 0.23 / Btrfs 0.22 / Btrfs 0.23: load 106.5 /
  2.2 / 65.6 / 6.0; first root hash 1.8 / 3.0 / 8.2 / 12.2; root hash after
  the input 5.1 / 10.0 / 2.4 / 6.0. Their sums (REPLY:51): XFS 113 -> 15 ms,
  Btrfs 76 -> 24 ms. Pre-reading the clone removes the difference (REPLY:51).
- "Processing an input on a fresh reflinked clone": about 40 ms on XFS and
  Btrfs in both versions, about 10 ms with the clone in memory (REPLY:53).
  The text does not say whether this includes the root hashes, the load, or
  only the run from feed to yield; it is not settled. Each clone is of the
  template, not a chain of clones of just-closed directories.
- XFS medians of 30 inputs "following your runner's sequence" (REPLY:57-64):
  destroy of a shared machine 2.05 -> 0.79 ms; remove its clone 12.5 -> 7.2
  ms (the removal call is not named); store a freshly loaded template
  259.5 -> 264.1 ms; store again 244.8 -> 247.2 ms.

Other Linux figures:
- ASKS-RESP:36-43: 8 GiB loopback XFS with `reflink=1`, synthetic machine
  with 16 MiB populated RAM, 25 fresh clones: clone 1.12 ms, fresh load 0.67
  (NONE) / 0.71 (ALL), warm 0.33 / 0.35. Not after dropping caches, not a
  cloud volume (ASKS-RESP:46-48). v0.23.0-test2 pre-release.
- OVH:145-165 and `lbench.out`: Docker VM, overlayfs on ext4, v0.22.0, 25
  reps: cold load after dropping caches 27-30 ms median, 65 ms p90; clone is
  a warm copy of 90-139 ms (no reflink). "VM-indicative" by its own words.

## What the threshold is and where the docs use it

Derivation (my arithmetic, values from `docs/dimensioning.md:48`, `:68`):
`C + G` = 604,800 s + 300 s = 605,100 s; / 2^24 = 36.07 ms. Testnets, `C` = 8 h:
29,100 s / 2^24 = 1.73 ms. Root allowance "a week plus 140 minutes"
(`docs/dimensioning.md:106-107`) = 613,200 s; half over 2^24 = 18.27 ms.

Uses:
- 36 ms and 1.7 ms: `docs/dimensioning.md:85-86`; `docs/todo.md:22`, `:42`.
- 18 ms: `docs/dimensioning.md:102-103` (spill-epoch backlog bound).
- Reference price at 0.14-0.2 s (v0.22): `docs/dimensioning.md:67-77`, flagged
  as due re-derivation at `:77-81` and `docs/todo.md:41-46`.
- Drain 4.3-5.0 days (61%-72% of a week) and 38-47 inputs per second:
  `docs/dimensioning.md:91-95`; `docs/todo.md:44-45`. Check: 2^24 x 22 ms =
  4.27 d, x 26 ms = 5.05 d; 1/26 ms = 38.5/s, 1/22 ms = 45.5/s (mine).
- Runner cap "near 40 inputs per second": `docs/node-architecture.md:347`,
  `docs/dimensioning.md:278-280`.
- Gap and crossing cost: "a crossing costs it once per crossed input"
  (`docs/node-architecture.md:348-349`); per-input contract "each replayed
  input also pays the node's fixed overhead (about 0.14-0.2 s on macOS),
  about 9-13 s of the 150 s at the default gap ... caps any gap near
  `G / (2 x overhead)`" (`docs/dimensioning.md:243-246`).
- Spill-epoch flood door 3.9-5.6 times the reference price
  (`docs/dimensioning.md:108-111`), relative to the 0.14-0.2 s price.

If Linux measured about 60 ms per input (my arithmetic):
- Above 36 ms: "inputs alone no longer outrun the root join"
  (`docs/dimensioning.md:85-87`, `docs/todo.md:41-43`) becomes false; the
  aggregate-throughput contract binds again (`docs/dimensioning.md:282-285`).
- Reference price: `C + G` holds about 10.1 million inputs, about 3.0e11 gas
  at 30k per input, versus 3-4.3 million at 0.14-0.2 s (`:68-71`).
- Drain: 2^24 x 60 ms = 11.65 days, more than `C`; the 4.3-5.0 day figure
  and "61% to 72%" (`:92-93`, `docs/todo.md:44`) fail.
- Rate: 16.7 per second, not 38-47 (`:93`) or "near 40"
  (`docs/node-architecture.md:347`, `docs/dimensioning.md:279`).
- 18 ms statement: its premise "below the threshold" no longer holds
  (`docs/dimensioning.md:100-103`).
- Gap cap `G / (2 x overhead)` with G = 300 s: 2,500 inputs at 60 ms; the
  64-input gap's replay overhead would be 63 x 60 ms = 3.8 s of 150 s. Neither
  binds at the default gap; the doc's own 9-13 s (`:244`) uses v0.22 figures.
- The flood-door ratio (`:108-111`) moves with the price.

## What the emulator does on clone, close, sync, load and remove

- Clone (`emulator:src/cm.h:603-615`): "Read-only files are copied using hard
  links" (:608), "Writable files are copied using reflinks on copy-on-write
  filesystems" (:609), sparsity preserved (:610), source must have no running
  instance (:611), durable only after sync (:614). It says nothing about the
  source's dirty pages. Implementation: `machine::clone_stored` clones three
  files per address range (data, dht, dpt), then `sht`, `phtc`, and the config
  last (`emulator:src/machine.cpp:521-567`). `clone_file` takes `LOCK_SH`
  on the source, reflinks a writable file or hard-links a read-only one
  (`emulator:src/os-filesystem.cpp:582-614`), and falls back to a sparse
  `pread`/`pwrite` copy only on ENOTSUP, EXDEV, or EPERM/EMLINK for read-only
  files (`:615-625`, `copy_file` at `:398`). Linux reflink is
  `ioctl(FICLONE)` with `LOCK_EX` on the destination
  (`emulator:src/os-filesystem.cpp:524-566`); macOS is `clonefile`
  (`:573-575`). The writeback of the source's dirty pages before FICLONE
  shares blocks is the kernel's, stated in REPLY:9, not in `cm.h` or the
  emulator source. REPLY:11: macOS `clonefile` is not documented to include
  dirty pages.
- Load (`emulator:src/cm.h:563-577`): `CM_SHARING_ALL` means "Machine state
  will be fully on-disk" (:569); "The directory holds a valid machine again
  only after cm_destroy() succeeds and cm_sync_stored() then succeeds" (:574);
  discard after a crash (:575). A shared writable mapping takes `LOCK_EX`,
  a private one `LOCK_SH`, and maps `MAP_SHARED` or `MAP_PRIVATE`
  (`emulator:src/os-mapped-memory.cpp:144`, `:182`). Which files a load reads
  eagerly is not in `cm.h`; REPLY:39 says v0.23 reads only what it needs and
  each root hash faults in phtc pages for the pages it rehashes.
- Destroy versus delete (`emulator:src/cm.h:510-515`, `:654-661`):
  `cm_delete` "silently calls cm_destroy()"; to be sure, "call cm_destroy()
  explicitly" (:658). At the pin the destructor marks write-TLB dirty pages
  and swallows a failure to stderr (`emulator:src/machine.cpp:829-837`);
  mappings `msync(MS_ASYNC)` and `munmap` with results ignored
  (`emulator:src/os-mapped-memory.cpp:537-539`). REPLY:19 says test4 makes
  `cm_destroy` save the dirty marks itself and report failure; the node pins
  test3.
- Sync (`emulator:src/cm.h:643-652`): fails while a running machine maps a
  file for writing (:650); on success all previous changes are durable
  (:651). Implementation fsyncs every stored file, the directory and its
  parent (`emulator:src/machine.cpp:707-716`), `F_FULLFSYNC` on macOS
  (`emulator:src/os-filesystem.cpp:633-645`).
- Store (`emulator:src/cm.h:589-601`): durable only after sync (:600). The
  runner never stores.
- Rename (`emulator:src/cm.h:617-625`): no replacement; rename and parent
  entries durable on success (:624).
- Remove (`emulator:src/cm.h:627-641`): removal durable on success (:637-638).
  The node does not use it for volatile directories (`stored.rs:107-108`).

## What the benchmark measures today

- `bench_runner` (`examples/measure.rs:369-454`) times one call of
  `MachineRunner::process_rollup` over 4 batches x 64 = 256 inputs
  (`:381-383`, `:432`) and divides: whole time per input only, no phases.
  It includes the plans, batch begins, collects, rotations, the per-batch
  publication and SQLite commits.
- Two separate runs: all accepted, or all rejected (every input carries the
  echo fixture's rejecting index 2, `:400-410`). No alternating mix.
- Canonical two-level table, root stride 2^38 (`:402`, `:390-392`), echo only
  (`main` runs it only for the echo profile, `:154-156`).
- One sample per kind; the preamble says entries are order-of-magnitude
  (`:180-183`).
- The all-rejected run never leaves its durable seed: every input clones and
  privately reloads the same source directory, and no batch publishes
  (`storage/advance.rs:299`, `:430`, `:476-480`). It never clones a
  just-closed dirty directory, so on Linux it would not pay the FICLONE
  writeback the accepted path pays (inference from REPLY:9 and the code).
- Scratch lives under `std::env::temp_dir()` (`:130`), so a Linux run measures
  whatever `TMPDIR` (default `/tmp`) is: tmpfs or ext4 would measure copies,
  not reflinks. `just measure` has no `TMPDIR` note; the node-vs-emulator
  recipe does (`justfile:255-260` versus `:268-269`).
- Run on Linux: `just measure` (`justfile:256-260`) needs `bind`, the echo image
  built and fingerprint-verified (`:257`; the image is not present in this
  worktree), and the emulator library (`LIBCARTESI_PATH` or
  `just machine::setup`). It overwrites `docs/measurements/measurements.md`
  whole (`--out`, `:260`), including the fold, store, clone-loop, atom and
  span-replay sections, with no host, filesystem or version line.
- `bench_clone_loop` (`examples/measure.rs:271-326`) times clone, shared load,
  one raw advance, root hash and destroy for 2 inputs; no removal, no
  rejected path, no ruler.

## What is not measured anywhere

- The node's own cycle on Linux XFS, any phase or whole: no source. The
  upstream XFS rows clone the template per input, not a chain of
  just-closed directories (REPLY:43).
- A cloud block volume at baseline provisioning (`docs/todo.md:18-23`;
  ASKS-RESP:46-48 excludes it).
- The cost and bytes of the FICLONE writeback of a dirty source per accepted
  input; the reply says it happens (REPLY:9) and did not measure close
  writeback (REPLY:66).
- Memory pressure: page-cache eviction of the transient checkpoint between
  close and clone or between rejections; a container memory limit.
- Long clone chains: extent fragmentation after 10^5 or more reflink
  generations on XFS; every figure is 2 to 256 inputs.
- Concurrent Hero work (a crossing, a leaf build) sharing cores and disk with
  a runner batch (`docs/todo.md:15-17`, `docs/dimensioning.md:79-81`).
- An application heavier than echo through the runner (`bench_runner` is
  echo only); stress has only the clone loop.
- The rejected path on Linux, and alternating or mixed accept/reject batches
  on any platform (`docs/todo.md:24-25` asks for them).
- Repetitions or percentiles of the runner figure on Linux; production
  `published ... ms per input` logs (`machine_runner/mod.rs:273-280`) from a
  Linux node are not collected anywhere I found.

## Inconsistencies between sources

1. Whole-time figure: docs say about 26 ms accepted and 22 ms rejected
   (`docs/node-architecture.md:340-341`, `docs/todo.md:21`); the checked-in
   table says 24.2 and 21.1 (`docs/measurements/measurements.md:62-63`);
   medians are 25.1 and 21.6 (STRIDE:13). The docs round up from the
   range tops (REPORT:542-545); the commit message keeps them on purpose.
2. Rate 38-47 per second (`docs/dimensioning.md:93`) mixes bases: 22-26 ms
   gives 38-45; 47 matches the 21.1 ms rejected sample (47.5/s).
3. Phase sum: docs say "about 15 ms of rotation (close 5, clone 3, reload 3,
   removal 3)" (`docs/node-architecture.md:341-342`), which adds to 14; the
   probe's pieces add to 13.1 against its own "rotation total" 14.9
   (REPORT:156-161). The rejected rotation is costed as the accepted one
   (14.6), but the rejected path does an extra private load and root hash
   (`engine/machine_stf.rs:314-324`) and the rejected whole time is lower
   (22 vs 26); the probe's rejected sequence is not in the repository, so I
   could not check whether it mirrors `restore_rejected`.
4. First touch: macOS cold first input 10.2 ms vs warm 2.3 ms (REPORT:162-163,
   about 8 ms of first touch, `docs/node-architecture.md:343-344`) versus the
   upstream figures of about 40 ms cold and 10 ms warm on XFS and Btrfs (REPLY:53).
   Images, hardware, emulator build and the scope of "processing" all differ
   or are unstated, so the gap of about 30 ms is not attributable yet.
5. Destroy and removal: macOS v0.23 close 4.6 ms and discard 3.2 ms
   (REPORT:158-159) versus XFS 0.79 ms and 7.2 ms (REPLY:61-62); the reply
   could not reproduce the macOS slowdown (REPLY:57, :66).
6. Load on XFS: 2.2 ms on a fresh template clone (REPLY:47) versus 0.71 ms on
   the loopback XFS synthetic image (ASKS-RESP:43); different images.
7. The per-input contract still prices replay overhead at v0.22's 0.14-0.2 s
   without a staleness flag (`docs/dimensioning.md:243-245`), while the same
   file quotes v0.23's 22-26 ms (`:77-78`, `:91-93`). The reference price at
   `:67-71` carries the flag (`:77-81`).
8. v0.22 load: "about 130 ms" (`docs/node-architecture.md:344-346`) versus
   126.4 ms (REPORT:156) and 132.3 ms (ASKS:47); rounding, not a conflict.
9. REPORT:171-172 gives 4.3-4.9 days and 40-47 per second; the docs and
   REPORT:544 give 4.3-5.0 and 38-47 after the revised figures.
10. The docs do not yet reflect the reply: nothing cites the XFS cold reads
    or the 40 ms (no match for those figures under `docs/`).

## Not verified

- The node's actual time per input on Linux, XFS or otherwise: no data.
- The upstream measurement's image, hardware, emulator build, and exact call
  sequence and timing scope; whether their "removal" is `cm_remove_stored`
  or a plain directory removal.
- Whether `docs/measurements/measurements.md` was generated on v0.23.0-test3
  (inferred from the change history, not stated in the file).
- The probe behind REPORT:154-163 (kept with that report, out of tree) was not
  read; its rejected sequence and the 14.9 vs 13.1 ms gap are unexplained.
- The count S of in-window root hashes for echo at stride 2^38.
- That FICLONE writes back dirty pages: taken from REPLY:9, not checked
  against kernel source. That tmpfs refuses FICLONE with an errno that takes
  the copy fallback: not checked.
- The kernel and APFS behaviour of `clonefile` on dirty pages (REPLY:11 says
  undocumented).
