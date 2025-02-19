#!/usr/bin/env bash

set -euo pipefail

INITIAL_HASH=`xxd -p -c32 "${MACHINE_PATH}/hash"`

export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

inputbox_script="forge script \
    script/InputBox.s.sol \
    --fork-url 'http://127.0.0.1:8545' \
    --broadcast \
    --non-interactive \
    --sig 'run()' \
    -vvvv 2>&1"

deploy_inputbox=$(eval $inputbox_script)
inputbox_addresses=$(echo $deploy_inputbox | grep -oP 'new InputBox@(0x[a-fA-F0-9]{40})' | grep -oP '0x[a-fA-F0-9]{40}')
INPUTBOX_ADDRESS=$(echo $inputbox_addresses | cut -d ' ' -f 1)
echo $INPUTBOX_ADDRESS

daveconsensus_script="forge script \
    script/DaveConsensus.s.sol \
    --fork-url 'http://127.0.0.1:8545' \
    --broadcast \
    --non-interactive \
    --sig 'run(bytes32,address)' \
    '$INITIAL_HASH' \
    '$INPUTBOX_ADDRESS' \
    -vvvv 2>&1"

deploy_daveconsensus=$(eval $daveconsensus_script)
daveconsensus_addresses=$(echo $deploy_daveconsensus | grep -oP 'new DaveConsensus@(0x[a-fA-F0-9]{40})' | grep -oP '0x[a-fA-F0-9]{40}')
DAVECONSENSUS_ADDRESS=$(echo $daveconsensus_addresses | cut -d ' ' -f 1)
echo $DAVECONSENSUS_ADDRESS
