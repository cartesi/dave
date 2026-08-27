#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_FOUNDRY_VERSION="1.5.1-v1.5.1"
readonly EXPECTED_DEPENDENCIES_SHA256="0390394d7559329a94913a96b298a798c16fb03446600ca746760d5942ae6f4d"
readonly EXPECTED_MACHINE_HASH="9b358eac8ebd2aa2c7ab4c00d098da7fd90906dc571ec83ec16e889fd220e0fb"
readonly EXPECTED_FOUNDRY_CONFIG='{"solc":"0.8.30","via_ir":true,"optimizer":true,"optimizer_runs":200,"evm_version":"prague"}'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
contracts_dir=$(cd -- "$script_dir/.." && pwd -P)
cd "$contracts_dir"

diagnostic="${ALLOW_DIAGNOSTIC_GAS_MEASUREMENT:-0}"
foundry_overrides=$(env | sed -n '/^FOUNDRY_/p')
if [ -n "$foundry_overrides" ]; then
    if [ "$diagnostic" != "1" ]; then
        printf '%s\n' \
            'error: clear FOUNDRY_* overrides for gas calibration' >&2
        exit 1
    fi
    printf '%s\n' \
        'warning: FOUNDRY_* overrides make this report diagnostic only' >&2
fi
export FOUNDRY_PROFILE=default

revision=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    revision="$revision (dirty)"
    if [ "$diagnostic" != "1" ]; then
        printf '%s\n' \
            'error: authoritative gas calibration requires a clean worktree' >&2
        exit 1
    fi
    printf '%s\n' \
        'warning: dirty worktree makes this report diagnostic only' >&2
fi

version_output=$(forge --version)
actual_version=$(printf '%s\n' "$version_output" \
    | sed -n 's/^forge Version: //p')
if [ "$actual_version" != "$EXPECTED_FOUNDRY_VERSION" ]; then
    if [ "$diagnostic" != "1" ]; then
        printf 'error: gas calibration requires Forge %s, found %s\n' \
            "$EXPECTED_FOUNDRY_VERSION" "$actual_version" >&2
        exit 1
    fi
    printf 'warning: unpinned Forge %s; report is diagnostic only\n' \
        "$actual_version" >&2
fi

effective_config=$(forge config --json | jq -c \
    '{solc, via_ir, optimizer, optimizer_runs, evm_version}')
if [ "$effective_config" != "$EXPECTED_FOUNDRY_CONFIG" ]; then
    if [ "$diagnostic" != "1" ]; then
        printf 'error: unexpected effective Foundry config: %s\n' \
            "$effective_config" >&2
        exit 1
    fi
    printf 'warning: unexpected effective config: %s\n' \
        "$effective_config" >&2
fi

# Soldeer may retain nested Git metadata, and dependencies may contain build
# output. Neither is a compiler input or stable across equivalent restores.
dependency_digest=$( \
    find dependencies ../../prt/contracts/dependencies -type f \
    ! -path '*/.git/*' ! -name '.git' \
    ! -path '*/broadcast/*' ! -path '*/cache/*' \
    ! -path '*/deployments/*' ! -path '*/out/*' -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum \
    | cut -d' ' -f1)
if [ "$dependency_digest" != "$EXPECTED_DEPENDENCIES_SHA256" ]; then
    if [ "$diagnostic" != "1" ]; then
        printf 'error: unexpected dependency digest: %s\n' \
            "$dependency_digest" >&2
        exit 1
    fi
    printf 'warning: unexpected dependency digest: %s\n' \
        "$dependency_digest" >&2
fi

if ! command -v cartesi-machine-stored-hash >/dev/null; then
    printf '%s\n' \
        'error: cartesi-machine-stored-hash is required; enter the dev shell' >&2
    exit 1
fi
for tool in lua cartesi-machine; do
    if ! command -v "$tool" >/dev/null; then
        printf 'error: %s is required; enter the dev shell\n' "$tool" >&2
        exit 1
    fi
done

machine_hash=$( \
    cartesi-machine-stored-hash ../../test/programs/yield/machine-image)
machine_hash=${machine_hash#0x}
if [ "$machine_hash" != "$EXPECTED_MACHINE_HASH" ]; then
    if [ "$diagnostic" != "1" ]; then
        printf 'error: unexpected yield machine hash: %s\n' \
            "$machine_hash" >&2
        exit 1
    fi
    printf 'warning: unexpected yield machine hash: %s\n' \
        "$machine_hash" >&2
fi

lua_version=$(lua -v 2>&1)
machine_version=$(cartesi-machine --version)
cartesi_lua=$( \
    lua -e 'io.write(assert(package.searchpath("cartesi", package.cpath)))')
cartesi_lua_hash=$(sha256sum "$cartesi_lua" | cut -d' ' -f1)

printf 'revision: %s\n' "$revision"
printf '%s\n' "$version_output"
printf 'effective config: %s\n' "$effective_config"
printf 'dependencies sha256: %s\n' "$dependency_digest"
printf 'yield machine hash: %s\n' "$machine_hash"
printf 'lua: %s\n' "$lua_version"
printf '%s\n' "$machine_version"
printf 'cartesi lua module: %s\n' "$cartesi_lua"
printf 'cartesi lua module sha256: %s\n' "$cartesi_lua_hash"
sha256sum foundry.toml soldeer.lock \
    ../../prt/contracts/foundry.toml ../../prt/contracts/soldeer.lock
git submodule status --recursive

measurement_args=(--force --color never -vv)
"$script_dir/test-prt-leaf-gas.sh" "${measurement_args[@]}"
