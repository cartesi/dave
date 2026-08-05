#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

deployment_complete=0
build_fingerprint=$(../../script/devnet-fingerprint.sh inputs)
base_contracts=dependencies/cartesi-rollups-contracts-3.0.0-alpha.6

cleanup() {
    exit_code=$?
    trap - EXIT
    if kill -0 "$anvil_pid" 2>/dev/null
    then
        echo "Killing Anvil (PID $anvil_pid)..."
        kill "$anvil_pid"
        echo "Waiting for Anvil to finish..."
        if wait "$anvil_pid"
        then
            echo "Anvil exited with code 0"
        else
            anvil_exit_code=$?
            echo "Anvil exited with code $anvil_exit_code" >&2
            if [[ "$exit_code" -eq 0 ]]
            then
                exit_code=$anvil_exit_code
            fi
        fi
    else
        echo "Anvil (PID $anvil_pid) exited prematurely" >&2
        wait "$anvil_pid" 2>/dev/null || true
        if [[ "$exit_code" -eq 0 ]]
        then
            exit_code=1
        fi
    fi

    if [[ "$exit_code" -eq 0 && "$deployment_complete" -eq 1 ]]
    then
        if [[ ! -s state.json || ! -d deployments/31337 ]]
        then
            echo "error: Anvil did not publish a complete devnet bundle" >&2
            exit_code=1
        else
            if ../../script/devnet-fingerprint.sh write "$build_fingerprint" \
                cartesi-rollups/contracts
            then
                echo "state fingerprint: $(cat state.fingerprint)"
            else
                exit_code=1
            fi
        fi
    fi
    exit "$exit_code"
}

# The fingerprint is the bundle-completeness marker readers check
# before touching any artifact: drop it first, so no reader can see a
# valid marker next to a partially deleted bundle.
rm -f state.fingerprint state.fingerprint.pending
rm -rf deployments "$base_contracts/deployments" \
    ../../prt/contracts/deployments \
    state.json
forge clean --root ../../prt/contracts
forge clean --root "$base_contracts"
forge clean --root .

echo "Spawning Anvil..."

anvil --dump-state state.json --preserve-historical-states --quiet &
anvil_pid=$!
trap cleanup EXIT

echo "Anvil spawned"

wait_for_anvil() {
    delay=0.5
    for i in {1..10}
    do
        echo "Pinging Anvil..."
        if cast chain-id >/dev/null 2>/dev/null
        then
            echo "Anvil is listening"
            return
        else
            echo "Anvil is not listening yet. Waiting $delay seconds..."
            sleep "$delay"
        fi
    done

    >&2 echo "Anvil did not respond within a reasonable amount of time."
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

# The EXIT trap stops Anvil first, which makes it dump state.json, then
# publishes the source fingerprint. Interrupted builds leave no marker.
deployment_complete=1
