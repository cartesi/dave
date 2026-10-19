# Dave Rollups Node

The PRT validator node (the sling node), one crate: it follows an
application's inputs, recomputes its state, settles epochs, and defends the
correct result in disputes. It is a focused validator and stays one: it
keeps no outputs and serves no output or voucher proofs, and any reader
feature belongs in a separate executable.
Architecture and known debts: [docs/node-architecture.md](../../docs/node-architecture.md).
How epochs and disputes flow: [docs/epoch-lifecycle.md](../../docs/epoch-lifecycle.md).

## Layout (`src/`)

Worker modules - one thread each, synchronizing through the node
database: `blockchain_reader` (chain logs to db), `machine_runner`
(inputs to machine execution to leaf hashes and snapshots),
`epoch_manager` (settlement and disputes). `storage` is the single
view of that database and the only module that speaks SQL.

The dispute engine (formerly the `cartesi-prt-core` crate):

- `engine/` - commitment construction and geometry: driving the Cartesi
  Machine through meta-cycles (`machine_stf`, `stf`), the
  `Structure`/`Position` coordinate system (`structure`), the quartet
  cache and the ruler (`cache`, `ruler` - `Ruler::prove_transition`
  generates on-chain step proofs), and the dispute source serving every
  tree query a dispute needs (`dispute`). Read
  `docs/computation-hash.md` first; this is the arcane part.
- `hero/` - the honest player: per tick it observes, plans, and
  dispatches either one dispute action - join, bisect, seal, prove, or
  win by timeout - or one timeout/child cleanup (`gc_planner`).
- `tournament/` - the semantic chain interface: `dispute` owns the recursive,
  event-derived tournament tree; `domain` defines wire-independent values;
  `observer` performs the narrow pinned point reads; `reader` maintains the
  finalized Solid prefix and builds a disposable Latest Foam; and `sender`
  prepares contract mutation requests.
- `merkle/` - the tree builders shared by commitment construction.

The Rust node is the only honest dispute client. The Lua client
(`prt/client-lua/`) is its testing companion: its commitment construction
is an independent oracle that the e2e tests cross-check every epoch and
that must agree with the node's, and its player is the e2e sybil actor,
which needs to agree with the node only well enough to steer disputes.

## Build (release)

Run at the repository root:
```
just build-release-rust-workspace
```

The executable will appear at:
```
./target/release/cartesi-sling-node
```

## Run

Running the node requires an Ethereum JSON-RPC gateway and a funded wallet.
Reads use `--blockchain-http-endpoint`, on the chain `--blockchain-id` names;
neither has a default. Raw signed transactions use
`--blockchain-http-submit-endpoint`, which defaults to the read endpoint and
may instead name a private relay with revert protection: honest nodes that
share a commitment race on every step, and without it each pays for its
reverted copies of the steps another node landed first, as it does for an
adversary's copies (up to about 3.76M gas for a leaf proof). A relay must:

1. not land reverting transactions;
2. reach builders that cover most blocks;
3. free a nonce it holds within 5 minutes, the response window: admit a
   different transaction at that nonce, which the node's next tick sends, or
   drop a held transaction that can no longer succeed. Each hold delays the
   node's next action by the hold plus a polling interval and an inclusion,
   so a hold near 5 minutes already draws on the dispute's censorship budget
   (about 40 s at the default polling interval), and a relay with no bound on
   the hold does not qualify;
4. answer `eth_chainId` with the node's chain: the node asks at every start
   and does not start (exit 1) while the relay does not answer.

No relay has passed the qualification in
[docs/runbooks/submit-relay.md](../../docs/runbooks/submit-relay.md) yet, so
the node does not require one, though a production deployment should use
one. What the candidates document, read 2026-10-15 and unmeasured until the
runbook records results:

- Flashbots Protect (settings guide, updated 2026-05-12): no reverts land by
  default (`?canRevert=true` lands them); a transaction is retried for 25
  blocks and then dropped, and `?blockRange=N` changes that; the default
  endpoint forwards only to the Flashbots builder, while `/fast` shares with
  every registered builder. Sepolia has its own endpoint (quick start,
  updated 2025-12-16), which the team found does not include transactions
  (a lead). No page says whether a different transaction is
  admitted at a nonce Protect holds (the cancellations, nonce management and
  stuck transactions pages, updated 2025-12-16).
- MEV Blocker (endpoints and send-transactions pages, updated 2025-12-18):
  `/noreverts` stops broadcasting a transaction once it is no longer valid,
  which documents requirement 1, while the default `/fast` carries no revert
  guarantee; retention and same-nonce admission are undocumented, and no
  testnet endpoint is documented.

At startup the node asks each endpoint its chain and refuses one on another
chain (exit 30) or one that does not answer (exit 1, retried by the
supervisor). An endpoint must omit `error` from a successful JSON-RPC
response: alloy, like go-ethereum since v1.17.5, rejects `"error": null`, and
the failure quotes the response. Without a separate submit endpoint, on any
chain but anvil's, it warns once at startup that transactions go to the read
endpoint's public pool. The signer must be exclusive to one node process
because the node owns its nonce sequence. Each tick batches the applicable
dispute or cleanup action, settlement step, and all available bond
recoveries at consecutive nonces from the latest mined count. The next tick
rebuilds the batch from chain state without waiting for receipts.
An endpoint URL that embeds an API key or a token belongs in
`CARTESI_SLING_BLOCKCHAIN_HTTP_ENDPOINT` or
`CARTESI_SLING_BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT`, not on the command line,
which any local user can read; a malformed one is refused without being
quoted (exit 2).

The signer is a private key (`pk`) or an AWS KMS key (`aws-kms`). The `pk`
signer reads its key from the `CARTESI_SLING_AUTH_PRIVATE_KEY` environment
variable or from the first line of `--auth-private-key-file`, and refuses
neither or both (exit 30); no flag takes the key itself, since any local user
can read a process's arguments. The `aws-kms` signer resolves its region and
endpoint as any AWS client does (`AWS_REGION`, `AWS_ENDPOINT_URL_KMS`, the
profile, instance metadata, FIPS endpoints, other partitions);
`--aws-region` and `--aws-endpoint-url` override them, and a start where no
region resolves fails (exit 1) naming `--aws-region`.

The node completes epochs in order: it waits for finalized settlement and its
winning bond recoveries before participating in the next epoch. It resumes the
same unfinished epoch after restart. Other participants may advance meanwhile;
the operating timing assumption allows a modest delay while refunds finish.
Changing the signer keeps the data directory: the node recovers the bonds of
its current signer, and a previous signer's bonds stay recoverable by anyone
through `tryRecoveringBond`, which pays the recorded claimer. A changed store
format or commitment semantics requires a fresh directory under the node's
rebuild policy. The first
start checks the `--template-path` image and pins the directory to its
application, chain and the application's on-chain initial hash. The image is
either the application's template, whose root hash is that initial hash, or
the state the application's current sealed epoch starts from, which the node
reads from the consensus at a finalized block; the directory then starts at
that epoch (operator notes). Any other image is refused before anything is
written, and so is a matching image that is not paused at a manual accepted
yield, from which no epoch can start. Later starts compare the pins and never
read `--template-path`. Startup also
refuses a deployment whose state transition disagrees with the linked Cartesi
Machine library (its `CM_MARCHID` or pristine uarch hash), and a first start
refuses an image whose uarch state is not that pristine uarch (custom uarch
code, or an image built by another emulator) or whose hash tree is not
Keccak-256. It also refuses an image with a file the node maps for writing
(all but `config.json` and the data of the PMAs and read-only drives) that
lacks the owner write bit: the copy the node seeds keeps each file's mode,
so every advance batch would fail. Make such an image writable
(`chmod -R u+w`).

One node process owns a data directory: startup locks its `node.lock` and
refuses a directory another process holds, or one on a filesystem without
file locks. The lock does not cover the signer: nodes on different
directories must still not share a key.

Stop the node with SIGTERM or SIGINT. Ingestion stops at once and machine
execution before its next input or epoch roll, dropping an unfinished batch
that a restart replays. A dispute tick in flight finishes, so a prepared
action still goes out, while the dispute's machine work stops early and
resumes after the restart. Give the stop timeout room for one input's
execution and one tick's RPC calls; under three levels a dispute's leaf and
middle commitment builds also run to completion. A second stop signal exits at
once, as safely as SIGKILL. A restart refetches the live tournaments' logs.
Upgrade or rebuild the data directory between disputes: a fresh directory
rebuilds every engaged level's commitment on the dispute clock.

Put `--data-dir` on XFS with reflinks (`reflink=1`, the mkfs.xfs default
since xfsprogs 5.1; check with `xfs_info <mountpoint> | grep reflink=1`), on
a volume or bind mount, not a container's writable layer or a network
filesystem. That is the one production filesystem: every input clones the
stored machine, XFS shares the unchanged extents, and its per-file
link limit is far above any epoch's snapshot count. The startup line names
the data directory's filesystem, and on Linux the node warns when it is not
XFS. Elsewhere:

- ext4 has no reflinks, so every clone is a sparse copy: each input pays a
  copy of the machine, and each kept snapshot costs the machine's allocated
  size. Like btrfs it caps a file at about 65k links, so about 65k live
  snapshots. Development and small applications only (many cloud volumes
  default to it).
- btrfs is for development only: it caps a file at 65,535 links, every kept
  snapshot links the machine's read-only files, and at that count clones
  fail and the node stops computing.
- ZFS is untested; APFS (macOS) is for development; tmpfs does not survive a
  reboot.

Performance is the operator's to size. The node aims to add no work
over the emulator's own (work-count tests guard the algorithms; a comparison
against the emulator on the same host is a release measurement), and the Hero
logs how long each action took from reading the chain through commitment
builds and proving (`prepared ... in ...`), plus any slow tick that built
without acting, for comparison with the deployed response and commitment
budgets.

Each transaction's gas limit is its estimate at the latest block plus half
again, at least 150,000 (a join that pairs on inclusion needs up to 110,161
more than its estimate), and stops at the EIP-7825 cap of 16,777,216 when the
estimate fits under it; the largest action, a maximum-input leaf proof,
estimates about 5.1M. A call that already reverts there is not sent. When
estimation fails for another reason the node falls back to 15M. A transaction
the pool turns down on price is sent once more with its priority fee raised
to its max fee, which displaces a pending transaction the base fee has
outrun.

Fund the signer for a whole batch. A pool admits a transaction only while the
balance covers every pending transaction's gas limit at its max fee plus its
value, and the node logs an error on each tick whose batch reserves more than
the signer holds. A dispute posts a join bond at every level it reaches, each
the level's match work allocation at 50 gwei (`Bond.sol`), and a bond comes
back only once its tournament's result is finalized, so a level whose next
join comes due sooner holds two. With the canonical table (heights 54 and
38) and a peak base fee of 100 gwei, twice the contracts' 50 gwei work-price
cap, which the node quotes as a max fee of about 200 gwei (twice the base fee
plus the tip):

```
floor = root bond + 2 x the leaf bond
        + (leaf-proof gas limit + 1M) x peak max fee
      = 0.36115 + 2 x 0.51265 + (7.61M + 1M) x 200 gwei
      = about 3.1 ETH
```

The 1M covers the settlement step and bond recoveries that share the leaf
proof's batch. A slot whose estimate fails other than by a revert reserves
15M, 3 ETH at that fee. Above the work-price cap an action's refund falls short
of its cost, and a replaced transaction pays its whole max fee, so a long
dispute during a fee spike draws the balance down: the per-tick error is the
signal to top up. These are Ethereum L1 numbers from `Bond.sol`, `Gas.sol` and
the deployed table; recompute them when any of them changes.

Here are its arguments:

```
The sling node: a PRT validator for Cartesi Rollups applications

Usage: cartesi-sling-node [OPTIONS] --app-address <APP_ADDRESS> --template-path <TEMPLATE_PATH> --blockchain-http-endpoint <BLOCKCHAIN_HTTP_ENDPOINT> --blockchain-id <BLOCKCHAIN_ID> --data-dir <DATA_DIR> <COMMAND>

Commands:
  pk       private-key signer: the key comes from the CARTESI_SLING_AUTH_PRIVATE_KEY environment variable or a key file, never from the command line
  aws-kms  AWS KMS signer
  help     Print this message or the help of the given subcommand(s)

Options:
      --app-address <APP_ADDRESS>
          address of application [env: CARTESI_SLING_APP_ADDRESS]
      --template-path <TEMPLATE_PATH>
          machine image a new data directory starts from: the application's template, or the state its current sealed epoch starts from; a seeded directory does not read it [env: CARTESI_SLING_TEMPLATE_PATH]
      --blockchain-http-endpoint <BLOCKCHAIN_HTTP_ENDPOINT>
          blockchain read gateway endpoint URL [env: CARTESI_SLING_BLOCKCHAIN_HTTP_ENDPOINT]
      --blockchain-http-submit-endpoint <BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT>
          raw-transaction submission endpoint URL; defaults to the read gateway [env: CARTESI_SLING_BLOCKCHAIN_HTTP_SUBMIT_ENDPOINT]
      --blockchain-id <BLOCKCHAIN_ID>
          blockchain chain id [env: CARTESI_SLING_BLOCKCHAIN_ID]
      --polling-interval <POLLING_INTERVAL>
          polling interval in seconds; a due response can wait one interval before the node sees it, out of a 5-minute response window [env: CARTESI_SLING_POLLING_INTERVAL] [default: 30]
      --snapshot-gap-inputs <SNAPSHOT_GAP_INPUTS>
          execute and durably publish open-epoch inputs in batches of N; 1 processes each input immediately, and sealing flushes a shorter final batch [env: CARTESI_SLING_SNAPSHOT_GAP_INPUTS] [default: 64]
      --data-dir <DATA_DIR>
          node data directory (database and machine snapshots); keep it across restarts, on XFS with reflink=1 [env: CARTESI_SLING_DATA_DIR]
  -h, --help
          Print help
```

## Operator notes

- The node's HTTP client honors the `HTTP_PROXY`, `HTTPS_PROXY` and
  `ALL_PROXY` environment variables (and macOS's system proxy settings), and
  on Linux it needs the system's CA certificates even for a plain-http
  endpoint: without them it stops at startup with an error saying so.
- Supported chains are Ethereum mainnet and Sepolia. OP Mainnet, Base and
  their Sepolia testnets have experimental deployments: the node runs there
  but is not validated, and refunds leave out the L1 data fee. Inputs there
  cost about a thousand times less while bonds do not, so a flood of inputs
  that outruns the node costs about 0.1-1.3 ETH instead of 90-1,300
  ([dimensioning.md](../../docs/dimensioning.md), the reference price). On
  Arbitrum the node stops at startup: contracts there measure clocks in the
  parent chain's block numbers, while logs and the node's heads use Arbitrum's
  own.
- A fresh data directory seeded from the template replays every input since
  the application's deployment. To skip that replay, seed it from the
  application's last settled state instead: read its hash with
  `cast call --block finalized <consensus> 'getLastFinalizedMachineMerkleRoot(address)(bytes32)' <app>`
  (the node accepts a settled state only once its settlement is finalized),
  or let the node's refusal print it, and point `--template-path` at
  `snapshots/0x<hash>` in the data directory of a node of the same emulator
  release that still works on that epoch: on the same host, that path itself,
  since the node clones it into its store; from another host, a sparse
  preserving copy of that directory (`rsync -S` or `tar --sparse`). The node
  then executes from that epoch on and never touches an earlier one, though
  the provider must still serve the application's logs since its
  deployment, which the node ingests either way. Bonds its signer holds in
  earlier epochs are the operator's: a `tryRecoveringBond` call on each such
  tournament has no deadline, may come from anyone and pays the recorded
  claimer; or keep the node that placed them running until it logs those
  epochs complete, as in the side-by-side upgrade below. Until it has
  replayed the seeded epoch, it logs that it waits for the machine runner, at
  ERROR after 5 minutes, since that epoch's clock runs: seed early in an
  epoch, between disputes. Across an emulator archive change (v0.22 refuses archive 7) an
  older release's snapshot does not load: the first node of the new release
  replays from a template stored by that release, and the others seed from
  it. The node takes the image's root from its stored hash tree and cannot
  check that tree against the contents until an emulator release supports
  hash-tree verification ([todo.md](../../docs/todo.md)), so until then take
  the image from a source you trust like the template, such as your own
  node's store.
- To upgrade across a change that requires a fresh data directory, start the
  new node on a new directory with its own funded signer, let it catch up,
  then stop the old one; never wipe the only node's directory in place. The
  new node recovers only its own signer's bonds and never revisits an epoch
  it has completed, even when restarted under another signer. The old
  signer's outstanding bonds stay recoverable by anyone: a direct
  `tryRecoveringBond` call on each such tournament pays the recorded
  claimer, whoever sends it.
- The first log line names the release the binary was built from (its tag,
  or `unreleased build`), the linked Cartesi Machine and its `MARCHID`:
  quote it in bug reports. Startup then logs whether the signer is a sentry
  of the consensus, and the configuration it runs with on one line, the
  endpoint URLs redacted.
- Read the levels as the failure policy defines them
  ([node-architecture.md](../../docs/node-architecture.md#failure-policy)):
  an ERROR asks an operator to act; a WARN means the node carries on. A
  failure that would cost a dispute logs WARN while it lasts and ERROR once
  it has lasted 5 minutes, the response window past which a late response
  draws on the dispute's censorship budget, so a transient blip never pages
  and a page means the node is losing clock.
- Run the node under a supervisor that never stops restarting it and waits
  well under 5 minutes between restarts. Startup exits 1 when an endpoint does
  not answer, so a node that starts before its RPC (after a reboot) fails
  fast, and a supervisor that gives up leaves it down while clocks run. With
  systemd, the start limit belongs in `[Unit]` and the restart policy in
  `[Service]`; the default start limit stops the unit for good after five
  failed starts in 10 seconds:

  ```ini
  [Unit]
  StartLimitIntervalSec=0

  [Service]
  Restart=on-failure
  RestartSec=5s
  # systemd 254+ backs off to a minute; older versions keep 5s
  RestartSteps=5
  RestartMaxDelaySec=60s
  RestartPreventExitStatus=2 30 40
  ```

  Docker and Kubernetes restart any failure status (unless Kubernetes v1.35+
  restart rules filter it), so alert on a last exit of 30 or 40.
- The exit status says why the node stopped: 0 a requested stop; 1 any other
  error (restart); 2 a usage error; 30 terminal, when a flag, the seed image,
  the deployment or the settled chain disagrees with the node (do not
  restart: an operator must act); 40 the data directory was built under
  another store format, commitment semantics, emulator, consensus or
  tournament geometry (start a fresh one beside it, as above); 101 a panic
  (restart with backoff and page, since a loop means a bug or corrupt local
  state). A 101 loop at a snapshot-root assert means corrupt local state:
  rebuild the data directory beside it as for 40, never delete a row or a
  snapshot directory alone, which a replay would adopt again. A death by
  signal logs nothing of its own: 137 (SIGKILL) is usually the kernel's
  out-of-memory killer; 135 (SIGBUS, systemd `status=7/BUS`) means the data
  directory's filesystem filled while a machine was mapped for writing; 134
  and 139 are crashes below the panic path, to report with stderr's last
  lines. Size memory for the application's machine plus a dispute's, plus
  about 250 bytes per input of the epoch, which the root composition holds
  at the roll and in a root dispute, plus about three times the input bytes
  of the densest 10,000 blocks since the deployment, which a catch-up holds
  at once: an out-of-memory kill there repeats on every restart.
- Behind a relay, an error that a call has been planned for some minutes
  without landing, naming a last verdict rather than a revert at latest,
  means the relay holds, drops or refuses its sends; the nonce it names is
  the stuck one (a nonce that advances each tick instead means the call mines
  without effect; [submit-relay.md](../../docs/runbooks/submit-relay.md) says
  how to find the held transaction). Until the relay recovers, restart
  without `--blockchain-http-submit-endpoint`, accepting paid reverts on the
  public pool.
- The read endpoint is part of the node's trust base: its answers are taken
  as true and its logs as complete. While it does not answer or stops
  following the chain, the node cannot act, and after 5 minutes each due
  response draws on the dispute's censorship budget, a week on Ethereum but
  hours on a testnet. Give it redundancy outside the node: point
  `--blockchain-http-endpoint` at a JSON-RPC proxy that fails over between
  two or more independent upstreams and stops routing to one that lags,
  ideally one of them an execution and consensus client you run. A plain
  HTTP balancer covers a dead upstream, not a lagging one. Each upstream
  must serve the node's chain (the startup check sees only the one that
  answers it), answer a request for a block it does not have with an error,
  not a short result, and not be served `latest` or `finalized` from a stale
  cache. Prefer upstreams other validators of the application do not use:
  honest nodes behind one provider stop together. Keep
  `--blockchain-http-submit-endpoint` out of the proxy.
- Size the host for the runner and a dispute together, at least two cores,
  since an adversary can time input load into a dispute. A host outage, a
  restart loop or an unanswered page draws on the same censorship budget as a
  provider outage.
- Alert on every ERROR line, on restart loops, on free space on the data
  directory's filesystem (the node refuses a batch below 1 GiB, except the
  newest sealed epoch's, leaving that space to it and its dispute), and on the
  signer's balance against the funding floor above, which the node checks
  only when a batch is due.
- Keep `--data-dir` on XFS with `reflink=1` in production (above). An epoch
  keeps one snapshot per `--snapshot-gap-inputs` inputs until it completes (a
  batch with no accepted input shares its predecessor's), and about two
  epochs are live at once, so size the disk for 2 x (1 + inputs per epoch /
  gap) snapshots: a few MB to tens of
  MB each with reflinks (the pages the application dirties across one gap),
  up to the whole machine without. The database also keeps every input
  payload since the deployment, so size it for the application's input
  volume too. Move or copy the directory only while the node is stopped,
  and only within the filesystem (`cp -a --reflink=always`): any other copy
  expands every snapshot to its full size. To relocate, seed a fresh
  directory from the last settled state instead.
- The signer must be a plain account that accepts ETH transfers, not one
  delegated (EIP-7702) to code that refuses or spends a payment: refunds and
  bonds are paid to it within a fixed gas allowance, and a recovery payment it
  refuses holds the node out of every later epoch and mines one no-op
  `tryRecoveringBond` per tick until the signer is fixed.
- A steady-state tick refuses an incomplete log response before committing
  and heals on the next tick. During a cold-start catch-up, a chunk that ends
  before the finalized head is checked for contiguity only, so an input or
  epoch dropped at its tail surfaces later as an index or epoch error that
  does not heal. Either failure logs an error once it has persisted 5
  minutes: point the node at a provider that serves complete logs, and if
  the error persists, rebuild the data directory.
- A directory seeded from the template walks every settled epoch's
  tournament logs up to the head before it reaches the current epoch. Behind
  a provider that caps `eth_getLogs` ranges, that grows with the history
  (hours per year of Sepolia history at a 10,000-block cap) and can outlast
  a testnet's root allowance: use a provider without a tight cap, or seed
  from the last settled state (above).
- Every epoch settles no sooner than its root tournament's allowance, plus
  the application's claim staging period unless every sentry agrees. With the
  canonical table that allowance is about one week and 140 minutes on
  mainnets and about 10 hours 20 minutes on testnets.
- A lost root, a root without a winner, and a won epoch whose final state
  cannot settle (a terminal application) each log an error every tick: they
  are the application guardian's to resolve, by foreclosure if need be
  ([epoch-lifecycle.md](../../docs/epoch-lifecycle.md#consensus-layer-staging-sentries-and-foreclosure)).
  A lost root's error says whether the winner ends in this node's final state
  or diverges from it; a sentry node claims its own state either way. After a
  divergent state settles, the node stops with exit 30 at the next epoch.
  A foreclosed application settles nothing more: let the node finish
  recovering its winning bonds, then stop it.
