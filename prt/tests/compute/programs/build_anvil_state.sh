#!/usr/bin/env bash
set -euo pipefail
program_path=$1

mkdir -p $program_path

# start anvil with dump state
rm -f $program_path/anvil_state.json
anvil --preserve-historical-states --slots-in-an-epoch 1 \
    --dump-state $program_path/anvil_state.json > $program_path/_anvil.log 2>&1 &
anvil_pid=$!
sleep 5


# deploy smart contracts
initial_hash=`xxd -p -c32 "${program_path}/machine-image/hash"`
just -f ../../../contracts/justfile deploy-dev $initial_hash


# generate address file
rm -f $program_path/addresses

jq -r '.transactions[] | select(.transactionType=="CALL") | select(.contractName=="MultiLevelTournamentFactory") .additionalContracts[0].address' \
    ../../../contracts/broadcast/TopTournament.s.sol/31337/run-latest.json \
    >> $program_path/addresses

cast rpc anvil_mine 2

#
# kill anvil, thus dumping its state, to be loaded later by tests
kill -INT "$anvil_pid"
wait $anvil_pid
