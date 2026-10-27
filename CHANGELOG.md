# Changelog

## Unreleased

A new deployment generation: the consensus and application-factory bytecode
changes, moving deterministic deployment addresses. This node requires a
DaveConsensus that caps each epoch at the Machine's input span; earlier
uncapped deployments are unsupported: the node stalls at the first seal
past the span.

### Contracts

- DaveConsensus seals at most 2^24 pending inputs, retaining excess inputs
  for later epochs. Only processed, accepted inputs become finalized.
- DaveAppFactory binds application addresses to the full consensus settings,
  so other settings cannot occupy a predicted application address. Anyone can
  still occupy one through the shared ApplicationFactory, which makes
  `newDaveApp` revert: do not send value to a predicted address before
  `DaveAppCreated`.

### Node

- Split full pending epochs at the input span, check every later seal against
  those boundaries, and stall at the first seal past the span.

### For developers

- Rebuild the devnet bundle with `just rollups-contracts::build-devnet` after
  the contract changes.

## v3.0.0-alpha.6

A new deployment generation (cartesi/dave#287). Nodes from earlier releases
cannot read these contracts, this node cannot start against earlier ones, and
every address moves. Nothing is deployed on mainnet yet, so no migration is
needed.

### Contracts

- Clock refill: a winner returning from a child tournament is refilled by up
  to `T + 2G` (commitment budget plus two inclusions), within the sealed
  pair's envelope `max(r1, r2)`, so repeated Sybil delegations cannot drain a
  correct commitment's clock. A leaf proof or a timeout win earns one
  inclusion `G`. The root allowance is `C + 2G + (L - 1)(T + 2G)`.
- In-flight reserve: the root allowance holds one more inclusion, because a
  response is accepted only while its latency fits the balance and the root
  join's lateness is deducted with no discount; at one level `C + G` lost
  the correct commitment at zero censorship (F-01,
  docs/reviews/2026-10-13-prt-cyber-verification). The canonical mainnet
  allowance is one week plus 140 minutes. `ClockBudgets` changes, so the
  provider's initcode and every address built from it move.
- Refunds count the leaf proof's bytes at 16 units per byte. Only the proof
  is metered: the state transition fixes its length, and it now rejects input
  bytes at a position with no input (`InputBytesWithoutInput`). Every
  allocation was recalibrated; `WIN_LEAF_MATCH` is 5,536,000.
- Interface changes: `TournamentArguments` (the clone arguments) and
  `TournamentParameters` gain `commitmentBudget`, so `tournamentParameters()`
  returns six fields; `CanonicalTournamentParametersProvider`'s constructor
  takes `(blockMilliseconds, censorshipSeconds, inclusionSeconds)`, derives
  the budgets (`ClockBudgets`) and can revert with `BlockTimeCannotBeZero`;
  `CartesiStateTransition` gains one error and the
  `UARCH_PRISTINE_STATE_HASH()` getter. Tournament's function ABI is
  unchanged; its events change as below.
- Tournament and factory events gain fields, so every changed event has a
  new topic0. `MatchCreated` and `MatchAdvanced` add the responder's
  deadline, and `MatchAdvanced` the pair and the post-advance height;
  `LeafMatchSealed` adds the pair, the sealed divergence and both deadlines;
  `NewInnerTournament` adds the pair, the contested final states, and the
  child's descriptor and bond; `TournamentCreated` adds the descriptor and
  bond. The new `StandingChanged` follows every join and match deletion
  with the live match count, the dangling commitment and, once no match is
  live, the finish instant and an inner winner's parent commitment and
  expiry.
- `IMultiLevelTournamentFactory.instantiateInner` also returns the child's
  descriptor, which the parent publishes; existing selectors and ERC-165
  ids are unchanged. The rollups contracts import these interfaces, so their
  bytecode metadata changes too, and every CREATE2 address built from these
  sources moves: `CartesiStateTransition`, `Tournament`, the factory,
  `DaveAppFactory`, and the applications and consensuses it creates.
- The canonical table is two levels: `log2step = [38, 0]`,
  `height = [54, 38]`, with a 120-minute commitment budget. Existing
  applications keep the table of the factory that deployed them:
  `DaveConsensus` binds its tournament factory immutably. Off-chain
  claimers now build the root commitment at one leaf per 2^38 meta-cycles
  (an emulator mcycle computation-hash period of 2^18, 2^30 leaves per
  input window, root height 54), so a claimer pinned to the three-level
  root (2^44, height 48) cannot join applications from the new factory.
- An epoch now settles no sooner than about one week and 140 minutes after it
  seals on mainnet (one week and 60 minutes before), and about 10 hours 20
  minutes on testnets, plus the claim staging period unless every sentry
  agrees.
- Join bonds at the 50 gwei work-price cap, canonical table: root (height
  54) 0.36115 ETH, leaf (38) 0.51265 ETH.
- `CartesiStateTransition` qualifies Cartesi Machine v0.22 through
  solidity-step v0.16: `CM_MARCHID()` is 22, now imported from step instead
  of a local literal, and every uarch reset restores v0.22's pristine uarch
  hash. Every machine state hash moves, so templates must be rebuilt with the
  v0.22 tools.

### Chains

- Supported: Ethereum mainnet and Sepolia, in the `deployment-addresses`
  asset.
- Experimental, in the `deployment-addresses-experimental` asset:
  - OP Mainnet, Base and their Sepolia testnets: the node runs there but is
    not validated, and refunds leave out the L1 data fee.
  - Arbitrum One and Arbitrum Sepolia, registered at the parent chain's
    12 s block time (their addresses equal Ethereum's and Sepolia's). The
    node does not support them and stops at startup: contracts there measure
    clocks in the parent chain's block numbers, while logs use Arbitrum's.

### Addresses

The CREATE2 addresses the deploy scripts produce, as in the
`deployment-addresses` asset. These moved:

| Contract | Ethereum mainnet | Sepolia |
| --- | --- | --- |
| `CanonicalTournamentParametersProvider` | `0xF536648a9cc6c20c4824dDf653C03145A2A31DD9` | `0x008C22Ba3Fb5CBAb17A78188EC3251e31Df5e719` |
| `MultiLevelTournamentFactory` | `0xeF9028820bA365Cd0368ACe2681BfdD78815C000` | `0x66f3d801Aa9b047113fc9Ca09Fe9Efd9A338F397` |
| `DaveAppFactory` | `0x37238515E8161486C53741abe615EF1452309128` | `0xBD2a661328595113669a6b4c235126eec8c06A15` |
| `CartesiStateTransition` | `0x81d9bD8A7EdAC76B7A5b6635076944924883383a` | same |
| `Tournament` | `0x070d2c95Da45F665D383C3757476A76a5b0Be237` | same |

The rollups contracts (cartesi-rollups-contracts 3.0.0-alpha.10) keep their
v3.0.0-alpha.5 addresses on both chains, `InputBox` at
`0xEbE9f4Dfc04ae10bBeE663859c3dc5A23f94eA3C` among them.

### Node

- Links Cartesi Machine v0.22, which refuses machines stored by v0.21: a
  node built against v0.21 cannot start against these contracts, and v0.21
  templates and data directories do not load.
- Start from a fresh data directory: the schema changed (tournament events are
  no longer stored; the chain id is pinned), and the directory holds a
  `node.lock` that refuses a second process. The store carries a format stamp,
  so a directory an earlier release built exits 40. A stopped directory may
  now be moved or copied: snapshot paths derive from their state hashes. A
  fresh directory seeded from the template replays every input since the
  application's deployment; one seeded from the state the current sealed epoch
  starts from executes from that epoch on and never touches an earlier one, so
  bonds its signer holds there are the operator's to recover. See the README's
  operator notes for both and for a side-by-side upgrade.
- Changing the signer no longer needs a fresh directory: the node recovers
  its current signer's bonds, and a previous signer's stay recoverable by
  anyone through `tryRecoveringBond`, which pays the recorded claimer. The
  node does not revisit a completed epoch for them.
- A first start checks the seed image (the template, or the last settled
  state at the finalized head) against the chain, and every start checks the
  directory's pins and each endpoint's chain id, before writing anything; an
  endpoint on another chain exits 30, and one that does not answer, the
  submit endpoint included, exits 1. A seeded directory never reads
  `--template-path` again.
- A first start also refuses a seed image whose files the node maps for
  writing lack the owner write bit (exit 30): it would seed and then fail
  every batch. Make such an image writable (`chmod -R u+w`).
- Startup warns when no separate submit endpoint is set off anvil, and a send
  the submit endpoint does not answer is a WARN that pages after 5 minutes,
  not an ERROR on every send. The README lists what a submit relay must do,
  answering `eth_chainId` included, and docs/runbooks/submit-relay.md
  qualifies one; none has passed yet.
- The exit status says why the node stopped: 0 a requested stop, 1 any other
  error, 2 a usage error, 30 terminal (an operator must act), 40 a data
  directory to rebuild, 101 a panic. Under systemd, set
  `RestartPreventExitStatus=2 30 40`. See the README's operator notes.
- One paging rule: a failure that would cost a dispute logs WARN while it
  lasts and ERROR once it has lasted 5 minutes, the response window, so an
  ERROR asks an operator to act.
- An obligation the local commitment already missed (joins closed before it
  joined, its clock expired, its match or its match's child is eliminable)
  logs an ERROR every tick, and a loss names its case: elimination, another
  class's child win, or another commitment's root win, whose ERROR says
  whether its final state is this node's. Once a state this node did not
  compute settles, the node stops with exit 30 at the next epoch.
- A sentry also claims its own computed state after another commitment wins
  the root, as the dissent a guardian reads; staging and acceptance still
  follow only its own win.
- The runner refuses a batch or an epoch roll with less than 1 GiB free on
  the data directory's filesystem, where a full disk would kill it mid-batch
  with nothing logged.
- Every AWS KMS call is bounded like an RPC attempt (20 s), so a KMS endpoint
  that never answers fails the tick instead of parking it.
- Once caught up, the node logs an ERROR when the read endpoint's latest
  block is 5 minutes old or more: such a provider answers consistently with
  an old head while dispute clocks run.
- The first log line names the release tag the binary was built from (or
  says it is an unreleased build), the linked Cartesi Machine and its
  `MARCHID`, and startup logs whether the signer is a sentry of the
  consensus. The configuration it runs with is now one log line, not a
  record split over several.
- Startup also requires the deployed state transition's
  `UARCH_PRISTINE_STATE_HASH()`, the linked emulator's pristine uarch hash and
  the template's uarch state hash to be equal, beside the `CM_MARCHID` check,
  and names the pair that disagrees.
- Ingestion starts at the application's (or its consensus's) deployment,
  checks the chain's input and sealed-epoch totals at the finalized head, and
  refuses an incomplete response there before committing (catch-up chunks are
  checked for contiguity only; see the README's operator notes).
- `--long-block-range-error-codes` is removed: any failed `eth_getLogs` over
  more than one block is split, and a failure at one block fails the tick.
  Passing the flag is now a startup error; its environment variable is
  ignored.
- `--auth-private-key` is removed: any local user can read a process's
  arguments. The `pk` signer takes its key from
  `CARTESI_SLING_AUTH_PRIVATE_KEY` or `--auth-private-key-file`, and
  passing the old flag is a usage error. See the README's Run section.
- `--blockchain-http-endpoint` and `--blockchain-id` are required; they
  defaulted to anvil's `http://127.0.0.1:8545` and 31337.
- `aws-kms` no longer defaults `--aws-region` to `us-east-1` or builds
  `https://kms.<region>.amazonaws.com`: the AWS SDK resolves the region and
  endpoint (profile, instance metadata, FIPS, other partitions), and the
  two flags only override it. They no longer read `AWS_REGION` and
  `AWS_ENDPOINT_URL` themselves; the SDK still does. A start where no region
  resolves fails, naming `--aws-region`.
- Bond recovery keeps its dispute tree across ticks instead of re-walking it,
  so its scan no longer grows with the dispute's age.
- Gas limits come from estimates (half again, at least 150,000, clamped at the
  EIP-7825 cap); a call that already reverts is not sent; an underpriced
  replacement is retried once. The node logs an error when the batch needs
  more than the signer holds; see the README's funding floor.
- A terminal application's epoch is defended and then held, never staged,
  instead of crashing every node.
- SIGTERM stops the node like Ctrl-C; a second signal exits at once.
- SQLite commits sync fully, and release builds keep overflow checks.
- Logged RPC errors no longer quote the endpoint URL, which often carries an
  API key.
- The RPC client keeps reqwest's defaults apart from a 20 s timeout, HTTP/2
  keep-alive PINGs and a 60 s idle timeout. A rate-limited request is resent
  at most twice, never waiting over 5 s, and never for Infura's result-count
  rejection, which the log fetch splits instead.

### For developers

- Renamed or removed recipes: `measure-constants` is
  `measure-level-constants`; `prt-contracts::measure-gas` and
  `rollups-contracts::measure-prt-leaf-gas` are `just measure-prt-gas`; the
  `clean-*` recipes are `programs::clean PROGRAM`, one `clean` per contracts
  project and the root `clean`; the e2e entry points are `just e2e`,
  `just e2e-smoke` and `just e2e-logs`.
- Also removed: the Docker dev environment and its recipes (`setup-docker`,
  `prepare-docker-context`, `run-dockered`, `exec-dockered`),
  `update-submodules`, `check-rust-workspace`, `test-prt-timeout-boundaries`,
  the per-scenario `test-rollups-*` recipes (use `just e2e`) and the
  per-module `doctor` recipes (use `just doctor`).
- The honeypot image is an opt-in build from a pinned ref:
  `programs::build-honeypot-snapshot` is `programs::build-honeypot`. Docker is
  needed only for `just test-kms` and the honeypot image.
- Each worktree's devnet needs one rebuild:
  `just rollups-contracts::build-devnet`.
- `build-devnet` now deploys a three-level test table through a test-only
  provider (`TableTournamentParametersProvider`), the one CI and local tests
  run; `DEVNET_GEOMETRY=canonical` deploys the production contracts and
  geometry, as the release's `-anvil-` asset does. That asset's clocks assume
  12 s blocks and no censorship slack: an epoch settles no sooner than 700
  blocks (140 minutes) after it seals, and a leaf join gets 600 blocks to
  build its commitment. A dense two-level leaf takes tens of minutes to
  build, so on a devnet that mines faster an honest node can run out of
  clock.
- The measurement tool is the node crate's example, `cargo run --example
  measure`, which the `just measure*` recipes run; release builds no longer
  compile it.
- `just test-node-harness` runs the anvil harness and the other anvil tests
  in parallel.
- `just test-lua-client` also checks the Lua client's event layouts against
  the compiled `ITournament` ABI, so it now needs `forge`, `jq` and the PRT
  contract dependencies (`just prt-contracts::install-deps`).
