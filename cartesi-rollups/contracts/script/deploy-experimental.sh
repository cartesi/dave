#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# The registered public chains other than Ethereum and Sepolia: experimental,
# not supported (docs/dispute-game.md, Clock model).
chain_ids=(
    10         # OP Mainnet
    8453       # Base Mainnet
    42161      # Arbitrum One (the node does not start there)
    84532      # Base Sepolia
    421614     # Arbitrum Sepolia (the node does not start there)
    11155420   # OP Sepolia
)

for chain_id in "${chain_ids[@]}"
do
    ./script/deploy.sh --chain-id "$chain_id" "$@"
done
