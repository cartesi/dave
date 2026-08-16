#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'preflight: %s\n' "$1" >&2
    printf "preflight: run 'just doctor-all' at the repo root for a full diagnosis\n" >&2
    exit 1
}

if (($# != 2)); then
    fail "expected PROGRAM and SCENARIO"
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
    || fail "cannot resolve the preflight script directory"
e2e_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" \
    || fail "cannot resolve the E2E directory"
repo_root="$(CDPATH= cd -- "${e2e_dir}/../../.." && pwd -P)" \
    || fail "cannot resolve the repository root"
readonly script_dir e2e_dir repo_root

readonly program=$1
readonly scenario=$2
readonly devnet_dir="${repo_root}/cartesi-rollups/contracts"
readonly devnet_checker="${repo_root}/script/devnet-fingerprint.sh"
readonly image_checker="${repo_root}/script/machine-image-fingerprint.sh"

[[ "$program" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe program name"
[[ "$scenario" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe scenario name"
[[ -f "${e2e_dir}/scenarios/${scenario}.lua" ]] \
    || fail "scenarios/${scenario}.lua missing"
[[ -f "${devnet_dir}/state.json" ]] \
    || fail "devnet state.json missing (just rollups-contracts::build-devnet)"
[[ -d "${devnet_dir}/deployments/31337" ]] \
    || fail "devnet deployments missing (just rollups-contracts::build-devnet)"

for tool in anvil cast lua5.4 cartesi-machine \
    cartesi-machine-stored-hash forge git jq realpath sha256sum \
    sort sqlite3; do
    command -v "$tool" >/dev/null || fail "$tool not on PATH"
done

"$devnet_checker" verify >/dev/null 2>&1 \
    || fail "devnet bundle is stale, mixed, or unverified (just rollups-contracts::build-devnet)"
"$image_checker" verify "$program" >/dev/null 2>&1 \
    || fail "test/programs/$program/machine-image is stale or unverified (rebuild it under test/programs)"
[[ -x "${repo_root}/target/debug/cartesi-rollups-prt-node" ]] \
    || fail "node binary not built (just build-rust-workspace at the repo root)"
