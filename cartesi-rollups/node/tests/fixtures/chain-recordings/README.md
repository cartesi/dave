# Chain recordings

Raw devnet log ranges captured after e2e disputes settle: every log
the chain emitted (unfiltered, undecoded) plus the timestamp of each
block carrying one. They are the oracle material for the
tournament-state fold (docs/plans/node-refactor.md, workstream 5):
fold tests decode these through the same bindings the production
fetcher uses, so the fixtures cannot bake in decoding assumptions.

Regenerate from prt/tests/rollups (the node and record_chain binaries
must be built):

```
RECORD_CHAIN_FIXTURE=<absolute path to this dir>/echo_simple.json \
  just test-echo

RECORD_CHAIN_FIXTURE=<absolute path to this dir>/multilevel_stf.json \
  just test-honeypot-stf

RECORD_CHAIN_FIXTURE=<absolute path to this dir>/multi_sybil.json \
  just test-multi-sybil
```

echo_simple is one dispute descending all three levels; multilevel_stf
is the state-transition suite's five epochs, one steered dispute per
on-chain transition shape.

The hook lives in test_env.lua's run_epoch: it records after each
epoch settles, so a multi-epoch scenario's final recording contains
the whole run. Committing a regenerated fixture is a reviewed act,
like every fixture in this repo.
