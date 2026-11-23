# Card: material for the detector sketch

Scope: evidence only, no design. Read for interfaces:
`cartesi-rollups/contracts/src/{IDaveConsensus,DaveConsensus,IDaveAppFactory,DaveAppFactory}.sol`,
`prt/contracts/src/ITournament.sol`, `prt/contracts/src/tournament/Tournament.sol`
(two spots), the rollups-contracts 3.0.0-alpha.10 dependency (InputBox,
Inputs, IApplication, ApplicationChecker; NOT in this worktree, read from the
main checkout's soldeer `dependencies/`, cited below as `DEP/src/...`), the
node's `blockchain_reader`, `engine/machine_stf.rs`, `machine_runner`,
`epoch_manager`, `harness/`, cartesi/dave#304 (via `gh`), and the hardening
catalog of 2026-10-27 (out of tree; cited `CAT:line`).

## What is claimed on chain, and where

Root tournament (`ITournament`, one clone per epoch):
- `CommitmentJoined(Tree.Node indexed commitment, Machine.Hash finalStateHash,
  address indexed submitter)` (`prt/contracts/src/ITournament.sol:363-367`).
  In a ROOT tournament `finalStateHash` is the claimed post-epoch machine state
  (the commitment tree's last leaf, `ITournament.sol:660`). Log-only. In an
  INNER tournament it is an intermediate state of the contested span, not an
  epoch final state (joins must match one of the parent's two contested states,
  `ITournament.sol:665-666`), so a final-state comparison uses root joins only.
- Root winner: there is no `arbitrationResult` in production; that name exists
  only in a test fixture (`prt/contracts/test/fixtures/TournamentInspector.sol:113`).
  The production view is `tournamentStanding() returns (TournamentStandingView)`
  (`ITournament.sol:914-917`): fields `standing, acceptsJoins, hasCandidate,
  candidate, finalState, parentCommitment, finishedAt, winnerExpiresAt`
  (`ITournament.sol:188-197`). `ROOT_WINNER` sets `finalState =
  finalStates[candidate]`, the same value the join recorded
  (`prt/contracts/src/tournament/Tournament.sol:1005-1011`); `ROOT_FAILED` has
  no candidate. Log-only alternative: `StandingChanged(matchCount, dangling,
  parentCommitment, resultAt, winnerExpiresAt)` (`ITournament.sol:446-452`):
  with `matchCount == 0` the dangling commitment is the prospective winner from
  `resultAt` on; clients take the latest event per tournament
  (`ITournament.sol:434-445`). Map `dangling` to its final state through the
  matching `CommitmentJoined`. The view is the authoritative read.
- `MatchDeleted(matchIdHash indexed, one indexed, two indexed,
  MatchDeletionReason reason, WinnerCommitment winnerCommitment)`
  (`ITournament.sol:351-357`); reasons `STEP, TIMEOUT, CHILD_TOURNAMENT`
  (`ITournament.sol:102-106`), winner `NONE, ONE, TWO` (`:112-116`). Log-only;
  the tournament is the log's address.
- `NewInnerTournament(matchIdHash indexed, childTournament indexed, one, two,
  contestedFinalStateOne, contestedFinalStateTwo, TournamentDescriptor
  descriptor, uint256 bondValue)` (`ITournament.sol:412-421`). Log-only; the
  only source of the child's contested states (`:407-408`). Children are
  trusted only when reached through `EpochSealed` then `NewInnerTournament`
  (`:443-445`): anyone can instantiate a tournament through the factory.
- `LeafMatchSealed(..., agreeState, divergencePosition, finalStateOne,
  finalStateTwo, deadlineOne, deadlineTwo, eliminableAt)`
  (`ITournament.sol:332-343`) is the durable divergence record (`:329-331`).
- Event counters per tournament (`getCommitmentJoinedCount`, ...,
  `getNewInnerTournamentCount`, `ITournament.sol:971-991`) let a reader prove
  its log fetch complete (`:959-964`).

Consensus (`DaveConsensus`, one per application):
- `EpochSealed(uint256 indexed epochNumber, inputIndexLowerBound,
  inputIndexUpperBound, Machine.Hash initialMachineStateHash, bytes32
  outputsMerkleRoot, ITournament tournament)`
  (`cartesi-rollups/contracts/src/IDaveConsensus.sol:75-82`). Emitted at
  construction for epoch 0 with the template as initial state and a zero
  outputs root (`DaveConsensus.sol:141-145`), and by every acceptance for epoch
  k+1, carrying epoch k's SETTLED final state as the initial state and epoch
  k's outputs root (`DaveConsensus.sol:264-286`). So "the state that settled
  for epoch k" is in `EpochSealed(k+1)`, log-only.
- `EpochStaged(uint256 indexed epochNumber, Machine.Hash
  stagedPostEpochMachineStateHash, bytes32 stagedPostEpochOutputsMerkleRoot)`
  (`IDaveConsensus.sol:100-104`; emitted `DaveConsensus.sol:195`). Log-only;
  the staging block is the log's block (`_stagingBlockNumber = block.number`,
  `DaveConsensus.sol:190`).
- `SentryClaim(uint256 indexed epochNumber, uint256 indexed sentryId, address
  indexed sentry, Machine.Hash postEpochMachineStateHash)`
  (`IDaveConsensus.sol:89-94`). Log-only. Emitted for ANY hash: the contract
  checks only caller, epoch number and one-claim-per-slot, never the staged
  value or whether a winner exists (`DaveConsensus.sol:198-221`). A claim that
  differs from the staged state, or precedes staging, is emitted and counted.
- `SentryRotation(sentryId indexed, oldSentry indexed, newSentry indexed)`
  (`IDaveConsensus.sol:115`).
- There is no "accepted" event: acceptance is visible only as the next
  `EpochSealed` (`DaveConsensus.sol:279`).

## What the consensus exposes about settlement

All on `DaveConsensus` unless noted:
- `getCurrentSealedEpoch() returns (epochNumber, inputIndexLowerBound,
  inputIndexUpperBound, tournament, isTournamentResultStaged,
  stagingBlockNumber, stagedPostEpochMachineStateHash,
  stagedPostEpochOutputsMerkleRoot)` (`IDaveConsensus.sol:250-262`); staged
  fields zero unless staged (`DaveConsensus.sol:324-328`).
- `canStageTournamentResult() returns (isFinished, isTournamentFailed,
  isTournamentResultStaged, epochNumber, winnerCommitment,
  winnerPostEpochMachineStateHash)` (`IDaveConsensus.sol:278-288`), derived from
  the root's `tournamentStanding()` (`DaveConsensus.sol:443-456`). Total, never
  reverts; ignores foreclosure (`IDaveConsensus.sol:272-277`).
- `canAcceptStagedTournamentResult() returns (isTournamentResultStaged,
  doAllSentriesAgreeWithStagedTournamentResult, isClaimStagingPeriodOver,
  epochNumber, stagedPostEpochMachineStateHash,
  stagedPostEpochOutputsMerkleRoot)` (`IDaveConsensus.sol:320-330`). Period
  test: `block.number - _stagingBlockNumber >= _CLAIM_STAGING_PERIOD`
  (`DaveConsensus.sol:240`); unanimity: `N > 0 && claimCount[epoch][staged] ==
  N` (`DaveConsensus.sol:475-477`). Ignores foreclosure
  (`IDaveConsensus.sol:318-319`).
- `getLastFinalizedMachineMerkleRoot(address appContract) returns (bytes32)`
  (`DaveConsensus.sol:408-416`): reverts `ApplicationMismatch` for another app;
  returns ZERO before the first acceptance (the storage slot is only written at
  `DaveConsensus.sol:273`), not the template. The node special-cases epoch 0
  (`cartesi-rollups/node/src/blockchain_reader/mod.rs:194-195`).
- `getClaimStagingPeriod() returns (uint256)` in base-layer BLOCKS
  (`IDaveConsensus.sol:179-185`, error `:131-134`); immutable
  (`DaveConsensus.sol:51`).
- Sentries: `getNumberOfSentries`, `getSentryManager`, `getSentryId(address)`,
  `getSentryById(uint256)`, `hasSentryClaimedInEpoch(epoch, id)`,
  `getSentryClaimCount(epoch, hash)` (`IDaveConsensus.sol:189-221`).
- Also: `isOutputsMerkleRootValid(app, root)` (`DaveConsensus.sol:398-406`),
  `wasInputFinalized(app, index, _) = index < lowerBound`
  (`DaveConsensus.sol:418-426`), `getInputBox`, `getApplicationContract`,
  `getTournamentFactory`, `getDeploymentBlockNumber`
  (`IDaveConsensus.sol:168-177`).
- Guardian and foreclosure live on the APPLICATION (rollups-contracts), not
  here: `IApplication.isForeclosed()`, `getGuardian()`, `foreclose()`,
  `getTemplateHash()`, event `Foreclosure()` (`DEP/src/dapp/IApplication.sol:
  286, 290, 190, 266, 57`). DaveConsensus only consumes it through the
  `notForeclosed(appContract)` modifier on stage, claim, accept and rotate
  (`DaveConsensus.sol:170, 201, 246, 293`), a staticcall to `isForeclosed`
  (`DEP/src/dapp/ApplicationChecker.sol:12-26`). `InputBox.addInput` is also
  `notForeclosed` (`DEP/src/inputs/InputBox.sol:20-23`).

## What an independent replay needs from the chain

- Initial state: `EpochSealed(0).initialMachineStateHash`, which the factory
  sets to `templateHash` (`cartesi-rollups/contracts/src/DaveAppFactory.sol:85-94`);
  the same value is `IApplication.getTemplateHash()` (`DEP/src/dapp/IApplication.sol:266`).
  The node reads it from the epoch-0 log in the deployment block
  (`blockchain_reader/mod.rs:255-284`), which breaks on chains whose
  `block.number` is not the log block coordinate, e.g. Arbitrum (`:271-279`).
  The chain gives only the hash; the image itself must come from elsewhere.
- Epoch k > 0 starts from `EpochSealed(k).initialMachineStateHash`
  (`DaveConsensus.sol:277-283`); a replay chaining its own states can compare
  each with it.
- Epoch bounds: `[inputIndexLowerBound, inputIndexUpperBound)` of `EpochSealed`
  (`IDaveConsensus.sol:68-71`), sampled at acceptance and capped at
  `MAX_INPUTS_PER_EPOCH = 1 << ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH` (2^24),
  excess left pending (`DaveConsensus.sol:37-39, 470-473`).
- Inputs: `InputAdded(address indexed appContract, uint256 indexed index, bytes
  input)` (`DEP/src/inputs/IInputBox.sol:19`). The payload exists only in the
  log; on chain the InputBox stores only `keccak256(input)`
  (`DEP/src/inputs/InputBox.sol:50-55`), readable as `getInputHash(app,
  index)` (`:69-76`), with `getNumberOfInputs(app)` (`:59-66`). `input` is
  already the `EvmAdvance(chainId, appContract, msgSender, blockNumber,
  blockTimestamp, prevRandao, index, payload)` ABI call
  (`DEP/src/inputs/InputBox.sol:30-41`, `DEP/src/common/Inputs.sol:21-30`),
  capped at `CanonicalMachine.INPUT_MAX_SIZE` (`InputBox.sol:43-47`; 2^16 bytes
  per `cartesi-rollups/node/src/harness/tests.rs:26-29`).
- The node feeds that blob verbatim: the reader stores `input_added.input` as
  `Input.data` (`blockchain_reader/mod.rs:803-809`); the runner hands it to
  `MachineStf::over_advancing` (`machine_runner/mod.rs:219-225`), whose feed
  calls `send_cmio_response(Advance, &payload, Some(&root))` with the pre-feed
  root as revert root (`engine/machine_stf.rs:354-360, 406-436`). A harness test
  pins `keccak(stored) == getInputHash` and the length `4 + 9*32 + payload`
  (`harness/tests.rs:323-331`). The consensus's data provider checks the same
  hash (`DaveConsensus.sol:376-396`). The node itself never calls
  `getInputHash` in production; it checks indices and totals only
  (`blockchain_reader/mod.rs:780-793, 736-762`).
- Semantics the replay must reproduce (owned by `docs/computation-hash.md`):
  a REJECTED yield restores the pre-input root; exception, unexpected yield,
  halt and overflow are terminal fixed points (`docs/computation-hash.md:186-211`);
  off-chain clients reload a pre-input snapshot on reject (`:213-218`, node
  `engine/machine_stf.rs:357-360`). Startup checks the template's uarch against
  the linked emulator and the deployed step (`docs/computation-hash.md:162-166`).
- The value to compare: the node's settled `final_state` is the hash of the
  epoch's last boundary snapshot after its final input
  (`cartesi-rollups/node/src/storage/advance.rs:148-160, 515-538`); padding
  leaves repeat that hash (`engine/dispute.rs:167-168`), so it is the root
  commitment's last leaf.
- Stageability: staging requires a `MachineValidityProof` of three leaves
  (iflags_Y, HTIF tohost, TX buffer) against the final state
  (`DaveConsensus.sol:462-468`; `docs/epoch-lifecycle.md:117-123, 186-189`).
  The proof is not bound to the epoch, only to the hash.

## What the node's harness can already stage

Gating: `mod harness` is `#[cfg(test)]` and private (`cartesi-rollups/node/src/lib.rs:31-32`);
its deploy helpers live in `blockchain_reader::test_utils`, also `#[cfg(test)]`
`pub(crate)` (`blockchain_reader/mod.rs:650-651`); `Tail` is `#[cfg(test)]`
(`engine/dispute.rs:180-185`). No other crate can import any of it. A separate
binary could be driven only as a process from a harness test, as cartesi/dave#304
does with `python3` (`Command::new`), or by duplicating the anvil setup. The
bindings crates are separate workspace members (`Cargo.toml:3-13`). The tests
are `#[ignore]` and run via `just test-node-harness` (`justfile:215-222`),
which CI runs (`.github/workflows/build.yml:248`).

Primitives (`cartesi-rollups/node/src/harness/mod.rs`):
- `World::spawn(sentries: &[usize], claim_staging_period: u64)` (`:84`): anvil
  over the devnet bundle, echo template, guardian = operator key 9 (`:56, 122`),
  automine off, 1 s timestamps (`:104-116`), finalized = latest - 2 (`:144-151`).
  `spawn_on_template(.., template: PathBuf)` (`:93`, module-private) takes any
  stored machine.
- `World::mine(blocks)`, `mine_to(block)` (`:179, 213`) check every receipt;
  `add_input(payload)`, `accepts_input` (`:411, 402`); `drop_pending()` (`:429`);
  `consensus()` (`:434`); `sealed_epochs()` (`:439`); `root_closes_at()` (`:453`);
  log helpers `matches_created/deleted`, `commitments_joined`, `bonds_recovered`,
  `inner_tournaments`, `deepest` (`:282-398`); views `standing(t, c)`,
  `timeout_outcome_at` (`:350, 364`); `calls(key, selector)`, `honest_calls`,
  `trace()` (`:265-276, 223`).
- `World::honest_node()`, `World::node(key: usize)` (`:463, 469`): a full
  node (reader, runner, manager) on any anvil key over a fresh directory.
  `Node::tick`, `turn`, `roll(world, epoch)` (ingest and execute without the
  manager, `:620-634`), `run_until`, `run_with(adversaries)`, `restart`
  (`:603-688`).
- `World::adversary(&node, key, tail: Tail, policy: Policy)` (`:494-547`): the
  production Hero over a copy of the node's store with a `Tail { from, value }`
  overlay (every leaf at or past `from` reads `value`); no manager, so it never
  stages or claims. `Policy::{Rational, StopAfter(label), Hold(label)}`
  (`:693-701`); `Adversary::turn/release/stop/holding` (`:718-767`).
- Test-side helpers: `foreclose(world)` via the operator key
  (`harness/tests.rs:85-100`); `tail(leaf, fill)`, `idle_tail()`
  (`harness/tests.rs:409-420`).

Answers:
- Fabricated claim WINS a root: yes. `a_sentry_that_lost_its_root_still_claims_its_state`
  rolls the node, lets the adversary join, mines past closure without ticking
  the node, and the adversary's commitment ending in `[0xee; 32]` wins; the
  node then claims its own state as sentry and stages nothing
  (`harness/tests.rs:472-511`).
- That win can be staged: not with today's tails. `Tail.value` is a fixed
  digest (`tests.rs:415-419`), and staging needs a three-leaf validity proof
  against it (`DaveConsensus.sol:184`), which a constant like `0xee..` has no
  known preimage tree for. Lead, not verified: a `Tail` whose value is a real
  RX_ACCEPTED state (the template, or an earlier settled state, with the proof
  from that epoch's `settlement_info`) would end in a stageable wrong state,
  since the proof binds only the hash.
- Hold the honest node out past join closure: yes, `Node::roll` then not
  ticking (`harness/mod.rs:620-634`, `tests.rs:477-487`).
- Second node on another key: yes, `World::node(key)` (`mod.rs:469`); not
  exercised with two nodes defending at once (`docs/todo.md:146-148`).
- Sentries and a nonzero staging period: yes, `World::spawn(&[HONEST, 8], 30)`
  (`tests.rs:383-402`).
- Foreclose: yes, `tests.rs:85-100`, used in `tests.rs:147-200`.
- Terminal application: `a_guest_halted_by_an_input_is_defended_across_restart_and_never_staged`
  (`tests.rs:202-204`).
- Disputes run only on an empty epoch (idle spans); a steered divergence point
  is an open item (`docs/test-harness.md:31-34`, `docs/todo.md:144-145`).

## What cartesi/dave#304 does

Open PR "feat: add settlement detection and recovery tools", two commits, not in
this tree (`gh pr view`/`gh pr diff`, read-only). Files and behavior:
- `script/settlement-watch.py` (145 lines): JSON-RPC `eth_call` at one pinned
  block (`--block finalized` default) of `getApplicationContract`,
  `getCurrentSealedEpoch`, `canStageTournamentResult`,
  `canAcceptStagedTournamentResult` and the app's `isForeclosed`, cross-checks
  their epoch/staged fields, re-checks the block hash, and classifies phase:
  `foreclosed`, `staging_wait`, `acceptance_ready`, `root_failed`,
  `winner_unstaged`, `tournament_in_progress`. A JSON state file keyed on
  (epoch, phase, winner, staged_state) turns `winner_unstaged` or
  `acceptance_ready` into `stalled` after `--grace-blocks`. Exit 2 stalled, 3
  root failure, 1 observation error. Selectors come from `cast sig`. It never
  replays and never compares states with an independent value.
- `script/settlement-recover.py` (134): `export` reads the node's SQLite
  read-only: `sling_config(chain_id, app, consensus)` and `settlement_info`
  columns `computation_hash, final_state, iflags_y_data_block,
  iflags_y_siblings, htif_tohost_data_block, htif_tohost_siblings,
  tx_buffer_data_block, tx_buffer_siblings` (59 siblings each). `stage`/`accept`
  re-snapshot, require the winner and staged values to equal the evidence,
  build `stageTournamentResult` or `acceptStagedTournamentResult` calldata with
  `cast calldata`, and `eth_call` it at the observed block.
- `script/settlement-operator.py` (96): runs the watcher, asks twice on stdin,
  re-prepares, then sends with `cast send --async` (`--account` keystore or
  `--unlocked`). Never forecloses.
- `script/tests/settlement-watch.py`, `script/tests/settlement-recovery.py`:
  provider-free Python tests.
- `cartesi-rollups/node/src/harness/tests/settlement_liveness.rs` (311): four
  `#[ignore]` anvil scenarios (outage before staging with recovery by a fresh
  `world.node(8)` replay and the operator key; outage after staging; phases
  open/failed/foreclosed; terminal winner not stageable). They spawn
  `python3 ../../script/settlement-*.py` through `std::process::Command`.
- `docs/runbooks/settlement-liveness.md` (207), `docs/README.md` link.
- `justfile`: `test-settlement-tools` (runs both Python tests) added to
  `just check`; `test-settlement-liveness` runs the harness module.
  `.github/workflows/build.yml`: a CI step running `just test-settlement-tools`.
Its own body says the replay "shares Sling's implementation and emulator" and
is not independent assurance. It adds Python to the repository's tooling and
check gate.

## The watchtower catalog (W1-W8, R1-R4), reduced

Columns: inputs; alarm; deadline protected; needs execution. "Here" = logs and
views of contracts in this repository; "App" = needs rollups-contracts'
Application; "Replay" = machine execution. The catalog's `DaveConsensus.sol`
line numbers predate this tree (e.g. it cites `:250-256, 464-466` for
acceptance, now `DaveConsensus.sol:255-261, 475-477`).
- W1 deployment audit (`CAT:97-100`): guardian, P, sentry set and manager,
  factory/InputBox/parameters, STF MARCHID and pristine uarch hash,
  Tournament code hash, outputs validator, withdrawal builder. Alarm: any
  differs from policy. Protects: before first deposit (immutables). No
  execution. Here + App + release assets.
- W2 participation (`CAT:101-104`): EpochSealed, NewInnerTournament,
  MatchCreated/Advanced, LeafMatchSealed, StandingChanged, commitmentStanding.
  Alarm: no operator-class join within G+finality; response overdue; deadline
  margin low. Protects: root join closure, responderDeadline, winnerExpiresAt.
  No execution. Here, plus a configured list of operator signers.
- W3 C ledger (`CAT:105-108`): commitmentStanding every block, LeafMatchSealed
  deadlines, block interval. Alarm: C spent crosses 10/25/50%, leaf-race
  margin, block-time drift. Protects: C, leaf race. No execution. Here.
- W4 sentry and staging (`CAT:109-112`): SentryRotation, SentryClaim,
  EpochStaged, accepts, MatchDeleted. Alarm: unannounced rotation; claim before
  a winner or differing; staged state differs; accept before stagingBlock+P;
  MatchDeleted STEP or TIMEOUT against the operator class. Protects:
  stagingBlock+P. No execution. Here. The catalog says it is NOT independent of
  a bug every sling node shares, since the operator class is sling's state
  (`CAT:112`).
- W5 stuck settlement and due-action simulation (`CAT:113-116`): eth_call of
  stage/accept/timeout/recover, canStage, tournamentStanding. Alarm: winner
  unstaged N blocks; ROOT_FAILED; accept uncalled; due simulation reverts;
  EpochSealed older than allowance+P. Protects: liveness, freeze. No execution,
  but its stage simulation uses "the operator's stored proof" (node data unless
  a replay supplies it). Here (+ App for foreclosure state). This is what
  cartesi/dave#304 implements, minus the timeout/recovery simulations.
- W6 load projection (`CAT:117-120`): InputAdded count and bytes vs a measured
  per-input time and blocks to root closure. Protects: root join closure. No
  execution (a measured constant). Here (InputBox).
- W7 operator wallet (`CAT:121-124`): signer balance, nonce, receipts vs
  floor. Protects: every response. No execution. Chain only, operator signers.
- W8 self-health (`CAT:125-128`): heartbeat, two providers compared on head,
  finalized, input count and tournament event counters. Protects: the
  watcher's own validity. No execution. Here.
- R1 final-state replay (`CAT:129-132`): InputBox payloads checked against
  getInputHash, image rebuilt and checked against templateHash, MARCHID/uarch
  check; compare with every root CommitmentJoined, root winner, EpochStaged,
  SentryClaim, next EpochSealed initial hash. Alarm: replay matches no join or
  only a non-operator join (page about a week early); staged/claimed/settled
  differs; payload hash mismatch; replay lag past closure. Protects: root
  closure, then stagingBlock+P. Replay. Here (+ App for templateHash, optional).
  Not independent of libcartesi (`CAT:132`).
- R2 per-input audit (`CAT:133-136`): status, cycles, outputs, outputs tree vs
  TX-buffer root and EpochStaged; OutputExecuted. Alarm: terminal input,
  rejected deposit, outputs mismatch, executed output not replayed. Replay.
  Here + App (OutputExecuted).
- R3 step shadow (`CAT:137-140`): independent step proof on LeafMatchSealed
  and seam samples, eth_call to the deployed STF. Protects: min(deadlineOne,
  deadlineTwo). Replay (uarch). Here (STF).
- R4 exit-path dry run (`CAT:141-144`): anvil fork, impersonate guardian,
  foreclose, prove accounts drive, withdraw, refund. Replay plus forked
  transactions (never on the real chain). App.

Cascades (`CAT:32-93`) that bear on independence: a defect shared by every
sling instance makes all of them join the same wrong state, sentries agree, and
"nothing computes a reference state" (`CAT:34-38`); the honest node held out
lets a fabricated stageable claim win (`CAT:39-43`); an alarm that is not
independent can make the guardian foreclose a healthy app irreversibly, so the
catalog asks for a corroboration rule before foreclosure (`CAT:89-93`).

## What the node logs today that a detector would duplicate

ERROR conditions (policy in `docs/node-architecture.md:256-266`; paging rule
`:203-216`):
- Lost root, by case: eliminated, another class's child win, root won by
  another commitment with this node's final state, or DIVERGED with another
  final state (`cartesi-rollups/node/src/epoch_manager/mod.rs:606-641`).
- Root without a winner (`epoch_manager/mod.rs:592-596`).
- Won but terminal, cannot settle (`epoch_manager/mod.rs:491-496`).
- Input made the application terminal (`machine_runner/mod.rs:264-267`).
- Obligation already missed (`hero/actor.rs:264-267`).
- Planned call not landing for G; epoch not advancing for G
  (`epoch_manager/mod.rs:170-173, 343-346`).
- Machine advance failing for G (`machine_runner/mod.rs:128-131`).
- Reader failing for G; latest block older than G; finalized older than an
  hour (`blockchain_reader/mod.rs:350-353, 371-374, 386-389`).
- Unknown bond disposition (`epoch_manager/recovery.rs:154-157`).
- Worker exit, panics (`main.rs:18, 42`; `lib.rs:140, 152, 193`).
- Settle asserts panic on winner/staged mismatch with local material
  (`epoch_manager/mod.rs:480-487, 532-541`).

What only an outside observer sees (the node does not read it): `SentryClaim`,
`EpochStaged` and `SentryRotation` events (no consumer under
`cartesi-rollups/node/src` outside the harness trace), `getInputHash`,
`getTemplateHash`, `getGuardian`, the tournament event counters, other
signers' balances; and every signal while the node is dead, since its alarms
come from the absent process (`CAT:42`). Its sentry claim is its own state,
never the staged one (`epoch_manager/mod.rs:386-446`), and it claims only once
the root has a winner (`docs/epoch-lifecycle.md:193-194`). A replay that shares
the node's engine repeats the node's view, not an independent one.

## Open facts

1. Staging period in time: P is in blocks (`IDaveConsensus.sol:179`); the node
   knows no block time (`docs/node-architecture.md:215-216`). On L2s
   `block.number` may be the parent chain's (`blockchain_reader/mod.rs:271-279`),
   so blocks-to-seconds is per deployment and not in the repository.
2. Whether a plain big-machine run to yield (with reload on reject) yields
   exactly the boundary hash the node settles, in every terminal case
   (exception, unexpected yield, halt, overflow at 2^64-1). The doc says the
   closing ureset restores the base hash (`docs/computation-hash.md:135-150`);
   not checked against an independent run here.
3. Where the template image comes from: the chain holds only its hash.
   Reproducible build from source versus a published image is not settled in
   this repository.
4. How a detector learns the "operator class" (W2-W4, W7) without the node's
   database: a configured signer list is implied by the catalog, not specified.
5. Whether the stageable-fabrication lead (Tail value = a real RX_ACCEPTED
   state, proof reused from another epoch) works in the harness as is.
6. How a separate workspace binary is located from the node crate's
   `#[cfg(test)]` harness (no `CARGO_BIN_EXE_` across packages); cartesi/dave#304
   uses a relative path.
7. SentryClaim for a differing hash: settled, it is emitted
   (`DaveConsensus.sol:198-221`).

## Not verified

- Tournament.sol beyond the standing derivation and the join emit
  (`Tournament.sol:990-1011, 1431-1438`); Match/Clock internals not read.
- The rollups-contracts dependency is read from the main checkout's
  `cartesi-rollups/contracts/dependencies/cartesi-rollups-contracts-3.0.0-alpha.10/`,
  not this worktree; LibMachineValidityProof not read.
- cartesi/dave#304 read as a diff only; not run, line numbers are the PR's.
- The catalog's per-item evidence (MA/SI/SD/PC/CA/IM/OPS sections) not checked;
  only the critic sections were reduced.
- No test, build or chain query was run.
