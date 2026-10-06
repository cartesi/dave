# Provider requirements

Status: open, written 2026-10-06 as a brief for a later campaign; linked
from [`docs/todo.md`](../todo.md). When it lands, the requirements move into
the node README's operator notes, their reasoning into
[`dimensioning.md`](../dimensioning.md), and this file is deleted.

## Why

The node assumes a reasonably behaved RPC provider: something has to give,
and no client outlasts an endpoint that stops answering. "Reasonable" is
not written down, so an operator cannot size a plan against it, and the
node's read load is not dimensioned the way its clocks and bonds are. The
goal is a short, measured statement of the minimum provider an honest node
needs (request rate, `eth_getLogs` range and response size, latency) in the
steady state and in a dispute at the dimensioned attack.

## Two regimes

- Steady state: the reads follow inputs. Anyone may add inputs to any
  application, so the worst case is priced by blockspace, as a Sybil is
  priced by its bond: at most a block's calldata throughput of inputs per
  block, each at most the InputBox's maximum size (a lead to compute from
  the gas limit and the EIP-7623 floor). How to dimension an application's
  ordinary input size and rate is open.
- Disputes: the reads grow with the tournaments Sybils create. The attack
  is priced (a join bond per Sybil), and the hero's effort grows about
  logarithmically with the Sybils at each level, so the attack's cost grows
  roughly exponentially with the effort it forces. The reads may not follow
  the effort. Each tick the tournament reader extends every live tournament
  in the tree, the Sybils' own matches included, with one `eth_getLogs`
  each, in sequence (`tournament/reader.rs`); the recovery scan reads the
  disposition of every open tournament. Whether a tick then grows linearly
  with the Sybils, and how that compares with `G`, is a lead to measure.

## What to measure

- The read load per tick in each regime: requests, `eth_getLogs` ranges and
  response bytes, against the Sybil count up to the dimensioned attack.
- Timeliness under a degraded provider. Each response's budget is
  `G = 5 minutes` (dispute-game.md), and lateness beyond it is charged to
  `C`. A tick plans the dispute, then the recovery scan, and only then sends
  the wave (`epoch_manager/mod.rs`), so the scan's latency delays every
  action. Bounded is not timely: a range whose `eth_getLogs` times out at
  every size costs about log2(range) + 1 sequential 20 s attempts, about
  4m40s for 10,000 blocks, and after a restart the recovery walk spans the
  epoch's whole history. Time a prepared dispute action through a degraded
  scan and a large live tree before changing anything; the levers are the
  tick's ordering and concurrency, not more retries.
- Under a provider's per-second cap, one read failing every attempt fails
  the whole tick. The levers are the read concurrency and per-read failure
  isolation.
- Hosted plans' caps (Infura, Alchemy, a self-hosted node) against the
  measured load. The live tests (`just test-live-rpc`) are the first data
  points: one 10,000-block chunk of USDC logs (349,084) took 138 s on
  Infura, and Alchemy's free tier caps `eth_getLogs` at 10 blocks.
