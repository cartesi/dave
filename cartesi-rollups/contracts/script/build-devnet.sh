#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

cleanup() {
    exit_code=$?
    if kill -0 "$anvil_pid" 2>/dev/null
    then
        echo "🚧 Killing Anvil (PID $anvil_pid)..."
        kill "$anvil_pid"
        echo "🚧 Waiting for Anvil to finish...."
        wait "$anvil_pid"
        anvil_exit_code=$?
        if [[ "$anvil_exit_code" -eq 0 ]]
        then
            echo "✅ Anvil exited with code $anvil_exit_code"
        else
            echo "❌ Anvil exited with code $anvil_exit_code"
            if [[ "$exit_code" -eq 0 ]]
            then
                exit_code=$anvil_exit_code
            fi
        fi
    else
        echo "💡 Anvil (PID $anvil_pid) exited prematurely"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

echo "🚧 Spawning Anvil..."

anvil --dump-state state.json --preserve-historical-states --quiet &
anvil_pid=$!

echo "✅ Anvil spawned!"

wait_for_anvil() {
    delay=0.5
    for i in {1..10}
    do
        echo "🚧 Pinging Anvil..."
        if cast chain-id >/dev/null 2>/dev/null
        then
            echo "✅ Anvil is listening!"
            return
        else
            echo "🚧 Anvil is not listening yet. Waiting $delay ms..."
            sleep "$delay"
        fi
    done

    >&2 echo "❌ Anvil did not respond within a reasonable amount of time."
    exit 1
}

wait_for_anvil

rpc_url='http://127.0.0.1:8545'
private_key='0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

./script/deploy.sh \
    --broadcast \
    --non-interactive \
    --private-key "$private_key" \
    --rpc-url "$rpc_url" \
    --slow
