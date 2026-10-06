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
  inclusion `G`. The root allowance is `C + G + (L - 1)(T + 2G)`.
- Refunds count the leaf proof's bytes at 16 units per byte. Only the proof
  is metered: the state transition fixes its length, and it now rejects input
  bytes at a position with no input (`InputBytesWithoutInput`). Every
  allocation was recalibrated; `WIN_LEAF_MATCH` is 5,543,000.
- Interface changes: `TournamentArguments` (the clone arguments) and
  `TournamentParameters` gain `commitmentBudget`, so `tournamentParameters()`
  returns six fields; `CanonicalTournamentParametersProvider`'s constructor
  takes `(blockMilliseconds, censorshipSeconds, inclusionSeconds)`, derives
  the budgets (`ClockBudgets`) and can revert with `BlockTimeCannotBeZero`;
  `CartesiStateTransition` gains one error. Tournament's function and event
  ABI is unchanged.
- An epoch now settles no sooner than about one week and 85 minutes after it
  seals on mainnet with the canonical three-level table (one week and 60
  minutes before), and about 9 hours 25 minutes on testnets, plus the claim
  staging period unless every sentry agrees.
- Join bonds at the 50 gwei work-price cap, canonical table: root (height
  48) 0.3353 ETH, middle (17) 0.1369 ETH, leaf (27) 0.45115 ETH.

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

- Start from a fresh state directory: the schema changed (tournament events
  are no longer stored; the chain id is pinned), and the directory holds a
  `node.lock` that refuses a second process. A fresh directory replays every
  input since the application's deployment; see the README's operator notes
  for a side-by-side upgrade.
- Changing the signer no longer needs a fresh directory: the node recovers
  its current signer's bonds, and a previous signer's stay recoverable by
  anyone.
- Startup checks the template against the chain, the directory's pins and
  the chain id before writing anything, and refuses a template no epoch can
  start from.
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
  at most twice, a second apart, never after a server-requested wait over
  5 s, and never for Infura's result-count rejection, which the log fetch
  splits instead.

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
