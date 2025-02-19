#!/usr/bin/env bash

set -euo pipefail

INITIAL_HASH=`xxd -p -c32 "${MACHINE_PATH}/hash"`

export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge_script="forge script \
    script/TopTournament.s.sol \
    --fork-url 'http://127.0.0.1:8545' \
    --broadcast \
    --non-interactive \
    --sig 'run(bytes32)' \
    '${INITIAL_HASH}' \
    -vvvv 2>&1"

output=$(eval $forge_script)
top_tournament_addresses=$(echo $output | grep -oP 'new TopTournament@(0x[a-fA-F0-9]{40})' | grep -oP '0x[a-fA-F0-9]{40}')
top_tournament_address=$(echo $top_tournament_addresses | cut -d ' ' -f 1)

echo $top_tournament_address
