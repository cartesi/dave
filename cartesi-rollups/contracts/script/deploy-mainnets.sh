#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# Every registered mainnet; only Ethereum is supported (docs/dispute-game.md,
# Clock model).
chain_ids=(
    1          # Ethereum Mainnet (supported)
    10         # OP Mainnet (experimental)
    8453       # Base Mainnet (experimental)
    42161      # Arbitrum One (experimental; the node does not run there)
)

for chain_id in "${chain_ids[@]}"
do
    ./script/deploy.sh --chain-id "$chain_id" "$@"
done
