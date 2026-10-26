#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

# Ethereum Mainnet, the one supported mainnet. The other registered chains are
# in deploy-experimental.sh (docs/dispute-game.md, Clock model).
#
# Gas limits come from the chain, as in deploy-testnets.sh, so the deploy
# follows the gas schedule mainnet runs on either side of Glamsterdam.
./script/deploy.sh --chain-id 1 --skip-simulation "$@"
