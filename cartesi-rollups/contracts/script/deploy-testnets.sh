#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# Ethereum Sepolia, the one supported testnet. The other registered chains are
# in deploy-experimental.sh (docs/dispute-game.md, Clock model).
#
# --skip-simulation takes each gas limit from the chain's eth_estimateGas, not
# from Forge's local simulation. That simulation runs the pinned evm_version
# (prague), so on a chain past Glamsterdam it underprices code deposit
# (EIP-8037) several times over, and every deploy runs out of gas. Forge then
# also waits for each receipt before sending the next transaction.
./script/deploy.sh --chain-id 11155111 --skip-simulation "$@"
