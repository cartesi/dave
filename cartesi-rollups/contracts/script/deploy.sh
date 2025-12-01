#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

roots=(
    '../../prt/contracts'
    'dependencies/cartesi-rollups-contracts-2.1.1'
    '.'
)

for root in "${roots[@]}"
do
    forge script --root "$root" DeploymentScript "$@"
done
