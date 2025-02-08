#!/usr/bin/env bash
set -euo pipefail
program_path=$1

mkdir -p $program_path

# start anvil with dump state
rm -f $program_path/anvil_state.json
anvil --disable-code-size-limit --preserve-historical-states --slots-in-an-epoch 1 \
    --dump-state $program_path/anvil_state.json > $program_path/_anvil.log 2>&1 &
anvil_pid=$!
trap 'kill $anvil_pid' EXIT

# wait for anvil to start listening
num_tries=10
while true
do
    if chain_id=$(cast chain-id 2>/dev/null)
    then
        if [[ $chain_id == 31337 ]]
        then
            >&2 echo "Anvil is listening."
            break
        else
            >&2 echo "Anvil has unexpected chain ID $chain_id."
            exit 1
        fi
    else
        if kill -0 $anvil_pid
        then
            if [[ $num_tries == 0 ]]
            then
                >&2 echo "Anvil is not listening."
                exit 1
            else
                >&2 echo "Waiting for Anvil to start listening... ($num_tries tries left)"
                num_tries=$(( $num_tries - 1 ))
                sleep 1
            fi
        else
            >&2 echo "Anvil exited..."
            exit 1
        fi
    fi
done

# deploy smart contracts
initial_hash=`xxd -p -c32 "${program_path}/machine-image/hash"`
just -f ../../cartesi-rollups/contracts/justfile deploy-dev $initial_hash


# generate address file
rm -f $program_path/addresses

jq -r '.transactions[] | select(.transactionType=="CREATE").contractAddress' \
    ../../cartesi-rollups/contracts/broadcast/InputBox.s.sol/31337/run-latest.json \
    >> $program_path/addresses

jq -r '.transactions[] | select(.transactionType=="CREATE") | select(.contractName=="DaveConsensus") .contractAddress' \
    ../../cartesi-rollups/contracts/broadcast/DaveConsensus.s.sol/31337/run-latest.json \
    >> $program_path/addresses

cast rpc anvil_mine 2
