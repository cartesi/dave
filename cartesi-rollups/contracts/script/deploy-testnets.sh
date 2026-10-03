#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# Every registered testnet; only Ethereum Sepolia is supported
# (docs/dispute-game.md, Clock model).
chain_ids=(
    84532      # Base Sepolia (experimental)
    421614     # Arbitrum Sepolia (experimental; the node does not run there)
    11155111   # Ethereum Sepolia (supported)
    11155420   # OP Sepolia (experimental)
)

for chain_id in "${chain_ids[@]}"
do
    ./script/deploy.sh --chain-id "$chain_id" "$@"
done
