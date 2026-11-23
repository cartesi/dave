# Card: Cartesi Machine bindings (machine/rust-bindings, machine/script, build seam)

Scope (production lines, `#[cfg(test)]` modules excluded):
`cartesi-machine/src/machine.rs` 1054, `stored.rs` 153, `config/machine.rs`
506, `config/runtime.rs` 163, `config/mod.rs` 5, `types/base64_decode.rs` 174,
`types/collect.rs` 137, `types/cmio.rs` 104, `types/access_proof.rs` 91,
`types/mod.rs` 64, `types/memory_proof.rs` 31, `types/memory_range.rs` 22,
`constants.rs` 140, `lib.rs` 35, `error.rs` 21 (wrapper: 2700);
`cartesi-machine-sys/build.rs` 381, `src/lib.rs` 9; `machine/script/cartesi-machine-source.sh`
409; `machine/AGENTS.md` 37, `machine/README.md` 67. C API read at the pinned
emulator commit (`src/cm.h`, 1248 lines; cited below as `cm.h:N`).

## Possible correctness bug

None met. One P1-shaped lead, not a bug today: `CmioRequest::new` panics on an
unknown command or automatic reason (`machine/rust-bindings/cartesi-machine/src/types/cmio.rs:39`,
`:52`), so `Machine::receive_cmio_request` (`machine.rs:728`) can panic on
guest-shaped state. The node never calls it in production; it decodes the
HTIF header itself for exactly this reason (`cartesi-rollups/node/src/engine/machine_stf.rs:120-126`).
Whether the emulator can return such a `cmd` is unverified. A replay tool
reusing the wrapper would inherit the panic.

## Owns

- The only `unsafe` FFI into libcartesi: every `cm_*` call goes through
  `check_err!` (`machine.rs:59-67`) and `Machine::last_error` (`machine.rs:999-1007`).
- The machine handle's lifetime: `Drop` calls `cm_delete` (`machine.rs:49-57`);
  `Machine::close` calls `cm_destroy`, checked (`machine.rs:240-244`).
- The typed rules for stored directories (`stored.rs:4-25`): `Volatile`
  (closed, unsynced, removed on drop), `Durable` (synced, never opened shared,
  never removed), `Stored` (loadable/clonable). `Machine.home` ties a shared
  open to its directory (`machine.rs:41-47`, `:200-207`).
- JSON marshalling of configs, proofs, access logs and collector results, with
  panics on schema mismatch by design (`machine.rs:69-98`).
- Argument guards the C API lacks: bundle sizes (`machine.rs:984-996`), cmio
  length u32 (`machine.rs:971-978`), path NUL bytes (`machine.rs:1033-1053`).
- Provider selection, bindgen and static linking (`cartesi-machine-sys/build.rs:28-124`).
- The emulator version guard `EXPECTED_EMULATOR_VERSION = 23_000` (`lib.rs:26`).

## Takes

- From libcartesi (static archive): everything. The wrapper trusts the C API
  contract and JSON shape; the round-trip tests are the check
  (`config/machine.rs:530-579`, `config/runtime.rs:177-229`).
- From callers: paths. `Durable::at` trusts its argument entirely
  (`stored.rs:137-140`); `Volatile::adopt` trusts that no machine maps it and
  that removing it is the caller's intent (`stored.rs:64-70`).
- From the build environment: `LIBCARTESI_PATH` (must be absolute,
  `build.rs:37-44`), `INCLUDECARTESI_PATH` (absolute, else sibling
  `include/cartesi-machine`, `build.rs:215-236`), or the prepared submodule
  plus `target/machine-source/prepared-generated-sources` (`build.rs:126-213`).

## Gives

Node production call sites (tests, `examples/measure.rs`, `tests/` excluded),
wrapper function -> C function:

| wrapper | cm_* | node production caller |
|---|---|---|
| `Machine::version` | `cm_get_version` | `src/main.rs:29`, `src/engine/config.rs:56` |
| `Machine::uarch_pristine_hash` | `cm_get_uarch_pristine_hash` | `src/args.rs:150`, `src/storage/open.rs:154` |
| `Machine::reg_address` | `cm_get_reg_address` | `src/storage/rollups_machine.rs:59-62` |
| `Machine::load`, `Stored::load` | `cm_load_new(SHARING_NONE)` | `rollups_machine.rs:257`, `machine_stf.rs:167`, `:314`, `open.rs:121`, `snapshots.rs:109` |
| `Volatile::open` -> `open_shared` | `cm_load_new(SHARING_ALL)` | `rollups_machine.rs:274`, `:299`, `open.rs:347-348` |
| `Machine::close` | `cm_destroy` | `rollups_machine.rs:291`, `open.rs:351-354` |
| `Drop for Machine` | `cm_delete` | every drop |
| `Stored::clone_to` | `cm_clone_stored` | `snapshots.rs:148` |
| `Volatile::persist` | `cm_sync_stored` + `cm_rename_stored` | `snapshots.rs:127` |
| `Durable::at`, `Durable::sync` | `cm_sync_stored` | `snapshots.rs:120-121`, `advance.rs:285`, `open.rs:343` |
| `root_hash` | `cm_get_root_hash` | `machine_stf.rs:320`, `:339`, `:360`, `:557`; `rollups_machine.rs:324`, `:354`; `open.rs:123`, `:350` |
| `node_hash` | `cm_get_node_hash` | `open.rs:153` |
| `initial_config` | `cm_get_initial_config` | `open.rs:124` |
| `proof` | `cm_get_proof` | `rollups_machine.rs:189` |
| `read_memory` | `cm_read_memory` | `rollups_machine.rs:194` |
| `read_reg`, `mcycle`, `imcyclemax`, `iflags_y`, `iflags_h`, `ucycle`, `uarch_halt_flag` | `cm_read_reg` | `machine_stf.rs:128-131`, `:170`, `:285`, `:296`, `:351`, `:461-475` |
| `run` | `cm_run` | `machine_stf.rs:464` |
| `run_uarch` | `cm_run_uarch` | `machine_stf.rs:444` |
| `reset_uarch` | `cm_reset_uarch` | `machine_stf.rs:450` |
| `collect_uarch_cycle_root_hashes` | same | `machine_stf.rs:429-431`, `:502-506` |
| `send_cmio_response` | same | `machine_stf.rs:435-436` |
| `log_send_cmio_response`, `log_step_uarch`, `log_reset_uarch` | same | `machine_stf.rs:558`, `:571`, `:577` |
| `RuntimeConfig::quiet_console`, `clear_hash_tree` | (JSON) | `rollups_machine.rs:256`, `open.rs:193-198`, `machine_stf.rs:112-118` |

No production caller in the node: `Machine::store` (`machine.rs:320`; reached
only through `MachineStf::store` from `examples/measure.rs:243` and the
Scratch feeder `machine_stf.rs:379`, used by tests and measure: production
never serializes a machine, it clones), `create`, `default_config`,
`write_reg`, `write_memory` (tests only); `verify_reset_uarch`,
`receive_cmio_request` (node tests only, `machine_stf.rs:1503`, `:1552`,
`tests/common/instance.rs:224`); `clone_stored` direct (`tests/engine_machine.rs:1564`);
`Volatile::adopt` (`open.rs:643`, test module). Nobody outside the wrapper's
own tests: `collect_mcycle_root_hashes`, `log_step`, `verify_step`,
`verify_step_uarch`, `verify_send_cmio_response`, `remove_stored`/`RemoveMode`,
`set_runtime_config`, `runtime_config`, `replace_memory_range`,
`memory_ranges`, `read_word`, `read/write_virtual_memory`,
`translate_virtual_address`. Unbound in `cm.h`: `cm_new`, `cm_clone_empty`,
`cm_read/write_revert_root_hash` (`cm.h:727`, `:733`), `cm_write_word`,
console I/O, `cm_collect_mcycle_bundle` (`cm.h:965`),
`cm_collect_uarch_cycle_bundle` (`cm.h:1051`), `cm_clear_hash_tree`,
`cm_verify_hash_tree`, `cm_get_hash`, `cm_get_concat_hash`.

Other items the node uses: `types::Hash` as its general 32-byte type, even in
chain code (`src/blockchain_reader/mod.rs:15`, `src/storage/convert.rs:12`,
`src/storage/mod.rs:43`); `constants::rollup` and `ar` (`src/engine/constants.rs:8-43`,
`src/engine/structure.rs:12`); `error::MachineError` (`src/storage/error.rs:5`, `:26-30`).

## Invariants

1. A shared-open directory cannot be loaded, cloned or synced while mapped:
   `Volatile::open` consumes the handle and only `close` returns it
   (`stored.rs:72-77`, `machine.rs:240-244`). Backed by the emulator's locks
   (`cm.h:650`); test `machine.rs:1683`. Breaks: a clone or publication of a
   half-written state.
2. A volatile directory not persisted is removed: `Drop for Volatile`
   (`stored.rs:105-118`); `Machine.home` drops after `Drop::drop` has called
   `cm_delete` (`machine.rs:46`, `:49-57`). Test `machine.rs:1530`. Breaks:
   staging leak (disk), which the node also sweeps at start (`snapshots.rs:167-188`).
3. Persist is sync then no-replace rename (`stored.rs:82-88`; `cm.h:617-625`,
   `:643-652`). Test `machine.rs:1576`, `:1606`. Breaks: a row naming an
   undurable machine.
4. A closed, unsynced directory is loadable and clonable in the same process,
   and its hash sidecars are exact if `root_hash` ran before close
   (`stored.rs:14-19`, `machine.rs:193-199`). Pinned only by test
   `machine.rs:1476`; see Docs versus code 1.
5. Collector results are well formed before the caller indexes them
   (`types/collect.rs:73-91`); bundle sizes are refused before UB in the C
   side (`machine.rs:984-996`); test `machine.rs:2032`.
6. The linked emulator is 0.23.x patch 0: `config/machine.rs:518`. It cannot
   tell a release candidate from the final tag (the Makefile label is not
   encoded; the pinned commit even reports label `-test2`, docs/test-harness.md:111).
   The commit pin in `machine/script/cartesi-machine-source.sh:13` and the
   package digest in `.github/actions/cartesi-machine/action.yml:19` are the
   real guards.

## Concurrency and crash consistency

`Machine` is `!Send + !Sync` because the last error message is thread-local
(`machine.rs:35-40`; `cm.h:423-432`); every error is copied at once
(`machine.rs:1002-1006`), and every JSON result is parsed before the next call
(`machine.rs:681`, `:721`; `cm.h:436-437`). The wrapper starts no threads; the
emulator's hash-tree concurrency is a runtime-config knob the node sets
(`machine_stf.rs:105-118`).

Crash: a shared open mutates files in place; after kill -9 the directory must
be discarded (`cm.h:573-575`). The wrapper leaves that to the caller
(`stored.rs:19`); the node names all such directories `.work-*` and sweeps
them at startup under the state-dir lock (`snapshots.rs:141-149`, `:162-188`).
An interrupted clone or store also must be discarded (`cm.h:598`, `:612`):
covered by the same sweep. Drop paths: `cm_delete` may fail silently
(`cm.h:657-658`); the wrapper calls it only where the directory is discarded
anyway, and `close` (checked) wherever it is kept (`rollups_machine.rs:289-294`,
`advance.rs:366-369`, `open.rs:351-354`). After a failed `cm_destroy`, `close`
returns early and `Drop` still calls `cm_delete` (`machine.rs:241-242`), as the
header requires (`cm.h:659-660`). A failed `Volatile` removal only logs
(`stored.rs:112-115`): in a long-lived process `.work-*` directories then
accumulate until the next restart's sweep. That is a disk-space cost, not a
correctness one; the runner's free-space check (`machine_runner/mod.rs:159-161`)
is the backstop.

## What it knows about its neighbours

- Nothing of the node. It does carry rollup semantics: `send_cmio_response`
  takes the revert root (`machine.rs:771-789`), the uarch collector takes the
  revert tail (`machine.rs:693-724`), and the docs explain step agreement
  (`machine.rs:768-770`). Needed: these are emulator API, not node policy.
- The build script knows the repository layout: `../../emulator` and
  `../../../target/machine-source/...` relative to the crate (`build.rs:12`,
  `:127`), and runs `make` inside the submodule, writing outside `OUT_DIR`
  (`build.rs:345-366`). A leak only for consumers outside this repository.

The node reaching past the wrapper into `cartesi_machine_sys` in production:
- HTIF decode, twice: `engine/machine_stf.rs:25-29`, `:127-140` (live register)
  and `storage/rollups_machine.rs:11-15`, `:119-129` (word in a proof's data
  block). The two spell RX_ACCEPTED differently (`constants::cmio` at
  `machine_stf.rs:33` vs raw `CM_HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED` at
  `rollups_machine.rs:14`). Storage reaches into the engine for it
  (`open.rs:166` calls `machine_stf::awaits_input`).
- `CM_REG_HTIF_TOHOST`, `CM_REG_IFLAGS_Y` for `read_reg`/`reg_address`
  (`machine_stf.rs:131`, `rollups_machine.rs:59-62`): unavoidable while
  `Register` is the sys enum (`types/mod.rs:11`).
- `CM_MARCHID` (`src/args.rs:66`, `src/main.rs:30`).
The wrapper should own the HTIF decode as a pure function of the tohost word
(the yield semantics are emulator ABI, and two consumers plus a replay tool
need it) and re-export MARCHID; see Candidate 1.

## Boundary verdict

Real. It is the one `unsafe` seam, a cross-implementation seam (its
constants are what the node holds against solidity-step, `src/engine/constants.rs:24-43`),
and since the stored-directory types it is where the emulator's
crash-consistency rules are made unrepresentable rather than commented.
Historical residue sits around it, not in it: the nested Cargo workspace
(`machine/rust-bindings/Cargo.toml:1-12`: version 0.23.0, edition 2021) that
the repository build ignores (`Cargo.lock:1720-1721` records version 2.0.0,
the root's, `Cargo.toml:17`) but CI uses to build and test the crate alone
(`.github/workflows/build.yml:301-310`), and the `remote_machine` feature
(below).

## Docs versus code

1. `cm.h:574` says a shared-loaded directory "holds a valid machine again only
   after cm_destroy() succeeds and cm_sync_stored() then succeeds".
   `stored.rs:8-12` and `docs/node-architecture.md:309-317` read it as two
   halves (valid in-process after destroy; durable after sync). The node
   relies on the weaker reading for every rollback checkpoint
   (`advance.rs:48-55`, `machine_stf.rs:314`) and for the staged load in
   `snapshots.rs:109`. Only `machine.rs:1476` pins it. Not a bug (the page
   cache is coherent in-process), but an upstream doc ask is warranted.
2. `cm_clone_stored` (`cm.h:603-615`) documents hard links for read-only
   files, reflinks on CoW filesystems and preserved sparsity, and nothing about
   filesystems without reflink. The wrapper's doc (`machine.rs:246-256`)
   states the fallbacks; they match the emulator source at the pinned commit
   (`src/os-filesystem.cpp:611-624`: copy on ENOTSUP/EXDEV, and on EPERM/EMLINK
   for read-only files; a writable-file EPERM is rethrown). On ext4 every
   per-input clone is therefore a sparse full copy.
3. `lib.rs:22-25` says the version pin is asserted "at build time"; it is a
   unit test (`config/machine.rs:518`).
4. `machine.rs:43-46` justifies `home` drop-after-destroy by declaration
   order; fields always drop after `Drop::drop`, so order is irrelevant. Harmless.
5. `docs/glossary.md:79-80` (mcycle collector bound but unused) matches code.
6. Version and digest pins an emulator bump touches: submodule gitlinks
   `machine/emulator`, `machine/step`; `machine/script/cartesi-machine-source.sh:12-14`
   (tag, commit, patch SHA-256; Boost `:17-19`); `.github/actions/cartesi-machine/action.yml:7`,
   `:11`, `:19`; `script/computation-hash-corpus.sh:8`; `lib.rs:26`;
   `machine/rust-bindings/Cargo.toml:11`; `cartesi-rollups/node/tests/engine_machine.rs:339`;
   `docs/test-harness.md:111`; plus the non-version pins listed in
   `docs/build-system.md:250-272` and the external nix flake. The doc's list
   omits `machine/rust-bindings/Cargo.toml:11` (cosmetic in-repo, see Boundary).

## Defended mechanisms

- `Volatile`/`Durable`/`Stored` (153 lines). Looks like ceremony around
  paths; it encodes four header rules (`cm.h:573-575`, `:612`, `:647-650`,
  `:622`) as moves, so the runner and positioner cannot clone, sync or reload a
  mapped directory or forget to discard one. Evidence: every node publication
  and checkout goes through it (`snapshots.rs:108-160`, `advance.rs:276-436`).
  Reopen if the emulator gains an in-process checkpoint primitive (Q8: it has
  none).
- `bundle_log2` and `cmio_length` guards: the C side computes before
  validating (`machine.rs:984-987`); cheap and tested (`machine.rs:2032`).
- Panic-on-malformed-JSON: a schema mismatch is a build/pin bug, caught by
  round-trip tests; a `Result` would only re-panic upstream (`machine.rs:86-92`).
- Network-free `build.rs` with a SHA-256 checked preparation stamp
  (`build.rs:155-213`): the only build script in the workspace stays offline
  and refuses generated sources from another commit. It does run `git` and
  `make` locally (`build.rs:183-188`, `:369-380`).

## Candidate changes

1. Move the HTIF yield decode into the wrapper (a pure `fn` on the tohost word
   plus a `Machine` accessor) and re-export MARCHID. Premises: decode is
   emulator ABI; it exists twice in the node and once more in tests
   (`storage/queries.rs:266-284`, `src/engine/constants.rs:51-55`). Evidence:
   `machine_stf.rs:120-146`, `rollups_machine.rs:113-130`, `open.rs:166`.
   Buys: one decode, storage stops importing the engine for it, no sys
   constants in node production, a replay tool gets it for free. Cost: the
   step-agreement rationale (`machine_stf.rs:120-126`, `:288-298`) must move
   with it or the terminal rule (node policy) and the decode (ABI) get split
   carefully; only the decode moves, `terminal_fixed` stays. Could break the
   settlement predicate if the data-block path diverges from the register
   path; both have tests. Reopen: none. Confidence: medium.
2. Drop the `remote_machine` feature and the jsonrpc archive build. Premises:
   nothing enables it (only `cartesi-machine/Cargo.toml:16`,
   `cartesi-machine-sys/Cargo.toml:15`, `build.rs:64-68`, `:291-296`); bindgen
   reads only `cm.h` (`build.rs:108`), which does not include `cm-jsonrpc.h`,
   so `cm_jsonrpc_*` is never bound and the feature is unusable; source mode
   still builds `libcartesi_jsonrpc.a` every time (`build.rs:358-366`). Buys:
   build time, about 20 lines, one dead concept. Cost: an external consumer
   may enable it (unverifiable). Reopen: a need for `cm_jsonrpc_fork_server`.
   Confidence: medium.
3. Remove the nested workspace or make its version the one that ships.
   Premises: two identities for one crate (Boundary verdict). Buys: one
   version field to bump. Cost: the CI standalone step
   (`build.yml:301-310`) and any git-rev consumer that builds from that
   directory. Confidence: low (consumer unknown).
4. Prune the unused surface (virtual memory, `replace_memory_range`,
   `memory_ranges`, `read_word`, runtime-config setters, `log_step`/`verify_step`,
   the mcycle collector, `remove_stored`). Not worth it: a general binding,
   each function is a thin tested shim, and an external consumer exists by
   report; the mcycle collector is recorded as bound but unused
   (`docs/glossary.md:79-80`).
5. Gate `Volatile::adopt` to tests. Not worth it: node tests are another
   crate, so it needs a feature; the only production risk is a caller that
   deliberately adopts a directory it does not own.
6. Guard the version label too. Not worth it: the pinned commit reports
   `-test2` for the `-test3` tag (`docs/test-harness.md:111`), so the label
   would add a false pin; the commit and package digests already decide.

## Q7: what a code-independent replay tool needs from the wrapper

Without `engine/`: `Stored::load`/`Machine::load` (image), `root_hash`
(revert root and final hash), `send_cmio_response(Advance, payload,
Some(&root))`, `run`, `read_reg`/`iflags_y`/`iflags_h`/`mcycle`/`imcyclemax`,
and a pre-input checkpoint by `store` or `clone_to` plus a private `load` to
restore. All exist. The tool must re-derive what lives only in the node:
the HTIF decode (`machine_stf.rs:127-140`); terminal classification (manual
yield other than accepted/rejected, else halt or `mcycle >= imcyclemax`,
`machine_stf.rs:288-298`); the run loop through automatic yields
(`machine_stf.rs:463-474`); that a rejection must be restored physically,
since the reset substitutes only the root (`machine_stf.rs:300-324`); and
image distrust (`clear_hash_tree`, pristine uarch, Keccak, `open.rs:113-198`).
The per-input budget itself is the emulator's (written at delivery,
emulator `src/send-cmio-response.cpp:70-71`; enforced by `cm_run`, break
`MCYCLE_OVERFLOW`). Q8: `cm.h` has no in-process snapshot, rollback or commit
primitive; `fork` appears only for remote objects (`cm.h:493-495`) and
`cm_jsonrpc_fork_server` (`cm-jsonrpc.h:76-95`), which the wrapper does not
bind. The revert-root accessors (`cm.h:723-733`) restore nothing.

## Not verified

- How Cargo resolves the nested workspace for a git dependency, and the
  recon report that another repository pins this crate by git revision
  (not readable here). A git-rev consumer without `LIBCARTESI_PATH` would hit
  the missing `target/machine-source` stamp (`build.rs:155-163`): inference.
- Whether `cm_receive_cmio_request` can return an unknown `cmd` (lead above).
- How the Hero handles a `MachineError` on the dispute path; the runner
  retries per tick (`machine_runner/mod.rs:118-134`). The node never branches
  on `MachineError::code` (no matches in `src/`, `tests/`, `examples/`).
  Wrapper panics (JSON, `uarch_pristine_hash` at `machine.rs:152`) exit 101
  and restart (`src/fatal.rs:10-15`).
- Wrapper tests: 44 (`machine.rs` 29, `types/collect.rs` 4, `config/machine.rs` 4,
  `config/runtime.rs` 4, `types/base64_decode.rs` 2, `types/cmio.rs` 1), run by
  root `cargo test` (`justfile:196-199`). They pin the version, the config
  JSON schema, log/verify round trips, uarch reset to the pristine hash,
  `node_hash` against proofs, the stored-directory rules above, and the
  collectors' revert-root and revert-tail semantics (`machine.rs:1838-2074`).
  Several assert upstream error text (`machine.rs:1635`, `:1655`, `:1709`,
  `:2003`, `:2026`), which a message change breaks. They need repository
  images (`machine.rs:1075`, `:1755`). I did not run them.
- `config/`, `access_proof.rs`, `base64_decode.rs` read only by test names.
