# Card: process shell

Scope (production lines, `#[cfg(test)]` modules excluded), all under
`cartesi-rollups/node/`: `src/main.rs` 46; `src/lib.rs` 215 (1-215);
`src/args.rs` 541 (1-541); `src/fatal.rs` 77; `src/sync.rs` 102;
`src/escalation.rs` 54; `src/kms.rs` 59; `src/arithmetic.rs` 8;
`src/test_machine.rs` 0 (whole module is `#[cfg(test)]`, `src/lib.rs:33-34`,
54 lines); `Cargo.toml` 62; workspace `Cargo.toml` 82; `README.md` 478.
Startup also runs code in `src/provider.rs`, `src/blockchain_reader/mod.rs`
and `src/storage/open.rs`; those lines are cited where the shell calls them.

## Possible correctness bug

None met. Closest items (not bugs, all medium/low):
- An Arbitrum deployment, a deterministic refusal, exits 1, not 30:
  `src/blockchain_reader/mod.rs:274-281` is a plain `with_context`, so the
  README's systemd unit (`README.md:358`, `RestartPreventExitStatus=2 30 40`)
  restarts it forever. `README.md:288-290` says only "stops at startup".
- `--polling-interval` has no range (`src/args.rs:255-256`), unlike
  `--snapshot-gap-inputs` (`src/args.rs:265`). 0 makes every worker spin
  (`src/machine_runner/mod.rs:139`, `src/epoch_manager/mod.rs:124-127`). A value
  of 300 or more makes each due response wait at least G, past which a late
  response draws on C (`src/escalation.rs:12-22`).

## Owns

- The process lifecycle: logger and panic hook (`src/main.rs:12-20`), the
  release banner (`src/main.rs:23-31`), the setup-then-run sequence
  (`src/main.rs:33-38`), and the mapping of errors to exit status
  (`src/main.rs:39-45`, `src/fatal.rs:69-76`).
- The flag and environment surface (`src/args.rs:215-317`) and the validated
  `NodeConfig` (`src/args.rs:319-345`), which holds the only signing capability
  (`wallet`, `src/args.rs:341`) and the data-directory lock for the life of
  the process (`_state_lock: Arc<StateDirLock>`, `src/args.rs:344`).
- The startup validation order (list below), up to `Storage::initialize`.
- Worker wiring and the join/drain protocol (`src/lib.rs:59-214`).
- The shutdown primitive and stop signals (`src/sync.rs:24-101`).
- The paging rule G (`src/escalation.rs:22`) and its single-condition timer
  `Persistence` (`src/escalation.rs:26-53`).
- The exit-code vocabulary `Fatal`/`FatalKind`/`Panicked` (`src/fatal.rs:19-66`).
- The KMS client construction and its timeout (`src/kms.rs:13-58`).
- Shared integer helpers `max_uint`, `add_and_clamp` (`src/arithmetic.rs:1-8`).

### Startup sequence (Q1)

`main` -> `NodeConfig::setup` (`src/args.rs:406-408`, `PRTArgs::parse`) ->
`setup_with` (`src/args.rs:417-539`):

1. Flag parsing, clap (`src/args.rs:407`). Refuses missing or invalid flags,
   including a malformed URL, which it does not quote (`src/args.rs:191-212`),
   and a gap of 0 (`src/args.rs:265`): exit 2.
2. Chain id known by name (`src/args.rs:418`, `56-63`): exit 30 otherwise.
3. Key preparation, local only, before any network (`src/args.rs:419`,
   `src/provider.rs:54-90`). pk: both or neither key source exits 30
   (`src/provider.rs:150-157`); a key that does not parse exits 30
   (`src/provider.rs:130`); an unreadable key file exits 1
   (`src/provider.rs:142`). KMS: an unreadable id file exits 1
   (`src/provider.rs:69-75`).
4. Chain-id probe of the read endpoint (`src/args.rs:425-427`,
   `src/provider.rs:323-350`): no answer exits 1, another chain exits 30.
5. The same probe of a distinct submit endpoint (`src/args.rs:428-436`).
   Without one it warns, except on anvil (`src/args.rs:438-444`).
6. Wallet (`src/args.rs:449`). KMS asks AWS for the public key here
   (`src/provider.rs:103-115`). Unresolved region or a KMS failure exits 1
   (`src/kms.rs:53-56`).
7. Finalized head sampled (`src/args.rs:452-456`). It bounds the watermark
   (`src/blockchain_reader/mod.rs:156-158`). Failure exits 1.
8. Deployment discovery: `AddressBook::new` (`src/args.rs:457-464`,
   `src/blockchain_reader/mod.rs:72-145`) reads consensus, the two-way
   app/consensus binding (`:89-92`), input box, factory, deployment blocks,
   and the initial hash from epoch 0's `EpochSealed` (`:257-284`). Every
   failure exits 1, including a non-Dave address and Arbitrum.
9. Sentry role, logged only (`src/args.rs:465`, `165-182`).
10. Geometry and emulator compatibility: `discover_deployed_tournament`
    (`src/args.rs:93-160`). A level count outside 1..=ruler exits 30
    (`:107-112`); a table that fails the validator exits 30 (`:126-130`);
    MARCHID (`:65-74`) and pristine uarch hash (`:79-87`, `:150-158`) exit 30.
    RPC failures exit 1.
11. Data-directory probe `Storage::is_seeded` (`src/args.rs:469-470`,
    `src/storage/open.rs:249-280`). It creates nothing for a missing db
    (`:251-256`), and the open does not hold the lock.
12. Unseeded only: image inspection `Template::inspect` (`src/args.rs:478`,
    `src/storage/open.rs:112-170`). Not a directory, a non-Keccak tree, a
    missing owner write bit, or a foreign uarch exits 30 (`:116, :130, :143,
    :157`); a load failure exits 1 (`:120-121`).
13. Seed-epoch decision (`src/args.rs:479-481`,
    `src/blockchain_reader/mod.rs:167-253`): the initial hash gives 0; the
    last settled state at a fresh finalized head gives k; anything else exits
    30 (`:235`, `:245`). Then the awaits-input refusal, exit 30
    (`src/args.rs:484-492`).
14. Lock (`src/args.rs:499`, `src/storage/open.rs:54-78`). This is the first
    write: it creates the directory and `node.lock`. Another holder, or no
    lock support, exits 1.
15. `Storage::initialize` (`src/args.rs:500-511`, `src/storage/open.rs:291-334`):
    directories, schema stamp check (exit 40, `src/storage/sql/schema.rs:61-78`),
    staging sweep (`open.rs:309`), then the pin check (exit 30 for app, chain
    or initial hash; exit 40 for the rest, `open.rs:480-519`) or the seed.
16. Filesystem warning (`src/args.rs:512-522`). The setup's own `Storage` is
    dropped when `setup_with` returns.
17. `run` (`src/lib.rs:59`): it installs the stop signals first (`:63`), then
    spawns the three workers (`:72-121`).

Order constraints the docs state:
- Endpoints' chains before any other read (`docs/node-architecture.md:80-83`).
  Honoured: steps 4-5 precede step 7.
- Validate before writing (`docs/node-architecture.md:63-74`,
  `src/args.rs:410-416`). Honoured up to step 14. Within step 15, the schema
  stamp and the staging sweep come before the pin comparison
  (`src/storage/open.rs:300, 309, 313`). See Docs versus code.

## Takes

- argv and env through clap (`src/args.rs:215-317`). The private key comes
  from env only, read by the signer (`src/args.rs:278`, `src/provider.rs:60`).
- `RUST_LOG` (`src/main.rs:12`).
- `CARTESI_SLING_RELEASE`, read at compile time (`src/main.rs:23`, set by
  `.github/workflows/build.yml:317`).
- Chain reads at latest (address book, factory table, state transition) and
  at finalized (head, seed epoch). All are trusted as RPC answers (P2).
- The linked emulator's `CM_MARCHID` and pristine uarch hash
  (`src/args.rs:66`, `150`).
- SIGINT and SIGTERM (`src/sync.rs:30-43`).
- Worker results through `JoinHandle<Result<()>>` (`src/lib.rs:72, 88, 100`).

## Gives

- `NodeConfig` to the workers by clone (`src/lib.rs:73, 89, 101`). Each worker
  opens its own writer connection (`src/args.rs:385-387`,
  `src/storage/open.rs:381-389`). The read provider is signerless; the
  manager alone gets the transaction lane (`src/args.rs:390-404`).
- A `ShutdownSignal` clone to every worker (`src/lib.rs:74, 90, 102`).
- The exit status (`src/main.rs:39-45`).
- `Persistence` and `PAGE_AFTER` to the reader (`src/blockchain_reader/mod.rs:322, 371`),
  the runner (`src/machine_runner/mod.rs:67, 112, 127`) and the manager
  (`src/epoch_manager/mod.rs:44, 96, 341`; per-call `track_planned` compares
  with `PAGE_AFTER` at `:672`).

### Workers (Q2)

| worker | spawn | storage | stops | 
|---|---|---|---|
| machine runner | `spawn_blocking` (`src/lib.rs:75`) | `src/lib.rs:76` | `wait_timeout` and `is_requested` (`src/machine_runner/mod.rs:139-140, 152-153`) |
| blockchain reader | `tokio::spawn` (`src/lib.rs:91`) | `src/lib.rs:92` | biased select on `requested()` (`src/blockchain_reader/mod.rs:333-334`) |
| epoch manager | `tokio::spawn` (`src/lib.rs:103`) | `src/lib.rs:105` | loop guard and biased select (`src/epoch_manager/mod.rs:106, 124-127`) |

`run` races the signals (biased first) against all three handles
(`src/lib.rs:126-135`) and requests shutdown (`:143`). It then awaits every
unfinished handle (`:157-166`). A second signal calls `process::exit` with
the first failure's code, or 1 (`:149-154`). Verified: `ShutdownSignal`
carries no payload (`src/sync.rs:46-101`), and errors return only through the
handles (`src/lib.rs:176-214`). A clean return before shutdown is still a
failure (`:178`).

### Exit codes (Q3)

0 is a clean drain (`src/main.rs:40`). 1 is the default (`src/fatal.rs:74`).
2 is clap. 101 is `Panicked` (`src/fatal.rs:73`, made at `src/lib.rs:180, 211`),
or Rust's own status for a panic on the main task during setup. The 30 and 40
sites:
- 30, flags and keys: `src/args.rs:58`; `src/provider.rs:130, 150, 154, 344`.
- 30, deployment against the linked emulator: `src/args.rs:69, 82, 109, 127`.
- 30, seed image: `src/storage/open.rs:116, 130, 143, 157`; `src/args.rs:486`;
  `src/blockchain_reader/mod.rs:235, 245`.
- 30, directory pins: `src/storage/open.rs:486` (app), `495` (chain), `503`
  (initial hash, another deployment).
- 30, runtime: a settled divergent root (`src/hero/actor.rs:290-300`) and
  finalized foreclosure with work done (`src/epoch_manager/mod.rs:325-328`).
  The manager passes them out (`:118`, `:259`); the reader and runner retry
  every tick error and raise none.
- 40: `src/storage/sql/schema.rs:61, 68, 75` (store format, semantics);
  `src/storage/open.rs:514` (consensus, emulator, structure or geometry pin).

### Paging rule (Q4)

The whole API: `PAGE_AFTER` (`src/escalation.rs:22`), `Persistence::{failed,
cleared, minutes}` (`:32, 45, 50`). G = 300 s is hardcoded. It matches
`_getInclusionBudget` (`prt/contracts/script/Deployment.s.sol:225-227`). The
users are listed under Gives. A second mechanism with the same threshold is the
reader's `FINALITY_PAGE` of one hour (`src/blockchain_reader/mod.rs:290`).

## Invariants

1. Nothing is written before validation. Enforced by statement order in
   `src/args.rs:417-511`, with the lock as the first write (`:499`), and by
   tests (`src/args.rs:821-922`, `src/harness/settled_start.rs:108-165`). If it
   fails, a wrong flag corrupts or creates a directory.
2. One process per data directory. The kernel lock
   (`src/storage/open.rs:49-78`) is held through `Arc` clones in every worker
   (`src/args.rs:343-344`). If it fails, two nodes sweep each other's clones.
3. Every handle is awaited (`src/lib.rs:157-166`). Otherwise a task is
   detached mid-write.
4. The first failure's exit status wins (`src/lib.rs:187-198`, test at
   `:231-246`). Otherwise a supervisor restarts a terminal node.
5. `Fatal` survives added context (`src/fatal.rs:55-60`, test `:84-98`).
6. The runtime is multi-threaded (default `#[tokio::main]`, `src/main.rs:10`).
   `hero::machine_work` relies on it to hand off its worker
   (`src/hero/mod.rs:23-28`). On a current-thread runtime a leaf build would
   stall the reader. Nothing asserts this.
7. Secrets never reach logs. URLs are withheld at parse (`src/args.rs:184-212`),
   help hides env values (`:219-222`), Display redacts (`:359-367`), and the
   key comes from env or a file, never a flag (`:275-278`).
8. Panics reach the log as ERROR (`src/main.rs:16-20`).

## Concurrency and crash consistency

- Setup runs before `StopSignals::listen` (`src/lib.rs:63`). A SIGTERM during
  a long image inspection or seed takes the default action. That is as safe
  as SIGKILL: the seed publishes its clone before one transaction
  (`src/storage/open.rs:338-363`), and the next start sweeps staging (`:309`)
  or adopts the orphan.
- `is_seeded` runs unlocked. `initialize` decides again under the lock and
  handles both races (`src/storage/open.rs:311-331`).
- During the drain a second signal exits at once (`src/lib.rs:150-154`).
  Recovery is replay.
- Held only in process memory: the `Persistence` timers and the planned-call
  map. Losing them delays a page by up to G after a restart. A restart loop
  under 5 minutes never pages through them, which is why the README asks for
  alerts on restart loops (`README.md:423`).

## What it knows about its neighbours

- `args.rs` knows the factory ABI, the table row shape, the geometry validator
  and the state-transition compatibility rule (`src/args.rs:31-160`). This is
  deployment and protocol knowledge, a leak into the flag module (Q11). The
  harness reuses it (`src/harness/mod.rs:39, 129`).
- `args.rs` encodes a seed rule: refuse an image that does not await input
  (`src/args.rs:484-492`). `Template::inspect` computes the bit
  (`src/storage/open.rs:162`), but the refusal lives in args. One rule is split
  across two files.
- The seed-epoch decision and deployment discovery live in
  `blockchain_reader` (`src/blockchain_reader/mod.rs:68-285`). They are
  startup-only and not ingestion. `blockchain_reader` is `pub` only because of
  them (`src/lib.rs:4-6`).
- `ANVIL_CHAIN_ID` special-cases production behaviour: the relay warning
  (`src/args.rs:438`) and the head-age page
  (`src/blockchain_reader/mod.rs:325`). Defended by the docs (anvil mines only
  with a transaction, `docs/node-architecture.md:220-221`), but it is
  test-shaped.
- `lib.rs` knows each worker's constructor; it holds no protocol logic.

## Boundary verdict

The process/worker boundary is real. It is the crash and concurrency seam:
three independent connections, one shutdown flag, errors through handles, and
an exit-status contract a supervisor acts on. `fatal.rs`, `sync.rs` and
`escalation.rs` are small, single-purpose and tested. The boundary between
`args.rs` and the rest is historical. `args.rs` is half clap, half startup
protocol: geometry discovery and compatibility checks (lines 31-160), plus the
orchestration of a seed decision whose parts live in three modules. The real
seam is "a startup gate that validates the deployment and image before the
first write". It deserves one home, with clap and `NodeConfig` beside it, not
inside it.

## Docs versus code

- `docs/node-architecture.md:87-91` says the root initial-hash check "panic"s.
  The code exits 30 (`src/hero/actor.rs:289-300`).
  `docs/node-architecture.md:170-172` and `src/hero/context.rs:28-34` agree
  with the code. Only the level-table check panics.
- `docs/node-architecture.md:63-65` says pins are compared "before anything is
  written", and `src/args.rs:414-415` says a refused pin "leaves the existing
  directory untouched". The schema stamp check (which writes only to an empty
  db) and the staging sweep run first (`src/storage/open.rs:296-309`). Both are
  benign: the sweep removes only crash leftovers, under the lock. The wording
  overstates.
- `README.md:13` says "Worker modules - one thread each". Two of them are
  async tasks (`src/lib.rs:91, 103`); `docs/node-architecture.md:15-23` is
  right.
- `README.md:288-290`, on Arbitrum: the code exits 1
  (`src/blockchain_reader/mod.rs:274-281`), so the recommended unit restarts
  it forever.
- `src/kms.rs:11-12` says "`Some(chain_id)` makes its signatures EIP-155". The
  parameter is a plain `ChainId` and is always wrapped (`:15, :20`). The comment
  is stale.
- Checked and honoured: `README.md:76-77, 100-101, 115, 120-125, 141-144,
  155-157, 160-167, 171-178, 328-332, 363-370, 426`, against the sites above
  and `src/machine_runner/mod.rs:80, 159-160`.
- Two paging mechanisms serve one concept: `Persistence` for one condition,
  and `track_planned` keyed per call (`src/epoch_manager/mod.rs:653-679`). Both
  use one G. That is acceptable, since a per-call map is not one condition.

## Defended mechanisms

- The biased select plus awaiting every handle (`src/lib.rs:123-166`). Without
  it a worker could be detached mid-drain. The argument and its test are at
  `src/lib.rs:49-58, 229-246`.
- The dual Notify plus Condvar `ShutdownSignal` (`src/sync.rs:51-101`). One
  half serves the blocking runner, the other the async tasks. The
  enable-before-check race fix is at `:77-87`. It is about 50 lines, tested
  (`:109-166`), and buys a runner sleep a stop can cut short.
- Signals tested in their own binary (`tests/stop_signal.rs:4-7`). The handlers
  are process-wide.
- `EndpointUrl` and the hidden env values (`src/args.rs:184-222`). The
  URL-secret leak is real, and clap would print the value otherwise.
- The KMS operation timeout of 20 s (`src/kms.rs:40-49`,
  `src/provider.rs:163`). Without it an unanswered KMS call parks the manager
  with nothing logged.
- `reqwest` as a direct dependency. The workspace entry turns on `http2`
  (workspace `Cargo.toml:62`), and `src/provider.rs:168-184` configures it.
- `overflow-checks = true` in release (workspace `Cargo.toml:80-82`).
- Exit 101 kept separate from 1 (`src/fatal.rs:10-15`), with its stated reason.
  This is a recorded decision, not reopened.

## Candidate changes

1. Move `serde_json` to `[dev-dependencies]`. Premise: it has no use in
   production `src`; every hit is in a `#[cfg(test)]` module or in
   `examples/measure.rs:1216` (examples may use dev-dependencies). Evidence:
   `Cargo.toml:43`, and the grep in Not verified. Buys a correct manifest.
   Cost: none. Reopen if production code needs JSON. Confidence: high.
2. Drop the duplicate dev `hex = "0.4.3"` (`Cargo.toml:51`; already a
   production dependency at `:42`). Consider replacing the one `hex` use
   (`src/merkle/digest/mod.rs:5, 19`) with `alloy::hex`, which the rest of the
   crate uses. Buys one dependency line. Confidence: high for the duplicate,
   low for the swap.
3. Fold `arithmetic.rs` away. Move `max_uint` into `engine/constants.rs` (its
   production consumer, `src/engine/constants.rs:13-17`), and replace
   `add_and_clamp`, which is `saturating_add` (`src/arithmetic.rs:6-8`), at
   `src/engine/machine_stf.rs:462, 490, 503` and `tests/common/instance.rs:253`.
   Buys one public module (8 lines, no license header) and an alias that
   hides std semantics. Cost: test import churn. Confidence: high.
4. Pull the startup gate out of `args.rs` and `blockchain_reader`. Move
   `AddressBook::new`, `initial_hash`, `seed_epoch`, `initial_watermark`
   (`src/blockchain_reader/mod.rs:68-285`), `discover_deployed_tournament` and
   the checks (`src/args.rs:31-160`), and the awaits-input refusal (`:484-492`)
   into one startup or deployment module. `args.rs` keeps clap, `NodeConfig`
   and the call order. Buys one home for "validate before the first write",
   and `blockchain_reader` loses its pub-for-a-field reason (`src/lib.rs:4-6`).
   Cost: a pure move of about 350 lines. Risk: none if order is kept
   (invariant 1). Reopen if the reader starts using these at runtime.
   Confidence: medium.
5. Bound `--polling-interval` with a clap range, for example 1..=60
   (`src/args.rs:255`). Buys removal of a footgun: 0 spins, and at least 300
   misses G. Cost: one line and a test. It fits P1: the flag would no longer
   bound responses below the deployed budget (`docs/node-architecture.md:147-150`).
   Confidence: medium on the upper bound value.
6. Make the Arbitrum refusal terminal. Turn the missing epoch-0
   `EpochSealed` into exit 30 only when the chain is a known Arbitrum id.
   Otherwise, document exit 1 in `README.md:288-290`. Premise: a missing log
   can also be an incomplete provider (P2), so a blanket 30 would be wrong.
   Confidence: low. The doc fix alone is high.
7. Narrow the `pub` surface. `NodeConfig::setup_with` (`src/args.rs:417`) is
   used only in the crate (`src/args.rs:578+`, `src/harness/settled_start.rs`).
   `PRTArgs` and `SignerArgs` need not be pub. `chain` and `provider` are pub
   only for `tests/live_rpc.rs:24-26`. Buys dead-code reporting
   (`src/lib.rs:4-6` states that intent). Cost: `live_rpc` must keep access, so
   `chain` and `provider` likely stay pub. Confidence: medium for args, not
   worth it for chain and provider.
8. Put the AWS SDK behind a cargo feature. `aws-config` and `aws-sdk-kms`
   (`Cargo.toml:21-28`) serve 59 lines (`src/kms.rs`). Not worth it: KMS is a
   production signer, and a feature would add a build matrix that rots.
9. Make `--template-path` optional for a seeded directory. It is required
   (`src/args.rs:231-232`) but is only printed when seeded (`:352`). Not worth
   it: a branch in exchange for ergonomics. At most, print "not read" in
   Display.
10. Drop `--aws-endpoint-url` and `--aws-region`, since the SDK reads
    `AWS_ENDPOINT_URL_KMS` and `AWS_REGION` itself (`src/args.rs:304-315`).
    Not worth it: these are documented operator overrides
    (`README.md:124-125`) and cost 10 lines.
11. Fix the stale `src/kms.rs:11-12` comment and `README.md:13`. Confidence:
    high.

### Flag surface (Q5)

| flag | env | default | consumer |
|---|---|---|---|
| --app-address | CARTESI_SLING_APP_ADDRESS | required | `src/args.rs:457` |
| --template-path | CARTESI_SLING_TEMPLATE_PATH | required | `src/args.rs:478` (unseeded only); Display `:352` |
| --blockchain-http-endpoint | CARTESI_SLING_BLOCKCHAIN_HTTP_ENDPOINT | required | `src/args.rs:425, 391` |
| --blockchain-http-submit-endpoint | CARTESI_SLING_BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT | read endpoint | `src/args.rs:428-448, 395` |
| --blockchain-id | CARTESI_SLING_BLOCKCHAIN_ID | required | `src/args.rs:418` |
| --polling-interval | CARTESI_SLING_POLLING_INTERVAL | 30 | all three workers (`src/lib.rs:80, 95, 115`); operations tuning, unbounded |
| --snapshot-gap-inputs | CARTESI_SLING_SNAPSHOT_GAP_INPUTS | 64 (`src/machine_runner/mod.rs:17`) | runner (`src/lib.rs:79`); operations tuning (disk vs replay) |
| --data-dir | CARTESI_SLING_DATA_DIR | required | lock, probe, initialize |
| pk --auth-private-key-file | CARTESI_SLING_AUTH_PRIVATE_KEY_FILE | none | `src/provider.rs:58-61` |
| (env only) | CARTESI_SLING_AUTH_PRIVATE_KEY | none | `src/provider.rs:60` |
| aws-kms --auth-aws-kms-key-id(-file) | CARTESI_SLING_AUTH_AWS_KMS_KEY_ID(_FILE) | one required (`src/args.rs:292`) | `src/provider.rs:68-82` |
| aws-kms --aws-endpoint-url, --aws-region | none (SDK env) | SDK | `src/kms.rs:34-39` |

None is a reader feature, and every flag has a production consumer. The
test-shaped items are `ANVIL_CHAIN_ID` (`src/args.rs:28`) and the
`#[cfg(test)]` test credentials in production `client()` (`src/kms.rs:30-33`).
Other env: `RUST_LOG`, `HTTP(S)_PROXY` (reqwest), `AWS_*`, `OMP_*` (emulator,
`README.md:415-422`).

### lib.rs visibility (Q7)

Pub: `args` and `fatal` (for `src/main.rs:4`); `blockchain_reader` (only for
the `NodeConfig.address_book` field, `src/lib.rs:4-6`); `chain` and `provider`
(only `tests/live_rpc.rs:24-26`); `machine_runner`, `storage`, `sync`,
`engine`, `merkle` (integration tests and `examples/measure.rs:19-25, 378-379`);
`arithmetic` (`tests/common/*.rs`); `run`. Private: `epoch_manager`,
`escalation`, `kms`, `hero`, `tournament`. `harness` and `test_machine` are
`#[cfg(test)]` (`src/lib.rs:31-34`), so neither is in the binary. The same
holds for `blockchain_reader::test_utils` (`src/blockchain_reader/mod.rs:650-651`)
and `engine::{spec,toy}` (`src/engine/mod.rs:43-46`).

### Dependencies (Q8)

Production (`Cargo.toml:13-47`): cartesi-machine; the dave and prt binding
crates; `cartesi-rollups-contracts` (crates.io `=3.0.0-alpha.10`, only
`IApplication` and `IInputBox`, `src/blockchain_reader/mod.rs:21-24`,
`src/epoch_manager/mod.rs:199`); aws-config and aws-sdk-kms (`kms.rs` only);
alloy, alloy-transport (`chain.rs`, `provider.rs`), alloy-chains (`NamedChain`);
reqwest (http2 toggle); anyhow; clap; futures (two files,
`src/tournament/observer.rs:22`, `src/epoch_manager/recovery.rs:31`);
thiserror; tokio; log; rusqlite; hex (one use); serde_json (no production
use); tower (one layer, `src/provider.rs:243-285`); env_logger (`main.rs`
only); libc (statvfs and statfs, `src/storage/open.rs:396-419`). Dev: alloy
with node-bindings and rpc-types, a duplicate hex, tempfile,
testcontainers-modules (KMS tests). No `[features]`. The example `measure`
needs `serde_json` (`examples/measure.rs:1216`) and libc `getrusage`
(`:667-670`), and builds under `cargo test` (`Cargo.toml:58-62`). Workspace
version 2.0.0 names no release (`src/main.rs:21-22`).

### arithmetic.rs and test_machine.rs (Q9)

`arithmetic.rs` is two helpers and does not earn a module (candidate 3).
`test_machine.rs` holds the tiny HTIF guests used by unit tests in three
modules (`src/harness/tests.rs:207, 273`, `src/machine_runner/mod.rs:327`,
`src/engine/machine_stf.rs:937`). It is test-only and earns its place as a
shared fixture.

## Not verified

- `src/harness/` beyond the call sites, and the `args.rs` tests (543-925),
  were not read line by line.
- That opening a WAL database read-write in `is_seeded`
  (`src/storage/open.rs:259-262`) leaves no `-shm`/`-wal` files on a seeded
  directory was not checked against SQLite behaviour.
- The production-use grep for `serde_json` relied on the first
  `#[cfg(test)]` line per file and was spot-checked for `chain.rs`,
  `provider.rs`, `hero/actor.rs`, `epoch_manager/mod.rs`, `machine_stf.rs` and
  `tournament/reader.rs`.
- Nothing was built or run.
