#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    printf 'usage: %s EXPECTED_FOUNDRY_VERSION EXPECTED_DEPENDENCIES_SHA256\n' \
        "$0" >&2
    exit 2
fi

readonly EXPECTED_FOUNDRY_VERSION="$1"
readonly EXPECTED_DEPENDENCIES_SHA256="$2"
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

dependency_digest=$(find dependencies -type f -print0 \
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

printf 'revision: %s\n' "$revision"
printf '%s\n' "$version_output"
printf 'effective config: %s\n' "$effective_config"
printf 'dependencies sha256: %s\n' "$dependency_digest"
sha256sum foundry.toml soldeer.lock
git submodule status --recursive
forge test --force --threads 1 --color never \
    --match-path "test/gas/TournamentGas.t.sol" -vv
