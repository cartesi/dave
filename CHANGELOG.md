# Changelog

## Unreleased

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

### Node

- Links Cartesi Machine v0.22, which refuses machines stored by v0.21: a
  node built against v0.21 cannot start against these contracts, and v0.21
  templates and data directories do not load.
- Start from a fresh data directory: the schema changed (tournament events
  are no longer stored; the chain id is pinned), and the directory holds a
  `node.lock` that refuses a second process. A fresh directory seeded from
  the template replays every input since the application's deployment; one
  seeded from the state the current sealed epoch starts from executes from
  that epoch on and never touches an earlier one, so bonds its signer holds
  there are the operator's to recover. See the README's operator notes for
  both and for a side-by-side upgrade.
- Changing the signer no longer needs a fresh directory: the node recovers
  its current signer's bonds, and a previous signer's stay recoverable by
  anyone through `tryRecoveringBond`, which pays the recorded claimer. The
  node does not revisit a completed epoch for them.
- A first start checks the seed image (the template, or the last settled
  state at the finalized head) against the chain, and every start checks the
  directory's pins and each endpoint's chain id, before writing anything; an
  endpoint on another chain exits 30. A seeded directory never reads
  `--template-path` again.
- Startup warns when no separate submit endpoint is set off anvil, and a send
  the submit endpoint does not answer is a WARN that pages after 5 minutes,
  not an ERROR on every send.
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
- `just test-lua-client` also checks the Lua client's event layouts against
  the compiled `ITournament` ABI, so it now needs `forge`, `jq` and the PRT
  contract dependencies (`just prt-contracts::install-deps`).
