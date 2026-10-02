#!/usr/bin/env bash
# Set up this worktree. With SOURCE, a green sibling worktree, adopt its
# devnet and machine images instead of building them (the devnet takes
# minutes, the honeypot docker). The fingerprint checkers are the guard: a
# copy is kept only if it verifies against this checkout.
set -euo pipefail

(($# <= 1)) || { echo "usage: script/bootstrap-worktree.sh [SOURCE]" >&2; exit 2; }
source_root=
if [[ -n "${1:-}" ]]; then source_root="$(cd -- "$1" && pwd -P)"; fi
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ -z "$source_root" ]]; then
    just setup
    just bind
    exec just doctor
fi
[[ "$source_root" != "$(pwd -P)" ]] || { echo "error: SOURCE must be another worktree" >&2; exit 2; }

verify() {
    case "$1" in
        devnet) script/devnet-fingerprint.sh verify ;;
        *) script/machine-image-fingerprint.sh verify "$1" ;;
    esac
}

paths() {
    case "$1" in
        devnet) echo cartesi-rollups/contracts/{state.json,deployments,state.fingerprint} ;;
        *) echo "test/programs/$1/machine-image" "test/programs/$1/machine-image.fingerprint" ;;
    esac
}

# Keep a verified ARTIFACT, else adopt SOURCE's copy if it verifies here.
# Fails, leaving nothing unverified behind, when neither does.
adopt() {
    local path
    if verify "$1" >/dev/null 2>&1; then echo "kept verified $1"; return; fi
    for path in $(paths "$1"); do
        rm -rf -- "$path"
        if [[ -e "$source_root/$path" ]]; then cp -R -- "$source_root/$path" "$path"; fi
    done
    if verify "$1" >/dev/null 2>&1; then echo "copied verified $1"; return; fi
    rm -rf -- $(paths "$1")
    echo "SOURCE has no $1 that verifies here"
    return 1
}

# download-deps then verifies these copies and refetches a bad one.
for dep in test/programs/{linux.bin,rootfs.ext2}; do
    if [[ ! -e "$dep" && -f "$source_root/$dep" ]]; then cp -- "$source_root/$dep" "$dep"; fi
done
just machine::setup
just prt-contracts::install-deps
just rollups-contracts::install-deps
just programs::download-deps
just bind

adopt devnet || just rollups-contracts::build-devnet
adopt echo || just programs::build-echo
adopt yield || just programs::build-yield
adopt honeypot || echo "the honeypot image is opt-in: just programs::build-honeypot"
exec just doctor-all
