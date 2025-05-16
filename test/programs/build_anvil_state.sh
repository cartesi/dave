#!/usr/bin/env bash
set -euo pipefail
program_path=$1

mkdir -p $program_path

# make sure anvil is cleaned up on exit or error
anvil_pid=""
cleanup() {
    if [[ -n "$anvil_pid" ]] && kill -0 "$anvil_pid" 2>/dev/null; then
        echo "Cleaning up anvil process (PID $anvil_pid)..."
        kill -INT "$anvil_pid"
        wait "$anvil_pid" || true
    fi
}
trap cleanup EXIT

# start anvil with dump state
rm -f $program_path/anvil_state.json
anvil --preserve-historical-states --slots-in-an-epoch 1 \
    --dump-state $program_path/anvil_state.json > $program_path/_anvil.log 2>&1 &
anvil_pid=$!
sleep 5


# deploy smart contracts
initial_hash=0x`xxd -p -c32 "${program_path}/machine-image/hash"`
just -f ../../cartesi-rollups/contracts/justfile deploy-dev $initial_hash


# generate address file
rm -f $program_path/addresses

jq -r '.address' ../../cartesi-rollups/contracts/deployments/InputBox.json >> $program_path/addresses
jq -r '.address' ../../cartesi-rollups/contracts/deployments/DaveConsensusInstance.json >> $program_path/addresses
jq -r '.address' ../../cartesi-rollups/contracts/deployments/ApplicationInstance.json >> $program_path/addresses

cast rpc anvil_mine 2

#
# kill anvil, thus dumping its state, to be loaded later by tests
cleanup
