#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

roots=(
    '../../prt/contracts'
    'dependencies/cartesi-rollups-contracts-2.2.0'
    '.'
)

for root in "${roots[@]}"
do
    forge script --root "$root" DeploymentScript "$@"
done
