#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

roots=(
    '../../prt/contracts'
    'dependencies/cartesi-rollups-contracts-3.0.0-alpha.3'
    '.'
)

for root in "${roots[@]}"
do
    forge script --root "$root" DeploymentScript "$@"
done
