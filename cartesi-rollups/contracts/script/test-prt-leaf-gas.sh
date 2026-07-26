#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
contracts_dir=$(cd -- "$script_dir/.." && pwd -P)
cd "$contracts_dir"

# The Lua proof generator interpolates TEST_INSTANCE into its scratch path.
instance="${TEST_INSTANCE:-prt-leaf-gas-$$}"
if [[ ! "$instance" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'error: unsafe TEST_INSTANCE: %s\n' "$instance" >&2
    exit 1
fi

# One Forge run shares this native-machine snapshot store, so it must own the
# directory and serialize the FFI writers.
scratch="_machine_scratch-$instance"
if ! mkdir -- "$scratch" 2>/dev/null; then
    if [ -e "$scratch" ]; then
        printf 'error: scratch path already exists: %s\n' "$scratch" >&2
    else
        printf 'error: could not create scratch path: %s\n' "$scratch" >&2
    fi
    exit 1
fi
trap 'rm -rf -- "$scratch"' EXIT

TEST_INSTANCE="$instance" forge test "$@" --threads 1 \
    --match-path "test/gas/PrtLeafProofGasFfi.t.sol" --ffi
