#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

chain_ids=(
    84532      # Base Sepolia
    421614     # Arbitrum Sepolia
    11155111   # Ethereum Sepolia
    11155420   # OP Sepolia
)

for chain_id in "${chain_ids[@]}"
do
    ./script/deploy.sh --chain-id "$chain_id" "$@"
done
