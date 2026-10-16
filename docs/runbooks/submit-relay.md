# Submit relay qualification

This runbook qualifies a relay for the node's
`--blockchain-http-submit-endpoint`: it states what the relay must do and
why, measures a candidate with `cast` and a dedicated key, and keeps the dated
results. The node requires a relay only once one passes here
([node-architecture.md](../node-architecture.md), Mutation scheduling); until
then it recommends one and warns at startup without one. Rerun it when a
relay announces a change and before a release that recommends one.

No node code takes part. What the lane does with each answer a relay can give
is pinned by the tests in `cartesi-rollups/node/src/provider.rs`; what is
unknown is the relay, and `cast` observes it directly: receipts, the latest
nonce and the error text.

## Requirements

1. It does not land reverts. The lane reads no receipts, every contested step
   races among the honest nodes that share a commitment, and an adversary who
   orders transactions can land an identical copy of each honest step first.
   Each landed revert costs its gas, up to about 3.76M for a leaf proof
   ([L-06](../reviews/2026-10-13-prt-cyber-verification/FINDINGS.md)).
2. It reaches builders that cover most blocks. The response window G, 5
   minutes, covers one polling interval, the action's preparation and its
   inclusion ([dimensioning.md](../dimensioning.md), Tournament clock
   budgets); a relay that reaches few builders stretches the inclusion.
3. It frees a held nonce within G. Behind such a relay a transaction that can
   no longer succeed is never included, so it holds its nonce. The relay
   passes if it admits a different transaction at that nonce, which the
   lane's per-tick re-sign then is, or drops the held one within G. Each hold
   R delays the next action by about `R + polling interval + inclusion`, so
   it costs about `R + polling interval + inclusion - G` of the censorship
   budget C (node-architecture.md) once that is positive: a hold near G,
   such as Flashbots' default 25 blocks, already costs about 40 s each time.
   A hold with no bound disqualifies the relay.
4. It answers `eth_chainId` with the node's chain. The node asks every
   endpoint its chain at every start and does not start (exit 1) while one
   does not answer, so a send-only endpoint keeps it from starting.

## What the candidates document

Read 2026-10-15; page dates as shown. None of it is measured until the
Results table below has a row.

Flashbots Protect:

- [Settings guide](https://docs.flashbots.net/flashbots-protect/settings-guide)
  (updated 2026-05-12): reverted transactions do not land by default, and
  `canRevert=true` lands them; a transaction is retried for the next 25
  blocks and then dropped, and `blockRange=N` changes that window; the
  default endpoint forwards only to the Flashbots builder, `/fast` shares
  with every registered builder, and `builder=` adds builders while the
  Flashbots builder always receives the transaction.
- [Quick start](https://docs.flashbots.net/flashbots-protect/quick-start)
  (updated 2025-12-16): the Sepolia endpoint is
  `https://rpc-sepolia.flashbots.net/`; a zero priority fee is rejected.
- [Cancellations](https://docs.flashbots.net/flashbots-protect/cancellations)
  (updated 2025-12-16): a transaction may stay pending up to 6 minutes, which
  disagrees with the settings guide's 25 blocks (5 minutes at 12 s); a cancel
  is a transaction from the same sender at the same nonce, with `to` equal to
  `from` and empty data, never included on chain. It states no fee rule and
  nothing about a different transaction at that nonce.
- [Nonce management](https://docs.flashbots.net/flashbots-protect/nonce-management)
  and [stuck transactions](https://docs.flashbots.net/flashbots-protect/stuck_transactions)
  (both updated 2025-12-16): silent on same-nonce replacement. Protect counts
  what it holds in a pending nonce only for a signed request, so an ordinary
  endpoint's pending count does not see it.
- [Status API](https://docs.flashbots.net/flashbots-protect/rpc/status-api)
  (updated 2025-12-16): statuses PENDING, INCLUDED, FAILED, CANCELLED and
  UNKNOWN; a reverting transaction shows the simError
  `SimErrorExecutionReverted` while PENDING or FAILED.
- The proxy's source, [flashbots/rpc-endpoint](https://github.com/flashbots/rpc-endpoint)
  (`server/request_sendrawtx.go` on main, read 2026-10-15): a self-send with
  at most 2 bytes of data is a cancel, and a zero tip is rejected as
  "transaction underpriced: gas tip cap 0, minimum needed 1". Leads, not
  verified: a cancel resolves one hash per sender and nonce, an UNKNOWN hash is
  not resent for 5 minutes, and errors from behind the proxy reach the caller
  as a generic "internal error", which the lane logs at ERROR. Whether
  rpc.flashbots.net runs main is unconfirmed.

MEV Blocker:

- [Transaction endpoints](https://docs.mevblocker.io/reference/api/transaction-endpoints)
  and [send transactions](https://docs.mevblocker.io/how-to/transactions/send-transactions)
  (both updated 2025-12-18): `/noreverts` is the no-revert endpoint and stops
  broadcasting a transaction once it is no longer valid, and it is the only
  endpoint that documents a no-revert guarantee (name it explicitly in the
  URL); `softCancellations=true` works only on `/noreverts` and
  `/fullprivacy`. No retention time, no same-nonce rule and
  no testnet endpoint are documented.
- [Cancel a transaction](https://docs.mevblocker.io/how-to/transactions/cancel-transaction)
  (updated 2025-12-18): cancellation is best-effort; a soft cancel is a
  self-transfer at the same nonce.

So no candidate documents admitting a different transaction at a nonce it
holds, and only Flashbots documents a bound on the hold, which `blockRange`
configures.

## Configure

Keep the node's relay URL free of the knobs that break requirement 1:
Flashbots' `canRevert=true` and MEV Blocker's default `/fast`. For reach use
Flashbots' `/fast`; to shorten Flashbots' hold use `blockRange=N`. The node
sends no cancels, so it needs no cancellation setting. A shortened retention
costs a healthy transaction nothing: one the relay drops is signed again on
the next tick at a fresh quote.

## Procedure

Run `cast` from the nix devshell. Sign against the read endpoint and publish
to the relay, so the relay needs to serve `eth_sendRawTransaction` and
`eth_chainId`, as the node does.

Setup:

- Use a dedicated key in a cast keystore
  (`cast wallet new ~/.foundry/keystores relay-probe`), never the node's
  signer: the node owns its signer's nonces, and a probe would race them.
- Fund it with about 0.01 ETH on mainnet.
- Keep it idle: no other sender, and the latest and pending counts on the
  read endpoint equal. Watch the latest count during a run; the pending one
  does not see what the relay holds.
- cast asks for the keystore password at every signature; add
  `--password-file <file>` to the `cast mktx` in `send` below to skip it.

```bash
READ=<the node's --blockchain-http-endpoint>
RELAY=<the candidate URL>
ME=$(cast wallet address --account relay-probe)
cast chain-id -r "$RELAY"   # requirement 4: prints the node's chain id
cast nonce -r "$READ" -B latest "$ME"; cast nonce -r "$READ" -B pending "$ME"
```

The probe is a 13-byte contract that reverts exactly when `block.number`
exceeds its calldata word. Its initcode, `0x600d600a5f39600d5ff3`, returns
the runtime `0x6000354311600957005b5f5ffd` that follows it. Deploy it through
the read endpoint and check it:

```bash
PROBE=$(cast send -r "$READ" --account relay-probe --json \
  --create 0x600d600a5f39600d5ff36000354311600957005b5f5ffd | jq -r .contractAddress)
cast call -r "$READ" "$PROBE" "$(cast to-uint256 18446744073709551615)"  # succeeds
cast call -r "$READ" "$PROBE" "$(cast to-uint256 0)"                     # reverts

# send <nonce> <word>: sign at a fresh quote, publish to the relay, print the hash
send() {
  cast publish -r "$RELAY" --async "$(cast mktx -r "$READ" --account relay-probe \
    --nonce "$1" --gas-limit 50000 "$PROBE" "$(cast to-uint256 "$2")")"
}
```

Requirement 2, reach: send five `send "$N" 18446744073709551615` calls, one
at a time at the latest count `N`, and record the blocks from the send
(`cast block-number -r "$READ"`) to inclusion
(`cast receipt -r "$READ" <hash> blockNumber`).

Requirements 1 and 3, a held transaction at nonce `n`, the latest count:

1. Hold A, a transaction that can no longer succeed. If the relay accepts
   `send "$n" 0`, A is doomed from admission. Otherwise read the latest
   block `L` and `send "$n" $((L + 1))`: A is valid when sent and doomed from
   block `L + 2`. If A lands in `L + 1`, retry at the next count.
2. Then send B, `send "$n" 18446744073709551615`, every 30 s, as the lane
   re-signs a call each tick. When the relay answers that B is underpriced
   (including "replacement transaction underpriced"), re-sign it once at the
   same nonce with `--gas-price` and `--priority-gas-price` both at the
   quoted maximum fee, as the lane outbids, and record both answers. B must
   not be a self-transfer with empty data: Flashbots reads that as a cancel,
   which the node never sends.
3. Read the outcome from the latest count and the receipts of every hash
   sent at `n`:
   - A mined with status 0: requirement 1 fails.
   - B landing within a block or two of its first send (compare with the
     requirement 2 median, or read B's status on the relay): the relay admits
     a replacement, and requirement 3 passes.
   - Otherwise R is the time from B's first send to its inclusion, and
     requirement 3 passes when R is within 5 minutes.
4. Record each B send's error text, if any, and the verdict the lane would
   reach on it after its outbid retry (`judge` and `outbid` in
   `cartesi-rollups/node/src/provider.rs`).

A run in which A always lands first, or another sender moves the nonce, is
inconclusive, not a pass: retry it.

Variants to run, on mainnet with a small key: Flashbots Protect's default
endpoint and `/fast`, with `?blockRange=N` if the default holds longer than 5
minutes, and MEV Blocker `/noreverts`. Flashbots documents a Sepolia
endpoint, but the team found it does not include transactions (a lead, not
measured here), and MEV Blocker documents none, so a testnet run proves
nothing about either.

Results hold for one date: rerun when a relay announces a change. The runs
cost real gas, well under 0.01 ETH at ordinary fees.

## Results

| Date | Chain | Endpoint (no secrets) | 1. No reverts | 2. Median blocks to inclusion | 3. Frees a held nonce within G | Replacement admitted | R | B's error text and lane verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

No run is recorded yet ([todo.md](../todo.md), Node). Once one is, update the
candidate list in the node README. If no candidate frees a held nonce within
G, even with a retention setting, record R and price its draw on C.

## When a relay misbehaves

Behind a relay, the epoch manager's ERROR that a call has been planned for
some minutes without landing, naming a last verdict rather than a revert at
latest, means the relay holds, drops or refuses the sends. Its WARN that a
transaction got no answer from the submit endpoint means the relay is
unreachable, and its ERROR "failed to submit" carries the relay's rejection.
The page names the newest send at the stuck nonce, a call that still
succeeds at latest; the held transaction is an earlier send at that nonce,
often a step whose effect has since landed some other way. A hold looks like
the latest nonce staying at the named one while the named hash is UNKNOWN,
or PENDING without a simError, on the relay's status page
(`https://protect.flashbots.net/tx/<hash>` for Flashbots,
`https://protect-sepolia.flashbots.net/tx/<hash>` on Sepolia). The held
transaction's own hash is logged only at DEBUG ("submitted <label>
transaction <hash> at nonce <n>"): run with
`RUST_LOG=cartesi_sling_node::provider=debug` to keep it, and its status is
then PENDING with `SimErrorExecutionReverted`.

A relay that does not answer when the node starts keeps it exiting 1, and
its supervisor restarting it, until the relay answers.

Fallback: restart the node without `--blockchain-http-submit-endpoint`. Its
sends then go to the read endpoint's public pool, which mines a doomed
transaction as a paid revert and so frees its nonce, at the cost of the
reverted copies above. Return to the relay once it recovers.
