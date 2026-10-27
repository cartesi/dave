# Rollups consensus contracts - agent guidance

This directory is the on-chain settlement boundary: `DaveConsensus`
partitions an application's input stream into epochs, instantiates one PRT
root tournament per sealed epoch, and converts the tournament's arbitration
result into the application's settled outputs root. It sits at the same
trust tier as `prt/contracts/`; treat every change as security-sensitive.

These instructions extend the root `AGENTS.md`. The code is the source of
truth.

## Read before editing

| Work | Required context |
| --- | --- |
| Epoch sealing, staging, sentries, settlement | [`docs/epoch-lifecycle.md`](../../docs/epoch-lifecycle.md) |
| Tournament interface behavior consumed here | [`docs/dispute-game.md`](../../docs/dispute-game.md) |
| The data-provider seam and input coordinates | [`docs/computation-hash.md`](../../docs/computation-hash.md) |
| Leaf-proof gas through the production provider | [`docs/runbooks/prt-refund-gas-calibration.md`](../../docs/runbooks/prt-refund-gas-calibration.md) |
| e2e coverage of this contract | [`docs/test-harness.md`](../../docs/test-harness.md) |

## Trust boundary and assumptions

- Settlement safety derives from the tournament. The staged post-epoch
  machine state hash comes only from the `ROOT_WINNER` standing of the
  tournament this contract instantiated (`tournamentStanding()`), and the
  staged outputs root is bound to that state by a fixed-position Merkle
  replacement proof over the machine's CMIO tx buffer region. No other
  write path to staged values exists.
- Sentries are a delay-then-alarm mechanism, not a safety authority.
  Unanimous agreement (all N slots, N > 0) settles immediately; anything
  else waits out the claim staging period, after which settlement
  proceeds regardless of claims. A sentry can shorten settlement, never
  veto or corrupt it. The period is a reaction window for independent
  checkers and human operators; the application-layer foreclosure switch
  is the emergency brake.
- With zero sentries only the staging-period path exists.
- Staging and acceptance are permissionless; settlement liveness needs an
  externally motivated caller, not the sentry manager. Only rotation
  liveness depends on the immutable sentry-manager key.
- `notForeclosed(appContract)` gates all four mutators (stage, claim,
  accept, rotate): a foreclosed application freezes epoch progress and
  sentry rotation. Foreclosure belongs to the application layer: its
  guardian calls `Application.foreclose()`, irreversibly. The guardian is
  the last line for what the tournament cannot settle or got wrong (a
  no-winner root, a terminal application's epoch, a result decided outside
  the PRT model); the claim staging period is its reaction window
  (docs/epoch-lifecycle.md).
- InputBox integrity and the tournament factory's configuration are
  assumed. This contract is the application's
  `IOutputsMerkleRootValidator` and each tournament's `IDataProvider`;
  both interface behaviors are deployed compatibility surface.

## Source map

- `src/DaveConsensus.sol` - one instance per application: epoch
  bookkeeping, tournament instantiation, result staging with outputs
  proof validation, sentry claims and agreement counting, settlement,
  sentry rotation, and the data-provider/validator surfaces.
- `src/IDaveConsensus.sol` - the external behavior and event/error
  compatibility surface (`EpochSealed` has six fields with indexed
  epoch number; the node's blockchain reader consumes it).
- `src/DaveAppFactory.sol` - one-transaction CREATE2 deployment of
  application plus consensus: creates the app with no validator, deploys
  consensus, migrates the app's validator to it, renounces ownership.
  All steps run inside one `newDaveApp` call, so there is no
  partial-completion window; `calculateDaveAppAddress` predicts both
  addresses for pre-funding and configuration.
- `src/ISentryErrors.sol` - sentry error selectors.

## Invariants to protect

- Staged values originate only from the current tournament's
  `ROOT_WINNER` standing plus a valid outputs proof; a failed root
  reverts staging. Sentry claims only count agreement; nothing about the
  staged value is echoed back to or from a claim.
- One live tournament at a time - the current sealed epoch's. Acceptance
  settles, samples the next epoch's input bounds from the InputBox at
  that moment, capped at the Machine's 2^24-input span with excess left
  pending, records the outputs root in a write-once mapping, and
  instantiates the next tournament from the settled state.
- A sentry slot claims at most once per epoch (bitmap by slot ID).
  Rotation moves a slot to a new address but preserves an already-placed
  claim for the epoch.
- Staging moves no value. Bond recovery is a separate, explicit,
  permissionless call on the retired tournament; no progress path may
  depend on, or invoke, the tournament's payment path.
- `provideMerkleRootOfInput` validates input content against the InputBox
  hash and returns the zero hash for out-of-range indices - the fixpoint
  padding rule the off-chain commitment builders mirror
  (docs/computation-hash.md). Changing it desynchronizes every
  commitment producer.
## Change guardrails

- `MAX_INPUTS_PER_EPOCH` must equal the node's `Structure::max_inputs`.
  If it moves, update the reader's eager split and docs/epoch-lifecycle.md
  with it, and validate the cross-implementation boundary.
- Preserve the deployed ABI, events, error selectors, and the ERC-165
  surface (`IDataProvider`, `IOutputsMerkleRootValidator`) unless the
  task explicitly authorizes a compatibility break.
- Production bytecode changes require regenerated deployment artifacts
  and CREATE2-derived addresses, and a rebuilt devnet state for e2e
  (`just rollups-contracts::build-devnet`; `just doctor-e2e` fingerprints
  a stale one).
- The outputs-proof position ties this contract to the solidity-step copy
  bundled in its cartesi-rollups-contracts dependency (register addresses),
  and the data-provider seam to `machine/step` constants (input hashing)
  and off-chain commitment construction; changes there require coordinated
  node, Lua-client, and documentation work.
- Sentry semantics changes must preserve "shorten, never veto or
  corrupt", or explicitly re-argue the safety statement here and in
  docs/epoch-lifecycle.md.
- Use braces for every Solidity control-flow body, including a single
  statement.

## Build and test

```bash
just rollups-contracts::check-fmt
just rollups-contracts::test
just test-prt-gas          # includes the leaf-proof subsidy through this provider
just bind                  # after any interface change
```

Honest coverage statement: `test/DaveConsensusCapacity.t.sol` uses a mocked
fixture to cover capped epoch storage and events, backlog rollover and boundary
counts. `test/DaveAppFactory.t.sol` exercises construction, stage and accept,
`wasInputFinalized`, staging reverts on bad proofs, root failure, sentry
rotation and a winner exhausting the payment callback. The leaf-proof gas FFI fixture
(`test/gas/`), node integration tests and e2e smoke add coverage.
`test/NodeProofs.t.sol` and `test/NodeWitnesses.t.sol` check that the contracts'
verifiers and the step accept the node's proofs and witnesses, without running
`DaveConsensus`. When changing staging, sentry or settlement logic, add focused
tests rather than assuming the capacity fixture covers it.

## Explicit non-claims

- There is no on-chain recovery for a lost or compromised sentry-manager
  key: rotation stops; settlement continues through the staging period.
  Manager key custody is an operational concern, not solved here.
- Sentry agreement does not prove the result correct - it removes the
  delay. The staging period is a reaction window, not a fraud proof.
- Epochs have no inherent duration: sealing bounds are sampled at
  acceptance time, so epoch length is a function of settlement cadence.
