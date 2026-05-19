#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

chain_ids=(
    1          # Ethereum Mainnet
    10         # OP Mainnet
    8453       # Base Mainnet
    42161      # Arbitrum Mainnet
)

for chain_id in "${chain_ids[@]}"
do
    ./script/deploy.sh --chain-id "$chain_id" "$@"
done
