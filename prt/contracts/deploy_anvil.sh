#!/usr/bin/env bash

set -euo pipefail

INITIAL_HASH=`xxd -p -c32 "${MACHINE_PATH}/hash"`
LEVELS=3
LOG2STEP='[41,26,0]'
HEIGHT='[27,15,26]'

export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script \
    script/TopTournament.s.sol \
    --fork-url "http://127.0.0.1:8545" \
    --broadcast \
    --sig "run(bytes32,uint64,uint64[],uint64[])" \
    "${INITIAL_HASH}" \
    "${LEVELS}" \
    "${LOG2STEP}" \
    "${HEIGHT}" \
    -vvvv
