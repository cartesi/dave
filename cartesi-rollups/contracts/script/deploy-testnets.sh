#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# Ethereum Sepolia, the one supported testnet. The other registered chains are
# in deploy-experimental.sh (docs/dispute-game.md, Clock model).
./script/deploy.sh --chain-id 11155111 "$@"
