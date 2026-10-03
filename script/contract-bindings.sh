#!/usr/bin/env bash
# Generate or verify a contract project's Rust bindings against a stamp of
# everything that could change them. Stale bindings fail loudly at compile or
# test time, so the stamp only spares an unchanged forge bind: it hashes
# broadly and accepts the occasional needless regeneration.
set -euo pipefail

usage() {
    printf 'usage: script/contract-bindings.sh generate|verify prt|rollups\n' >&2
    exit 2
}

(($# == 2)) || usage
case "$1" in generate | verify) ;; *) usage ;; esac
readonly action=$1 module=$2
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly self="${script_dir}/$(basename -- "${BASH_SOURCE[0]}")"
readonly repo_root="${script_dir%/script}"
case "$module" in
    prt)
        cd "${repo_root}/prt/contracts"
        select='^(CartesiStateTransition|MultiLevelTournamentFactory|Tournament)$'
        ;;
    rollups)
        cd "${repo_root}/cartesi-rollups/contracts"
        select='^(I?DaveConsensus|I?DaveAppFactory)$'
        ;;
    *) usage ;;
esac
readonly bindings=bindings-rs/src/contract stamp=bindings-rs/src/.bind-stamp

# forge bind builds the whole project first; empty test and script roots keep
# that build to the production sources.
export FOUNDRY_TEST=.no-binding-tests FOUNDRY_SCRIPT=.no-binding-scripts

# Both modules hash every production source root either one imports. A
# missing root (machine/step before just machine::setup) is a setup gap, so
# it reads as stale rather than as a checker failure.
roots=(prt/contracts/src cartesi-rollups/contracts/src machine/step/src)
for root in "${roots[@]}"; do
    if [[ ! -d "${repo_root}/${root}" ]]; then
        printf 'error: binding source root %s is missing\n' "$root" >&2
        exit 1
    fi
done
inputs() {
    # The Etherscan key alone comes from the shell (ETHERSCAN_API_KEY) and
    # cannot change a binding, so it is pinned to its unset value.
    cat -- "$self" "${repo_root}"/{prt,cartesi-rollups}/contracts/soldeer.lock &&
        forge --version &&
        forge config --json | jq -c '.etherscan_api_key = null' &&
        (cd "$repo_root" && find "${roots[@]}" -type f -name '*.sol' -print0 |
            LC_ALL=C sort -z | xargs -0 sha256sum)
}

current="$(inputs | sha256sum)" || {
    printf 'error: cannot hash the %s binding inputs\n' "$module" >&2
    exit 2
}
current=${current%% *}
if [[ -s "${bindings}/mod.rs" && "$(cat "$stamp" 2>/dev/null)" == "$current" ]]; then
    printf '%s Rust bindings are up to date\n' "$module"
    exit 0
elif [[ "$action" == verify ]]; then
    printf 'error: %s Rust bindings are missing or stale\n' "$module" >&2
    exit 1
fi

# Dropping the stamp first means an interrupted generation reads as stale.
rm -rf -- "$stamp" "$bindings"
forge bind --force --alloy --alloy-version 2 --select "$select" --module \
    --bindings-path "./${bindings}" --skip-extra-derives --root .
printf '%s\n' "$current" >"$stamp"
