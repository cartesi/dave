#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# Ethereum Mainnet, the one supported mainnet. The other registered chains are
# in deploy-experimental.sh (docs/dispute-game.md, Clock model).
./script/deploy.sh --chain-id 1 "$@"
