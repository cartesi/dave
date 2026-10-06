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
  own matches included, with one `eth_getLogs` each, in sequence
  (`tournament/reader.rs`), and the recovery scan reads the disposition of
  every open tournament. Resolved matches and their children are dropped,
  so the reads track the live population, which at a dispute's start can
  be linear in the Sybils.

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
  scan and a large live tree before changing anything.
- Hosted plans' caps (Infura, Alchemy, a self-hosted node) against the
  measured load. The live tests (`just test-live-rpc`) are the first data
  points: one 10,000-block chunk of USDC logs (349,084) took 138 s on
  Infura, and Alchemy's free tier caps `eth_getLogs` at 10 blocks.

If reads dominate, the first lever is which reads the next action needs:
reading only the tournaments on the honest commitment's path would make
the reads follow the work. Then come the tick's ordering and the read
concurrency. Failure isolation and
more retries come last: dispute planning's reads still fail together under
a per-second cap, but that is worth machinery only once measured.
