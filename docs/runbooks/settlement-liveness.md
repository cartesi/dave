# Settlement sender outage drill

Reproduce a finished Dave tournament that nobody stages or accepts, detect the
stalled phase independently of Sling, and restore progress with another caller.
This exercises the liveness assumption that someone submits settlement actions;
it does not demonstrate a consensus-safety defect.

## Reproduce

Use the existing checkout, its pinned Machine and Foundry tools, the generated
bindings, devnet bundle and echo image. `just doctor` checks those prerequisites;
follow its fixes rather than substituting a different deployment. Never point
this drill at a live application.

```sh
just doctor
just logged /tmp/settlement-liveness.log just test-settlement-liveness
```

The provider-free tests run via `just test-settlement-tools`, included in both
`just check` and CI. CI runs the chain-backed cases through its existing
`just test-node-harness` step; the combined command above is for local drills.

The four tests run real Sling workers, Cartesi Machine execution and deployed
contracts on fresh Anvil chains. The harness owns the block clock, so no
week-long sleeps or changes to production contract rules are needed. It stops
ticking the sender's workers to model their continued absence; it does not
exercise operating-system process signals or a running Sequencer.

| Case | Injection and evidence | Expected result |
| --- | --- | --- |
| Sender disappears before staging | Complete a healthy epoch, execute an input in the next epoch, join and close its tournament, then drop the sender. | The epoch remains unstaged as another input lands, and its outputs root remains invalid until recovery. |
| Sender disappears after staging | Stage with Sling, then drop the sender before acceptance. | The observer respects the normal staging wait, then detects eligible acceptance that nobody submits. |
| Normal wait, failed root, foreclosure | Observe an open tournament, allow a root with no participants to fail, then foreclose the disposable application. | Each condition has its own verdict rather than a generic settlement timeout. |
| Terminal winner | Execute a halting guest, defend its true commitment and close the root. | The observer reports an unstaged winner, but a staging simulation rejects its proof; no automatic recovery transaction is sent. |

In the first case a fresh runner, with its own data directory, replays L1 and
checks the winner commitment and final state. Another account stages its proof
and accepts. The test checks successful receipts, the newly valid outputs root,
the next epoch including the input received during the outage, and that the
original sender did not perform that recovery. The fresh runner still shares
Sling's implementation and emulator: this is not cross-implementation assurance.
The fixture proves output-root eligibility, not a token payout or emergency exit.

## Detect

`script/settlement-watch.py` is a read-only observer requiring Python 3 and
Foundry `cast` on PATH. Use a different failure domain and, where practical, an
independent trusted RPC from the sender. Pin the deployed contract release:
the observer uses this checkout's static `DaveConsensus` ABI, not arbitrary
historical or future return layouts.

Example for an operator-configured deployment:

```sh
python3 script/settlement-watch.py \
  --rpc-url "$OBSERVER_RPC_URL" \
  --chain-id "$APP_CHAIN_ID" \
  --consensus "$DAVE_CONSENSUS_ADDRESS" \
  --state-file /var/lib/dave-observer/settlement.json \
  --grace-blocks "$SETTLEMENT_GRACE_BLOCKS" \
  --max-head-age-seconds "$MAX_HEAD_AGE_SECONDS"
```

The default view is `finalized`; `--block latest` is used only in the devnet
drill. Choose the head-age limit to include the chain's normal finality lag and
the operational failure allowance. The test explicitly relaxes it because its
reproducible timestamps predate wall time. Choose the block grace to accommodate
submission, fees, inclusion and observation latency. Four blocks is a test
fixture value, not a mainnet recommendation.

Run this command periodically, retaining the same state file. A phase is stalled
only after it has been observed unchanged across the configured number of chain
blocks. The first observation starts the allowance; a restart with the state
file retained does not reset it. Epoch, winner or phase changes start a new
allowance. Deleting the state file delays detection. Overlapping invocations
are refused. Do not share one state file between deployments or observers.

All contract views are pinned to one block number and that block's hash is
rechecked before publication. The chain ID and ABI shapes are checked. Stale or
future head timestamps, unavailable RPC, malformed responses, regressed heads,
invalid state files and overlapping runs produce observation errors, not a
healthy verdict. A different hash at the same observed height also requires
investigation; finalized history is assumed not to reorg.

| Exit | Verdict | Response |
| --- | --- | --- |
| 0 | `waiting`, `pending`, or `foreclosed` | Interpret the phase; exit zero does not certify execution correctness or overall application health. |
| 1 | `observation_error` | Restore observation and preserve the last successful report; do not infer that settlement is progressing. |
| 2 | `stalled` | Investigate an unchanged unstaged winner or eligible acceptance beyond the allowance. |
| 3 | `investigate_root_failure` | Escalate a finished root without a winner; another staging caller cannot repair it. |

JSON includes the epoch, phase, winner, staged state, observed block/hash, head
timestamp, observation time and elapsed blocks. The observer has no signing key
and sends no transactions. `winner_unstaged` does not prove a stageable or correct
result; terminal and faulty winners require different responses.

An external supervisor must alert on missing invocations and persistent exit 1,
as well as exit 2/3. A file left by a dead observer is not a fresh observation.
Choose poll, persistence and escalation thresholds with the on-call team. No
production paging integration or notification latency is established by this
drill. The observer deliberately does not classify a long-running dispute as
stalled: match-clock/cleanup monitoring is separate work.

## Operator wrapper

The tools remain separate: `settlement-watch.py` observes, while
`settlement-recover.py` exports replay material or prepares and simulates one
transaction. `settlement-operator.py` combines them interactively.

First independently replay and check the incident epoch in a fresh Sling state
directory. Export its settlement material:

```sh
python3 script/settlement-recover.py --action export \
  --state-dir "$VERIFIED_REPLAY_DIR" --epoch "$INCIDENT_EPOCH" > evidence.json
```

Export opens SQLite read-only and does not replay or certify the source. The
file contains deployment identity, epoch, commitment, final state, outputs root,
and the three machine leaf proofs (`data_block` and `siblings`). Do not replace
independent verification with a copy of the failing sender's database.

Then run:

```sh
python3 script/settlement-operator.py \
  --rpc-url "$OBSERVER_RPC_URL" --consensus "$DAVE_CONSENSUS_ADDRESS" \
  --chain-id "$APP_CHAIN_ID" --state-file "$OBSERVER_STATE_FILE" \
  --grace-blocks "$SETTLEMENT_GRACE_BLOCKS" \
  --max-head-age-seconds "$MAX_HEAD_AGE_SECONDS" \
  --evidence evidence.json --from "$RECOVERY_ADDRESS" --account "$FOUNDRY_ACCOUNT"
```

The wrapper checks once, prints the report, and on a stall asks whether to
prepare the available action. It verifies the evidence against a fresh latest
view and simulates the exact transaction. It then asks separately whether to
submit with the configured Foundry keystore account. Only the exact answer `yes`
proceeds; EOF and the default decline. Immediately before submission it checks
and simulates again, refusing changed epochs, result mismatches and unavailable
actions. The observer's default finalized view remains suitable for monitoring;
recovery checks latest to avoid sending an already-completed action.

Without `--account`, the wrapper prepares and simulates only. `--unlocked` is
available for the local devnet's RPC-managed accounts; it is not a default
signing configuration. No private key is passed on the command line. A missing
proof, refused simulation, mismatching replay or observation failure prevents
submission. The tool does not foreclose applications or decide why nodes failed.

Each invocation offers at most one transaction. After staging, run the observer
again; acceptance is offered only after it becomes eligible and outlasts its
own grace. The wrapper reports a submitted transaction hash, not confirmation.
Verify its receipt and the expected epoch transition before closing the incident.
For unattended monitoring, use the read-only tool and supervisor described above;
this interactive wrapper is an operator response, not an automatic keeper.

Standalone preparation is also available, without any submission:

```sh
python3 script/settlement-recover.py --action stage \
  --rpc-url "$OBSERVER_RPC_URL" --evidence evidence.json --from "$RECOVERY_ADDRESS"
```

Use `--action accept` once acceptance is eligible. Both actions emit the unsigned
transaction only after verification and simulation. The devnet test exports
material from the fresh runner, feeds both confirmations to the wrapper and
checks its actual staging/acceptance receipts through a different account.

## Handle

1. Check deployment identity, observer freshness, foreclosure and the phase
   again through a trusted RPC. Preserve reports, node logs and transaction
   receipts before changing anything. Check wallet balance, nonce conflicts,
   submission RPC errors and already-pending settlement transactions.
2. Independently replay the sealed input bounds from a trusted template or
   checkpoint. Compare the resulting final state and outputs root with the
   on-chain result. For staging, also verify the winning commitment and build
   the required machine-validity proof. A contract accepting a proof does not
   establish that the winning computation was honest.
3. If the result agrees and is stageable, restore the sender or have another
   funded caller submit `stageTournamentResult(epoch, proof)` and, once
   eligible, `acceptStagedTournamentResult(epoch)`. Simulate each call first,
   recheck epoch/result identity immediately before submission and verify the
   receipt and next `EpochSealed` afterwards. Do not race an existing pending
   sender transaction without understanding its nonce and inclusion status.
4. If the result disagrees, or replay reaches a terminal machine state, do not
   stage or accept it. Keep the honest defense alive where relevant and invoke
   the application's guardian incident procedure. A sender outage alone is not
   grounds for irreversible foreclosure.
5. Verify that the new epoch advances, the expected outputs root is valid, and
   actual withdrawal execution succeeds for the production application. Restore
   observation and sender supervision; retain the evidence and diagnose why the
   original sender remained unavailable.

The reproduced recovery is permissionless caller replacement, not an automatic
keeper that trusts whichever result won. The operator wrapper combines a watch-only alert with independently verified,
explicitly confirmed manual recovery.

## Remaining deployment checks

- Run with the production application, its account/output format and a real
  Sequencer kept running during the sender outage; measure soft confirmations,
  L1 inclusion and actual ERC-20 withdrawal balances separately.
- Rehearse notification and response with the actual on-call operator and
  validate the chosen observation/grace periods against provider and fee delays.
- Exercise a real process outage and a restored sender, including pending
  transactions, rather than only the harness's deterministic worker stoppage.
