# Card: chain access and the transaction lane

Scope: `cartesi-rollups/node/src/provider.rs` (lines 1-901 production, less
the `#[cfg(test)] submit` at 451-466: about 885), `cartesi-rollups/node/src/chain.rs`
(lines 1-250, less the test-only `latest_block_number` at 67-76: about 240),
`cartesi-rollups/node/src/tournament/sender.rs` (194, no tests). Read for
context: `args.rs`, `blockchain_reader/mod.rs` (AddressBook), `kms.rs`,
`epoch_manager/{mod,recovery}.rs`, `tournament/{reader,observer}.rs`,
`hero/actor.rs`, `lib.rs`.

## Possible correctness bug

None met. Traced: nonce base, skip-on-revert nonce reuse, outbid path,
verdict classification, bisection midpoint arithmetic (`chain.rs:235`), and
every pinned read listed below.

## Owns

### What lives where (question 1)

`provider.rs`, in file order: signer loading, `SignerSource` and key-source
rules (`provider.rs:44-159`); client construction, `REQUEST_TIMEOUT` (shared
with KMS, `kms.rs:47`) and `create_client` (`provider.rs:163-192`); retry
layer, `RateLimitOnly` (`provider.rs:197-233`); URL redaction
(`provider.rs:240-307`); provider constructors and chain check
(`provider.rs:313-350`); `LaneRequest` and the gas rule
(`provider.rs:355-398`); `TransactionLane` with `submit_wave`, the balance
check `check_funding`, `gas_limit`, `outbid`, `validate`, nonce, `sign`
(`provider.rs:417-699`); verdict types (`provider.rs:703-747`); `judge`,
`reserve`, `replacement_fees`, `normalize_fees` (`provider.rs:750-831`);
error classification, `is_revert`, `describe_revert`,
`classify_submission_error` (`provider.rs:838-900`).

`chain.rs`: `ChainHead` (`chain.rs:26-42`), `MAX_FILTER_ADDRESSES`
(`chain.rs:48`), and the `Chain` facade (`chain.rs:51-247`): head sampling
(`latest_head`, `finalized_head`, `tagged_head`), head ages (`latest_age`,
`finalized_age`), and log fetching (`raw_logs_from_any`, `decoded_logs`,
`decoded_logs_from_any`, `decoded_logs_in_order`, `logs_bisecting`).

Not in either: the address book and deployment discovery live in
`blockchain_reader/mod.rs:26-285` (`AddressBook`) and `args.rs:89-160`
(`discover_deployed_tournament`); request building lives in `sender.rs`
(Tournament verbs), `epoch_manager/mod.rs:443-551` (settlement) and
`epoch_manager/recovery.rs:193` (refunds).

Verdict: the split is roughly real (`provider.rs` = transport, signer and
write side; `chain.rs` = read-side policy, `chain.rs:4-8`), but `provider.rs`
also owns the read side's transport policy (timeout, retry, redaction), and
the name hides the lane. A reader looking for "the lane" finds it only by the
type name or the runbook (`docs/runbooks/submit-relay.md:11-12,179-180`); the
architecture doc's lane section (`docs/node-architecture.md:721-809`) never
names the file. `sender.rs` is not part of the lane: it is a set of pure
calldata builders for the nine Tournament verbs (`sender.rs:25-194`) that emit
`LaneRequest`s, called from `hero/actor.rs:358-` and `hero/actor.rs:331-341`.

### State it owns

- The lane holds no mutable state. `TransactionLane`'s five fields
  (`provider.rs:419-423`: read provider, submit provider, signer address,
  chain id, wallet) are set in `new` (`provider.rs:427-442`) and never
  written. What survives a tick is process plumbing only: reqwest's
  connection pools inside each provider, and whatever the boxed signer keeps
  (alloy's `AwsSigner` holds its fetched public key; not verified in alloy
  source). The one cross-tick lane-adjacent state is the manager's, not the
  lane's: `EpochManager.planned` (`epoch_manager/mod.rs:40-42`), the
  first-planned instant per call for the G page (`epoch_manager/mod.rs:156-176`).
- Decisions: nonce base, fee quote, gas limit, the one price retry, and the
  verdict for each slot.

### Signer (question 7)

Chosen by the clap subcommand (`args.rs:280-317`), prepared from local sources
before any network call (`provider.rs:54-90`, `args.rs:419`), turned into a
`Box<dyn TxSigner<Signature>>` wallet (`provider.rs:97-120`); KMS asks AWS for
its key with EIP-155 chain id (`kms.rs:13-21`), timeout `REQUEST_TIMEOUT`
(`kms.rs:44-50`). The lane assumes: (a) exclusive use, stated in docs only
(`docs/node-architecture.md:801`, node `README.md:106-107`); nothing in code
enforces it (the state-dir lock, `args.rs:499`, guards the data directory, not
the key); (b) nothing about nonce determinism in code: it hashes the raw bytes
it signed (`provider.rs:695-696`), so a random-k signer only turns
`AlreadyKnown` into replacement verdicts, as the doc argues
(`docs/node-architecture.md:746-750`).

## Takes

### Every chain read (question 4)

| Read | Tag or pin | Caller |
| --- | --- | --- |
| `eth_chainId` per endpoint | none | `provider.rs:331-337` via `args.rs:425-435` |
| finalized head (sample for watermark) | finalized | `args.rs:452-456` |
| AddressBook: app `getOutputsMerkleRootValidator`, `getDeploymentBlockNumber`; consensus `getApplicationContract`, `getInputBox`, `getTournamentFactory`, `getDeploymentBlockNumber` | latest (no `.block`) | `blockchain_reader/mod.rs:75-127` |
| epoch-0 `EpochSealed` log | by number, the consensus's deployment block, raw provider (no `Chain`) | `blockchain_reader/mod.rs:262-270` |
| `getSentryId` (startup log) | latest | `args.rs:166-169` |
| factory `tournamentLevelCount`, `tournamentParameters`, `stateTransition`; step `CM_MARCHID`, `UARCH_PRISTINE_STATE_HASH` | latest | `args.rs:98-149` |
| seed: `getCurrentSealedEpoch`, `getLastFinalizedMachineMerkleRoot` | by number at a fresh finalized sample | `blockchain_reader/mod.rs:171-207` |
| reader: finalized head | finalized | `blockchain_reader/mod.rs:419` |
| reader: `getNumberOfInputs`, `getCurrentSealedEpoch` | by number at F | `blockchain_reader/mod.rs:664-677` |
| reader: `EpochSealed`, `InputAdded` logs | range to F (number) | `blockchain_reader/mod.rs:523-531,566-574` |
| reader: head ages | latest, finalized | `blockchain_reader/mod.rs:370,383` |
| tournament reader: heads | finalized, then latest | `tournament/reader.rs:88,91` |
| tournament logs per level | range to F, then F+1..H (numbers; hash checked at the head) | `tournament/reader.rs:239-241` |
| root `tournamentDescriptor` | finalized hash | `tournament/reader.rs:128`, `observer.rs:118-121` |
| `tournamentStanding` (16 at a time) | latest hash; Solid hash for a join | `hero/actor.rs:302,221`, `observer.rs:158-178` |
| `classifyMatchTimeout` + one of `bisectingMatch`/`readyToSealMatch`/`sealedMatch` | the observation's hash | `hero/context.rs:115`, `observer.rs:237-291` |
| `bondValue` | action head hash (Solid for a join) | `hero/actor.rs:242,375`, `observer.rs:130-136` |
| manager: finalized head | finalized | `epoch_manager/mod.rs:191` |
| `isForeclosed` | Hero head hash; then finalized hash | `epoch_manager/mod.rs:213-217,319-323` |
| `getSentryId`, `canAcceptStagedTournamentResult`, `hasSentryClaimedInEpoch`, `canStageTournamentResult` | Hero head hash | `epoch_manager/mod.rs:396-431,456-460,518-522` |
| `NewInnerTournament` logs (recovery walk) | range to F (number) | `epoch_manager/recovery.rs:82-88` |
| `bondRecovery` | finalized hash; then latest hash for candidates | `epoch_manager/recovery.rs:130-133,179-186` |
| lane: nonce | latest | `provider.rs:667-672` |
| lane: fee quote | alloy default (fee history; tag not verified) | `provider.rs:479-484` |
| lane: `eth_estimateGas` | latest | `provider.rs:585` |
| lane: balance | latest | `provider.rs:557-562` |

Every worker builds its own read provider, so the reader and the manager do
not share a connection pool (`lib.rs:93,106-108`, `args.rs:390-392`); the Hero
reuses the manager's `Chain` (`epoch_manager/mod.rs:571`).

### Runtime coupling to the contracts (question 5)

| Contract (crate) | Calls, writes, events, errors |
| --- | --- |
| `IApplication` (published `cartesi-rollups-contracts`) | `getOutputsMerkleRootValidator`, `getDeploymentBlockNumber` (`blockchain_reader/mod.rs:76,122`); `isForeclosed` (`epoch_manager/mod.rs:214,320`) |
| `IInputBox` (published) | `getNumberOfInputs` (`blockchain_reader/mod.rs:667`); event `InputAdded` (`:567`) |
| `DaveConsensus` (`cartesi-dave-contracts`) | `getApplicationContract`, `getInputBox`, `getTournamentFactory`, `getDeploymentBlockNumber` (`blockchain_reader/mod.rs:85,94,99,107`), `getCurrentSealedEpoch` (`:183,673`), `getLastFinalizedMachineMerkleRoot` (`:198`), `getSentryId` (`args.rs:167`, `epoch_manager/mod.rs:397`), `canAcceptStagedTournamentResult`, `hasSentryClaimedInEpoch`, `canStageTournamentResult` (`epoch_manager/mod.rs:413,428,457,519`); writes `submitSentryClaim`, `stageTournamentResult`, `acceptStagedTournamentResult` (`:444,503,549`); event `EpochSealed` (`blockchain_reader/mod.rs:263,524`); errors (`provider.rs:849`) |
| `MultiLevelTournamentFactory` (`cartesi-prt-contracts`) | `tournamentLevelCount`, `tournamentParameters`, `stateTransition` (`args.rs:99,116,132`); table checked against `Structure::PRODUCTION` (`args.rs:52,108`) |
| `CartesiStateTransition` (`cartesi-prt-contracts`) | `CM_MARCHID`, `UARCH_PRISTINE_STATE_HASH` (`args.rs:136,142`), compared with the linked emulator's `CM_MARCHID` (`args.rs:66`) and `Machine::uarch_pristine_hash` (`args.rs:150`); errors (`provider.rs:851`) |
| `Tournament` (`cartesi-prt-contracts`) | `tournamentDescriptor`, `bondValue`, `tournamentStanding`, `classifyMatchTimeout`, `bisectingMatch`, `readyToSealMatch`, `sealedMatch` (`observer.rs:119,132,162,238,254,268,282`), `bondRecovery` (`recovery.rs:131,183`); writes: nine verbs (`sender.rs:44-191`), `tryRecoveringBond` (`recovery.rs:193`); events folded `CommitmentJoined`, `MatchCreated`, `MatchAdvanced`, `LeafMatchSealed`, `NewInnerTournament`, `MatchDeleted`; decoded and dropped `StandingChanged`, `PartialBondRefund`, `BondRecovered`; any other topic fails the harvest (`tournament/reader.rs:398-479`); `NewInnerTournament` again in recovery (`recovery.rs:83`); errors (`provider.rs:852`) |

### Bindings (question 6)

The node depends on `cartesi-dave-contracts`, `cartesi-rollups-contracts`,
`cartesi-prt-contracts` (`cartesi-rollups/node/Cargo.toml:15-18`). Two are
workspace paths with generated, gitignored sources
(`Cargo.toml:38-39`; `cartesi-rollups/contracts/bindings-rs/src/lib.rs:3`,
`prt/contracts/bindings-rs/src/lib.rs:3` include a generated `contract`
module) made by `forge bind` (`script/contract-bindings.sh:71-72`) with
selections `CartesiStateTransition|MultiLevelTournamentFactory|Tournament`
and `I?DaveConsensus|I?DaveAppFactory` (`script/contract-bindings.sh:22,26`),
through `just bind` (`justfile:119-121`). `cartesi-rollups-contracts` is the
published crate pinned `=3.0.0-alpha.10` (`Cargo.toml:49`); production uses it
only for `IApplication` and `IInputBox` (`blockchain_reader/mod.rs:21-23`,
`epoch_manager/mod.rs:199`); `inputs::EvmAdvanceCall` appears only in tests
(`storage/rollups_machine.rs:371,386`).

## Gives

### The lane, step by step (question 2)

`submit_wave` (`provider.rs:474-545`), called once per tick by the manager
(`epoch_manager/mod.rs:156`):
1. Validate every request: no nonce, no fees, `from` absent or the signer
   (`provider.rs:475-477,646-665`).
2. Nonce base = mined count at latest (`provider.rs:478,667-672`).
3. One EIP-1559 quote per wave, normalized so max fee >= tip
   (`provider.rs:479-484,828-831`).
4. Per slot, unless the request pins gas: estimate at latest from the signer
   (`provider.rs:583-585`). Ok: `gas_limit_for` = estimate + max(estimate/2,
   650,000) (`provider.rs:380,391-392`), capped at 2^24 when the estimate fits
   under it (`provider.rs:366,393-397`). Revert (message contains "revert",
   `provider.rs:838-842`): report `Reverts` with the decoded reason, take no
   nonce (`provider.rs:493-501`). Any other failure: 15,000,000
   (`provider.rs:360,592-595`).
5. Sign at `nonce` with the quote (`provider.rs:511-514,675-698`); a sign
   error aborts the rest of the wave (`?`, `provider.rs:514`).
6. Send to the submit endpoint in order (`provider.rs:515`).
7. Price retry: if the pool says replacement underpriced or bare underpriced
   and the quote's tip is below its max fee, re-sign once with tip = max fee
   (`provider.rs:516-527,603-644,821-826`).
8. Verdict (`provider.rs:750-803,865-900`): Submitted (DEBUG); AlreadyKnown;
   ReplacementUnderpriced -> `Underpriced` (TRACE, waits); NonceTooLow ->
   `Stale`; transport error -> `Unanswered` (WARN); bare underpriced after the
   retry, or anything else -> `Failed` (ERROR). A verdict never aborts the
   tail; the nonce advances for every sent slot (`provider.rs:541`).
9. Balance check after the sends (`provider.rs:543,553-575`).

Promise to the manager: one `SendReport` per request in order, with a revert
reason for a skipped call (`provider.rs:703-711`); the manager pages a call
planned for G (`epoch_manager/mod.rs:157-176`).

## Invariants

1. The lane alone sets nonce, fees and sender: `validate`
   (`provider.rs:646-665`). Breaks: a pinned nonce could collide in a wave.
2. Consecutive nonces from latest; a call reverting at latest takes no nonce
   (`provider.rs:487,493-502,541`; test at `provider.rs:1654`). Breaks: a gap
   stalls the tail.
3. The gas limit never lifts an admissible estimate past EIP-7825, and the
   fallback is admissible (`provider.rs:367,391-398`; tests at
   `provider.rs:1197,1217`; pairing measured in `harness/tests.rs:651-685`).
   Breaks: out-of-gas on the pairing branch, or an inadmissible transaction.
4. Pool verdicts never abort the wave (`provider.rs:516-541`; test at
   `provider.rs:1460`).
5. No error quotes an endpoint URL (`provider.rs:240-307`; tests at
   `provider.rs:1104,1158`).
6. Every endpoint serves the configured chain, terminal otherwise
   (`provider.rs:341-350`; test at `provider.rs:1124`).
7. Decoded logs come in chain order; a log without a block number fails the
   call (`chain.rs:179,194-203`).
8. Only ranges wider than one block split; a one-block failure fails the call
   (`chain.rs:233-241`): one left spine of queries per persistent error.
9. One owner per process: `&mut self` on `submit_wave`
   (`provider.rs:414-416,474`), though nothing is mutated; across processes,
   nothing in code.

## Concurrency and crash consistency

The lane runs only inside the epoch manager's task (`lib.rs:103-117`);
signing and sends are serial (`provider.rs:489-542`). Reads elsewhere use
`buffered(16)` (`observer.rs:42,178`, `recovery.rs:137`). kill -9 at any point
in a wave leaves some transactions pooled and nothing local: restart rebuilds
the lane from flags (`args.rs:394-404`), the next tick re-derives the wave and
re-signs from the latest nonce; already-pooled slots come back as
AlreadyKnown or take the price retry (test `restart_is_invisible_to_the_pool`,
`provider.rs:1690`). In-memory loss costs: the manager's `planned` timers
(`epoch_manager/mod.rs:42`) restart, delaying a G page by up to G; nothing
lane-side.

## What it knows about its neighbours

- `describe_revert` imports three contracts' error enums
  (`provider.rs:849-859`): the only reason the transport-and-lane module
  depends on contract bindings. Needed for operator-readable pages; a leak in
  placement, not in content.
- `sender.rs` takes `&DynProvider` only to instantiate a contract and call
  `into_transaction_request` (`sender.rs:33,43-51`); no request is sent.
  A leak of the provider into pure builders.
- `chain.rs` exposes `provider()` for pinned point reads
  (`chain.rs:60-65`), so policy for those reads (pinning, concurrency) lives in
  each caller, not here; the module doc's "one home for read-side provider
  policy" (`chain.rs:4-8`) covers logs and heads only.
- `MAX_FILTER_ADDRESSES` is re-used by the reader's tests and the live test
  (`tournament/reader.rs:497`, `tests/live_rpc.rs:25`).

## Boundary verdict

The lane boundary is real: it is the single owner of the signer's nonce
sequence and fee policy, enforced by `validate` and by single ownership in the
manager's task, and it is the only code that turns intent into signed bytes.
It carries no crash state by design, which matches "state whose loss costs one
tick must carry no correctness machinery". The `provider.rs`/`chain.rs` file
boundary is partly historical: transport configuration for reads sits with the
write lane, and deployment discovery, which is the node's whole startup
coupling to the contracts, sits in the ingestion worker's module and in
`args.rs`.

## Docs versus code

- Lane statelessness (`docs/node-architecture.md:721`): confirmed
  (`provider.rs:419-423`).
- "For every submission ... a fresh EIP-1559 fee estimate"
  (`docs/node-architecture.md:721-723`): one quote per wave, shared by its
  slots (`provider.rs:479-484`). Wording, not behavior.
- Sort key: doc says block, transaction and log index
  (`docs/node-architecture.md:526-528`), matching `chain.rs:179,203`; the
  tournament reader keeps its own sort by (block, log index)
  (`tournament/reader.rs:377-383`) over `raw_logs_from_any`. Equivalent, two
  homes.
- Duplicates of the read mechanics (question 8): bisection exists once
  (`chain.rs:225-246`); the 100-address chunk loop twice in the same file
  (`chain.rs:142-146,175-180`); a second, unbisected log path in
  `AddressBook::initial_hash` (`blockchain_reader/mod.rs:262-270`, one block,
  harmless). Outside the node, the Lua client sorts its logs
  (`prt/client-lua/player/semantic_reader.lua:541`) and fetches ranges without
  splitting (`semantic_reader.lua:812-824`); the e2e reader calls
  `eth_getLogs` through cast (`test/e2e/rollups/dave/reader.lua:84`). No other
  bisection found in the repository.
- `SendVerdict::Underpriced` means "waits behind a pending replacement"
  (`provider.rs:773-778`) while `SubmissionErrorKind::Underpriced` means a
  bare underpriced that ends `Failed` (`provider.rs:740-743,794-800`): one word,
  two meanings.
- "The signer must be exclusive" (`docs/node-architecture.md:801`) has no
  code home.
- The lane's file is not named in its doc section
  (`docs/node-architecture.md:669-809`), only in the RPC section (`:482`).

## Defended mechanisms

Question 3: the July 2026 simplification doctrine (nonce from latest mined,
tolerant classification, one write per tick; I found no copy of it under
`docs/`) against today's lane:
- Waves, not one write per tick: recorded, `docs/node-architecture.md:689-691`
  (Hero action, settlement and refunds in one batch); refunds before the next
  epoch at `:696-699`.
- Max-tip retry: recorded, `docs/node-architecture.md:766-782`,
  `provider.rs:811-826`. Argument: a fresh quote moves the max fee but not the
  market tip, and geth replaces only on +10% of both, so without the retry a
  transaction the base fee outran blocks its nonce; costs a non-refunded
  premium. Test `provider.rs:1237,1318`. Defended.
- Balance check: recorded, `docs/node-architecture.md:801-809`,
  `provider.rs:547-552`. Argument: behind a private relay an unaffordable
  batch is accepted silently; advisory only, one read. Defended.
- `Unanswered` verdict: recorded, `docs/node-architecture.md:261-263,744-746`,
  `provider.rs:728-731`. Argument: a send without a JSON-RPC answer may be
  held, so it is WARN and resent, not ERROR. Changes only the log level.
  Defended.
- 15M fallback: recorded only in code, `provider.rs:577-581` ("a flaky
  endpoint must not hold back a dispute action"); the doc states it without
  reason (`docs/node-architecture.md:735-736`) and prices its reserve cost
  (`:807-808`). Consistent with P1 (holding a step is the stall). Defended.
- Revert decoding against three ABIs: recorded,
  `docs/node-architecture.md:736-741`; it feeds the G page's reason
  (`epoch_manager/mod.rs:161-162`). Not sending a revert is the substantive
  part (saves gas, `:736-737`); the decoding is operator text, about 15 lines.
- Bisection on any error (`chain.rs:213-224`, `docs/node-architecture.md:519-525`):
  provider codes overlap, so splitting is the one uniform remedy, bounded at
  log2(range) + 1. Defended.

## Candidate changes

1. Move the lane (`provider.rs:352-900`) into its own module (`lane.rs`),
   leaving `provider.rs` as client, retry, redaction and signer loading.
   Premise: findability. Buys a named home for a concept the doc treats as
   one. Costs churn in `args.rs`, `epoch_manager`, harness and the runbook's
   pointers (`submit-relay.md:11-12,179-180`). Reopen: none needed. Medium.
2. Move `AddressBook` and `discover_deployed_tournament` into one
   deployment-discovery module next to `chain.rs`. Premise: it is startup
   coupling, not ingestion (`blockchain_reader/mod.rs:26-285`,
   `args.rs:89-182`). Buys one place listing the node's contract surface.
   Costs moves only. Low-medium.
3. Rename `SendVerdict::Underpriced` (e.g. `WaitsBehindPending`). Evidence
   above. Buys removal of a naming trap; touches the manager's page text and
   the runbook's verdict column (`submit-relay.md:197`). Medium.
4. Not worth it alone: drop the provider parameter from `sender.rs` builders
   (encode with `SolCall::abi_encode`), and share one chunk loop in
   `chain.rs:142-146,175-180`. Pure tidying, nine signatures. Low.
5. Remove the 15M fallback, skipping the slot. Not worth it: an estimation
   outage would hold every dispute step, the P1 stall
   (`docs/node-architecture.md:137-150`).
6. Remove the max-tip retry. Not worth it (Defended); reopens only if a
   required relay documents same-nonce admission.
7. Remove `log_sentry_role` (`args.rs:162-182`), an operations log, one read
   at latest. Not worth it: 20 lines, reason recorded (`args.rs:162-164`).

Question 9, operations features met: `log_sentry_role`; head-age pages
(`chain.rs:84-107`, `blockchain_reader/mod.rs:364-399`;
`docs/node-architecture.md:216-227`); the balance check; revert-reason text;
the startup relay warning (`args.rs:437-445`); URL redaction and the redacted
config line (`args.rs:349-382`). All report around validation obligations;
none changes what the node sends.

## Not verified

- alloy internals: the block tag of `estimate_eip1559_fees`, whether
  `AwsSigner` caches its key, whether `PrivateKeySigner` signs with RFC 6979.
- The harness's "fails on any honest skip" beyond `harness/mod.rs:610`.
- `hero/context.rs` beyond line 120 and the manager's `track_planned`.
- Behavior of real pools and relays; the lane tests use anvil and mocks.
