# Provider requirements

Status: open, written 2026-10-06 as a brief for a later campaign; linked
from [`docs/todo.md`](../todo.md). When it lands, the envelope moves into
the node README's operator notes, its reasoning into
[`dimensioning.md`](../dimensioning.md), and this file is deleted.

## Why

The node assumes a reasonably behaved RPC provider: something has to give,
and no client outlasts an endpoint that stops answering. "Reasonable" is
not written down, so an operator cannot size a plan against it, and the
node's read load is not dimensioned the way its clocks and bonds are. The
goal is a measured, supported workload envelope: input rate and volume,
live tournament population, provider capacity (request rate, `eth_getLogs`
range and response size, latency), and the action latency that results.

## Two regimes

- Steady state: the reads follow inputs. Anyone may add inputs to any
  application, and `InputBox.addInput` accepts contract calls, so a wrapper
  can build or reuse a large payload from little calldata and the event
  still carries all of it. The bound therefore comes from execution costs,
  not calldata pricing: about 8 gas per byte of log data, plus each input's
  storage write (about 22,000 gas), copying and hashing. These give the
  emitted bytes and inputs per block (leads to measure); direct calldata
  submission is one workload, not the upper bound. How to dimension an
  application's ordinary input size and rate is open.
- Disputes: each Sybil costs a join bond, and the honest work grows only
  logarithmically with the Sybils at each level, about log^L(N) over `L`
  levels. Sequential arrivals make it linear only in a bounded regime: a
  tournament closes to joins at its start plus its allowance, at most one
  commitment waits unpaired, and each match takes time, so only the Sybils
  that fit the join window meet the survivor one by one; the rest pair with
  each other and reach it through a bracket (dispute-game.md, "Delay, work,
  and bracket shape"). That regime's size per level is a lead to compute.
  The open question is whether the reads follow that work. Each tick the
  tournament reader extends every live tournament in the tree, the Sybils'
  own matches included, reading each level of the tree with one
  multi-address `eth_getLogs` per 100 tournaments, in sequence
  (`tournament/reader.rs`). The Hero then reads the standing of every live
  tournament, and the recovery scan the disposition of every open one.
  Resolved matches and their children are dropped, so the reads track the
  live population, which at a dispute's start can be linear in the Sybils.

## What to measure

- The read load per tick, against the Sybil count up to the dimensioned
  attack, under both sequential arrivals and balanced, concurrent trees:
  requests, `eth_getLogs` ranges and response bytes.
- Ingestion and disputes running together against one provider quota, with
  the steady-state input workloads above.
- The whole path from an action's eligibility to its inclusion. Each
  response's budget is `G = 5 minutes` (dispute-game.md), and RPC shares it
  with polling, proof preparation and submission; lateness beyond it is
  charged to `C`.
- Timeliness under a degraded provider. A tick plans the dispute, then the
  recovery scan, and only then sends the wave (`epoch_manager/mod.rs`). A
  failed scan keeps the prepared dispute work, but its latency delays every
  action. Bounded is not timely: a range whose `eth_getLogs` times out at
  every size costs about log2(range) + 1 sequential 20 s attempts, about
  4m40s for 10,000 blocks, and after a restart the recovery walk spans the
  epoch's whole history. Time a prepared dispute action through a degraded
  scan and a large live tree before changing anything. A finality stall
  widens the unfinalized tail every tick refetches whole for each log
  request (one per 100 tournaments of a level): a week on Ethereum is about
  50,400 blocks, 15 sequential calls per request behind a fast-failing
  10,000-block cap and 63 behind 2,000, or seven 20 s timeouts behind a
  provider that times out above 10,000 blocks (a lead to measure). A request
  for 100 tournaments returns up to 100 times one tournament's logs, so
  result-count and response-size caps bind at a narrower range than they did
  per tournament, and clear by the same splitting (also a lead).
- How each supported client and hosted provider answers `eth_getLogs` over
  a range that ends past its own head: with an error, or with a clamped,
  short result. The tournament fold trusts log completeness, and a
  load-balanced or proxied endpoint mixes backends a few blocks apart
  within one harvest, so a short result would be silent there.
- Hosted plans' caps (Infura, Alchemy, a self-hosted node) against the
  measured load. The live tests (`just test-live-rpc`) are the first data
  points: one 10,000-block chunk of USDC logs (349,084) took 138 s on
  Infura, and Alchemy's free tier caps `eth_getLogs` at 10 blocks. A filter's
  address list is one more cap: the tournament reader and the recovery walk
  send up to 100 addresses per request (geth refuses more than 1,000 by
  default). A provider that refuses 100 fails those reads at every range;
  which do is measured under "The filter's address cap" below.

Sybils buy read load. On the two-level table each live child tournament
costs the adversary about two root bonds (about 0.72 ETH at 50 gwei). The
log reads grow with the live tournaments a hundred times slower than they
did: a harvest (the latest tail every tick, and the finalized range on a
tick whose finalized head advanced) reads a root with 1,000 live children in
11 sequential `eth_getLogs`, where one request per tournament took 1,001
(both counted on a mocked chain) and, at 0.1-0.2 s per call, most of `G`
before the Hero acted. What still costs one call per live tournament is the
point reads, sixteen at a time: one `tournamentStanding` per live tournament
at the event head, and one `bondRecovery` per open tournament at the
finalized head. Around 1,000 live children that is about 2,000 calls a tick,
some 13-25 s if a round of sixteen takes one call's latency (a lead to
measure).

If reads dominate, the first lever is which reads the next action needs:
reading only the tournaments on the honest commitment's path would make the
reads follow the work. The smaller one, which keeps the full fold, is taken:
the reader fetches each level of live tournaments with multi-address
`eth_getLogs`, as the recovery walk reads its generations (up to 100
addresses per request). Then come the tick's ordering and the read
concurrency. Failure isolation and more retries come last: dispute
planning's reads still fail together under a per-second cap, but that is worth
machinery only once measured.

Considered and left out: splitting a filter's address list when a one-block
read fails. A block's tournament logs are bounded by its gas, and one
tournament can spend the whole block, so the bound is the same for one address
as for a hundred. An advance costs 86,000 to 106,000 gas in the gas witnesses
(`TournamentGas.t.sol`) and emits two logs, which puts a 60M-gas block on the
order of a thousand tournament logs (a lead: cheaper shapes are not measured).
A level's read therefore asks no more of a provider on one block than one
tournament's read did, and a provider that fails the one would fail the other
at the same density. A provider that refuses the filter itself fails at every
range, a different failure, taken up next.

## The filter's address cap

Measured on 2026-11-17 with one block of USDC logs through filters of 1, 10,
11 and 100 addresses, and with the live test of a 100-address filter:

- Infura and Alchemy (mainnet, keyed): the live test passed, 386 logs alone
  and among 100 addresses.
- dRPC, Tenderly's public gateway and MEV Blocker: 100 answered.
- PublicNode's shared endpoints, mainnet and Sepolia: more than 10 refused
  ("A maximum of 10 addresses is allowed").
- BlockRazor's public endpoint: more than 10 refused with geth's own error
  ("exceed max addresses or topics per search position"), so its geth limit
  is lowered.

The address count did not move latency: the same 8,389 logs over 100 blocks
took a median 811 ms through 1 address and 818 ms through 10 (12 samples
each). What else the capped endpoints refuse:

- PublicNode mainnet: logs older than about 10,000 blocks, some 33 hours, and
  state older than about 100 blocks, which is where the finalized block sits
  (head-100 answered once and was refused once). 960 `eth_call` sent sixteen
  at a time were all answered, median 195 ms.
- BlockRazor: log ranges over 25 blocks, pruned old blocks, and 233 of 320
  `eth_call` sent sixteen at a time (429).
- PublicNode Sepolia: ranges over 50,000 blocks, and state older than 140 to
  160 blocks (head-140 answered, head-160 refused). One block of logs
  8,000,000 blocks back answered. A 50,000-block range was once refused as
  pruned history, which reads like backends that disagree (a lead).

The node keeps 100 addresses per filter (`MAX_FILTER_ADDRESSES`). On mainnet
the capped endpoints cannot carry a node for reasons the address list has no
part in: a node ingests from the application's deployment and a restart
refetches each live tournament from its creation, while those endpoints serve
a day and a half of logs, or 25-block ranges. A lower cap buys nothing there.
The one capped endpoint found that otherwise serves a node is a free shared
testnet endpoint, where the cap binds only in a dispute with more than 10
tournaments open (at one level for the reader, in all for the recovery walk).
Against that, a harvest sends, per level, one request per cap of live
tournaments, in sequence, and the live tournaments are what an adversary pays
to enlarge. On the two-level table a cap of 10 changes nothing up to 10 live
children; 100 children then cost 11 requests where they cost 2, and 1,000 cost
101 where they cost 11. At 0.2 s a round trip that is 1.8 s and 18 s more per
harvest, beside point reads that do not change (about two per live tournament,
sixteen at a time: 2.5 s and 25 s).

What reopens this: an endpoint that operators are expected to run a mainnet
node on and that caps a filter below 100. The levers then are a lower
constant, or fetching a level's chunks concurrently as the point reads are,
which removes the sequential cost of a lower cap.
